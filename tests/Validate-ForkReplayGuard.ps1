$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'plugins\codex-wechat-bridge\scripts\CodexWeChatBridge.psm1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-wechat-fork-guard-" + [guid]::NewGuid().ToString('N'))
$bridgeRoot = Join-Path $tempRoot 'bridge'
$codexRoot = Join-Path $tempRoot 'codex'
$sessionsRoot = Join-Path $codexRoot 'sessions\2026\08\13'
$forkId = '11111111-1111-4111-8111-111111111111'
$missingSourceId = '22222222-2222-4222-8222-222222222222'
$expectedTurnId = 'expected-new-turn'
$inheritedTurnId = 'copied-history-turn'
$incrementalTurnId = 'later-incremental-turn'
$rolloutPath = Join-Path $sessionsRoot "rollout-2026-08-13T00-00-00-$forkId.jsonl"
$statePath = Join-Path $bridgeRoot 'rollout-monitor.json'
$oldBridgeHome = $env:CODEX_WECHAT_BRIDGE_HOME
$oldCodexHome = $env:CODEX_HOME

function ConvertTo-Line {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

try {
    [IO.Directory]::CreateDirectory($sessionsRoot) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $bridgeRoot 'inbox')) | Out-Null
    $env:CODEX_WECHAT_BRIDGE_HOME = $bridgeRoot
    $env:CODEX_HOME = $codexRoot

    $now = [DateTimeOffset]::Now.ToString('o')
    $lines = @(
        ConvertTo-Line ([ordered]@{
            type = 'session_meta'
            payload = [ordered]@{
                id = $forkId
                cwd = $tempRoot
                source = 'vscode'
                thread_source = 'user'
                forked_from_id = $missingSourceId
            }
        })
        ConvertTo-Line ([ordered]@{
            timestamp = $now
            type = 'event_msg'
            payload = [ordered]@{ type = 'task_started'; turn_id = $inheritedTurnId }
        })
        ConvertTo-Line ([ordered]@{
            timestamp = $now
            type = 'event_msg'
            payload = [ordered]@{ type = 'task_started'; turn_id = $expectedTurnId }
        })
    )
    [IO.File]::WriteAllText($rolloutPath, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $relayRecord = [ordered]@{
        relay_state = 'relay_running'
        target_session_id = $forkId
        created_thread_id = $forkId
        codex_turn_id = $expectedTurnId
    }
    [IO.File]::WriteAllText(
        (Join-Path $bridgeRoot 'inbox\relay.json'),
        (ConvertTo-Line $relayRecord),
        [Text.UTF8Encoding]::new($false)
    )

    $monitorState = [ordered]@{
        schema_version = 1
        initialized_at = [DateTimeOffset]::Now.AddMinutes(-1).ToString('o')
        files = [ordered]@{
            $rolloutPath = [ordered]@{
                session_id = $forkId
                cwd = $tempRoot
                user_visible = $true
                forked_from_id = $missingSourceId
                fork_replay_from_zero = $true
                fork_baseline_warning_logged = $false
                offset = 0
                carry = ''
            }
        }
    }
    [IO.File]::WriteAllText($statePath, (ConvertTo-Line $monitorState), [Text.UTF8Encoding]::new($false))

    Import-Module $modulePath -Force
    $module = Get-Module CodexWeChatBridge
    & $module { param($Path) Invoke-CodexRolloutMonitorScan -StatePath $Path } $statePath

    $savedState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $tracked = $savedState.files[$rolloutPath]
    if (-not [bool]$tracked.fork_baseline_warning_logged) { throw 'Missing source baseline warning was not persisted.' }
    if ([bool]$tracked.fork_replay_from_zero) { throw 'Zero replay guard did not close after the expected turn was observed.' }
    if ([long]$tracked.offset -ne [long](Get-Item -LiteralPath $rolloutPath).Length) { throw 'Rollout cursor was not advanced to EOF.' }

    $threadRecordPath = Join-Path $bridgeRoot "threads\$forkId.json"
    $threadRecord = Get-Content -LiteralPath $threadRecordPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$threadRecord.last_turn_id -ne $expectedTurnId) {
        throw "Inherited history was not filtered; recorded turn was $($threadRecord.last_turn_id)."
    }

    $warningPattern = 'Could not load source-turn baseline for fork'
    $warningCount = @(Get-ChildItem -LiteralPath (Join-Path $bridgeRoot 'logs') -File |
        Select-String -SimpleMatch $warningPattern).Count
    if ($warningCount -ne 1) { throw "Expected one baseline warning, found $warningCount." }

    $laterLine = ConvertTo-Line ([ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        type = 'event_msg'
        payload = [ordered]@{ type = 'task_started'; turn_id = $incrementalTurnId }
    })
    [IO.File]::AppendAllText($rolloutPath, ($laterLine + "`n"), [Text.UTF8Encoding]::new($false))
    & $module { param($Path) Invoke-CodexRolloutMonitorScan -StatePath $Path } $statePath

    $threadRecord = Get-Content -LiteralPath $threadRecordPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$threadRecord.last_turn_id -ne $incrementalTurnId) {
        throw 'Normal incremental monitoring did not resume after zero replay closed.'
    }
    $warningCountAfter = @(Get-ChildItem -LiteralPath (Join-Path $bridgeRoot 'logs') -File |
        Select-String -SimpleMatch $warningPattern).Count
    if ($warningCountAfter -ne 1) { throw "Baseline warning repeated; found $warningCountAfter entries." }

    [pscustomobject]@{
        valid = $true
        inherited_turn_filtered = $true
        expected_turn_admitted = $true
        incremental_turn_admitted = $true
        baseline_warning_count = $warningCountAfter
        live_wechat_messages_sent = 0
        live_codex_tasks_created = 0
    } | ConvertTo-Json -Compress
} finally {
    Remove-Module CodexWeChatBridge -Force -ErrorAction SilentlyContinue
    $env:CODEX_WECHAT_BRIDGE_HOME = $oldBridgeHome
    $env:CODEX_HOME = $oldCodexHome
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
