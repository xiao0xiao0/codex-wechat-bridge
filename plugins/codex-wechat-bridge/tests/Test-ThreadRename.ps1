param(
    [string]$ModulePath = (Join-Path $PSScriptRoot '..\scripts\CodexWeChatBridge.psm1'),
    [string]$DesktopSnapshotPath
)
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-rename-' + [guid]::NewGuid().ToString('N'))
$previousState = $env:CODEX_WECHAT_BRIDGE_HOME
$previousCodex = $env:CODEX_HOME
$env:CODEX_WECHAT_BRIDGE_HOME = Join-Path $testRoot 'bridge'
$env:CODEX_HOME = Join-Path $testRoot 'codex'
try {
    $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    & $module {
        param($SnapshotPath)
        function Assert-Equal($Actual,$Expected,[string]$Label) {
            if ($Actual -cne $Expected) { throw "$Label : expected '$Expected', got '$Actual'" }
        }
        $root = Initialize-BridgeState
        $taskId = 'eeeeeeee-1111-2222-3333-444444444444'
        $otherId = 'aaaaaaaa-1111-2222-3333-444444444444'
        $oldName = '项目讨论'
        $newName = '方案设计'
        Set-CodexThreadDisplayName -SessionId $taskId -Name $oldName | Out-Null
        $catalogPath = Join-Path $root 'thread-catalog.json'
        function Save-TestCatalog([string]$Name) {
            Write-BridgeJsonAtomic $catalogPath @{ refreshed_at=[DateTimeOffset]::Now.ToString('o');threads=@(
                @{session_id=$taskId;name=$Name;preview='不要用预览取代已知任务名';cwd=$root},
                @{session_id=$otherId;name=$oldName;preview='同名也不能串线';cwd=$root}
            ) }
        }
        Save-TestCatalog $newName
        Assert-Equal (Get-CodexThreadDisplayName $taskId) $newName 'Desktop catalog overrides old saved alias'
        Assert-Equal (Get-CodexThreadDisplayName $otherId) $oldName 'Name lookup remains scoped to id'
        Save-TestCatalog ''
        Assert-Equal (Get-CodexThreadDisplayName $taskId) $oldName 'Blank catalog falls back to saved name'
        Assert-Equal (Get-CodexThreadDisplayName 'bbbbbbbb-1111-2222-3333-444444444444' -FallbackName '新任务名') '新任务名' 'Unknown catalog retains supplied name'
        Save-TestCatalog $newName

        $script:testSubmissions = [Collections.Generic.List[object]]::new()
        $script:testReceipts = [Collections.Generic.List[string]]::new()
        $script:testBusy = $true
        $script:testRollout = Join-Path $root 'test-rollout.jsonl'
        [IO.File]::WriteAllText($script:testRollout, 'fixture')
        function Get-CodexRolloutPath { param($ThreadId) return $script:testRollout }
        function Test-CodexThreadIdle { param($RolloutPath) return -not $script:testBusy }
        function Submit-CodexDesktopPromptToUri {
            param($Uri,$Prompt,$ThreadId,$ExpectedThreadName,$NavigationDelayMs)
            $script:testSubmissions.Add([pscustomobject]@{id=$ThreadId;name=$ExpectedThreadName;uri=$Uri;prompt=$Prompt})
            return [pscustomobject]@{window_pid=1;targeting_mode='offline-title-checked';title_verified=$true}
        }
        function Wait-CodexDesktopTurnStarted { param($RolloutPath,$StartOffset,$SubmitTimeoutSeconds) return [DateTimeOffset]::Now }
        function Send-BridgeText { param($Text,$TimeoutSeconds,[switch]$AllowContextlessRetry) $script:testReceipts.Add($Text); return [pscustomobject]@{message_id='offline-ack'} }
        function Start-BridgeRelayWorkerProcess { }
        function Invoke-CodexAppServerTurn { throw 'Never start another writer for an existing task.' }
        function Refresh-CodexThreadCatalog { throw 'This fix must not introduce an extra catalog server.' }
        $config = Get-BridgeConfig
        $config.inbound_mode = 'codex_relay'
        $config.require_completion_quote = $true
        $config.relay_enabled_at = [DateTimeOffset]::Now.AddHours(-1).ToString('o')
        Save-BridgeConfig $config
        Register-BridgeReplyTarget -SessionId $taskId -ThreadName $oldName -Cwd $root -WeChatMessageId 'old-name-notification'
        $messagePath = Join-Path $root 'inbox\old-name-reply.json'
        Write-BridgeJsonAtomic $messagePath @{id='rename-test';create_time_ms=[DateTimeOffset]::Now.ToUnixTimeMilliseconds();received_at=[DateTimeOffset]::Now.ToString('o');relay_state='queued_only';reference_text="【已完成】$oldName";reference_message_ids=@('old-name-notification');reference_create_time_ms=@()}
        Invoke-BridgeInboundCommand -Text '只回复：微信续接成功' -SavedMessage ([pscustomobject]@{path=$messagePath;record=(Read-BridgeJson $messagePath)})
        $queued = Read-BridgeJson $messagePath
        Assert-Equal $queued.target_session_id $taskId 'Old quote preserves task id despite another task sharing old title'
        Assert-Equal $queued.target_thread_name $newName 'Acknowledgement and queue use current title'
        $deferred = Invoke-CodexRelayQueueItem $messagePath
        Assert-Equal $deferred.deferred $true 'Busy task stays queued'
        Assert-Equal $script:testSubmissions.Count 0 'Busy task is not submitted'
        Save-TestCatalog '方案设计（再次改名）'
        $script:testBusy = $false
        $submitted = Invoke-CodexRelayQueueItem $messagePath
        Assert-Equal $submitted.submitted $true 'Queued rename reaches submission'
        Assert-Equal $script:testSubmissions.Count 1 'Exactly one submission'
        Assert-Equal $script:testSubmissions[0].id $taskId 'Task id remains unchanged at submission'
        Assert-Equal $script:testSubmissions[0].name '方案设计（再次改名）' 'Queue rechecks title after waiting'
        Assert-Equal $script:testSubmissions[0].uri "codex://threads/$taskId" 'Navigation still uses immutable task id'
        Assert-Equal (Read-BridgeJson $messagePath).previous_target_thread_name $newName 'Rename reconciliation is audited'
        Invoke-CodexRelayQueueItem $messagePath | Out-Null
        Assert-Equal $script:testSubmissions.Count 1 'Submitted message is never replayed'

        $snapshotVerified = $false
        if ($SnapshotPath) {
            $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
            $validWindows = @($snapshot.windows | Where-Object {
                $window = $_
                $headers = @($window.header_controls | Where-Object { $_.name -ceq $newName -and -not $_.offscreen -and $_.bounds.left -ge ($window.bounds.left+280) -and $_.bounds.top -ge ($window.bounds.top+30) -and $_.bounds.top -le ($window.bounds.top+115) })
                $editors = @($window.editor_candidates | Where-Object { $_.control_type -eq 'ControlType.Edit' -and $_.class -match '(?i)(?:^|\s)ProseMirror(?:\s|$)' -and $_.enabled -and $_.keyboard_focusable -and -not $_.offscreen -and $_.bounds.width -ge 120 -and $_.bounds.height -ge 24 })
                $headers.Count -eq 1 -and $editors.Count -eq 1 -and @($window.target_title_matches).Count -eq 0
            })
            Assert-Equal $validWindows.Count 1 'Captured desktop passes existing selectors only with current title'
            $snapshotVerified = $true
        }
        [pscustomobject]@{passed=$true;version=$script:BridgeVersion;old_quote_current_name=$true;queued_rename_rechecked=$true;identity_unchanged=$true;submitted_once=$true;live_snapshot_verified=$snapshotVerified;live_submission_verified=$false;test_root=$root} | ConvertTo-Json -Compress
    } $DesktopSnapshotPath
} finally {
    $env:CODEX_WECHAT_BRIDGE_HOME = $previousState
    $env:CODEX_HOME = $previousCodex
}
