param([string]$ModulePath = (Join-Path $PSScriptRoot '..\scripts\CodexWeChatBridge.psm1'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-identity-' + [guid]::NewGuid().ToString('N'))
$oldStateRoot = $env:CODEX_WECHAT_BRIDGE_HOME
$oldCodexRoot = $env:CODEX_HOME
$env:CODEX_WECHAT_BRIDGE_HOME = Join-Path $testRoot 'bridge'
$env:CODEX_HOME = Join-Path $testRoot 'codex'
try {
    $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    & $module {
        param($TestRoot)
        function Assert-Equal($Actual, $Expected, [string]$Label) {
            if ($Actual -cne $Expected) { throw "$Label : expected '$Expected', got '$Actual'" }
        }
        $root = Initialize-BridgeState
        $sessions = Join-Path $env:CODEX_HOME 'sessions'
        $null = [IO.Directory]::CreateDirectory($sessions)
        $utf8 = [Text.UTF8Encoding]::new($false)
        $original = 'aaaaaaaa-1111-2222-3333-444444444444'
        $stream = 'bbbbbbbb-1111-2222-3333-444444444444'
        $child = 'cccccccc-1111-2222-3333-444444444444'
        $other = 'dddddddd-1111-2222-3333-444444444444'
        $ordinary = Join-Path $sessions "rollout-2026-09-01T00-00-00-$original.jsonl"
        $composite = Join-Path $sessions "rollout-2026-09-05T00-00-00-${original}_$stream.jsonl"
        $fork = Join-Path $sessions "rollout-2026-09-05T00-00-00-${original}_$child.jsonl"
        function Write-Fixture($Path, $Id, $Parent = '') {
            $line = @{ type = 'session_meta'; payload = @{ id = $Id; session_id = $Id; cwd = $root; source = 'vscode'; thread_source = 'user'; forked_from_id = $Parent } } | ConvertTo-Json -Depth 5 -Compress
            [IO.File]::WriteAllText($Path, $line + "`n", $utf8)
        }
        Write-Fixture $ordinary $original
        Write-Fixture $composite $original
        Write-Fixture $fork $child $original
        [IO.File]::SetLastWriteTimeUtc($ordinary, [DateTime]::UtcNow.AddMinutes(-10))
        [IO.File]::SetLastWriteTimeUtc($fork, [DateTime]::UtcNow.AddSeconds(1))
        Assert-Equal (Get-CodexSessionIdFromRolloutPath $ordinary) $original 'Ordinary task'
        Assert-Equal (Get-CodexSessionIdFromRolloutPath $composite) $original 'Restart stream uses metadata identity'
        Assert-Equal (Get-CodexSessionIdFromRolloutPath $fork) $child 'Real fork keeps child identity'
        Assert-Equal (Get-CodexRolloutPath $original) $composite 'Newest owned file, excluding newer real fork'
        Assert-Equal (Get-CodexRolloutPath $child) $fork 'Fork lookup'
        Assert-Equal (Get-CodexRolloutPath $original.ToUpperInvariant()) $composite 'Case-insensitive UUID'
        Assert-Equal (Resolve-CodexQuotedSessionId $stream) $original 'Old stream-id quote maps to original'
        Assert-Equal (Resolve-CodexQuotedSessionId $child) $child 'Real fork quote stays on fork'

        $broken = Join-Path $sessions "rollout-2026-09-05T00-00-00-${original}_$other.jsonl"
        [IO.File]::WriteAllText($broken, '{}', $utf8)
        Assert-Equal (Get-CodexSessionIdFromRolloutPath $broken) $null 'Unverifiable composite must not guess'
        Write-Fixture $broken $stream
        Assert-Equal (Get-CodexSessionIdFromRolloutPath $broken) $null 'Conflicting metadata must not guess'
        $second = Join-Path $sessions "rollout-2026-09-05T00-00-00-${other}_$stream.jsonl"
        Write-Fixture $second $other
        $blocked = $false
        try { Resolve-CodexQuotedSessionId $stream | Out-Null } catch { $blocked = $true }
        Assert-Equal $blocked $true 'Ambiguous old alias must not execute'
        [IO.File]::Move($second, (Join-Path $TestRoot 'ambiguous-case.jsonl'))

        # Exercise the real completion scanner while mocking only external effects.
        $script:notifications = [Collections.Generic.List[string]]::new()
        $script:submitted = [Collections.Generic.List[string]]::new()
        $script:receipts = [Collections.Generic.List[string]]::new()
        function Publish-CodexTurnNotification { param($HookEvent) $script:notifications.Add([string]$HookEvent.session_id) }
        function Start-BridgeRelayWorkerProcess { }
        function Send-BridgeText { param($Text, $TimeoutSeconds, [switch]$AllowContextlessRetry) $script:receipts.Add($Text); return [pscustomobject]@{ message_id = 'offline-ack' } }
        function Submit-CodexDesktopPrompt { param($ThreadId, $Prompt, $ExpectedThreadName, $NavigationDelayMs)
            $script:submitted.Add($ThreadId)
            return [pscustomobject]@{ window_pid = 1; targeting_mode = 'offline'; title_verified = $true }
        }
        function Wait-CodexDesktopTurnStarted { param($RolloutPath, $StartOffset, $SubmitTimeoutSeconds) return [DateTimeOffset]::Now }
        function Invoke-CodexAppServerTurn { throw 'Existing-task continuation must not start an App Server.' }
        $beforeOffset = (Get-Item -LiteralPath $composite).Length
        $monitorPath = Join-Path $root 'rollout-monitor.json'
        $files = @{}
        $files[$composite] = @{ session_id = $stream; cwd = $root; user_visible = $true; offset = $beforeOffset; carry = ''; forked_from_id = ''; fork_replay_from_zero = $false; fork_baseline_warning_logged = $false }
        Write-BridgeJsonAtomic $monitorPath @{ initialized_at = [DateTimeOffset]::Now.AddMinutes(-1).ToString('o'); files = $files }
        Invoke-CodexRolloutMonitorScan $monitorPath
        $tracked = Read-BridgeJson $monitorPath -AsHashtable
        Assert-Equal $tracked.files[$composite].session_id $original 'Monitor state corrected'
        Assert-Equal $tracked.files[$composite].offset $beforeOffset 'Byte offset preserved'
        Assert-Equal $script:notifications.Count 0 'Migration never replays history'
        $event = [ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); type = 'event_msg'; payload = [ordered]@{ type = 'task_complete'; turn_id = 'test-turn'; last_agent_message = 'done' } } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::AppendAllText($composite, $event + "`n", $utf8)
        Invoke-CodexRolloutMonitorScan $monitorPath
        Assert-Equal $script:notifications.Count 1 'One new completion'
        Assert-Equal $script:notifications[0] $original 'New notification owns correct task'
        $index = Get-CodexRolloutRuntimeIndex
        Assert-Equal $index[$original].path $composite 'Runtime index follows live stream'
        Assert-Equal ($index.ContainsKey($stream)) $false 'No invented stream task'

        # Real quote matching and queue dispatch; no desktop input is sent.
        $config = Get-BridgeConfig
        $config.inbound_mode = 'codex_relay'
        $config.require_completion_quote = $true
        $config.relay_enabled_at = [DateTimeOffset]::Now.AddHours(-1).ToString('o')
        Save-BridgeConfig $config
        Set-CodexThreadDisplayName -SessionId $original -Name '原来的真实任务' | Out-Null
        Register-BridgeReplyTarget -SessionId $stream -ThreadName '旧通知的文件夹名' -Cwd $root -WeChatMessageId 'old-quoted-notification'
        $messagePath = Join-Path $root 'inbox\quoted.json'
        $record = @{ id = 'quoted-test'; create_time_ms = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); received_at = [DateTimeOffset]::Now.ToString('o'); relay_state = 'queued_only'; reference_text = '【已完成】旧通知的文件夹名'; reference_message_ids = @('old-quoted-notification'); reference_create_time_ms = @() }
        Write-BridgeJsonAtomic $messagePath $record
        $saved = [pscustomobject]@{ path = $messagePath; record = Read-BridgeJson $messagePath }
        Invoke-BridgeInboundCommand -Text '继续测试' -SavedMessage $saved
        $queued = Read-BridgeJson $messagePath
        Assert-Equal $queued.target_session_id $original 'Quoted reply queued to canonical task'
        Assert-Equal $queued.target_thread_name '原来的真实任务' 'Canonical display name'
        Assert-Equal $queued.quoted_session_id $stream 'Original reference retained for audit'
        $result = Invoke-CodexRelayQueueItem $messagePath
        Assert-Equal $result.submitted $true 'Reply reaches submit path'
        Assert-Equal $script:submitted.Count 1 'Exactly one submission'
        Assert-Equal $script:submitted[0] $original 'Submit uses canonical id'
        $after = Read-BridgeJson $messagePath
        Assert-Equal $after.relay_state 'relay_submitted' 'Submission persisted'
        Assert-Equal ($script:receipts -contains "【原来的真实任务】`n开始处理") $true 'Start acknowledgement'
        $record.id = 'plain-test'
        $record.reference_text = ''
        $record.reference_message_ids = @()
        $plainPath = Join-Path $root 'inbox\plain.json'
        Write-BridgeJsonAtomic $plainPath $record
        Invoke-BridgeInboundCommand -Text '继续' -SavedMessage ([pscustomobject]@{path=$plainPath;record=(Read-BridgeJson $plainPath)})
        Assert-Equal (Read-BridgeJson $plainPath).relay_state 'not_executed_unquoted' 'Ordinary messages still cannot execute'
        [pscustomobject]@{ passed=$true; version=$script:BridgeVersion; composite_identity=$true; real_fork_isolated=$true; alias_quote_submitted_once=$true; ambiguous_alias_blocked=$true; history_replayed=0; new_notification_correct=$true; unquoted_blocked=$true; test_root=$TestRoot } | ConvertTo-Json -Compress
    } $testRoot
} finally {
    $env:CODEX_WECHAT_BRIDGE_HOME = $oldStateRoot
    $env:CODEX_HOME = $oldCodexRoot
}
