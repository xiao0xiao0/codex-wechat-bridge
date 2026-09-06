param([string]$ModulePath = (Join-Path $PSScriptRoot '..\scripts\CodexWeChatBridge.psm1'))
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-refresh-' + [guid]::NewGuid().ToString('N'))
$previousState = $env:CODEX_WECHAT_BRIDGE_HOME
$previousCodex = $env:CODEX_HOME
$env:CODEX_WECHAT_BRIDGE_HOME = Join-Path $testRoot 'initial-bridge'
$env:CODEX_HOME = Join-Path $testRoot 'initial-codex'
try {
    $module = Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    & $module {
        param($TestRoot)
        $script:refreshAssertions = 0
        function Assert-Equal($Actual,$Expected,[string]$Label) {
            $script:refreshAssertions++
            if ($Actual -cne $Expected) { throw "$Label : expected '$Expected', got '$Actual'" }
        }
        function Assert-True($Actual,[string]$Label) { Assert-Equal ([bool]$Actual) $true $Label }
        function New-Fixture([string]$Name) {
            $env:CODEX_WECHAT_BRIDGE_HOME = Join-Path $TestRoot "$Name\bridge"
            $env:CODEX_HOME = Join-Path $TestRoot "$Name\codex"
            $script:fixtureRoot = Initialize-BridgeState
            $script:fixtureSessions = Join-Path $env:CODEX_HOME 'sessions'
            [IO.Directory]::CreateDirectory($script:fixtureSessions) | Out-Null
            $script:fixtureNow = [DateTimeOffset]::Now
            Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'rollout-monitor.json') @{initialized_at=$script:fixtureNow.AddHours(-4).ToString('o');files=@{fixture=@{offset=9182}}}
            Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-history.json') @{keys=@{}}
            Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-reset.json') @{cutoff_at=$script:fixtureNow.AddHours(-2).ToString('o')}
            $config = Get-BridgeConfig
            $config.notifications_enabled=$true
            $config.outbox_send_batch_size=20
            Save-BridgeConfig $config
            $script:refreshTexts=[Collections.Generic.List[string]]::new()
            $script:refreshReceipts=[Collections.Generic.List[string]]::new()
            $script:refreshFailText=$false
            $script:refreshFailReceipt=$false
            $script:refreshAttachCalls=0
        }
        function Test-Id([int]$Number) { return ('aaaaaaaa-1111-2222-3333-' + $Number.ToString('000000000000')) }
        function Test-Event([string]$Type,[string]$Turn,[int]$Minutes,[string]$Summary='测试完成') {
            return @{timestamp=$script:fixtureNow.AddMinutes($Minutes).UtcDateTime.ToString('o');type='event_msg';payload=@{type=$Type;turn_id=$Turn;last_agent_message=$Summary}}
        }
        function Save-Rollout([int]$Number,[object[]]$Events,[int]$BirthMinutes=-240,[string]$Parent='', [string]$ThreadSource='user',[string]$Suffix='') {
            $id=Test-Id $Number
            $meta=@{timestamp=$script:fixtureNow.AddMinutes($BirthMinutes).UtcDateTime.ToString('o');type='session_meta';payload=@{id=$id;cwd=$script:fixtureRoot;thread_source=$ThreadSource;source='desktop'}}
            if ($Parent) { $meta.payload.forked_from_id=$Parent }
            $path=Join-Path $script:fixtureSessions ("rollout-fixture-$id$Suffix.jsonl")
            $lines=@($meta)+$Events | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
            [IO.File]::WriteAllText($path,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
            return $path
        }
        function Send-BridgeRoutableText {
            param($Text,$TimeoutSeconds,[switch]$AllowContextlessRetry)
            if ($script:refreshFailText) { throw 'offline simulated text failure' }
            $script:refreshTexts.Add($Text)
            return [pscustomobject]@{message_id="test-part-$($script:refreshTexts.Count)";send_started_at=[DateTimeOffset]::Now.ToString('o');send_completed_at=[DateTimeOffset]::Now.ToString('o')}
        }
        function Send-BridgeText {
            param($Text,$TimeoutSeconds,[switch]$AllowContextlessRetry)
            if ($script:refreshFailReceipt) { throw 'offline simulated connection failure' }
            $script:refreshReceipts.Add($Text)
            return [pscustomobject]@{message_id="test-receipt-$($script:refreshReceipts.Count)"}
        }
        function Flush-BridgeAttachmentOutbox { $script:refreshAttachCalls++ }
        function Publish-BridgeCompletedAttachmentSummaries { }
        function Submit-CodexDesktopPromptToUri { throw 'Refresh must not submit a task' }
        function Invoke-CodexAppServerTurn { throw 'Refresh must not create another writer' }
        function Refresh-CodexThreadCatalog { throw 'Refresh must not start an extra app server' }
        function New-RefreshCommand {
            $path=Join-Path $script:fixtureRoot ('inbox\refresh-'+[guid]::NewGuid().ToString('N')+'.json')
            Write-BridgeJsonAtomic $path @{id=[guid]::NewGuid().ToString('N');text='/刷新';received_at=[DateTimeOffset]::Now.ToString('o');relay_state='queued_only'}
            return [pscustomobject]@{path=$path;record=(Read-BridgeJson $path)}
        }
        New-Fixture 'recovery'
        $null=Save-Rollout 1 @((Test-Event task_complete 'missed' -90))
        $null=Save-Rollout 2 @((Test-Event task_complete 'sent' -50))
        Register-CodexNotificationKey (Test-Id 2) sent -State sent | Out-Null
        $null=Save-Rollout 3 @((Test-Event task_complete 'preclear' -180))
        $null=Save-Rollout 4 @((Test-Event task_complete 'previous' -70),(Test-Event task_started 'active' -5))
        $null=Save-Rollout 5 @((Test-Event task_complete 'obsolete' -60),(Test-Event task_complete 'latest' -30))
        $null=Save-Rollout 6 @((Test-Event task_complete 'suppressed' -45))
        Register-CodexNotificationKey (Test-Id 6) suppressed -State suppressed | Out-Null
        $null=Save-Rollout 7 @((Test-Event task_complete 'reserved' -45))
        Register-CodexNotificationKey (Test-Id 7) reserved -State reserved | Out-Null
        $null=Save-Rollout 8 @((Test-Event task_complete 'sent' -50)) -Parent (Test-Id 2) -BirthMinutes -20
        $null=Save-Rollout 9 @((Test-Event task_complete 'child' -5)) -Parent (Test-Id 99) -BirthMinutes -20
        $null=Save-Rollout 10 @((Test-Event task_complete 'child-new' -5)) -Parent (Test-Id 2) -BirthMinutes -20
        $null=Save-Rollout 11 @((Test-Event task_complete 'subagent' -50)) -ThreadSource 'subagent'
        $null=Save-Rollout 12 @((Test-Event turn_aborted 'aborted' -5))
        $incomplete=Save-Rollout 13 @((Test-Event task_complete 'stale-before-partial' -50))
        [IO.File]::AppendAllText($incomplete,'{"type":"event_msg","payload":{"type":"task_started"')
        $null=Save-Rollout 14 @((Test-Event task_complete 'stream' -35)) -Suffix '_bbbbbbbb-1111-2222-3333-000000000014'
        $monitorHash=(Get-FileHash (Join-Path $script:fixtureRoot 'rollout-monitor.json')).Hash
        $result=Repair-BridgeMissingCompletionNotifications
        Assert-Equal $result.recovered 4 'Recover only latest missing, latest task round, verified new fork round and composite task'
        Assert-True ($result.unsafe -ge 4) 'Reserved delivery, inherited fork, missing fork baseline and incomplete tail are surfaced'
        Assert-Equal $script:refreshTexts.Count 0 'Reconciliation itself is queue-only'
        $queued=@(Get-ChildItem (Join-Path $script:fixtureRoot 'outbox') -Filter '*.json' | ForEach-Object { Read-BridgeJson $_.FullName })
        Assert-Equal $queued.Count 4 'Only four notifications queued'
        Assert-True (@($queued.turn_id | Sort-Object) -join ',' -ceq 'child-new,latest,missed,stream') 'Correct rounds queued without historical messages'
        Assert-Equal (Repair-BridgeMissingCompletionNotifications).recovered 0 'Second reconciliation does not duplicate queued items'
        $flushed=Flush-BridgeOutbox -PassThru -SkipAttachments
        Assert-Equal $flushed.notifications_sent 4 'Flush counts actual successful notifications'
        Assert-Equal $flushed.text_parts_sent 4 'Flush counts successful text parts'
        Assert-Equal $script:refreshAttachCalls 0 'Manual refresh does not wait for attachment uploads'
        Assert-Equal (Repair-BridgeMissingCompletionNotifications).recovered 0 'Sent items are never replayed'
        Assert-Equal (Get-FileHash (Join-Path $script:fixtureRoot 'rollout-monitor.json')).Hash $monitorHash 'Live monitor offsets unchanged'

        New-Fixture 'chunks'
        $id=Test-Id 21
        $hook=[pscustomobject]@{session_id=$id;turn_id='long';cwd=$script:fixtureRoot;model='test';thread_name='长文字测试';event_at=$script:fixtureNow.AddMinutes(-1).ToString('o');last_assistant_message=('长文字分段。'*350)}
        Publish-CodexTurnNotification -HookEvent $hook -QueueOnly | Out-Null
        $partCount=@((Read-BridgeJson @(Get-ChildItem (Join-Path $script:fixtureRoot 'outbox') -File)[0].FullName).text_parts).Count
        Assert-True ($partCount -gt 1) 'Long summary actually has multiple parts'
        $one=Flush-BridgeOutbox -PassThru -SkipAttachments -TextPartLimit 1
        Assert-Equal $one.text_parts_sent 1 'Bounded flush sends one part'
        Assert-Equal $one.notifications_sent 0 'Partial message not falsely reported complete'
        Assert-True $one.budget_exhausted 'Bounded stop surfaced'
        $checkpoint=Read-BridgeJson @(Get-ChildItem (Join-Path $script:fixtureRoot 'outbox') -File)[0].FullName
        Assert-Equal $checkpoint.next_text_index 1 'Part checkpoint persisted'
        $script:refreshFailText=$true
        $failed=Flush-BridgeOutbox -PassThru -SkipAttachments
        Assert-Equal $failed.send_failures 1 'Failure counted'
        Assert-Equal $failed.notifications_sent 0 'Failed notification not reported sent'
        $script:refreshFailText=$false
        $rest=Flush-BridgeOutbox -PassThru -SkipAttachments
        Assert-Equal $rest.notifications_sent 1 'Remaining chunks complete notification'
        Assert-Equal $script:refreshTexts.Count $partCount 'Previously delivered part never repeated'
        Assert-Equal (Get-BridgeRefreshPendingCounts).text 0 'Finished text leaves outbox'

        New-Fixture 'receipts'
        $command=New-RefreshCommand
        Invoke-BridgeInboundCommand -Text '/刷新' -SavedMessage $command
        $record=Read-BridgeJson $command.path
        Assert-Equal $record.refresh_state completed 'Empty healthy queue gets completed refresh receipt'
        Assert-Equal $record.relay_state maintenance_completed 'Maintenance completion saved after work'
        Assert-Equal $script:refreshReceipts.Count 2 'Immediate acknowledgement plus result'
        Assert-True ($record.reply_text -match '当前没有待补发内容') 'No-op is explicit'
        Assert-Equal $record.refresh_receipt_pending $false 'Successful receipt is not retried'
        Flush-BridgeRefreshReceipts
        Assert-Equal $script:refreshReceipts.Count 2 'Receipt not duplicated'
        $offline=New-RefreshCommand
        $script:refreshFailReceipt=$true
        Invoke-BridgeInboundCommand -Text '/刷新' -SavedMessage $offline
        $record=Read-BridgeJson $offline.path
        Assert-Equal $record.refresh_state partial 'Offline run not falsely successful'
        Assert-Equal $record.refresh_receipt_pending $true 'Offline receipt durable'
        $script:refreshFailReceipt=$false
        Update-InboundRecord $offline.path @{refresh_receipt_next_at=[DateTimeOffset]::Now.AddMinutes(-1).ToString('o')} | Out-Null
        Flush-BridgeRefreshReceipts
        Assert-Equal (Read-BridgeJson $offline.path).refresh_receipt_pending $false 'Reconnect retries stored receipt'
        Assert-Equal $script:refreshReceipts.Count 3 'Only stored receipt resent, no command/progress replay'
        Update-InboundRecord $offline.path @{refresh_receipt_pending=$true;refresh_receipt_next_at=[DateTimeOffset]::Now.AddMinutes(-1).ToString('o');received_at=$script:fixtureNow.AddHours(-3).ToString('o')} | Out-Null
        Flush-BridgeRefreshReceipts
        Assert-True (Read-BridgeJson $offline.path).refresh_receipt_superseded_by_clear 'Clear suppresses older pending receipt'
        Assert-Equal $script:refreshReceipts.Count 3 'Pre-clear receipt not replayed'

        New-Fixture 'ledger-boundary'
        $keys=@{}
        foreach($n in 1..500) { $keys["retained-$n"]=@{state='sent';recorded_at=$script:fixtureNow.AddMinutes(-30).ToString('o')} }
        Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-history.json') @{keys=$keys}
        $null=Save-Rollout 31 @((Test-Event task_complete 'possibly-pruned' -60))
        $null=Save-Rollout 32 @((Test-Event task_complete 'safe-recent' -10))
        Assert-Equal (Repair-BridgeMissingCompletionNotifications).recovered 1 'Never recover older absent keys beyond retained ledger horizon'
        Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-history.json') @{broken=$true}
        Assert-True (Repair-BridgeMissingCompletionNotifications).blocked_reason 'Invalid history fails closed'
        Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-history.json') @{keys=@{}}
        Write-BridgeJsonAtomic (Join-Path $script:fixtureRoot 'notification-reset.json') @{cutoff_at='broken'}
        Assert-True (Repair-BridgeMissingCompletionNotifications).blocked_reason 'Invalid clear watermark fails closed'

        New-Fixture 'limit'
        $null=Save-Rollout 41 @((Test-Event task_complete 'one' -10))
        $null=Save-Rollout 42 @((Test-Event task_complete 'two' -10))
        $bounded=Repair-BridgeMissingCompletionNotifications -TaskLimit 1
        Assert-Equal $bounded.inspected 1 'Scan respects task bound'
        Assert-True $bounded.limited 'Limited scan never claims full coverage'
        $command=New-RefreshCommand
        $script:refreshFailText=$true
        Invoke-BridgeInboundCommand -Text '/刷新' -SavedMessage $command
        $record=Read-BridgeJson $command.path
        Assert-True ($record.refresh_result.pending.text -gt 0) 'Failure receipt shows retained pending notifications'
        Assert-Equal $record.refresh_state partial 'Delivery failure is partial, not successful refresh'
        [pscustomobject]@{passed=$true;version=$script:BridgeVersion;assertions=$script:refreshAssertions;network_calls=0;desktop_submissions=0;live_monitor_unchanged=$true;test_root=$TestRoot} | ConvertTo-Json -Compress
    } $testRoot
} catch {
    Write-Error ($_.Exception.Message + "`n" + $_.ScriptStackTrace) -ErrorAction Continue
    exit 1
} finally {
    $env:CODEX_WECHAT_BRIDGE_HOME=$previousState
    $env:CODEX_HOME=$previousCodex
}
