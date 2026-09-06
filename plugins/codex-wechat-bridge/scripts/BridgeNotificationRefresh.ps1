# Dot-sourced by CodexWeChatBridge.psm1. Refresh never rewinds the completion
# monitor, attaches a task writer, or removes an existing delivery-history key.

function Read-CodexRefreshLatestBoundary {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxBytes = 2097152)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $length = $stream.Length
        $start = [Math]::Max(0L, $length - $MaxBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new([int]($length - $start))
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        $lines = [regex]::Split([Text.Encoding]::UTF8.GetString($bytes, 0, $read), "\r?\n")
        $first = if ($start -gt 0) { 1 } else { 0 }
        if (-not [string]::IsNullOrWhiteSpace($lines[-1])) { return $null }
        # The final item may be a partially appended JSON record: never act on it.
        for ($i = $lines.Length - 2; $i -ge $first; $i--) {
            $line = $lines[$i]
            if ($line -notmatch '"type"\s*:\s*"event_msg"' -or $line -notmatch '"type"\s*:\s*"(?:task_started|task_complete|turn_aborted)"') { continue }
            try { $event = $line | ConvertFrom-Json -AsHashtable } catch { return $null }
            if ($event -isnot [Collections.IDictionary] -or $event['type'] -ne 'event_msg' -or $event['payload'] -isnot [Collections.IDictionary]) { continue }
            $payload = $event['payload']
            if ($payload['type'] -notin @('task_started','task_complete','turn_aborted')) { continue }
            return [pscustomobject]@{ type=[string]$payload['type']; turn_id=[string]$payload['turn_id']; timestamp=[string]$event['timestamp']; summary=[string]$payload['last_agent_message'] }
        }
        return $null
    } finally { $stream.Dispose() }
}

function Repair-BridgeMissingCompletionNotifications {
    param([int]$TaskLimit = 100, [int]$BudgetSeconds = 15)
    return Invoke-WithBridgeNotificationGate -Action {
        $root = Initialize-BridgeState
        $result = [ordered]@{ inspected=0; recovered=0; already_known=0; unsafe=0; limited=$false; blocked_reason=''; scope_after='' }
        $config = Get-BridgeConfig
        if (-not $config.notifications_enabled) { $result.blocked_reason='通知功能未开启'; return [pscustomobject]$result }
        $monitor = Read-BridgeJson (Join-Path $root 'rollout-monitor.json') -Default $null -AsHashtable
        $history = Read-BridgeJson (Join-Path $root 'notification-history.json') -Default $null -AsHashtable
        $floor = [DateTimeOffset]::MinValue
        if ($monitor -isnot [Collections.IDictionary] -or -not [DateTimeOffset]::TryParse([string]$monitor['initialized_at'], [ref]$floor)) {
            $result.blocked_reason='监控起点记录不可用，未回查历史'; return [pscustomobject]$result
        }
        if ($history -isnot [Collections.IDictionary] -or -not $history.ContainsKey('keys') -or $history.keys -isnot [Collections.IDictionary]) {
            $result.blocked_reason='发送记录不可核实，未回查历史'; return [pscustomobject]$result
        }
        $resetPath = Join-Path $root 'notification-reset.json'
        if (Test-Path -LiteralPath $resetPath) {
            $reset = Get-BridgeNotificationResetState
            $cutoff = [DateTimeOffset]::MinValue
            if (-not $reset -or -not (Test-BridgeProperty $reset 'cutoff_at') -or -not [DateTimeOffset]::TryParse([string]$reset.cutoff_at, [ref]$cutoff)) {
                $result.blocked_reason='清空边界不可核实，未回查历史'; return [pscustomobject]$result
            }
            if ($cutoff -gt $floor) { $floor = $cutoff }
        }
        # The legacy ledger prunes to 500 keys at 600 entries. For absent keys,
        # only trust event times newer than its retained lower bound; an older
        # absent key might have been sent and subsequently pruned.
        if ($history.keys.Count -ge 500) {
            $retainedFloor = [DateTimeOffset]::MaxValue
            foreach ($entry in $history.keys.Values) {
                $recorded = [DateTimeOffset]::MinValue
                if ($entry -isnot [Collections.IDictionary] -or -not [DateTimeOffset]::TryParse([string]$entry['recorded_at'], [ref]$recorded)) {
                    $result.blocked_reason='部分发送记录时间不可核实，未回查历史'; return [pscustomobject]$result
                }
                if ($recorded -lt $retainedFloor) { $retainedFloor = $recorded }
            }
            if ($retainedFloor -gt $floor) { $floor = $retainedFloor }
        }
        $result.scope_after = $floor.ToString('o')
        $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $sessions = Join-Path $codexRoot 'sessions'
        if (-not (Test-Path -LiteralPath $sessions -PathType Container)) {
            $result.blocked_reason='会话记录目录不可用'; return [pscustomobject]$result
        }
        $deadline = [DateTimeOffset]::Now.AddSeconds($BudgetSeconds)
        $latestByTask = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter 'rollout-*.jsonl' | Where-Object { $_.LastWriteTimeUtc -ge $floor.UtcDateTime } | Sort-Object LastWriteTimeUtc -Descending)) {
            if ([DateTimeOffset]::Now -ge $deadline) { $result.limited=$true; break }
            $id = Get-CodexSessionIdFromRolloutPath $file.FullName
            if (-not $id) { $result.unsafe++; continue }
            if (-not $latestByTask.ContainsKey($id)) { $latestByTask[$id]=$file }
        }
        $queueKeys = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'outbox') -File -Filter '*.json')) {
            $queued = Read-BridgeJson $file.FullName -Default $null
            if ($queued -and $queued.session_id -and $queued.turn_id) { $queueKeys["$($queued.session_id)|$($queued.turn_id)"]=$true }
        }
        $sourceSets = @{}
        foreach ($candidate in @($latestByTask.GetEnumerator() | Sort-Object { $_.Value.LastWriteTimeUtc } -Descending)) {
            if ($result.inspected -ge $TaskLimit -or [DateTimeOffset]::Now -ge $deadline) { $result.limited=$true; break }
            $id = [string]$candidate.Key
            $file = $candidate.Value
            try {
                $metadata = Get-CodexRolloutMetadata $file.FullName
                if (-not $metadata -or [string]$metadata.session_id -ne $id) { $result.unsafe++; continue }
                if (-not $metadata.user_visible) { continue }
                $result.inspected++
                $boundary = Read-CodexRefreshLatestBoundary $file.FullName
                if (-not $boundary) { $result.unsafe++; continue }
                if ($boundary.type -ne 'task_complete') { continue }
                $eventAt = ConvertTo-BridgeEventTime $boundary.timestamp
                if (-not $eventAt -or [string]::IsNullOrWhiteSpace($boundary.turn_id)) { $result.unsafe++; continue }
                if ($eventAt -le $floor) { continue }
                if ($eventAt -gt [DateTimeOffset]::Now.AddMinutes(1)) { $result.unsafe++; continue }
                $key = "$id|$($boundary.turn_id)"
                if ($history.keys.Contains($key) -or $queueKeys.ContainsKey($key)) {
                    $result.already_known++
                    if ($history.keys.Contains($key) -and [string]$history.keys[$key]['state'] -in @('reserved','queued') -and -not $queueKeys.ContainsKey($key)) { $result.unsafe++ }
                    continue
                }
                if ($metadata.forked_from_id) {
                    $birth = ConvertTo-BridgeEventTime ([string]$metadata.created_at)
                    if (-not $birth -or $eventAt -le $birth) { $result.unsafe++; continue }
                    $parentId = [string]$metadata.forked_from_id
                    if (-not $sourceSets.ContainsKey($parentId)) {
                        try { $sourceSets[$parentId] = Get-CodexRolloutLifecycleTurnIdSet $parentId } catch { $sourceSets[$parentId] = $null }
                    }
                    if (-not $sourceSets[$parentId]) { $result.unsafe++; continue }
                    if ($sourceSets[$parentId].Contains($boundary.turn_id)) { continue }
                }
                $hook = [pscustomobject]@{session_id=$id;turn_id=$boundary.turn_id;cwd=[string]$metadata.cwd;model=$null;thread_name=(Get-CodexThreadDisplayName -SessionId $id -Cwd ([string]$metadata.cwd));event_at=$eventAt.ToString('o');last_assistant_message=$boundary.summary}
                $published = Publish-CodexTurnNotification -HookEvent $hook -QueueOnly
                if ((Test-BridgeProperty $published 'queued') -and $published.queued) { $result.recovered++; $queueKeys[$key]=$true }
            } catch {
                $result.unsafe++
                Write-BridgeLog -Level WARN -Message "Refresh could not safely reconcile task $id : $($_.Exception.Message)"
            }
        }
        return [pscustomobject]$result
    }
}

function Get-BridgeRefreshPendingCounts {
    $root = Initialize-BridgeState
    $text = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'outbox') -Filter '*.json' -File)) {
        $record = Read-BridgeJson $file.FullName -Default $null
        if ($record -and (-not (Test-BridgeProperty $record 'text_sent') -or -not $record.text_sent)) { $text++ }
    }
    return [pscustomobject]@{text=$text;attachments=@(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-outbox') -Filter '*.json' -File).Count;failed_attachments=@(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-failed') -Filter '*.json' -File).Count}
}

function Invoke-BridgeNotificationRefreshCommand {
    param([Parameter(Mandatory)]$SavedMessage)
    $path = [string]$SavedMessage.path
    Update-InboundRecord $path @{relay_state='maintenance_running';command_type='refresh';bridge_version=$script:BridgeVersion;refresh_started_at=[DateTimeOffset]::Now.ToString('o')} | Out-Null
    $connected = $false
    $problem = ''
    try { Send-BridgeText -Text "【正在刷新】`n正在核对连接、最新完成结果和待发队列。" -TimeoutSeconds 10 | Out-Null; $connected=$true } catch { $problem='连接尚未恢复，结果将保留并重试投递。' }
    $recovery = [pscustomobject]@{inspected=0;recovered=0;unsafe=0;limited=$false;blocked_reason='';scope_after=''}
    $flush = [pscustomobject]@{notifications_sent=0;text_parts_sent=0;send_failures=0;budget_exhausted=$false}
    try {
        $recovery = Repair-BridgeMissingCompletionNotifications
        if ($connected) { $flush = Flush-BridgeOutbox -PassThru -SkipAttachments -TextPartLimit 6 -BudgetSeconds 25 }
    } catch {
        $problem = '部分检查或补发未完成，已保留待发内容。'
        Write-BridgeLog -Level WARN -Message "Notification refresh incomplete: $($_.Exception.Message)"
    }
    $pending = Get-BridgeRefreshPendingCounts
    $delivery = Get-BridgeDeliveryState
    $connected = $connected -and [string]$delivery.state -ne 'waiting_for_wechat'
    $partial = -not $connected -or $problem -or $recovery.blocked_reason -or $recovery.unsafe -gt 0 -or $recovery.limited -or $flush.send_failures -gt 0
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($(if ($partial) { '【刷新结果：部分完成】' } else { '【已刷新】' }))
    $lines.Add('微信连接：' + $(if ($connected) { '正常' } else { '尚未恢复' }))
    if ($recovery.scope_after) { $lines.Add('安全回查起点：' + ([DateTimeOffset]$recovery.scope_after).ToLocalTime().ToString('MM-dd HH:mm') + '（清空及去重记录约束）。') }
    $lines.Add("检查 $($recovery.inspected) 个任务的最新一轮，找回 $($recovery.recovered) 条漏通知。")
    $lines.Add("本次补发 $($flush.notifications_sent) 条通知，投递 $($flush.text_parts_sent) 段文字。")
    if ($pending.text -eq 0 -and $pending.attachments -eq 0) {
        $lines.Add($(if ($partial) { '当前已知待发队列为空；不能据此认定所有通知均已送达。' } else { '当前没有待补发内容。' }))
    } else {
        $lines.Add("仍待发送：通知 $($pending.text) 条、附件 $($pending.attachments) 个，后台将继续投递。")
    }
    if ($pending.failed_attachments -gt 0) { $lines.Add("另有 $($pending.failed_attachments) 个附件失败，可引用原通知发送 /附件 查看。") }
    if ($recovery.blocked_reason) { $lines.Add($recovery.blocked_reason + '。') }
    if ($recovery.unsafe -gt 0) { $lines.Add("另有 $($recovery.unsafe) 项无法安全核实，未强制重发。") }
    if ($recovery.limited) { $lines.Add('达到本次检查上限，未完成全量核查。') }
    if ($problem) { $lines.Add($problem) }
    $reply = $lines -join "`n"
    $result = @{connection_ok=$connected;recovery=$recovery;flush=$flush;pending=$pending;partial=[bool]$partial}
    Update-InboundRecord $path @{relay_state='maintenance_completed';refresh_state=$(if($partial){'partial'}else{'completed'});refresh_result=$result;reply_text=$reply;refresh_receipt_pending=$true;refresh_receipt_next_at=[DateTimeOffset]::Now.AddSeconds(30).ToString('o');relay_completed_at=[DateTimeOffset]::Now.ToString('o')} | Out-Null
    try {
        $sent = Send-BridgeText -Text $reply -TimeoutSeconds 10
        Update-InboundRecord $path @{reply_message_id=[string]$sent.message_id;refresh_receipt_pending=$false;refresh_receipt_sent_at=[DateTimeOffset]::Now.ToString('o')} | Out-Null
    } catch { Write-BridgeLog -Level WARN -Message 'Refresh result receipt is saved for retry; no task will be re-executed.' }
}

function Flush-BridgeRefreshReceipts {
    $root = Initialize-BridgeState
    $sentCount = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'inbox') -File -Filter '*.json' | Sort-Object LastWriteTimeUtc -Descending)) {
        $record = Read-BridgeJson $file.FullName -Default $null
        if (-not $record -or -not (Test-BridgeProperty $record 'refresh_receipt_pending') -or -not $record.refresh_receipt_pending) { continue }
        $reset = Get-BridgeNotificationResetState
        $receivedAt = [DateTimeOffset]::MinValue
        $cutoffAt = [DateTimeOffset]::MinValue
        if ($reset -and (-not (Test-BridgeProperty $reset 'cutoff_at') -or -not [DateTimeOffset]::TryParse([string]$reset.cutoff_at, [ref]$cutoffAt))) { continue }
        if (-not (Test-BridgeProperty $record 'received_at') -or -not [DateTimeOffset]::TryParse([string]$record.received_at, [ref]$receivedAt)) { continue }
        if ($reset -and $receivedAt -le $cutoffAt) {
            Update-InboundRecord $file.FullName @{refresh_receipt_pending=$false;refresh_receipt_superseded_by_clear=$true} | Out-Null
            continue
        }
        $nextAt = [DateTimeOffset]::MinValue
        if (-not (Test-BridgeProperty $record 'refresh_receipt_next_at') -or -not [DateTimeOffset]::TryParse([string]$record.refresh_receipt_next_at, [ref]$nextAt)) { continue }
        if ($nextAt -gt [DateTimeOffset]::Now) { continue }
        if ($sentCount -ge 1 -or [string](Get-BridgeDeliveryState).state -eq 'waiting_for_wechat') { break }
        try {
            $sent = Send-BridgeText -Text ([string]$record.reply_text) -TimeoutSeconds 10
            Update-InboundRecord $file.FullName @{reply_message_id=[string]$sent.message_id;refresh_receipt_pending=$false;refresh_receipt_sent_at=[DateTimeOffset]::Now.ToString('o')} | Out-Null
            $sentCount++
        } catch {
            Update-InboundRecord $file.FullName @{refresh_receipt_next_at=[DateTimeOffset]::Now.AddMinutes(1).ToString('o')} | Out-Null
            break
        }
    }
}
