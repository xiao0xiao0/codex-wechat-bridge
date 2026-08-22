param(
    [string]$ModulePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\codex-wechat-bridge\scripts\CodexWeChatBridge.psm1')
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-wechat-bridge-sync-test-{0}" -f [guid]::NewGuid().ToString('N'))
$previousBridgeHome = $env:CODEX_WECHAT_BRIDGE_HOME
$env:CODEX_WECHAT_BRIDGE_HOME = Join-Path $testRoot 'state'
[System.IO.Directory]::CreateDirectory($env:CODEX_WECHAT_BRIDGE_HOME) | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "ASSERTION FAILED: $Message (actual='$Actual', expected='$Expected')"
    }
}

try {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($ModulePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Equal $parseErrors.Count 0 'module must parse without errors'

    Import-Module $ModulePath -Force -DisableNameChecking
    $module = Get-Module CodexWeChatBridge
    Assert-True ($null -ne $module) 'module must import'
    $version = & $module { $script:BridgeVersion }
    Assert-Equal $version '0.9.30' 'module version'

    $cases = @(
        [pscustomobject]@{ name = 'missing'; bytes = $null; expected_reason = 'missing'; had_file = $false },
        [pscustomobject]@{ name = 'empty'; bytes = [byte[]]@(); expected_reason = 'empty'; had_file = $true },
        [pscustomobject]@{ name = 'contains_nul'; bytes = [byte[]](0, 0, 0, 0, 0); expected_reason = 'contains_nul'; had_file = $true },
        [pscustomobject]@{ name = 'invalid_json'; bytes = [Text.Encoding]::UTF8.GetBytes('{'); expected_reason = 'invalid_json'; had_file = $true },
        [pscustomobject]@{ name = 'object_without_cursor'; bytes = [Text.Encoding]::UTF8.GetBytes('{}'); expected_reason = 'missing_cursor'; had_file = $true },
        [pscustomobject]@{ name = 'empty_cursor'; bytes = [Text.Encoding]::UTF8.GetBytes('{"get_updates_buf":""}'); expected_reason = 'empty_cursor'; had_file = $true }
    )

    foreach ($case in $cases) {
        $caseRoot = Join-Path $testRoot $case.name
        [System.IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        $syncPath = Join-Path $caseRoot 'sync.json'
        if ($null -ne $case.bytes) { [System.IO.File]::WriteAllBytes($syncPath, $case.bytes) }

        $before = & $module { param($Path) Get-BridgeSyncState -Path $Path } $syncPath
        Assert-True (-not [bool]$before.valid) "$($case.name) must be invalid before repair"
        Assert-Equal $before.reason $case.expected_reason "$($case.name) invalid reason"

        $repair = & $module {
            param($Path)
            Repair-BridgeSyncCursor -Path $Path -BaseUrl 'https://offline.invalid' -Token 'offline-token' -FetchUpdates {
                [pscustomobject]@{
                    errcode = 0
                    ret = 0
                    get_updates_buf = 'cursor-after-safe-baseline'
                    msgs = @(
                        [pscustomobject]@{ id = 'history-1'; text = '/clear' },
                        [pscustomobject]@{ id = 'history-2'; text = '/help' }
                    )
                }
            }
        } $syncPath

        Assert-True ([bool]$repair.recovered) "$($case.name) must self-heal"
        Assert-Equal $repair.reason $case.expected_reason "$($case.name) recovery reason"
        Assert-Equal $repair.discarded_message_count 2 "$($case.name) replay messages must be discarded"
        $after = & $module { param($Path) Get-BridgeSyncState -Path $Path } $syncPath
        Assert-True ([bool]$after.valid) "$($case.name) must be healthy after repair"
        Assert-Equal $after.cursor 'cursor-after-safe-baseline' "$($case.name) recovered cursor"
        if ($case.had_file) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$repair.backup_path)) "$($case.name) must record a backup"
            Assert-True (Test-Path -LiteralPath ([string]$repair.backup_path) -PathType Leaf) "$($case.name) backup must exist"
        } else {
            Assert-Equal $repair.backup_path '' 'missing cursor has nothing to back up'
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $caseRoot 'sync-recovery.json') -PathType Leaf) "$($case.name) recovery metadata"
    }

    $healthyRoot = Join-Path $testRoot 'healthy'
    [System.IO.Directory]::CreateDirectory($healthyRoot) | Out-Null
    $healthyPath = Join-Path $healthyRoot 'sync.json'
    [System.IO.File]::WriteAllText($healthyPath, '{"get_updates_buf":"known-good-cursor"}', [Text.UTF8Encoding]::new($false))
    $healthyRepair = & $module {
        param($Path)
        Repair-BridgeSyncCursor -Path $Path -BaseUrl 'https://offline.invalid' -Token 'offline-token' -FetchUpdates {
            throw 'FetchUpdates must not run for a healthy cursor.'
        }
    } $healthyPath
    Assert-True (-not [bool]$healthyRepair.recovered) 'healthy cursor must not be replaced'
    Assert-Equal $healthyRepair.cursor 'known-good-cursor' 'healthy cursor must be preserved'

    $preservedRaw = [System.IO.File]::ReadAllText($healthyPath, [Text.Encoding]::UTF8)
    foreach ($badResponse in @(
        [pscustomobject]@{ errcode = 0 },
        [pscustomobject]@{ errcode = 0; get_updates_buf = '' }
    )) {
        $threw = $false
        try {
            & $module { param($Path, $Response) Save-BridgeSyncCursorFromResponse -Path $Path -Response $Response } $healthyPath $badResponse | Out-Null
        } catch {
            $threw = $true
        }
        Assert-True $threw 'malformed server response must fail closed'
        Assert-Equal ([System.IO.File]::ReadAllText($healthyPath, [Text.Encoding]::UTF8)) $preservedRaw 'malformed response must preserve the previous cursor byte-for-byte'
    }

    $inbox = Join-Path $env:CODEX_WECHAT_BRIDGE_HOME 'inbox'
    $executedCount = if (Test-Path -LiteralPath $inbox) {
        @(Get-ChildItem -LiteralPath $inbox -File -ErrorAction SilentlyContinue).Count
    } else { 0 }
    Assert-Equal $executedCount 0 'discarded recovery messages must never enter the execution inbox'

    [pscustomobject]@{
        valid = $true
        version = $version
        invalid_cases = $cases.Count
        replay_messages_discarded_per_case = 2
        healthy_cursor_preserved = $true
        malformed_response_preserved = $true
        recovery_messages_executed = $executedCount
        live_wechat_messages_sent = 0
        live_codex_tasks_created = 0
    } | ConvertTo-Json -Compress
} finally {
    $env:CODEX_WECHAT_BRIDGE_HOME = $previousBridgeHome
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
