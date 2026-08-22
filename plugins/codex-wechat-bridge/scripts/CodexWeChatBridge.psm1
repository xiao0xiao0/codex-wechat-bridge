Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BridgeVersion = '0.9.30'
$script:DefaultBaseUrl = 'https://ilinkai.weixin.qq.com'
$script:DefaultCdnBaseUrl = 'https://novac2c.cdn.weixin.qq.com/c2c'
$script:BotAgent = "CodexWeChatBridge/$($script:BridgeVersion)"
$script:IlinkAppId = 'bot'
$script:IlinkClientVersion = 256
$script:HttpClientHandler = [System.Net.Http.HttpClientHandler]::new()
$requestedProxyMode = ([string]$env:CODEX_WECHAT_BRIDGE_HTTP_PROXY_MODE).Trim().ToLowerInvariant()
if (-not $requestedProxyMode) {
    try {
        $earlyStateRoot = if ($env:CODEX_WECHAT_BRIDGE_HOME) {
            [System.IO.Path]::GetFullPath($env:CODEX_WECHAT_BRIDGE_HOME)
        } else {
            Join-Path $env:LOCALAPPDATA 'CodexWeChatBridge'
        }
        $earlyConfigPath = Join-Path $earlyStateRoot 'config.json'
        if (Test-Path -LiteralPath $earlyConfigPath -PathType Leaf) {
            $earlyConfig = [System.IO.File]::ReadAllText($earlyConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($earlyConfig.PSObject.Properties.Name -contains 'wechat_http_proxy_mode') {
                $requestedProxyMode = ([string]$earlyConfig.wechat_http_proxy_mode).Trim().ToLowerInvariant()
            }
        }
    } catch { }
}
if ($requestedProxyMode -notin @('direct', 'system', 'auto')) { $requestedProxyMode = 'direct' }

switch ($requestedProxyMode) {
    'system' {
        $script:HttpTransportMode = 'system_proxy'
    }
    'auto' {
        $script:HttpTransportMode = 'system_proxy'
        try {
            $proxyProbeUri = [Uri]$script:DefaultBaseUrl
            $defaultProxy = [System.Net.Http.HttpClient]::DefaultProxy
            $resolvedProxyUri = $defaultProxy.GetProxy($proxyProbeUri)
            if ($null -eq $resolvedProxyUri -or
                $defaultProxy.IsBypassed($proxyProbeUri) -or
                $resolvedProxyUri.AbsoluteUri -eq $proxyProbeUri.AbsoluteUri) {
                $script:HttpClientHandler.UseProxy = $false
                $script:HttpTransportMode = 'direct'
            }
        } catch {
            # Preserve the framework default if proxy discovery is unavailable.
        }
    }
    default {
        $script:HttpClientHandler.UseProxy = $false
        $script:HttpTransportMode = 'direct'
    }
}
$script:HttpClient = [System.Net.Http.HttpClient]::new($script:HttpClientHandler, $true)
$script:HttpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

function Get-BridgeDefaultConfig {
    return [ordered]@{
        bridge_version = $script:BridgeVersion
        base_url = $script:DefaultBaseUrl
        cdn_base_url = $script:DefaultCdnBaseUrl
        wechat_http_proxy_mode = 'direct'
        bot_agent = $script:BotAgent
        account_id = $null
        scanner_user_id = $null
        target_user_id = $null
        peer_confirmed = $false
        notifications_enabled = $true
        inbound_mode = 'queue_only'
        direct_reply_enabled = $false
        require_completion_quote = $true
        default_new_thread_cwd = $null
        notify_summary_chars = 700
        completion_text_chunk_chars = 1100
        completion_text_max_chunks = 6
        relay_command_prefix = '/codex'
        relay_max_input_chars = 4000
        relay_max_reply_chars = 1800
        relay_timeout_seconds = 1200
        relay_transport = 'desktop_single_writer'
        desktop_navigation_delay_ms = 2200
        desktop_submit_timeout_seconds = 30
        completion_monitor_enabled = $true
        completion_scan_interval_ms = 1500
        completion_event_max_age_seconds = 300
        completion_scan_notification_limit = 4
        thread_catalog_refresh_seconds = 45
        context_refresh_timeout_seconds = 45
        context_retry_cooldown_seconds = 300
        outbox_send_batch_size = 4
        completion_attachments_enabled = $false
        completion_attachment_max_files = 10
        completion_attachment_max_bytes = 104857600
        completion_attachment_send_batch_size = 3
        completion_attachment_retry_delays_seconds = @(60, 300, 900, 3600, 10800, 21600)
        completion_attachment_allowed_extensions = @(
            '.doc', '.docx', '.pdf', '.ppt', '.pptx', '.xls', '.xlsx',
            '.csv', '.txt', '.rtf',
            '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg',
            '.zip', '.7z', '.rar'
        )
        log_retention_days = 14
        worker_log_retention_days = 7
        inbound_history_limit = 1000
        managed_worktree_root = $null
        relay_enabled_at = $null
    }
}

function Get-BridgeStateRoot {
    if ($env:CODEX_WECHAT_BRIDGE_HOME) {
        return [System.IO.Path]::GetFullPath($env:CODEX_WECHAT_BRIDGE_HOME)
    }
    return Join-Path $env:LOCALAPPDATA 'CodexWeChatBridge'
}

function Initialize-BridgeState {
    $root = Get-BridgeStateRoot
    foreach ($name in @(
        '', 'outbox', 'outbox-superseded', 'attachment-outbox', 'attachment-catalog',
        'attachment-sent', 'attachment-failed', 'attachment-skipped', 'cleared', 'inbox', 'logs', 'threads', 'worktrees'
    )) {
        $path = if ($name) { Join-Path $root $name } else { $root }
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    $configPath = Join-Path $root 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $config = Get-BridgeDefaultConfig
        Write-BridgeJsonAtomic -Path $configPath -Value $config
    }
    return $root
}

function Write-BridgeJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 40 -Compress
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tempPath, $Path, $true)
}

function Read-BridgeJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        $Default = $null,
        [switch]$AsHashtable
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($AsHashtable) { return $raw | ConvertFrom-Json -AsHashtable }
        return $raw | ConvertFrom-Json
    } catch {
        return $Default
    }
}

function Get-BridgeSyncState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ valid = $false; reason = 'missing'; cursor = '' }
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ valid = $false; reason = 'empty'; cursor = '' }
        }
        if ($raw.IndexOf([char]0) -ge 0) {
            return [pscustomobject]@{ valid = $false; reason = 'contains_nul'; cursor = '' }
        }

        $record = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($record -isnot [System.Collections.IDictionary] -or -not $record.Contains('get_updates_buf')) {
            return [pscustomobject]@{ valid = $false; reason = 'missing_cursor'; cursor = '' }
        }
        $cursor = ([string]$record['get_updates_buf']).Trim()
        if ([string]::IsNullOrWhiteSpace($cursor)) {
            return [pscustomobject]@{ valid = $false; reason = 'empty_cursor'; cursor = '' }
        }
        return [pscustomobject]@{ valid = $true; reason = 'healthy'; cursor = $cursor }
    } catch {
        return [pscustomobject]@{ valid = $false; reason = 'invalid_json'; cursor = '' }
    }
}

function Move-BridgeInvalidSyncFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $parent = Split-Path -Parent $Path
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $backupPath = Join-Path $parent "sync.corrupt-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    [System.IO.File]::Move($Path, $backupPath)
    return $backupPath
}

function Save-BridgeSyncCursorFromResponse {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Response
    )

    if (-not (Test-BridgeProperty -Object $Response -Name 'get_updates_buf')) {
        throw 'WeChat getUpdates returned no durable cursor; the previous cursor was preserved.'
    }
    $cursor = ([string]$Response.get_updates_buf).Trim()
    if ([string]::IsNullOrWhiteSpace($cursor)) {
        throw 'WeChat getUpdates returned an empty durable cursor; the previous cursor was preserved.'
    }
    Write-BridgeJsonAtomic -Path $Path -Value @{ get_updates_buf = $cursor }
    return $cursor
}

function Repair-BridgeSyncCursor {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Token,
        [int]$TimeoutSeconds = 40,
        [scriptblock]$FetchUpdates
    )

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatSyncRepair', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) }
        catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while waiting for the WeChat cursor repair lock.' }

        $state = Get-BridgeSyncState -Path $Path
        if ([bool]$state.valid) {
            return [pscustomobject]@{
                recovered = $false
                cursor = [string]$state.cursor
                reason = 'healthy'
                backup_path = ''
                discarded_message_count = 0
            }
        }

        $backupPath = Move-BridgeInvalidSyncFile -Path $Path
        $response = if ($FetchUpdates) {
            & $FetchUpdates
        } else {
            Invoke-IlinkRequest -BaseUrl $BaseUrl -Endpoint 'ilink/bot/getupdates' `
                -Method POST -Body @{ get_updates_buf = ''; base_info = Get-BridgeBaseInfo } `
                -Token $Token -TimeoutSeconds $TimeoutSeconds
        }

        $errcode = if ($response -and (Test-BridgeProperty -Object $response -Name 'errcode')) { [int]$response.errcode } else { 0 }
        $ret = if ($response -and (Test-BridgeProperty -Object $response -Name 'ret')) { [int]$response.ret } else { 0 }
        if ($errcode -ne 0 -or $ret -ne 0) {
            throw "WeChat cursor recovery failed with errcode=$errcode, ret=$ret."
        }
        $discardedCount = @(if (Test-BridgeProperty -Object $response -Name 'msgs') { @($response.msgs) } else { @() }).Count
        try {
            $cursor = Save-BridgeSyncCursorFromResponse -Path $Path -Response $response
        } catch {
            throw "WeChat cursor recovery failed: $($_.Exception.Message)"
        }
        $fingerprint = [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cursor))
        ).Substring(0, 16).ToLowerInvariant()
        $recovery = [ordered]@{
            recovered_at = [DateTimeOffset]::Now.ToString('o')
            reason = [string]$state.reason
            backup_path = $backupPath
            discarded_message_count = $discardedCount
            cursor_fingerprint = $fingerprint
        }
        Write-BridgeJsonAtomic -Path (Join-Path (Split-Path -Parent $Path) 'sync-recovery.json') -Value $recovery
        Write-BridgeLog -Level WARN -Message "WeChat cursor self-healed from '$($state.reason)'; discarded $discardedCount replay message(s) without execution."
        return [pscustomobject]@{
            recovered = $true
            cursor = $cursor
            reason = [string]$state.reason
            backup_path = $backupPath
            discarded_message_count = $discardedCount
        }
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-WithBridgeNotificationGate {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutSeconds = 60
    )
    $mutex = [Threading.Mutex]::new($false, 'Local\CodexWeChatNotificationGate')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSeconds)))
        if (-not $acquired) { throw 'Timed out while waiting for the notification queue lock.' }
        return & $Action
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-BridgeNotificationResetState {
    $path = Join-Path (Initialize-BridgeState) 'notification-reset.json'
    return Read-BridgeJson -Path $path -Default $null
}

function ConvertTo-BridgeEventTime {
    param([string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp, [ref]$parsed)) { return $null }
    # PowerShell 7 may deserialize an ISO-8601 `Z` timestamp into DateTime and
    # stringify it without its zone (for example, "08/17/2026 17:38:16").
    # Codex rollout timestamps are UTC, so an unqualified lifecycle timestamp
    # must remain UTC instead of being reinterpreted as the Windows local zone.
    if ($Timestamp -notmatch '(?i)(?:z|[+-]\d{2}:?\d{2})$') {
        $unspecifiedUtc = [DateTime]::SpecifyKind($parsed.DateTime, [DateTimeKind]::Unspecified)
        return [DateTimeOffset]::new($unspecifiedUtc, [TimeSpan]::Zero)
    }
    return $parsed
}

function Get-BridgeQueuedRecordTime {
    param(
        $Record,
        [Parameter(Mandatory)][IO.FileInfo]$File
    )
    foreach ($name in @('source_event_at', 'event_at', 'created_at')) {
        if (-not $Record -or -not (Test-BridgeProperty -Object $Record -Name $name)) { continue }
        if ($name -in @('source_event_at', 'event_at')) {
            $eventTime = ConvertTo-BridgeEventTime -Timestamp ([string]$Record.$name)
            if ($null -ne $eventTime) { return $eventTime }
        } else {
            $parsed = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$Record.$name, [ref]$parsed)) { return $parsed }
        }
    }
    return [DateTimeOffset]$File.LastWriteTimeUtc
}

function Test-BridgeNotificationAfterReset {
    param([string]$Timestamp)
    $reset = Get-BridgeNotificationResetState
    if (-not $reset -or -not (Test-BridgeProperty -Object $reset -Name 'cutoff_at')) { return $true }
    $cutoff = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$reset.cutoff_at, [ref]$cutoff)) { return $true }
    $candidate = ConvertTo-BridgeEventTime -Timestamp $Timestamp
    if ($null -eq $candidate) { $candidate = [DateTimeOffset]::Now }
    return $candidate -gt $cutoff
}

function Move-BridgeQueuedRecordsAtOrBeforeReset {
    param([ValidateSet('outbox', 'attachment-outbox', 'all')][string]$Queue = 'all')
    $root = Initialize-BridgeState
    $reset = Get-BridgeNotificationResetState
    if (-not $reset -or -not (Test-BridgeProperty -Object $reset -Name 'cutoff_at')) {
        return [pscustomobject]@{ text = 0; attachments = 0 }
    }
    $cutoff = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$reset.cutoff_at, [ref]$cutoff)) {
        return [pscustomobject]@{ text = 0; attachments = 0 }
    }
    $archiveId = if ((Test-BridgeProperty -Object $reset -Name 'archive_id') -and $reset.archive_id) {
        [string]$reset.archive_id
    } else { 'reset-' + $cutoff.ToString('yyyyMMddHHmmssfff') }
    $archiveRoot = Join-Path (Join-Path $root 'cleared') $archiveId
    $queues = if ($Queue -eq 'all') { @('outbox', 'attachment-outbox') } else { @($Queue) }
    $textCount = 0
    $attachmentCount = 0
    foreach ($queueName in $queues) {
        $source = Join-Path $root $queueName
        $destination = Join-Path $archiveRoot ("late-$queueName")
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $source -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $record = Read-BridgeJson -Path $file.FullName -Default $null
            if ((Get-BridgeQueuedRecordTime -Record $record -File $file) -gt $cutoff) { continue }
            if ($queueName -eq 'outbox' -and $record -and $record.session_id -and $record.turn_id) {
                Set-CodexNotificationState -SessionId ([string]$record.session_id) `
                    -TurnId ([string]$record.turn_id) -State suppressed
            }
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -Force
            if ($queueName -eq 'outbox') { $textCount++ } else { $attachmentCount++ }
        }
    }
    if ($textCount -gt 0 -or $attachmentCount -gt 0) {
        Write-BridgeLog -Level INFO -Message "Reset watermark archived late backlog: text=$textCount, attachments=$attachmentCount."
    }
    return [pscustomobject]@{ text = $textCount; attachments = $attachmentCount }
}

function Clear-CodexWeChatNotificationBacklog {
    return Invoke-WithBridgeNotificationGate -Action {
        $root = Initialize-BridgeState
        $cutoff = [DateTimeOffset]::Now
        $archiveId = 'reset-' + $cutoff.ToString('yyyyMMddHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $archiveRoot = Join-Path (Join-Path $root 'cleared') $archiveId
        [IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
        $resetPath = Join-Path $root 'notification-reset.json'
        $reset = [ordered]@{
            schema_version = 1
            reset_id = [guid]::NewGuid().ToString('N')
            archive_id = $archiveId
            cutoff_at = $cutoff.ToString('o')
            completed_at = $null
            text_archived = 0
            attachments_archived = 0
        }
        # Publish the cutoff before touching either queue. All producers and
        # flushers consult this independent watermark, so a restart cannot
        # resurrect an event that belongs to the pre-reset period.
        Write-BridgeJsonAtomic -Path $resetPath -Value $reset

        $textCount = 0
        $attachmentCount = 0
        foreach ($queueName in @('outbox', 'attachment-outbox')) {
            $source = Join-Path $root $queueName
            $destination = Join-Path $archiveRoot $queueName
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            foreach ($file in @(Get-ChildItem -LiteralPath $source -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                $record = Read-BridgeJson -Path $file.FullName -Default $null
                if ($queueName -eq 'outbox' -and $record -and $record.session_id -and $record.turn_id) {
                    Set-CodexNotificationState -SessionId ([string]$record.session_id) `
                        -TurnId ([string]$record.turn_id) -State suppressed
                }
                Move-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name) -Force
                if ($queueName -eq 'outbox') { $textCount++ } else { $attachmentCount++ }
            }
        }
        $reset.text_archived = $textCount
        $reset.attachments_archived = $attachmentCount
        $reset.completed_at = [DateTimeOffset]::Now.ToString('o')
        Write-BridgeJsonAtomic -Path $resetPath -Value $reset
        Write-BridgeLog -Level INFO -Message "Notification backlog reset completed: text=$textCount, attachments=$attachmentCount, archive=$archiveId."
        return [pscustomobject]@{
            cutoff_at = [string]$reset.cutoff_at
            text_archived = $textCount
            attachments_archived = $attachmentCount
            archive_path = $archiveRoot
        }
    }
}

function Write-BridgeLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    $root = Initialize-BridgeState
    $safe = $Message -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+', '$1***'
    $safe = $safe -replace '(?i)(token[=:]\s*)[^\s,;]+', '$1***'
    $record = [ordered]@{
        ts = [DateTimeOffset]::Now.ToString('o')
        level = $Level
        message = $safe
    } | ConvertTo-Json -Compress
    $logPath = Join-Path (Join-Path $root 'logs') ("bridge-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
    [System.IO.File]::AppendAllText($logPath, $record + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Remove-BridgeExpiredLogs {
    $root = Initialize-BridgeState
    $config = Get-BridgeConfig
    $now = [DateTimeOffset]::Now
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'logs') -File -ErrorAction SilentlyContinue)) {
        $retentionDays = if ($file.Name -like 'relay-worker-*') {
            [Math]::Max(1, [int]$config.worker_log_retention_days)
        } else {
            [Math]::Max(1, [int]$config.log_retention_days)
        }
        if (($now - [DateTimeOffset]$file.LastWriteTimeUtc).TotalDays -gt $retentionDays) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    return $removed
}

function Protect-BridgeString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Unprotect-BridgeString {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $secure = ConvertTo-SecureString -String $Value
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-BridgeConfig {
    $root = Initialize-BridgeState
    $configPath = Join-Path $root 'config.json'
    $config = Read-BridgeJson -Path $configPath -Default ([pscustomobject]@{})
    $changed = $false
    foreach ($entry in (Get-BridgeDefaultConfig).GetEnumerator()) {
        if ($config.PSObject.Properties.Name -notcontains $entry.Key) {
            $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
            $changed = $true
        }
    }
    $previousVersion = [string]$config.bridge_version
    if ($previousVersion -ne $script:BridgeVersion) {
        $config.bridge_version = $script:BridgeVersion
        $config.bot_agent = $script:BotAgent
        if ([string]$config.relay_transport -in @('desktop_ui', 'app_server')) {
            $config.relay_transport = 'desktop_single_writer'
        }
        if ([int]$config.completion_attachment_max_files -eq 3) {
            $config.completion_attachment_max_files = 10
        }
        $changed = $true
    }
    if ([int]$config.context_refresh_timeout_seconds -lt 40) {
        $config.context_refresh_timeout_seconds = 45
        $changed = $true
    }
    if ([bool]$config.require_completion_quote -and [bool]$config.direct_reply_enabled) {
        $config.direct_reply_enabled = $false
        $changed = $true
    }
    $allowedExtensions = @($config.completion_attachment_allowed_extensions | ForEach-Object {
        ([string]$_).Trim().ToLowerInvariant()
    } | Where-Object { $_ -and $_ -ne '.md' } | Select-Object -Unique)
    if (@($config.completion_attachment_allowed_extensions).Count -ne $allowedExtensions.Count -or
        @($config.completion_attachment_allowed_extensions | Where-Object { ([string]$_).Trim().ToLowerInvariant() -eq '.md' }).Count -gt 0) {
        $config.completion_attachment_allowed_extensions = $allowedExtensions
        $changed = $true
    }
    if ($changed) { Write-BridgeJsonAtomic -Path $configPath -Value $config }
    return $config
}

function Save-BridgeConfig {
    param([Parameter(Mandatory)]$Config)
    $root = Initialize-BridgeState
    Write-BridgeJsonAtomic -Path (Join-Path $root 'config.json') -Value $Config
}

function Get-BridgeSecrets {
    $root = Initialize-BridgeState
    return Read-BridgeJson -Path (Join-Path $root 'secrets.json') -Default @{} -AsHashtable
}

function Set-BridgeSecret {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $root = Initialize-BridgeState
    $secrets = Get-BridgeSecrets
    $secrets[$Name] = Protect-BridgeString -Value $Value
    Write-BridgeJsonAtomic -Path (Join-Path $root 'secrets.json') -Value $secrets
}

function Get-BridgeSecret {
    param([Parameter(Mandatory)][string]$Name)
    $secrets = Get-BridgeSecrets
    if (-not $secrets.ContainsKey($Name)) { return $null }
    return Unprotect-BridgeString -Value ([string]$secrets[$Name])
}

function Get-RandomWechatUin {
    $bytes = [byte[]]::new(4)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $value = [System.BitConverter]::ToUInt32($bytes, 0)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$value))
}

function Get-BridgeBaseInfo {
    return [ordered]@{
        channel_version = $script:BridgeVersion
        bot_agent = $script:BotAgent
    }
}

function Get-BridgeDeliveryState {
    $path = Join-Path (Initialize-BridgeState) 'delivery-state.json'
    return Read-BridgeJson -Path $path -Default ([pscustomobject]@{
        state = 'unknown'
        updated_at = $null
        next_retry_at = $null
        last_error = $null
    })
}

function Set-BridgeDeliveryState {
    param(
        [Parameter(Mandatory)][ValidateSet('unknown', 'healthy', 'refreshing', 'waiting_for_wechat')][string]$State,
        [hashtable]$Extra
    )
    $path = Join-Path (Initialize-BridgeState) 'delivery-state.json'
    $existing = Read-BridgeJson -Path $path -Default ([pscustomobject]@{})
    $record = [ordered]@{}
    foreach ($property in $existing.PSObject.Properties) { $record[$property.Name] = $property.Value }
    $record.state = $State
    $record.updated_at = [DateTimeOffset]::Now.ToString('o')
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $record[$key] = $Extra[$key] }
    }
    Write-BridgeJsonAtomic -Path $path -Value $record
    return [pscustomobject]$record
}

function Set-BridgeContextToken {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token,
        [ValidateSet('inbound', 'recovery', 'login')][string]$Source = 'inbound'
    )
    Set-BridgeSecret -Name 'context_token' -Value $Token
    $fingerprint = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Token))
    ).Substring(0, 16).ToLowerInvariant()
    Set-BridgeDeliveryState -State healthy -Extra @{
        context_source = $Source
        context_updated_at = [DateTimeOffset]::Now.ToString('o')
        context_fingerprint = $fingerprint
        next_retry_at = $null
        last_error = $null
    } | Out-Null
}

function Test-BridgeDeliveryRetryDue {
    param($DeliveryState)
    if (-not $DeliveryState -or [string]$DeliveryState.state -ne 'waiting_for_wechat') { return $true }
    if (-not (Test-BridgeProperty -Object $DeliveryState -Name 'next_retry_at') -or
        [string]::IsNullOrWhiteSpace([string]$DeliveryState.next_retry_at)) { return $true }
    try { return [DateTimeOffset]::Now -ge [DateTimeOffset]::Parse([string]$DeliveryState.next_retry_at) }
    catch { return $true }
}

function Refresh-BridgeContextToken {
    param([switch]$Force)
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatContextRefresh', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return $false }
        $config = Get-BridgeConfig
        $delivery = Get-BridgeDeliveryState
        if (-not $Force -and -not (Test-BridgeDeliveryRetryDue -DeliveryState $delivery)) { return $false }
        $now = [DateTimeOffset]::Now
        Set-BridgeDeliveryState -State refreshing -Extra @{
            last_refresh_attempt_at = $now.ToString('o')
            last_error = $null
        } | Out-Null

        $token = Get-BridgeSecret -Name 'bot_token'
        if (-not $token) { throw 'WeChat bridge is not logged in.' }
        $response = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/getupdates' `
            -Method POST -Body @{ get_updates_buf = ''; base_info = Get-BridgeBaseInfo } `
            -Token $token -TimeoutSeconds ([int]$config.context_refresh_timeout_seconds)
        $ret = if ($response.PSObject.Properties.Name -contains 'ret') { [int]$response.ret } else { 0 }
        if ($ret -ne 0) { throw "WeChat context refresh returned ret=$ret." }
        $messages = @(if ($response.PSObject.Properties.Name -contains 'msgs') { @($response.msgs) })
        $authorized = @($messages | Where-Object {
            (Test-BridgeProperty -Object $_ -Name 'context_token') -and $_.context_token -and
            (Test-BridgeProperty -Object $_ -Name 'from_user_id') -and
            [string]$_.from_user_id -eq [string]$config.scanner_user_id
        } | Sort-Object {
            if (Test-BridgeProperty -Object $_ -Name 'create_time_ms') { [long]$_.create_time_ms } else { 0L }
        } -Descending)
        if ($authorized.Count -eq 0) { throw 'No reusable WeChat context was returned.' }
        Set-BridgeContextToken -Token ([string]$authorized[0].context_token) -Source recovery
        Write-BridgeLog -Level INFO -Message 'WeChat context token refreshed from a non-executing getUpdates replay.'
        return $true
    } catch {
        $config = Get-BridgeConfig
        $retryAt = [DateTimeOffset]::Now.AddSeconds([int]$config.context_retry_cooldown_seconds)
        $errorMessage = $_.Exception.Message
        if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + '…' }
        Set-BridgeDeliveryState -State waiting_for_wechat -Extra @{
            next_retry_at = $retryAt.ToString('o')
            last_error = $errorMessage
        } | Out-Null
        Write-BridgeLog -Level WARN -Message "WeChat context refresh deferred: $errorMessage"
        return $false
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Invoke-IlinkRequest {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST')][string]$Method = 'POST',
        $Body = $null,
        [string]$Token,
        [int]$TimeoutSeconds = 15
    )
    $base = $BaseUrl.TrimEnd('/') + '/'
    $uri = [Uri]::new([Uri]$base, $Endpoint.TrimStart('/'))
    $httpMethod = if ($Method -eq 'GET') {
        [System.Net.Http.HttpMethod]::Get
    } else {
        [System.Net.Http.HttpMethod]::Post
    }
    $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $uri)
    $null = $request.Headers.TryAddWithoutValidation('iLink-App-Id', $script:IlinkAppId)
    $null = $request.Headers.TryAddWithoutValidation('iLink-App-ClientVersion', [string]$script:IlinkClientVersion)
    $null = $request.Headers.TryAddWithoutValidation('AuthorizationType', 'ilink_bot_token')
    $null = $request.Headers.TryAddWithoutValidation('X-WECHAT-UIN', (Get-RandomWechatUin))
    if ($Token) { $null = $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") }
    if ($Method -eq 'POST') {
        $json = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 40 -Compress }
        $request.Content = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    }

    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $response = $null
    try {
        $response = $script:HttpClient.SendAsync($request, $cts.Token).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $preview = if ($text.Length -gt 300) { $text.Substring(0, 300) } else { $text }
            throw "HTTP $([int]$response.StatusCode): $preview"
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
        return $text | ConvertFrom-Json
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $cts.Dispose()
    }
}

function Invoke-BridgeTypingHandshake {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ToUserId,
        [string]$ContextToken,
        [int]$TimeoutSeconds = 10
    )
    try {
        $configBody = [ordered]@{
            ilink_user_id = $ToUserId
            base_info = Get-BridgeBaseInfo
        }
        if (-not [string]::IsNullOrWhiteSpace($ContextToken)) {
            $configBody.context_token = $ContextToken
        }
        $typingConfig = Invoke-IlinkRequest -BaseUrl ([string]$Config.base_url) `
            -Endpoint 'ilink/bot/getconfig' -Method POST -Body $configBody `
            -Token $Token -TimeoutSeconds $TimeoutSeconds
        $configRet = if (Test-BridgeProperty -Object $typingConfig -Name 'ret') { [int]$typingConfig.ret } else { 0 }
        if ($configRet -ne 0) { throw "WeChat getConfig failed with ret=$configRet." }
        $ticket = if (Test-BridgeProperty -Object $typingConfig -Name 'typing_ticket') {
            [string]$typingConfig.typing_ticket
        } else { '' }
        if ([string]::IsNullOrWhiteSpace($ticket)) { throw 'WeChat getConfig returned no typing ticket.' }

        $typing = Invoke-IlinkRequest -BaseUrl ([string]$Config.base_url) `
            -Endpoint 'ilink/bot/sendtyping' -Method POST -Body @{
                ilink_user_id = $ToUserId
                typing_ticket = $ticket
                status = 1
                base_info = Get-BridgeBaseInfo
            } -Token $Token -TimeoutSeconds $TimeoutSeconds
        $typingRet = if (Test-BridgeProperty -Object $typing -Name 'ret') { [int]$typing.ret } else { 0 }
        if ($typingRet -ne 0) { throw "WeChat sendTyping failed with ret=$typingRet." }
        return $true
    } catch {
        Write-BridgeLog -Level WARN -Message "WeChat typing handshake skipped: $($_.Exception.Message)"
        return $false
    }
}

function Save-BridgeStatus {
    param(
        [Parameter(Mandatory)][string]$State,
        [string]$Detail,
        [hashtable]$Extra
    )
    $root = Initialize-BridgeState
    $status = [ordered]@{
        state = $State
        detail = $Detail
        updated_at = [DateTimeOffset]::Now.ToString('o')
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $status[$key] = $Extra[$key] }
    }
    Write-BridgeJsonAtomic -Path (Join-Path $root 'status.json') -Value $status
}

function Connect-CodexWeChatBridge {
    param(
        [int]$TimeoutSeconds = 480,
        [switch]$OpenBrowser,
        [string]$VerifyCode
    )
    Initialize-BridgeState | Out-Null
    Save-BridgeStatus -State 'login_starting' -Detail 'Requesting QR code'
    $qr = Invoke-IlinkRequest -BaseUrl $script:DefaultBaseUrl `
        -Endpoint 'ilink/bot/get_bot_qrcode?bot_type=3' -Method POST `
        -Body @{ local_token_list = @() } -TimeoutSeconds 20
    if (-not $qr.qrcode -or -not $qr.qrcode_img_content) {
        throw 'WeChat did not return a QR code.'
    }

    $root = Get-BridgeStateRoot
    Set-BridgeSecret -Name 'login_qrcode' -Value ([string]$qr.qrcode)
    [System.IO.File]::WriteAllText((Join-Path $root 'qrcode-url.txt'), [string]$qr.qrcode_img_content, [Text.UTF8Encoding]::new($false))
    Save-BridgeStatus -State 'waiting_for_scan' -Detail 'Scan the QR code in the browser' -Extra @{ qrcode_url = [string]$qr.qrcode_img_content }
    if ($OpenBrowser) { Start-Process ([string]$qr.qrcode_img_content) }

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $pollBaseUrl = $script:DefaultBaseUrl
    while ([DateTimeOffset]::Now -lt $deadline) {
        $endpoint = "ilink/bot/get_qrcode_status?qrcode=$([Uri]::EscapeDataString([string]$qr.qrcode))"
        if ($VerifyCode) { $endpoint += "&verify_code=$([Uri]::EscapeDataString($VerifyCode))" }
        try {
            $result = Invoke-IlinkRequest -BaseUrl $pollBaseUrl -Endpoint $endpoint -Method GET -TimeoutSeconds 40
        } catch [System.Threading.Tasks.TaskCanceledException] {
            continue
        } catch {
            Write-BridgeLog -Level WARN -Message "QR polling retry: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
            continue
        }

        switch ([string]$result.status) {
            'wait' { }
            'scaned' { Save-BridgeStatus -State 'scanned' -Detail 'Confirm the connection in WeChat' }
            'scaned_but_redirect' {
                if ($result.redirect_host) { $pollBaseUrl = "https://$($result.redirect_host)" }
            }
            'need_verifycode' {
                Save-BridgeStatus -State 'verification_required' -Detail 'A verification code is required' -Extra @{ qrcode_url = [string]$qr.qrcode_img_content }
                throw 'WeChat requested a verification code. Re-run Connect-WeChatBridge.ps1 with -VerifyCode.'
            }
            'verify_code_blocked' {
                Save-BridgeStatus -State 'verification_blocked' -Detail 'Verification was blocked by WeChat'
                throw 'WeChat blocked the verification attempt. Generate a new QR code and retry.'
            }
            'binded_redirect' {
                if (Get-BridgeSecret -Name 'bot_token') {
                    Save-BridgeStatus -State 'connected' -Detail 'Existing WeChat credentials remain active'
                    return Get-CodexWeChatBridgeStatus
                }
                throw 'This ClawBot is already bound elsewhere and no local credentials are available.'
            }
            'expired' {
                Save-BridgeStatus -State 'qr_expired' -Detail 'The QR code expired; retry login'
                throw 'The QR code expired. Run the login command again.'
            }
            'confirmed' {
                if (-not $result.bot_token -or -not $result.ilink_bot_id) {
                    throw 'WeChat confirmed the scan without returning complete credentials.'
                }
                $config = Get-BridgeConfig
                $config.base_url = if ($result.baseurl) { [string]$result.baseurl } else { $pollBaseUrl }
                $config.account_id = [string]$result.ilink_bot_id
                $config.scanner_user_id = [string]$result.ilink_user_id
                $config.target_user_id = [string]$result.ilink_user_id
                $config.peer_confirmed = $false
                Save-BridgeConfig -Config $config
                Set-BridgeSecret -Name 'bot_token' -Value ([string]$result.bot_token)
                Save-BridgeStatus -State 'connected_waiting_for_message' -Detail 'Send a message to ClawBot to activate completion notifications'
                Write-BridgeLog -Level INFO -Message 'WeChat QR login confirmed.'
                return Get-CodexWeChatBridgeStatus
            }
        }
        Start-Sleep -Milliseconds 700
    }
    Save-BridgeStatus -State 'login_timeout' -Detail 'QR login timed out'
    throw 'Timed out waiting for the WeChat QR confirmation.'
}

function Send-BridgeMessageItems {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$Items,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 10,
        [switch]$AllowContextlessRetry
    )
    $config = Get-BridgeConfig
    $token = Get-BridgeSecret -Name 'bot_token'
    if (-not $token) { throw 'WeChat bridge is not logged in.' }
    if (-not $ToUserId) { $ToUserId = [string]$config.target_user_id }
    if (-not $ToUserId) { throw 'No WeChat target user is known yet.' }
    $deliveryState = Get-BridgeDeliveryState
    if ($AllowContextlessRetry -and [string]$deliveryState.state -eq 'waiting_for_wechat') {
        if (-not (Test-BridgeDeliveryRetryDue -DeliveryState $deliveryState)) {
            throw 'WeChat context is stale; waiting for a fresh inbound WeChat message.'
        }
        if (-not (Refresh-BridgeContextToken)) {
            throw 'WeChat context is stale; send any message to the ClawBot to resume queued notifications.'
        }
    }
    $contextToken = Get-BridgeSecret -Name 'context_token'
    $clientId = "codex-wechat-$([guid]::NewGuid().ToString('N'))"
    $normalizedItems = @($Items)
    if ($normalizedItems.Count -eq 0) { throw 'At least one WeChat message item is required.' }
    for ($index = 0; $index -lt $normalizedItems.Count; $index++) {
        $item = $normalizedItems[$index]
        $itemId = if ($index -eq 0) { $clientId } else { "$clientId-item-$index" }
        if ($item -is [System.Collections.IDictionary]) {
            if (-not $item.Contains('msg_id') -or [string]::IsNullOrWhiteSpace([string]$item['msg_id'])) {
                $item['msg_id'] = $itemId
            }
        } elseif ($item.PSObject.Properties.Name -notcontains 'msg_id') {
            $item | Add-Member -NotePropertyName msg_id -NotePropertyValue $itemId
        } elseif ([string]::IsNullOrWhiteSpace([string]$item.msg_id)) {
            $item.msg_id = $itemId
        }
    }

    $buildBody = {
        param([string]$Context)
        $msg = [ordered]@{
            from_user_id = ''
            to_user_id = $ToUserId
            client_id = $clientId
            message_type = 2
            message_state = 2
            item_list = @($normalizedItems)
        }
        if ($Context) { $msg.context_token = $Context }
        return @{ msg = $msg; base_info = Get-BridgeBaseInfo }
    }

    Invoke-BridgeTypingHandshake -Config $config -Token $token -ToUserId $ToUserId `
        -ContextToken $contextToken -TimeoutSeconds ([Math]::Min(10, $TimeoutSeconds)) | Out-Null
    $sendStartedAt = [DateTimeOffset]::Now
    $response = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/sendmessage' `
        -Method POST -Body (& $buildBody $contextToken) -Token $token -TimeoutSeconds $TimeoutSeconds
    $ret = if ($response.PSObject.Properties.Name -contains 'ret') { [int]$response.ret } else { 0 }
    if ($ret -eq -2 -and $AllowContextlessRetry) {
        if (Refresh-BridgeContextToken -Force) {
            $contextToken = Get-BridgeSecret -Name 'context_token'
            Invoke-BridgeTypingHandshake -Config $config -Token $token -ToUserId $ToUserId `
                -ContextToken $contextToken -TimeoutSeconds ([Math]::Min(10, $TimeoutSeconds)) | Out-Null
            $response = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/sendmessage' `
                -Method POST -Body (& $buildBody $contextToken) -Token $token -TimeoutSeconds $TimeoutSeconds
            $ret = if ($response.PSObject.Properties.Name -contains 'ret') { [int]$response.ret } else { 0 }
        }
        if ($ret -eq -2) {
            Write-BridgeLog -Level WARN -Message 'WeChat context remained stale; attempting one contextless send.'
            Invoke-BridgeTypingHandshake -Config $config -Token $token -ToUserId $ToUserId `
                -TimeoutSeconds ([Math]::Min(10, $TimeoutSeconds)) | Out-Null
            $response = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/sendmessage' `
                -Method POST -Body (& $buildBody $null) -Token $token -TimeoutSeconds $TimeoutSeconds
            $ret = if ($response.PSObject.Properties.Name -contains 'ret') { [int]$response.ret } else { 0 }
            if ($ret -eq 0) {
                Set-BridgeSecret -Name 'context_token' -Value ''
            }
        }
    }
    if ($ret -ne 0) {
        if ($ret -eq -2) {
            $retryAt = [DateTimeOffset]::Now.AddSeconds([int]$config.context_retry_cooldown_seconds)
            Set-BridgeDeliveryState -State waiting_for_wechat -Extra @{
                next_retry_at = $retryAt.ToString('o')
                last_error = 'WeChat send failed with ret=-2.'
            } | Out-Null
        }
        throw "WeChat send failed with ret=$ret."
    }
    Set-BridgeDeliveryState -State healthy -Extra @{
        last_success_at = [DateTimeOffset]::Now.ToString('o')
        next_retry_at = $null
        last_error = $null
    } | Out-Null
    $sendCompletedAt = [DateTimeOffset]::Now
    return [pscustomobject]@{
        sent = $true
        to = $ToUserId
        message_id = $clientId
        client_id = $clientId
        item_message_id = $clientId
        item_count = $normalizedItems.Count
        send_started_at = $sendStartedAt.ToString('o')
        send_completed_at = $sendCompletedAt.ToString('o')
    }
}

function Send-BridgeMessageItem {
    param(
        [Parameter(Mandatory)]$Item,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 10,
        [switch]$AllowContextlessRetry
    )
    return Send-BridgeMessageItems -Items @($Item) -ToUserId $ToUserId `
        -TimeoutSeconds $TimeoutSeconds -AllowContextlessRetry:$AllowContextlessRetry
}

function Send-BridgeText {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 10,
        [switch]$AllowContextlessRetry
    )
    return Send-BridgeMessageItem -Item @{ type = 1; text_item = @{ text = $Text } } `
        -ToUserId $ToUserId -TimeoutSeconds $TimeoutSeconds -AllowContextlessRetry:$AllowContextlessRetry
}

function Send-BridgeRoutableText {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 15,
        [switch]$AllowContextlessRetry,
        [int]$MinimumIntervalMilliseconds = 3000
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatRoutableNotificationSlot', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while reserving a routable WeChat notification slot.' }
        $slotPath = Join-Path (Initialize-BridgeState) 'notification-slot.json'
        $slot = Read-BridgeJson -Path $slotPath -Default ([pscustomobject]@{ last_send_completed_at = $null })
        if ((Test-BridgeProperty -Object $slot -Name 'last_send_completed_at') -and $slot.last_send_completed_at) {
            $lastCompletedAt = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse([string]$slot.last_send_completed_at, [ref]$lastCompletedAt)) {
                $waitUntil = $lastCompletedAt.AddMilliseconds([Math]::Max(1000, $MinimumIntervalMilliseconds))
                $remaining = [int][Math]::Ceiling(($waitUntil - [DateTimeOffset]::Now).TotalMilliseconds)
                if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
            }
        }
        $delivery = Send-BridgeText -Text $Text -ToUserId $ToUserId -TimeoutSeconds $TimeoutSeconds `
            -AllowContextlessRetry:$AllowContextlessRetry
        Write-BridgeJsonAtomic -Path $slotPath -Value ([ordered]@{
            last_send_completed_at = [string]$delivery.send_completed_at
            client_id = [string]$delivery.client_id
            updated_at = [DateTimeOffset]::Now.ToString('o')
        })
        return $delivery
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Protect-BridgeMediaBytes {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 128
        $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $encryptor = $aes.CreateEncryptor()
        try { return $encryptor.TransformFinalBlock($Bytes, 0, $Bytes.Length) }
        finally { $encryptor.Dispose() }
    } finally {
        $aes.Dispose()
    }
}

function Send-BridgeCdnRequest {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Url,
        [Parameter(Mandatory)][byte[]]$Ciphertext,
        [int]$TimeoutSeconds = 90
    )
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
        $content = [System.Net.Http.ByteArrayContent]::new($Ciphertext)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $request.Content = $content
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
        $response = $null
        try {
            $response = $script:HttpClient.SendAsync($request, $cts.Token).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -ge 400 -and [int]$response.StatusCode -lt 500) {
                $detail = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "WeChat CDN upload client error $([int]$response.StatusCode): $detail"
            }
            if (-not $response.IsSuccessStatusCode) {
                throw "WeChat CDN upload failed with HTTP $([int]$response.StatusCode)."
            }
            $values = $null
            if (-not $response.Headers.TryGetValues('x-encrypted-param', [ref]$values)) {
                throw 'WeChat CDN upload response did not include x-encrypted-param.'
            }
            return [string](@($values)[0])
        } catch {
            $lastError = $_.Exception
            if ($_.Exception.Message -match 'client error') { throw }
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (350 * $attempt) }
        } finally {
            if ($response) { $response.Dispose() }
            $cts.Dispose()
            $request.Dispose()
        }
    }
    throw $lastError
}

function New-BridgeFileMessageItem {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 90
    )
    $config = Get-BridgeConfig
    $token = Get-BridgeSecret -Name 'bot_token'
    if (-not $token) { throw 'WeChat bridge is not logged in.' }
    if (-not $ToUserId) { $ToUserId = [string]$config.target_user_id }
    if (-not $ToUserId) { throw 'No WeChat target user is known yet.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Attachment not found: $fullPath" }
    $file = Get-Item -LiteralPath $fullPath
    $maxBytes = [long]$config.completion_attachment_max_bytes
    if ($file.Length -gt $maxBytes) {
        throw "Attachment exceeds the configured limit of $maxBytes bytes: $($file.Name)"
    }

    $plain = [System.IO.File]::ReadAllBytes($fullPath)
    $key = [byte[]]::new(16)
    $fileKeyBytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($fileKeyBytes)
    $fileKey = [Convert]::ToHexString($fileKeyBytes).ToLowerInvariant()
    $aesKeyHex = [Convert]::ToHexString($key).ToLowerInvariant()
    $md5 = [Convert]::ToHexString([System.Security.Cryptography.MD5]::HashData($plain)).ToLowerInvariant()
    $ciphertext = Protect-BridgeMediaBytes -Bytes $plain -Key $key

    $upload = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/getuploadurl' `
        -Method POST -Body @{
            filekey = $fileKey
            media_type = 3
            to_user_id = $ToUserId
            rawsize = [long]$plain.Length
            rawfilemd5 = $md5
            filesize = [long]$ciphertext.Length
            no_need_thumb = $true
            aeskey = $aesKeyHex
            base_info = Get-BridgeBaseInfo
        } -Token $token -TimeoutSeconds 20
    $uploadRet = if (Test-BridgeProperty -Object $upload -Name 'ret') { [int]$upload.ret } else { 0 }
    if ($uploadRet -ne 0) { throw "WeChat getUploadUrl failed with ret=$uploadRet." }
    $uploadUrl = if ((Test-BridgeProperty -Object $upload -Name 'upload_full_url') -and $upload.upload_full_url) {
        [string]$upload.upload_full_url
    } elseif ((Test-BridgeProperty -Object $upload -Name 'upload_param') -and $upload.upload_param) {
        '{0}/upload?encrypted_query_param={1}&filekey={2}' -f `
            ([string]$config.cdn_base_url).TrimEnd('/'), `
            [Uri]::EscapeDataString([string]$upload.upload_param), `
            [Uri]::EscapeDataString($fileKey)
    } else {
        throw 'WeChat getUploadUrl returned no upload URL.'
    }
    $downloadParam = Send-BridgeCdnRequest -Url $uploadUrl -Ciphertext $ciphertext -TimeoutSeconds $TimeoutSeconds
    # Tencent's current official plugin uses base64(hex-string) for file/voice/video keys.
    $mediaKey = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($aesKeyHex))
    return [pscustomobject]@{
        item = @{
        type = 4
        file_item = @{
            media = @{
                encrypt_query_param = $downloadParam
                aes_key = $mediaKey
                encrypt_type = 1
            }
            file_name = $file.Name
            md5 = $md5
            len = [string]$plain.Length
        }
        }
        path = $fullPath
        name = $file.Name
        bytes = [long]$file.Length
    }
}

function Send-BridgeFile {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$ToUserId,
        [int]$TimeoutSeconds = 90,
        [switch]$AllowContextlessRetry
    )
    $prepared = New-BridgeFileMessageItem -Path $Path -ToUserId $ToUserId -TimeoutSeconds $TimeoutSeconds
    Send-BridgeMessageItem -Item $prepared.item -ToUserId $ToUserId -TimeoutSeconds 15 `
        -AllowContextlessRetry:$AllowContextlessRetry | Out-Null
    Write-BridgeLog -Level INFO -Message "WeChat attachment sent: $($prepared.name) ($($prepared.bytes) bytes)."
    return [pscustomobject]@{ sent = $true; path = $prepared.path; name = $prepared.name; bytes = [long]$prepared.bytes }
}

function Queue-BridgeMessage {
    param([Parameter(Mandatory)]$Message)
    $root = Initialize-BridgeState
    $name = '{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N'))
    Write-BridgeJsonAtomic -Path (Join-Path (Join-Path $root 'outbox') $name) -Value $Message
}

function Get-BridgeAttachmentKey {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [long]$Bytes = -1,
        [string]$Sha256
    )
    $fullPath = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    $material = '{0}|{1}|{2}|{3}' -f $SessionId.ToLowerInvariant(), $fullPath.ToLowerInvariant(), $Bytes, $Sha256
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))
    ).ToLowerInvariant()
}

function Test-BridgeAttachmentExtensionAllowed {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $extension = [IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrWhiteSpace($extension)) { return $false }
    $config = Get-BridgeConfig
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($config.completion_attachment_allowed_extensions)) {
        $normalized = ([string]$item).Trim()
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        if (-not $normalized.StartsWith('.')) { $normalized = ".$normalized" }
        [void]$allowed.Add($normalized)
    }
    return $allowed.Contains($extension)
}

function Get-BridgeAttachmentQueueRecords {
    param(
        [string]$SessionId,
        [string]$TurnId,
        [ValidateSet('queued', 'sent', 'failed', 'all')][string]$State = 'all'
    )
    $root = Initialize-BridgeState
    $folders = switch ($State) {
        'queued' { @('attachment-outbox') }
        'sent' { @('attachment-sent') }
        'failed' { @('attachment-failed') }
        default { @('attachment-outbox', 'attachment-sent', 'attachment-failed') }
    }
    $records = foreach ($folder in $folders) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root $folder) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $record = Read-BridgeJson -Path $file.FullName -Default $null
            if (-not $record) { continue }
            if ($SessionId -and [string]$record.session_id -ne $SessionId) { continue }
            if ($TurnId -and [string]$record.turn_id -ne $TurnId) { continue }
            [pscustomobject]@{ file = $file; record = $record; folder = $folder }
        }
    }
    return @($records | Sort-Object { [DateTimeOffset]$_.record.created_at }, { [int]$_.record.ordinal })
}

function Add-BridgeAttachmentQueueRecord {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName,
        [string]$Cwd,
        [Parameter(Mandatory)]$Attachment,
        [int]$Ordinal = 1,
        [int]$Total = 1,
        [string]$Source = 'completion'
    )
    $path = if ($Attachment -is [string]) { [string]$Attachment } else { [string]$Attachment.path }
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    $fullPath = try { [IO.Path]::GetFullPath($path) } catch { $path }
    if (-not (Test-BridgeAttachmentExtensionAllowed -Path $fullPath)) {
        Write-BridgeLog -Level INFO -Message "Skipped attachment queue request because its extension is not deliverable: $([IO.Path]::GetFileName($fullPath))"
        return [pscustomobject]@{ queued = $false; duplicate = $false; excluded = $true; key = $null; path = $null }
    }
    $bytes = if ($Attachment -isnot [string] -and (Test-BridgeProperty -Object $Attachment -Name 'bytes')) {
        [long]$Attachment.bytes
    } elseif (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        [long](Get-Item -LiteralPath $fullPath).Length
    } else { -1L }
    $sha256 = if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
    } else { '' }
    $key = Get-BridgeAttachmentKey -SessionId $SessionId -TurnId $TurnId -Path $fullPath -Bytes $bytes -Sha256 $sha256
    $root = Initialize-BridgeState
    foreach ($folder in @('attachment-outbox', 'attachment-sent', 'attachment-failed')) {
        $existing = Join-Path (Join-Path $root $folder) "$key.json"
        if (Test-Path -LiteralPath $existing -PathType Leaf) {
            return [pscustomobject]@{ queued = $false; duplicate = $true; key = $key; path = $existing }
        }
    }
    $now = [DateTimeOffset]::Now.ToString('o')
    $record = [ordered]@{
        id = $key
        type = 'codex_completion_attachment'
        state = 'queued'
        session_id = $SessionId
        turn_id = $TurnId
        thread_name = $ThreadName
        cwd = $Cwd
        path = $fullPath
        name = if ($Attachment -isnot [string] -and (Test-BridgeProperty -Object $Attachment -Name 'name')) {
            [string]$Attachment.name
        } else { [IO.Path]::GetFileName($fullPath) }
        bytes = $bytes
        sha256 = $sha256
        ordinal = $Ordinal
        total = $Total
        attempts = 0
        next_attempt_at = $now
        last_attempt_at = $null
        last_error = $null
        source = $Source
        created_at = $now
        updated_at = $now
        format_version = 1
    }
    $destination = Join-Path (Join-Path $root 'attachment-outbox') "$key.json"
    Write-BridgeJsonAtomic -Path $destination -Value $record
    return [pscustomobject]@{ queued = $true; duplicate = $false; key = $key; path = $destination }
}

function Save-BridgeAttachmentCatalog {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName,
        [string]$Cwd,
        [Parameter(Mandatory)]$Plan,
        $QueueResult
    )
    $keyMaterial = "$SessionId|$TurnId"
    $key = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyMaterial))
    ).ToLowerInvariant()
    $record = [ordered]@{
        id = $key
        session_id = $SessionId
        turn_id = $TurnId
        thread_name = $ThreadName
        cwd = $Cwd
        recognized = [int]$Plan.recognized
        eligible = @($Plan.eligible)
        filtered = @($Plan.filtered)
        oversized = @($Plan.oversized)
        over_limit = @($Plan.over_limit)
        queue_stats = if ($QueueResult) {
            [ordered]@{
                queued = [int]$QueueResult.queued
                duplicates = [int]$QueueResult.duplicates
                total = [int]$QueueResult.total
            }
        } else { [ordered]@{ queued = 0; duplicates = 0; total = 0 } }
        delivery_summary_sent = $false
        created_at = [DateTimeOffset]::Now.ToString('o')
        format_version = 1
    }
    $path = Join-Path (Join-Path (Initialize-BridgeState) 'attachment-catalog') "$key.json"
    Write-BridgeJsonAtomic -Path $path -Value $record
    $routePath = Join-Path (Join-Path (Initialize-BridgeState) 'attachment-catalog') 'latest-by-session.json'
    $routes = Read-BridgeJson -Path $routePath -Default @{} -AsHashtable
    $routes[$SessionId] = $key
    Write-BridgeJsonAtomic -Path $routePath -Value $routes
    return $path
}

function Get-BridgeAttachmentCatalog {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [string]$TurnId
    )
    $catalogPath = Join-Path (Initialize-BridgeState) 'attachment-catalog'
    if (-not $TurnId) {
        $routePath = Join-Path $catalogPath 'latest-by-session.json'
        $routes = Read-BridgeJson -Path $routePath -Default @{} -AsHashtable
        if ($routes.ContainsKey($SessionId)) {
            $latestPath = Join-Path $catalogPath ("$([string]$routes[$SessionId]).json")
            $latestRecord = Read-BridgeJson -Path $latestPath -Default $null
            if ($latestRecord) { return @([pscustomobject]@{ file = Get-Item -LiteralPath $latestPath; record = $latestRecord }) }
        }
    }
    $matches = foreach ($file in @(Get-ChildItem -LiteralPath $catalogPath `
        -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -eq 'latest-by-session.json') { continue }
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record -or [string]$record.session_id -ne $SessionId) { continue }
        if ($TurnId -and [string]$record.turn_id -ne $TurnId) { continue }
        [pscustomobject]@{ file = $file; record = $record }
    }
    return @($matches | Sort-Object { [DateTimeOffset]$_.record.created_at } -Descending | Select-Object -First 1)
}

function Add-BridgeAttachmentQueueRecords {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName,
        [string]$Cwd,
        [object[]]$Attachments = @(),
        [string]$Source = 'completion'
    )
    $records = @($Attachments)
    $queued = 0
    $duplicates = 0
    $excluded = 0
    for ($index = 0; $index -lt $records.Count; $index++) {
        $result = Add-BridgeAttachmentQueueRecord -SessionId $SessionId -TurnId $TurnId `
            -ThreadName $ThreadName -Cwd $Cwd -Attachment $records[$index] `
            -Ordinal ($index + 1) -Total $records.Count -Source $Source
        if ($result -and [bool]$result.queued) { $queued++ }
        elseif ($result -and [bool]$result.duplicate) { $duplicates++ }
        elseif ($result -and (Test-BridgeProperty -Object $result -Name 'excluded') -and [bool]$result.excluded) { $excluded++ }
    }
    return [pscustomobject]@{ queued = $queued; duplicates = $duplicates; excluded = $excluded; total = $records.Count }
}

function Move-BridgeAttachmentQueueRecord {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('sent', 'failed')][string]$State,
        [Parameter(Mandatory)]$Record
    )
    $root = Initialize-BridgeState
    if (Test-BridgeProperty -Object $Record -Name 'state') { $Record.state = $State }
    else { $Record | Add-Member -NotePropertyName state -NotePropertyValue $State }
    $updatedAt = [DateTimeOffset]::Now.ToString('o')
    if (Test-BridgeProperty -Object $Record -Name 'updated_at') { $Record.updated_at = $updatedAt }
    else { $Record | Add-Member -NotePropertyName updated_at -NotePropertyValue $updatedAt }
    $folder = if ($State -eq 'sent') { 'attachment-sent' } else { 'attachment-failed' }
    $destination = Join-Path (Join-Path $root $folder) ([IO.Path]::GetFileName($Path))
    Write-BridgeJsonAtomic -Path $destination -Value $Record
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $destination
}

function Remove-BridgeDisallowedQueuedAttachments {
    $root = Initialize-BridgeState
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record -or [string]::IsNullOrWhiteSpace([string]$record.path) -or
            (Test-BridgeAttachmentExtensionAllowed -Path ([string]$record.path))) { continue }
        if (Test-BridgeProperty -Object $record -Name 'state') { $record.state = 'skipped' }
        else { $record | Add-Member -NotePropertyName state -NotePropertyValue 'skipped' }
        if (Test-BridgeProperty -Object $record -Name 'skip_reason') { $record.skip_reason = 'extension_not_allowed' }
        else { $record | Add-Member -NotePropertyName skip_reason -NotePropertyValue 'extension_not_allowed' }
        $skippedAt = [DateTimeOffset]::Now.ToString('o')
        if (Test-BridgeProperty -Object $record -Name 'skipped_at') { $record.skipped_at = $skippedAt }
        else { $record | Add-Member -NotePropertyName skipped_at -NotePropertyValue $skippedAt }
        $destination = Join-Path (Join-Path $root 'attachment-skipped') $file.Name
        Write-BridgeJsonAtomic -Path $destination -Value $record
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        $removed++
    }
    if ($removed -gt 0) {
        Write-BridgeLog -Level INFO -Message "Removed $removed queued attachment(s) whose extensions are no longer deliverable. Local files were not deleted."
    }
    return $removed
}

function Get-BridgeAttachmentRetryDelaySeconds {
    param([Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$Attempt)
    $config = Get-BridgeConfig
    $delays = @($config.completion_attachment_retry_delays_seconds | ForEach-Object { [Math]::Max(1, [int]$_) })
    if ($delays.Count -eq 0) { $delays = @(60, 300, 900, 3600, 10800, 21600) }
    return [int]$delays[[Math]::Min($Attempt - 1, $delays.Count - 1)]
}

function Test-BridgeAttachmentPermanentError {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Message)
    return [regex]::IsMatch($Message, '(?i)Attachment not found|exceeds the configured limit|not supported|invalid path|Access.+denied')
}

function Publish-BridgeCompletedAttachmentSummaries {
    $root = Initialize-BridgeState
    $catalogPath = Join-Path $root 'attachment-catalog'
    foreach ($file in @(Get-ChildItem -LiteralPath $catalogPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -eq 'latest-by-session.json') { continue }
        $catalog = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $catalog -or ((Test-BridgeProperty -Object $catalog -Name 'delivery_summary_sent') -and
            [bool]$catalog.delivery_summary_sent)) { continue }
        $expected = if ((Test-BridgeProperty -Object $catalog -Name 'queue_stats') -and $catalog.queue_stats) {
            [int]$catalog.queue_stats.total
        } else { @($catalog.eligible).Count }
        if ($expected -le 0) {
            if (Test-BridgeProperty -Object $catalog -Name 'delivery_summary_sent') { $catalog.delivery_summary_sent = $true }
            else { $catalog | Add-Member -NotePropertyName delivery_summary_sent -NotePropertyValue $true }
            Write-BridgeJsonAtomic -Path $file.FullName -Value $catalog
            continue
        }
        $records = @(Get-BridgeAttachmentQueueRecords -SessionId ([string]$catalog.session_id) `
            -TurnId ([string]$catalog.turn_id) -State all)
        $queued = @($records | Where-Object { $_.folder -eq 'attachment-outbox' }).Count
        if ($queued -gt 0) { continue }
        $sent = @($records | Where-Object { $_.folder -eq 'attachment-sent' }).Count
        $failed = @($records | Where-Object { $_.folder -eq 'attachment-failed' }).Count
        $duplicates = if ((Test-BridgeProperty -Object $catalog -Name 'queue_stats') -and $catalog.queue_stats) {
            [int]$catalog.queue_stats.duplicates
        } else { 0 }
        if (($sent + $failed + $duplicates) -lt $expected) { continue }
        $text = "【附件完成】$([string]$catalog.thread_name)`n已发送 $sent 个"
        if ($duplicates -gt 0) { $text += "，已有/重复 $duplicates 个" }
        if ($failed -gt 0) { $text += "，失败 $failed 个；可引用原【已完成】通知发送 /附件 重试" }
        $text += '。'
        try {
            Send-BridgeText -Text $text -AllowContextlessRetry -TimeoutSeconds 15 | Out-Null
            if (Test-BridgeProperty -Object $catalog -Name 'delivery_summary_sent') { $catalog.delivery_summary_sent = $true }
            else { $catalog | Add-Member -NotePropertyName delivery_summary_sent -NotePropertyValue $true }
            $summarySentAt = [DateTimeOffset]::Now.ToString('o')
            if (Test-BridgeProperty -Object $catalog -Name 'delivery_summary_sent_at') { $catalog.delivery_summary_sent_at = $summarySentAt }
            else { $catalog | Add-Member -NotePropertyName delivery_summary_sent_at -NotePropertyValue $summarySentAt }
            Write-BridgeJsonAtomic -Path $file.FullName -Value $catalog
        } catch {
            Write-BridgeLog -Level WARN -Message "Attachment completion summary deferred: $($_.Exception.Message)"
        }
    }
}

function Get-CodexThreadShortId {
    param([Parameter(Mandatory)][string]$SessionId)
    $bytes = [Text.Encoding]::UTF8.GetBytes($SessionId)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).Substring(0, 8).ToLowerInvariant()
}

function Set-CodexThreadDisplayName {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name
    )
    $root = Initialize-BridgeState
    $path = Join-Path $root 'thread-names.json'
    $names = Read-BridgeJson -Path $path -Default @{} -AsHashtable
    $cleanName = ($Name -replace '\s+', ' ').Trim()
    $names[$SessionId] = $cleanName
    Write-BridgeJsonAtomic -Path $path -Value $names

    $recordPath = Get-CodexThreadRecordPath -SessionId $SessionId
    $record = Read-BridgeJson -Path $recordPath -Default $null
    if ($record) {
        if (Test-BridgeProperty -Object $record -Name 'name') { $record.name = $cleanName }
        else { $record | Add-Member -NotePropertyName name -NotePropertyValue $cleanName }
        Write-BridgeJsonAtomic -Path $recordPath -Value $record
    }
    return $cleanName
}

function Get-CodexThreadDisplayName {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [string]$Cwd
    )
    $root = Initialize-BridgeState
    $names = Read-BridgeJson -Path (Join-Path $root 'thread-names.json') -Default @{} -AsHashtable
    if ($names.ContainsKey($SessionId) -and -not [string]::IsNullOrWhiteSpace([string]$names[$SessionId])) {
        return [string]$names[$SessionId]
    }

    $catalog = Read-BridgeJson -Path (Join-Path $root 'thread-catalog.json') -Default $null
    if ($catalog -and (Test-BridgeProperty -Object $catalog -Name 'threads')) {
        $thread = @($catalog.threads | Where-Object { [string]$_.session_id -eq $SessionId } | Select-Object -First 1)
        if ($thread.Count -gt 0) {
            $candidate = [string]$thread[0].name
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { return ($candidate -replace '\s+', ' ').Trim() }
            $candidate = [string]$thread[0].preview
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $candidate = ($candidate -replace '\s+', ' ').Trim()
                if ($candidate.Length -gt 42) { $candidate = $candidate.Substring(0, 42) + '…' }
                return $candidate
            }
            if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = [string]$thread[0].cwd }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $leaf = Split-Path -Leaf $Cwd
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    }
    return 'Codex 对话'
}

function Get-CodexThreadRecordPath {
    param([Parameter(Mandatory)][string]$SessionId)
    $safeName = $SessionId -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path (Join-Path (Initialize-BridgeState) 'threads') ($safeName + '.json')
}

function Update-CodexThreadRegistry {
    param(
        [Parameter(Mandatory)]$HookEvent,
        [ValidateSet('running', 'completed', 'paused', 'failed')][string]$State,
        [string]$Summary
    )
    $sessionId = [string]$HookEvent.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return }
    $path = Get-CodexThreadRecordPath -SessionId $sessionId
    $existing = Read-BridgeJson -Path $path -Default $null
    $now = if ((Test-BridgeProperty -Object $HookEvent -Name 'event_at') -and $HookEvent.event_at) {
        [string]$HookEvent.event_at
    } else {
        [DateTimeOffset]::Now.ToString('o')
    }
    $cwd = [string]$HookEvent.cwd
    if ([string]::IsNullOrWhiteSpace($cwd) -and $existing -and (Test-BridgeProperty -Object $existing -Name 'cwd')) {
        $cwd = [string]$existing.cwd
    }
    $project = if ($cwd) { Split-Path -Leaf $cwd } else { 'Codex' }
    $threadName = if ((Test-BridgeProperty -Object $HookEvent -Name 'thread_name') -and
        -not [string]::IsNullOrWhiteSpace([string]$HookEvent.thread_name)) {
        [string]$HookEvent.thread_name
    } elseif ($existing -and (Test-BridgeProperty -Object $existing -Name 'name') -and
        -not [string]::IsNullOrWhiteSpace([string]$existing.name)) {
        [string]$existing.name
    } else {
        Get-CodexThreadDisplayName -SessionId $sessionId -Cwd $cwd
    }
    if ($Summary -and $Summary.Length -gt 300) { $Summary = $Summary.Substring(0, 300) + '…' }

    $record = [ordered]@{
        session_id = $sessionId
        short_id = Get-CodexThreadShortId -SessionId $sessionId
        state = $State
        cwd = $cwd
        project = $project
        name = $threadName
        last_turn_id = if (Test-BridgeProperty -Object $HookEvent -Name 'turn_id') { [string]$HookEvent.turn_id } else { $null }
        model = if (Test-BridgeProperty -Object $HookEvent -Name 'model') { [string]$HookEvent.model } elseif ($existing -and (Test-BridgeProperty -Object $existing -Name 'model')) { [string]$existing.model } else { $null }
        started_at = if ($State -eq 'running') { $now } elseif ($existing -and (Test-BridgeProperty -Object $existing -Name 'started_at')) { [string]$existing.started_at } else { $null }
        completed_at = if ($State -ne 'running') { $now } else { $null }
        updated_at = $now
        summary = if ($Summary) { $Summary } elseif ($existing -and (Test-BridgeProperty -Object $existing -Name 'summary')) { [string]$existing.summary } else { $null }
    }
    Write-BridgeJsonAtomic -Path $path -Value $record
    return [pscustomobject]$record
}

function Get-CodexThreadRegistry {
    param([int]$Limit = 6)
    $root = Join-Path (Initialize-BridgeState) 'threads'
    $records = foreach ($file in (Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if ($record) { $record }
    }
    return @($records | Sort-Object { [DateTimeOffset]$_.updated_at } -Descending | Select-Object -First $Limit)
}

function Get-BridgeReplyRoutingState {
    $path = Join-Path (Initialize-BridgeState) 'reply-routing.json'
    $state = Read-BridgeJson -Path $path -Default $null
    if (-not $state) {
        $state = [pscustomobject]@{
            selected_session_id = $null
            selected_thread_name = $null
            selected_cwd = $null
            selected_at = $null
            pending_targets = @()
            message_targets = @()
            updated_at = [DateTimeOffset]::Now.ToString('o')
        }
    }
    if (-not (Test-BridgeProperty -Object $state -Name 'pending_targets')) {
        $state | Add-Member -NotePropertyName pending_targets -NotePropertyValue @()
    }
    if (-not (Test-BridgeProperty -Object $state -Name 'message_targets')) {
        $state | Add-Member -NotePropertyName message_targets -NotePropertyValue @()
    }
    return $state
}

function Register-BridgeReplyTarget {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName,
        [string]$Cwd,
        [string]$TurnId,
        [string]$WeChatMessageId,
        [string]$SendStartedAt,
        [string]$SendCompletedAt
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatReplyRouting', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while updating WeChat reply routing.' }
        $state = Get-BridgeReplyRoutingState
        $pending = @($state.pending_targets | Where-Object { [string]$_.session_id -ne $SessionId })
        $pending += [pscustomobject]@{
            session_id = $SessionId
            thread_name = $ThreadName
            cwd = $Cwd
            turn_id = $TurnId
            wechat_message_id = $WeChatMessageId
            send_started_at = $SendStartedAt
            send_completed_at = $SendCompletedAt
            notified_at = [DateTimeOffset]::Now.ToString('o')
        }
        $state.pending_targets = @($pending | Sort-Object { [DateTimeOffset]$_.notified_at } | Select-Object -Last 12)
        if (-not [string]::IsNullOrWhiteSpace($WeChatMessageId)) {
            $messageTargets = @($state.message_targets | Where-Object {
                [string]$_.wechat_message_id -ne $WeChatMessageId
            })
            $messageTargets += [pscustomobject]@{
                session_id = $SessionId
                thread_name = $ThreadName
                cwd = $Cwd
                turn_id = $TurnId
                wechat_message_id = $WeChatMessageId
                send_started_at = $SendStartedAt
                send_completed_at = $SendCompletedAt
                notified_at = [DateTimeOffset]::Now.ToString('o')
            }
            $state.message_targets = @($messageTargets | Sort-Object { [DateTimeOffset]$_.notified_at } | Select-Object -Last 200)
        }
        $state.updated_at = [DateTimeOffset]::Now.ToString('o')
        Write-BridgeJsonAtomic -Path (Join-Path (Initialize-BridgeState) 'reply-routing.json') -Value $state
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Find-BridgeThreadRouteByName {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName)
    $matches = @(Get-CodexThreadRegistry -Limit 200 | Where-Object {
        [string]$_.name -eq $ThreadName -or
        (Get-CodexThreadDisplayName -SessionId ([string]$_.session_id) -Cwd ([string]$_.cwd)) -eq $ThreadName
    } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return [pscustomobject]@{
        session_id = [string]$matches[0].session_id
        thread_name = $ThreadName
        cwd = [string]$matches[0].cwd
        turn_id = [string]$matches[0].last_turn_id
    }
}

function Resolve-BridgeReplyTarget {
    param(
        [string]$ReferenceText,
        [string[]]$ReferenceMessageIds = @(),
        [long[]]$ReferenceCreateTimeMs = @(),
        [string]$InboundMessageId,
        [long]$InboundCreateTimeMs,
        [switch]$RequireQuotedReference
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatReplyRouting', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while resolving WeChat reply routing.' }
        $state = Get-BridgeReplyRoutingState
        $pending = @($state.pending_targets)
        $messageTargets = @($state.message_targets)
        $target = $null
        $selection = 'none'
        foreach ($referenceId in @($ReferenceMessageIds)) {
            if ([string]::IsNullOrWhiteSpace([string]$referenceId)) { continue }
            $idMatches = @($messageTargets | Where-Object {
                [string]$_.wechat_message_id -eq [string]$referenceId
            } | Select-Object -Last 1)
            if ($idMatches.Count -gt 0) {
                $target = $idMatches[0]
                $selection = 'quoted_id'
                break
            }
        }
        if (-not $target -and @($ReferenceCreateTimeMs).Count -gt 0) {
            $explicitTimeMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($referenceTimeMs in @($ReferenceCreateTimeMs)) {
                if ([long]$referenceTimeMs -le 0) { continue }
                $referenceAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$referenceTimeMs)
                foreach ($candidate in $messageTargets) {
                    $candidateAtText = if ((Test-BridgeProperty -Object $candidate -Name 'send_completed_at') -and
                        $candidate.send_completed_at) { [string]$candidate.send_completed_at } else { [string]$candidate.notified_at }
                    $candidateAt = [DateTimeOffset]::MinValue
                    if (-not [DateTimeOffset]::TryParse($candidateAtText, [ref]$candidateAt)) { continue }
                    $explicitTimeMatches.Add([pscustomobject]@{
                        target = $candidate
                        distance_seconds = [Math]::Abs(($referenceAt - $candidateAt).TotalSeconds)
                    })
                }
            }
            $explicitBestBySession = @($explicitTimeMatches | Sort-Object distance_seconds |
                Group-Object { [string]$_.target.session_id } | ForEach-Object { $_.Group[0] } |
                Sort-Object distance_seconds)
            $explicitMaxDistanceSeconds = 90.0
            # ref_msg.message_item.create_time_ms is explicit WeChat quote metadata.
            # It is commonly rounded to one second, so only near-ties inside the
            # sub-second precision window should fail closed. A broad margin makes
            # sequential notifications impossible to quote when several tasks finish together.
            $explicitAmbiguityMarginSeconds = 0.75
            if ($explicitBestBySession.Count -gt 0 -and
                [double]$explicitBestBySession[0].distance_seconds -le $explicitMaxDistanceSeconds) {
                $explicitAmbiguous = $explicitBestBySession.Count -gt 1 -and
                    [double]$explicitBestBySession[1].distance_seconds -le $explicitMaxDistanceSeconds -and
                    ([double]$explicitBestBySession[1].distance_seconds - [double]$explicitBestBySession[0].distance_seconds) -lt $explicitAmbiguityMarginSeconds
                if ($explicitAmbiguous) {
                    return [pscustomobject]@{
                        resolved = $false; ambiguous = $true; pending_count = $pending.Count
                        names = @($explicitBestBySession | Select-Object -First 6 | ForEach-Object { [string]$_.target.thread_name })
                        reason = 'quoted_explicit_time_ambiguous'
                    }
                }
                $target = $explicitBestBySession[0].target
                $selection = 'quoted_explicit_create_time'
            }
        }
        if (-not $target -and $InboundCreateTimeMs -gt 0 -and
            -not [string]::IsNullOrWhiteSpace($InboundMessageId) -and @($ReferenceMessageIds).Count -gt 0) {
            $currentNumericId = [UInt64]0
            if ([UInt64]::TryParse($InboundMessageId, [ref]$currentNumericId)) {
                $currentHigh = [long]($currentNumericId -shr 32)
                $inboundAt = [DateTimeOffset]::FromUnixTimeMilliseconds($InboundCreateTimeMs)
                $timeMatches = [System.Collections.Generic.List[object]]::new()
                foreach ($referenceId in @($ReferenceMessageIds)) {
                    $referenceNumericId = [UInt64]0
                    if (-not [UInt64]::TryParse([string]$referenceId, [ref]$referenceNumericId)) { continue }
                    $referenceHigh = [long]($referenceNumericId -shr 32)
                    $estimatedReferenceAt = $inboundAt.AddSeconds($referenceHigh - $currentHigh)
                    foreach ($candidate in $messageTargets) {
                        $candidateAtText = if ((Test-BridgeProperty -Object $candidate -Name 'send_completed_at') -and
                            $candidate.send_completed_at) { [string]$candidate.send_completed_at } else { [string]$candidate.notified_at }
                        $candidateAt = [DateTimeOffset]::MinValue
                        if (-not [DateTimeOffset]::TryParse($candidateAtText, [ref]$candidateAt)) { continue }
                        $distance = [Math]::Abs(($estimatedReferenceAt - $candidateAt).TotalSeconds)
                        $timeMatches.Add([pscustomobject]@{
                            target = $candidate
                            distance_seconds = $distance
                            estimated_reference_at = $estimatedReferenceAt.ToString('o')
                        })
                    }
                }
                $bestBySession = @($timeMatches | Sort-Object distance_seconds |
                    Group-Object { [string]$_.target.session_id } | ForEach-Object { $_.Group[0] } |
                    Sort-Object distance_seconds)
                $strictMaxDistanceSeconds = 45.0
                $strictAmbiguityMarginSeconds = 10.0
                $extendedMaxDistanceSeconds = 900.0
                $extendedAmbiguityMarginSeconds = 120.0
                $multipleCandidateSessions = @($messageTargets | Group-Object { [string]$_.session_id }).Count -gt 1
                if ($multipleCandidateSessions -and $bestBySession.Count -gt 0) {
                    return [pscustomobject]@{
                        resolved = $false
                        ambiguous = $true
                        pending_count = $pending.Count
                        names = @($bestBySession | Select-Object -First 6 | ForEach-Object { [string]$_.target.thread_name })
                        reason = 'quoted_numeric_unsafe_multiple_candidates'
                    }
                }
                if (-not $multipleCandidateSessions -and $bestBySession.Count -gt 0 -and
                    [double]$bestBySession[0].distance_seconds -le $extendedMaxDistanceSeconds) {
                    $usingExtendedMatch = [double]$bestBySession[0].distance_seconds -gt $strictMaxDistanceSeconds
                    $allowedDistance = if ($usingExtendedMatch) { $extendedMaxDistanceSeconds } else { $strictMaxDistanceSeconds }
                    $requiredLead = if ($usingExtendedMatch) { $extendedAmbiguityMarginSeconds } else { $strictAmbiguityMarginSeconds }
                    $isAmbiguousTimeMatch = $bestBySession.Count -gt 1 -and
                        [double]$bestBySession[1].distance_seconds -le $allowedDistance -and
                        ([double]$bestBySession[1].distance_seconds - [double]$bestBySession[0].distance_seconds) -lt $requiredLead
                    if ($isAmbiguousTimeMatch) {
                        return [pscustomobject]@{
                            resolved = $false
                            ambiguous = $true
                            pending_count = $pending.Count
                            names = @($bestBySession | Select-Object -First 6 | ForEach-Object { [string]$_.target.thread_name })
                            reason = 'quoted_server_time_ambiguous'
                        }
                    }
                    $target = $bestBySession[0].target
                    $selection = if ($usingExtendedMatch) { 'quoted_server_time_extended_unique' } else { 'quoted_server_time' }
                }
            }
        }
        if (-not $target -and -not [string]::IsNullOrWhiteSpace($ReferenceText)) {
            $nameMatch = [regex]::Match($ReferenceText, '【(?:已完成|已暂停|执行失败|已创建)】(?<name>[^\r\n]+)')
            if ($nameMatch.Success) {
                $quotedName = $nameMatch.Groups['name'].Value.Trim()
                $quoted = @($pending | Where-Object { [string]$_.thread_name -eq $quotedName } | Select-Object -Last 1)
                if ($quoted.Count -gt 0) { $target = $quoted[0] }
                else { $target = Find-BridgeThreadRouteByName -ThreadName $quotedName }
                if ($target) { $selection = 'quoted' }
            }
        }
        if ($RequireQuotedReference -and -not $target) {
            return [pscustomobject]@{
                resolved = $false
                ambiguous = $false
                quote_not_found = $true
                pending_count = $pending.Count
            }
        }
        if (-not $target) {
            if ($pending.Count -gt 1) {
                return [pscustomobject]@{
                    resolved = $false
                    ambiguous = $true
                    pending_count = $pending.Count
                    names = @($pending | ForEach-Object { [string]$_.thread_name })
                }
            }
            if ($pending.Count -eq 1) {
                $target = $pending[0]
                $selection = 'single_pending'
            } elseif ($state.selected_session_id) {
                $target = [pscustomobject]@{
                    session_id = [string]$state.selected_session_id
                    thread_name = [string]$state.selected_thread_name
                    cwd = [string]$state.selected_cwd
                    turn_id = $null
                }
                $selection = 'selected'
            } else {
                $active = Read-BridgeJson -Path (Join-Path (Initialize-BridgeState) 'active-thread.json') -Default $null
                if ($active -and $active.session_id) {
                    $target = [pscustomobject]@{
                        session_id = [string]$active.session_id
                        thread_name = Get-CodexThreadDisplayName -SessionId ([string]$active.session_id) -Cwd ([string]$active.cwd)
                        cwd = [string]$active.cwd
                        turn_id = [string]$active.turn_id
                    }
                    $selection = 'active'
                }
            }
        }
        if (-not $target -or -not $target.session_id) {
            return [pscustomobject]@{ resolved = $false; ambiguous = $false; pending_count = $pending.Count }
        }
        $state.selected_session_id = [string]$target.session_id
        $state.selected_thread_name = [string]$target.thread_name
        $state.selected_cwd = [string]$target.cwd
        $state.selected_at = [DateTimeOffset]::Now.ToString('o')
        $state.pending_targets = @($pending | Where-Object { [string]$_.session_id -ne [string]$target.session_id })
        if ($selection -eq 'quoted_explicit_create_time') {
            foreach ($referenceId in @($ReferenceMessageIds)) {
                if ([string]::IsNullOrWhiteSpace([string]$referenceId)) { continue }
                $existingAlias = @($messageTargets | Where-Object {
                    [string]$_.wechat_message_id -eq [string]$referenceId
                })
                if ($existingAlias.Count -gt 0) { continue }
                $messageTargets += [pscustomobject]@{
                    session_id = [string]$target.session_id
                    thread_name = [string]$target.thread_name
                    cwd = [string]$target.cwd
                    turn_id = [string]$target.turn_id
                    wechat_message_id = [string]$referenceId
                    send_started_at = if (Test-BridgeProperty -Object $target -Name 'send_started_at') { [string]$target.send_started_at } else { $null }
                    send_completed_at = if (Test-BridgeProperty -Object $target -Name 'send_completed_at') { [string]$target.send_completed_at } else { $null }
                    notified_at = [DateTimeOffset]::Now.ToString('o')
                    route_alias = 'wechat_quoted_server_id'
                }
            }
            $state.message_targets = @($messageTargets | Sort-Object { [DateTimeOffset]$_.notified_at } | Select-Object -Last 200)
        }
        $state.updated_at = [DateTimeOffset]::Now.ToString('o')
        Write-BridgeJsonAtomic -Path (Join-Path (Initialize-BridgeState) 'reply-routing.json') -Value $state
        return [pscustomobject]@{
            resolved = $true
            ambiguous = $false
            selection = $selection
            session_id = [string]$target.session_id
            thread_name = [string]$target.thread_name
            cwd = [string]$target.cwd
            turn_id = if (Test-BridgeProperty -Object $target -Name 'turn_id') { [string]$target.turn_id } else { '' }
        }
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Initialize-CodexThreadRegistryFromActive {
    $root = Initialize-BridgeState
    $active = Read-BridgeJson -Path (Join-Path $root 'active-thread.json') -Default $null
    if (-not $active -or -not $active.session_id) { return }
    $path = Get-CodexThreadRecordPath -SessionId ([string]$active.session_id)
    if (Test-Path -LiteralPath $path) { return }
    Update-CodexThreadRegistry -HookEvent $active -State completed -Summary '此前的最近活动 Codex 对话。' | Out-Null
}

function Get-CodexRolloutRuntimeIndex {
    $index = @{}
    $monitor = Read-BridgeJson -Path (Join-Path (Initialize-BridgeState) 'rollout-monitor.json') `
        -Default $null -AsHashtable
    if (-not $monitor -or -not $monitor.ContainsKey('files')) { return $index }
    foreach ($entry in $monitor.files.GetEnumerator()) {
        $path = [string]$entry.Key
        $tracking = $entry.Value
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $sessionId = if ($tracking -and $tracking.ContainsKey('session_id')) {
            [string]$tracking.session_id
        } else {
            Get-CodexSessionIdFromRolloutPath -Path $path
        }
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $key = $sessionId.ToLowerInvariant()
        $file = Get-Item -LiteralPath $path
        if ($index.ContainsKey($key) -and
            [DateTimeOffset]$index[$key].updated_at -ge [DateTimeOffset]$file.LastWriteTimeUtc) { continue }
        $index[$key] = [pscustomobject]@{
            session_id = $sessionId
            path = $path
            updated_at = ([DateTimeOffset]$file.LastWriteTimeUtc).ToString('o')
            user_visible = $tracking -and $tracking.ContainsKey('user_visible') -and [bool]$tracking.user_visible
        }
    }
    return $index
}

function Resolve-CodexTaskRuntimeState {
    param(
        [string]$RegisteredState,
        [string]$CatalogStatusType,
        [string]$RolloutPath
    )
    if (-not [string]::IsNullOrWhiteSpace($RolloutPath) -and
        (Test-Path -LiteralPath $RolloutPath -PathType Leaf)) {
        try {
            $boundary = Get-CodexRolloutLatestBoundary -Path $RolloutPath
            if ($boundary) {
                $runtimeState = switch ([string]$boundary.type) {
                    'task_started' { 'running' }
                    'turn_aborted' { 'paused' }
                    default { 'completed' }
                }
                return $runtimeState
            }
        } catch { }
    }
    if ($CatalogStatusType -eq 'active') { return 'running' }
    if ($CatalogStatusType -eq 'systemError') { return 'failed' }
    if ($RegisteredState -in @('completed', 'paused', 'failed')) { return $RegisteredState }
    # A historical registry row can remain `running` after its rollout was
    # archived or lost. Without a live lifecycle boundary it must not be
    # presented as an executing task.
    if ($RegisteredState -eq 'running') { return 'paused' }
    return 'completed'
}

function Get-BridgeTasksText {
    param(
        [switch]$IncludeSummary,
        [switch]$IncludeCompleted
    )
    $catalog = $null
    try { $catalog = Refresh-CodexThreadCatalog -Force } catch { }
    $records = @(Get-CodexThreadRegistry -Limit 200)
    $rollouts = Get-CodexRolloutRuntimeIndex
    $candidates = @{}

    foreach ($thread in @(if ($catalog -and (Test-BridgeProperty -Object $catalog -Name 'threads')) { $catalog.threads } else { @() })) {
        $sessionId = [string]$thread.session_id
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $key = $sessionId.ToLowerInvariant()
        $candidates[$key] = [ordered]@{
            session_id = $sessionId
            name = [string]$thread.name
            cwd = [string]$thread.cwd
            summary = ''
            registered_state = ''
            catalog_status_type = [string]$thread.status_type
            active_flags = @(if (Test-BridgeProperty -Object $thread -Name 'active_flags') { $thread.active_flags } else { @() })
            updated_at = [string]$thread.updated_at
        }
    }
    foreach ($record in $records) {
        $sessionId = [string]$record.session_id
        if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
        $key = $sessionId.ToLowerInvariant()
        if (-not $candidates.ContainsKey($key)) {
            $candidates[$key] = [ordered]@{
                session_id = $sessionId; name = [string]$record.name; cwd = [string]$record.cwd
                summary = ''; registered_state = ''; catalog_status_type = ''; active_flags = @()
                updated_at = [string]$record.updated_at
            }
        }
        $candidate = $candidates[$key]
        if ([string]::IsNullOrWhiteSpace([string]$candidate.name)) { $candidate.name = [string]$record.name }
        if ([string]::IsNullOrWhiteSpace([string]$candidate.cwd)) { $candidate.cwd = [string]$record.cwd }
        $candidate.summary = [string]$record.summary
        $candidate.registered_state = [string]$record.state
        if ([string]::IsNullOrWhiteSpace([string]$candidate.updated_at)) { $candidate.updated_at = [string]$record.updated_at }
    }
    foreach ($entry in $rollouts.GetEnumerator()) {
        if ($candidates.ContainsKey([string]$entry.Key) -or -not [bool]$entry.Value.user_visible) { continue }
        $metadata = $null
        try { $metadata = Get-CodexRolloutMetadata -Path ([string]$entry.Value.path) } catch { }
        $sessionId = [string]$entry.Value.session_id
        $cwd = if ($metadata) { [string]$metadata.cwd } else { '' }
        $candidates[[string]$entry.Key] = [ordered]@{
            session_id = $sessionId
            name = Get-CodexThreadDisplayName -SessionId $sessionId -Cwd $cwd
            cwd = $cwd
            summary = ''
            registered_state = ''
            catalog_status_type = ''
            active_flags = @()
            updated_at = [string]$entry.Value.updated_at
        }
    }

    $resolved = foreach ($candidate in $candidates.Values) {
        $key = ([string]$candidate.session_id).ToLowerInvariant()
        $rollout = if ($rollouts.ContainsKey($key)) { $rollouts[$key] } else { $null }
        $state = Resolve-CodexTaskRuntimeState -RegisteredState ([string]$candidate.registered_state) `
            -CatalogStatusType ([string]$candidate.catalog_status_type) `
            -RolloutPath $(if ($rollout) { [string]$rollout.path } else { '' })
        $updatedAt = if ($rollout) { [string]$rollout.updated_at } else { [string]$candidate.updated_at }
        [pscustomobject]@{
            session_id = [string]$candidate.session_id
            name = if ([string]::IsNullOrWhiteSpace([string]$candidate.name)) {
                Get-CodexThreadDisplayName -SessionId ([string]$candidate.session_id) -Cwd ([string]$candidate.cwd)
            } else { [string]$candidate.name }
            cwd = [string]$candidate.cwd
            summary = [string]$candidate.summary
            state = $state
            active_flags = @($candidate.active_flags)
            updated_at = $updatedAt
        }
    }
    $resolved = @($resolved | Sort-Object {
        try { [DateTimeOffset]::Parse([string]$_.updated_at) } catch { [DateTimeOffset]::MinValue }
    } -Descending)
    if (-not $IncludeCompleted) {
        $resolved = @($resolved | Where-Object { [string]$_.state -eq 'running' })
    } else {
        $resolved = @($resolved | Select-Object -First 8)
    }
    if ($resolved.Count -eq 0 -and $candidates.Count -eq 0) {
        return '尚未记录 Codex 对话。插件升级后运行过的任务会显示在这里。'
    }
    $lines = @($(if ($IncludeCompleted) { '最近 Codex 对话：' } else { "正在执行的 Codex 对话（$($resolved.Count)）：" }))
    foreach ($record in $resolved) {
        $stateText = switch ([string]$record.state) {
            'running' { '执行中' }
            'paused' { '已暂停' }
            'failed' { '失败' }
            default { '已完成' }
        }
        $summary = if ((Test-BridgeProperty -Object $record -Name 'summary') -and $record.summary) {
            ([string]$record.summary -replace '\s+', ' ').Trim()
        } else { '' }
        if ($summary.Length -gt 70) { $summary = $summary.Substring(0, 70) + '…' }
        $line = "[$stateText] $([string]$record.name)"
        $activeFlags = @($record.active_flags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($activeFlags.Count -gt 0) {
            $line += "（$($activeFlags -join '、')）"
        }
        if ([string]$record.state -eq 'running') {
            $progress = Get-CodexThreadProgressText -SessionId ([string]$record.session_id)
            if (-not [string]::IsNullOrWhiteSpace($progress)) { $line += "`n  进展：$progress" }
            if ($IncludeSummary -and $summary) { $line += "`n  上次结果：$summary" }
        } elseif ($IncludeSummary -and $summary) {
            $line += " — $summary"
        }
        $lines += $line
    }
    if ($lines.Count -eq 1) { $lines += '当前没有正在执行的 Codex 对话。' }
    if ($IncludeSummary) {
        $lines += '继续原任务和创建分支都必须引用对应通知；/新建无需引用。'
    } elseif ($IncludeCompleted) {
        $lines += '发送 /状态 完整 查看这些任务的结果摘要。'
    } else {
        $lines += '发送 /状态 最近 查看最近已完成任务。'
    }
    return $lines -join "`n"
}

function Get-BridgeDefaultNewThreadTarget {
    $root = Initialize-BridgeState
    $config = Get-BridgeConfig
    $configuredCwd = if (Test-BridgeProperty -Object $config -Name 'default_new_thread_cwd') {
        [string]$config.default_new_thread_cwd
    } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($configuredCwd) -and
        (Test-Path -LiteralPath $configuredCwd -PathType Container)) {
        return [pscustomobject]@{
            session_id = ''
            thread_name = Split-Path -Leaf $configuredCwd
            cwd = [IO.Path]::GetFullPath($configuredCwd)
            selection = 'configured_default_project'
        }
    }

    # Codex requires an internal cwd even for a projectless task. Use one
    # bridge-owned neutral directory instead of inheriting the latest task's
    # project, so /new never becomes part of new-chat or another saved project.
    $projectlessCwd = Join-Path $root 'projectless-workspace'
    [IO.Directory]::CreateDirectory($projectlessCwd) | Out-Null
    return [pscustomobject]@{
        session_id = ''
        thread_name = '微信独立任务'
        cwd = [IO.Path]::GetFullPath($projectlessCwd)
        selection = 'bridge_projectless_workspace'
    }
}

function Register-CodexNotificationKey {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [ValidateSet('sent', 'queued', 'suppressed', 'reserved')][string]$State = 'reserved'
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatNotificationHistory', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while updating notification history.' }
        $path = Join-Path (Initialize-BridgeState) 'notification-history.json'
        $history = Read-BridgeJson -Path $path -Default @{ keys = @{} } -AsHashtable
        if (-not $history.ContainsKey('keys') -or $null -eq $history.keys) { $history.keys = @{} }
        $key = "$SessionId|$TurnId"
        if ($history.keys.ContainsKey($key)) { return $false }
        $history.keys[$key] = [ordered]@{
            state = $State
            recorded_at = [DateTimeOffset]::Now.ToString('o')
        }
        if ($history.keys.Count -gt 600) {
            $keep = @($history.keys.GetEnumerator() |
                Sort-Object { [DateTimeOffset]$_.Value.recorded_at } -Descending |
                Select-Object -First 500)
            $trimmed = @{}
            foreach ($entry in $keep) { $trimmed[[string]$entry.Key] = $entry.Value }
            $history.keys = $trimmed
        }
        Write-BridgeJsonAtomic -Path $path -Value $history
        return $true
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Set-CodexNotificationState {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][ValidateSet('sent', 'queued', 'suppressed', 'reserved')][string]$State
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatNotificationHistory', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while updating notification history.' }
        $path = Join-Path (Initialize-BridgeState) 'notification-history.json'
        $history = Read-BridgeJson -Path $path -Default @{ keys = @{} } -AsHashtable
        if (-not $history.ContainsKey('keys') -or $null -eq $history.keys) { $history.keys = @{} }
        $key = "$SessionId|$TurnId"
        if (-not $history.keys.ContainsKey($key)) { $history.keys[$key] = @{} }
        $history.keys[$key].state = $State
        $history.keys[$key].updated_at = [DateTimeOffset]::Now.ToString('o')
        if (-not $history.keys[$key].ContainsKey('recorded_at')) {
            $history.keys[$key].recorded_at = [DateTimeOffset]::Now.ToString('o')
        }
        Write-BridgeJsonAtomic -Path $path -Value $history
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Remove-CodexSuppressedNotificationKeyForRecovery {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TurnId,
        [Parameter(Mandatory)][DateTimeOffset]$NotBefore
    )
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexWeChatNotificationHistory', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while recovering notification history.' }
        $path = Join-Path (Initialize-BridgeState) 'notification-history.json'
        $history = Read-BridgeJson -Path $path -Default @{ keys = @{} } -AsHashtable
        $key = "$SessionId|$TurnId"
        if (-not $history.ContainsKey('keys') -or -not $history.keys.ContainsKey($key)) { return $false }
        $record = $history.keys[$key]
        $recordedAt = [DateTimeOffset]::MinValue
        if ([string]$record.state -ne 'suppressed' -or
            -not [DateTimeOffset]::TryParse([string]$record.recorded_at, [ref]$recordedAt) -or
            $recordedAt -lt $NotBefore) { return $false }
        [void]$history.keys.Remove($key)
        Write-BridgeJsonAtomic -Path $path -Value $history
        return $true
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Split-BridgeTextByBoundary {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text,
        [Parameter(Mandatory)][ValidateRange(200, 10000)][int]$MaxChars,
        [Parameter(Mandatory)][ValidateRange(1, 20)][int]$MaxParts
    )
    $remaining = ($Text -replace "`r`n?", "`n").Trim()
    $parts = [System.Collections.Generic.List[string]]::new()
    while ($remaining.Length -gt $MaxChars -and $parts.Count -lt ($MaxParts - 1)) {
        $window = $remaining.Substring(0, $MaxChars)
        $minimumBreak = [Math]::Max(80, [int][Math]::Floor($MaxChars * 0.45))
        $splitAt = -1
        $separatorLength = 0
        foreach ($separator in @("`n`n", "`n", '。', '！', '？', '；', ';', '，', ',', ' ')) {
            $candidate = $window.LastIndexOf($separator, [StringComparison]::Ordinal)
            if ($candidate -ge $minimumBreak -and $candidate -gt $splitAt) {
                $splitAt = $candidate
                $separatorLength = $separator.Length
            }
        }
        $takeLength = if ($splitAt -ge $minimumBreak) { $splitAt + $separatorLength } else { $MaxChars }
        if ($takeLength -gt 0 -and $takeLength -lt $remaining.Length -and
            [char]::IsHighSurrogate($remaining[$takeLength - 1])) { $takeLength-- }
        $part = $remaining.Substring(0, $takeLength).Trim()
        if ($part) { $parts.Add($part) }
        $remaining = $remaining.Substring($takeLength).TrimStart()
    }
    if ($remaining) {
        if ($remaining.Length -gt $MaxChars) {
            $takeLength = $MaxChars - 1
            if ($takeLength -gt 0 -and [char]::IsHighSurrogate($remaining[$takeLength - 1])) { $takeLength-- }
            $remaining = $remaining.Substring(0, $takeLength).TrimEnd() + '…'
        }
        $parts.Add($remaining)
    }
    return @($parts)
}

function New-CodexCompletionTextBundle {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [string]$Summary,
        [int]$ChunkChars,
        [int]$MaxChunks
    )
    $cleanName = ($Name -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = '本轮处理已经结束，请打开 Codex 查看结果。' }
    $cleanSummary = [regex]::Replace(
        $Summary.Trim(),
        ':codex-file-citation\{path="([^"]+)"[^}]*\}',
        '文件：$1'
    )
    $header = "【已完成】$cleanName"
    $safeChunkChars = [Math]::Max(400, $(if ($ChunkChars -gt 0) { $ChunkChars } else { 1100 }))
    $safeMaxChunks = [Math]::Min(12, [Math]::Max(1, $(if ($MaxChunks -gt 0) { $MaxChunks } else { 6 })))
    if (($header.Length + 1 + $cleanSummary.Length) -le $safeChunkChars) {
        return [pscustomobject]@{
            summary = $cleanSummary
            parts = @("$header`n$cleanSummary")
            truncated = $false
        }
    }

    # Reserve enough room for the repeated routable header and a marker such
    # as （12/12）. Every segment remains independently quote-routable.
    $bodyChars = [Math]::Max(200, $safeChunkChars - $header.Length - 16)
    $maxSummaryChars = $bodyChars * $safeMaxChunks
    $truncated = $cleanSummary.Length -gt $maxSummaryChars
    if ($truncated) {
        $takeLength = $maxSummaryChars - 1
        if ($takeLength -gt 0 -and [char]::IsHighSurrogate($cleanSummary[$takeLength - 1])) { $takeLength-- }
        $cleanSummary = $cleanSummary.Substring(0, $takeLength).TrimEnd() + '…'
    }
    $bodies = @(Split-BridgeTextByBoundary -Text $cleanSummary -MaxChars $bodyChars -MaxParts $safeMaxChunks)
    $count = $bodies.Count
    $parts = for ($index = 0; $index -lt $count; $index++) {
        "$header`n（$($index + 1)/$count）`n$($bodies[$index])"
    }
    return [pscustomobject]@{
        summary = $cleanSummary
        parts = @($parts)
        truncated = $truncated
    }
}

function Format-CodexCompletionText {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [string]$Summary
    )
    $cleanName = ($Name -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = '本轮处理已经结束，请打开 Codex 查看结果。' }
    $cleanSummary = [regex]::Replace(
        $Summary.Trim(),
        ':codex-file-citation\{path="([^"]+)"[^}]*\}',
        '文件：$1'
    )
    return "【已完成】$cleanName`n$cleanSummary"
}

function Get-CodexCompletionAttachmentPlan {
    param(
        [string]$Text,
        [string]$Cwd
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ recognized = 0; eligible = @(); filtered = @(); oversized = @(); over_limit = @() }
    }
    $config = Get-BridgeConfig
    if (-not [bool]$config.completion_attachments_enabled) {
        return [pscustomobject]@{ recognized = 0; eligible = @(); filtered = @(); oversized = @(); over_limit = @() }
    }
    $allowedExtensions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in @($config.completion_attachment_allowed_extensions)) {
        $normalized = [string]$extension
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        if (-not $normalized.StartsWith('.')) { $normalized = ".$normalized" }
        [void]$allowedExtensions.Add($normalized)
    }
    $candidates = [System.Collections.Generic.List[string]]::new()
    $filtered = [System.Collections.Generic.List[object]]::new()
    $patterns = @(
        ':codex-file-citation\{path="(?<path>[^"]+)"[^}]*\}',
        '\]\(<(?<path>/?[A-Za-z]:[\\/][^>]+)>\)',
        '\]\((?<path>/?[A-Za-z]:[\\/][^)]+)\)',
        '(?:交付文件|输出文件|附件|下载|交付|文件)\s*[：:]\s*(?<path>/?[A-Za-z]:[\\/][^\r\n"''<>|?*]+?\.[A-Za-z0-9]{1,10})'
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $candidate = [Uri]::UnescapeDataString([string]$match.Groups['path'].Value).Trim()
            $candidate = $candidate.Trim('<', '>', '"', '''', ' ', "`t")
            if ($candidate -match '^/[A-Za-z]:/') { $candidate = $candidate.Substring(1) }
            if (-not [System.IO.Path]::IsPathRooted($candidate) -and -not [string]::IsNullOrWhiteSpace($Cwd)) {
                $candidate = Join-Path $Cwd $candidate
            }
            try { $candidate = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $candidateExtension = [System.IO.Path]::GetExtension($candidate)
            if ($allowedExtensions.Count -eq 0 -or -not $allowedExtensions.Contains($candidateExtension)) {
                Write-BridgeLog -Level INFO -Message "Skipped non-deliverable completion attachment: $([System.IO.Path]::GetFileName($candidate))"
                $filtered.Add([pscustomobject]@{
                    path = $candidate
                    name = [IO.Path]::GetFileName($candidate)
                    reason = 'extension_not_allowed'
                })
                continue
            }
            if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
        }
    }
    $maxFiles = [Math]::Max(0, [int]$config.completion_attachment_max_files)
    $maxBytes = [long]$config.completion_attachment_max_bytes
    $oversized = [System.Collections.Generic.List[object]]::new()
    $overLimit = [System.Collections.Generic.List[object]]::new()
    $eligible = [System.Collections.Generic.List[object]]::new()
    $candidateIndex = 0
    foreach ($path in @($candidates)) {
        $candidateIndex++
        $item = Get-Item -LiteralPath $path
        if ($item.Length -gt $maxBytes) {
            Write-BridgeLog -Level WARN -Message "Skipped oversized completion attachment: $($item.Name) ($($item.Length) bytes)."
            $oversized.Add([pscustomobject]@{ path = $item.FullName; name = $item.Name; bytes = [long]$item.Length; reason = 'oversized' })
            continue
        }
        $record = [pscustomobject]@{
            path = $item.FullName
            name = $item.Name
            bytes = [long]$item.Length
        }
        if ($eligible.Count -lt $maxFiles) { $eligible.Add($record) }
        else { $overLimit.Add($record) }
    }
    return [pscustomobject]@{
        recognized = $candidates.Count + $filtered.Count
        eligible = @($eligible)
        filtered = @($filtered)
        oversized = @($oversized)
        over_limit = @($overLimit)
    }
}

function Get-CodexCompletionAttachments {
    param([string]$Text, [string]$Cwd)
    return @((Get-CodexCompletionAttachmentPlan -Text $Text -Cwd $Cwd).eligible)
}

function Publish-CodexTurnNotification {
    param(
        [Parameter(Mandatory)]$HookEvent,
        [switch]$SuppressNotification
    )
    return Invoke-WithBridgeNotificationGate -Action {
        Invoke-CodexTurnNotificationCore -HookEvent $HookEvent -SuppressNotification:$SuppressNotification
    }
}

function Invoke-CodexTurnNotificationCore {
    param(
        [Parameter(Mandatory)]$HookEvent,
        [switch]$SuppressNotification
    )
    $root = Initialize-BridgeState
    $displayName = if ((Test-BridgeProperty -Object $HookEvent -Name 'thread_name') -and
        -not [string]::IsNullOrWhiteSpace([string]$HookEvent.thread_name)) {
        [string]$HookEvent.thread_name
    } else {
        Get-CodexThreadDisplayName -SessionId ([string]$HookEvent.session_id) -Cwd ([string]$HookEvent.cwd)
    }
    $thread = [ordered]@{
        session_id = [string]$HookEvent.session_id
        turn_id = [string]$HookEvent.turn_id
        cwd = [string]$HookEvent.cwd
        model = [string]$HookEvent.model
        name = $displayName
        updated_at = [DateTimeOffset]::Now.ToString('o')
    }
    Write-BridgeJsonAtomic -Path (Join-Path $root 'active-thread.json') -Value $thread

    $registrySummary = [string]$HookEvent.last_assistant_message
    Update-CodexThreadRegistry -HookEvent $HookEvent -State completed -Summary $registrySummary | Out-Null
    $sessionId = [string]$HookEvent.session_id
    $turnId = [string]$HookEvent.turn_id
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $turnId = 'completion-' + [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($registrySummary))
        ).Substring(0, 20).ToLowerInvariant()
    }
    if ($SuppressNotification) {
        Register-CodexNotificationKey -SessionId $sessionId -TurnId $turnId -State suppressed | Out-Null
        return [pscustomobject]@{ suppressed = $true }
    }
    $sourceEventAt = if (Test-BridgeProperty -Object $HookEvent -Name 'event_at') { [string]$HookEvent.event_at } else { '' }
    if (-not (Test-BridgeNotificationAfterReset -Timestamp $sourceEventAt)) {
        Register-CodexNotificationKey -SessionId $sessionId -TurnId $turnId -State suppressed | Out-Null
        Write-BridgeLog -Level INFO -Message "Notification reset suppressed pre-cutoff completion $sessionId/$turnId."
        return [pscustomobject]@{ suppressed = $true; reset = $true }
    }

    $config = Get-BridgeConfig
    if (-not $config.notifications_enabled) { return [pscustomobject]@{ skipped = $true } }
    if (-not (Register-CodexNotificationKey -SessionId $sessionId -TurnId $turnId -State reserved)) {
        return [pscustomobject]@{ skipped = $true; duplicate = $true }
    }
    $summary = [string]$HookEvent.last_assistant_message
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = '本轮处理已经结束，请打开 Codex 查看结果。' }
    $chunkChars = if ($config.completion_text_chunk_chars) { [int]$config.completion_text_chunk_chars } else { 1100 }
    $maxChunks = if ($config.completion_text_max_chunks) { [int]$config.completion_text_max_chunks } else { 6 }
    $attachmentPlan = Get-CodexCompletionAttachmentPlan -Text $registrySummary -Cwd ([string]$HookEvent.cwd)
    $attachments = @($attachmentPlan.eligible)
    $excludedAttachmentCount = @($attachmentPlan.filtered).Count + @($attachmentPlan.oversized).Count
    $overLimitAttachmentCount = @($attachmentPlan.over_limit).Count
    $queueResult = [pscustomobject]@{ queued = 0; duplicates = 0; total = 0 }
    if ($attachments.Count -gt 0) {
        $queueResult = Add-BridgeAttachmentQueueRecords -SessionId $sessionId -TurnId $turnId `
            -ThreadName $displayName -Cwd ([string]$HookEvent.cwd) -Attachments $attachments
        Write-BridgeLog -Level INFO -Message (
            "Completion attachments prepared: recognized=$($attachmentPlan.recognized), queued=$($queueResult.queued), " +
            "duplicates=$($queueResult.duplicates), excluded=$excludedAttachmentCount, over_limit=$overLimitAttachmentCount."
        )
    }
    Save-BridgeAttachmentCatalog -SessionId $sessionId -TurnId $turnId -ThreadName $displayName `
        -Cwd ([string]$HookEvent.cwd) -Plan $attachmentPlan -QueueResult $queueResult | Out-Null
    if ([int]$attachmentPlan.recognized -gt 0) {
        $attachmentSummary = "附件：识别 $([int]$attachmentPlan.recognized) 个，本轮加入发送队列 $([int]$queueResult.queued) 个"
        if ([int]$queueResult.duplicates -gt 0) { $attachmentSummary += "，已有 $([int]$queueResult.duplicates) 个在队列中或已发送" }
        if ($excludedAttachmentCount -gt 0) { $attachmentSummary += "，已排除 $excludedAttachmentCount 个" }
        if ($overLimitAttachmentCount -gt 0) { $attachmentSummary += "，另有 $overLimitAttachmentCount 个超过自动发送上限" }
        $attachmentSummary += '。可引用本通知发送 /附件 查看或重试。'
        $summary = "$attachmentSummary`n`n$summary"
    }
    $textBundle = New-CodexCompletionTextBundle -Name $displayName -Summary $summary `
        -ChunkChars $chunkChars -MaxChunks $maxChunks
    $summary = [string]$textBundle.summary
    $textParts = @($textBundle.parts)
    $text = [string]$textParts[0]
    $message = [ordered]@{
        id = [guid]::NewGuid().ToString('N')
        type = 'codex_turn_complete'
        text = $text
        session_id = $sessionId
        turn_id = $turnId
        thread_name = $displayName
        cwd = [string]$HookEvent.cwd
        summary = $summary
        text_parts = $textParts
        next_text_index = 0
        wechat_message_ids = @()
        attachments = $attachments
        text_sent = $false
        wechat_message_id = $null
        next_attachment_index = 0
        attachment_stats = [ordered]@{
            recognized = [int]$attachmentPlan.recognized
            queued = $attachments.Count
            excluded = $excludedAttachmentCount
            over_limit = $overLimitAttachmentCount
        }
        format_version = 7
        source_event_at = $sourceEventAt
        created_at = [DateTimeOffset]::Now.ToString('o')
    }
    $message.attachments = @()
    $message.next_attachment_index = 0
    try {
        foreach ($textPart in $textParts) {
            $textDelivery = Send-BridgeRoutableText -Text ([string]$textPart) -AllowContextlessRetry -TimeoutSeconds 15
            $message.next_text_index = [int]$message.next_text_index + 1
            $message.wechat_message_ids = @($message.wechat_message_ids) + [string]$textDelivery.message_id
            $message.wechat_message_id = [string]$textDelivery.message_id
            Register-BridgeReplyTarget -SessionId $sessionId -ThreadName $displayName `
                -Cwd ([string]$HookEvent.cwd) -TurnId $turnId -WeChatMessageId ([string]$textDelivery.message_id) `
                -SendStartedAt ([string]$textDelivery.send_started_at) -SendCompletedAt ([string]$textDelivery.send_completed_at)
        }
        $message.text_sent = $true
        Set-CodexNotificationState -SessionId $sessionId -TurnId $turnId -State sent
        Write-BridgeLog -Level INFO -Message "Codex completion notification text sent in $($textParts.Count) part(s)."
        return [pscustomobject]@{
            sent = $true
            attachments_queued = [int]$queueResult.queued
            attachments_excluded = $excludedAttachmentCount
            attachments_over_limit = $overLimitAttachmentCount
        }
    } catch {
        Queue-BridgeMessage -Message $message
        Set-CodexNotificationState -SessionId $sessionId -TurnId $turnId -State queued
        Write-BridgeLog -Level WARN -Message "Notification queued: $($_.Exception.Message)"
        return [pscustomobject]@{ sent = $false; queued = $true }
    }
}

function Publish-CodexStateNotification {
    param(
        [Parameter(Mandatory)]$HookEvent,
        [Parameter(Mandatory)][ValidateSet('paused', 'failed')][string]$State,
        [string]$Reason
    )
    return Invoke-WithBridgeNotificationGate -Action {
        Invoke-CodexStateNotificationCore -HookEvent $HookEvent -State $State -Reason $Reason
    }
}

function Invoke-CodexStateNotificationCore {
    param(
        [Parameter(Mandatory)]$HookEvent,
        [Parameter(Mandatory)][ValidateSet('paused', 'failed')][string]$State,
        [string]$Reason
    )
    $sessionId = [string]$HookEvent.session_id
    $turnId = [string]$HookEvent.turn_id
    if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = [guid]::NewGuid().ToString('N') }
    $notificationTurnId = "$turnId-$State"
    $displayName = if ((Test-BridgeProperty -Object $HookEvent -Name 'thread_name') -and $HookEvent.thread_name) {
        [string]$HookEvent.thread_name
    } else {
        Get-CodexThreadDisplayName -SessionId $sessionId -Cwd ([string]$HookEvent.cwd)
    }
    $registryState = if ($State -eq 'paused') { 'paused' } else { 'failed' }
    $summary = if ($Reason) { $Reason } elseif ($State -eq 'paused') { '本轮已中断，可引用本通知继续。' } else { '本轮未正常完成。' }
    Update-CodexThreadRegistry -HookEvent $HookEvent -State $registryState -Summary $summary | Out-Null
    Write-BridgeJsonAtomic -Path (Join-Path (Initialize-BridgeState) 'active-thread.json') -Value ([ordered]@{
        session_id = $sessionId
        turn_id = $turnId
        cwd = [string]$HookEvent.cwd
        model = [string]$HookEvent.model
        name = $displayName
        updated_at = [DateTimeOffset]::Now.ToString('o')
    })
    $config = Get-BridgeConfig
    if (-not [bool]$config.notifications_enabled) { return [pscustomobject]@{ skipped = $true } }
    $sourceEventAt = if (Test-BridgeProperty -Object $HookEvent -Name 'event_at') { [string]$HookEvent.event_at } else { '' }
    if (-not (Test-BridgeNotificationAfterReset -Timestamp $sourceEventAt)) {
        Register-CodexNotificationKey -SessionId $sessionId -TurnId $notificationTurnId -State suppressed | Out-Null
        Write-BridgeLog -Level INFO -Message "Notification reset suppressed pre-cutoff state event $sessionId/$notificationTurnId."
        return [pscustomobject]@{ suppressed = $true; reset = $true }
    }
    if (-not (Register-CodexNotificationKey -SessionId $sessionId -TurnId $notificationTurnId -State reserved)) {
        return [pscustomobject]@{ skipped = $true; duplicate = $true }
    }
    $header = if ($State -eq 'paused') { '已暂停' } else { '执行失败' }
    $text = "【$header】$displayName`n$summary"
    $message = [ordered]@{
        id = [guid]::NewGuid().ToString('N')
        type = 'codex_state'
        text = $text
        session_id = $sessionId
        turn_id = $notificationTurnId
        thread_name = $displayName
        cwd = [string]$HookEvent.cwd
        summary = $summary
        attachments = @()
        text_sent = $false
        wechat_message_id = $null
        next_attachment_index = 0
        format_version = 5
        source_event_at = $sourceEventAt
        created_at = [DateTimeOffset]::Now.ToString('o')
    }
    try {
        $delivery = Send-BridgeRoutableText -Text $text -AllowContextlessRetry -TimeoutSeconds 15
        Register-BridgeReplyTarget -SessionId $sessionId -ThreadName $displayName -Cwd ([string]$HookEvent.cwd) `
            -TurnId $notificationTurnId -WeChatMessageId ([string]$delivery.message_id) `
            -SendStartedAt ([string]$delivery.send_started_at) -SendCompletedAt ([string]$delivery.send_completed_at)
        Set-CodexNotificationState -SessionId $sessionId -TurnId $notificationTurnId -State sent
        return [pscustomobject]@{ sent = $true }
    } catch {
        Queue-BridgeMessage -Message $message
        Set-CodexNotificationState -SessionId $sessionId -TurnId $notificationTurnId -State queued
        return [pscustomobject]@{ sent = $false; queued = $true }
    }
}

function Register-CodexPromptStart {
    param([Parameter(Mandatory)]$HookEvent)
    $root = Initialize-BridgeState
    $record = [ordered]@{
        session_id = [string]$HookEvent.session_id
        turn_id = [string]$HookEvent.turn_id
        cwd = [string]$HookEvent.cwd
        started_at = [DateTimeOffset]::Now.ToString('o')
    }
    Write-BridgeJsonAtomic -Path (Join-Path $root 'current-turn.json') -Value $record
    Update-CodexThreadRegistry -HookEvent $HookEvent -State running | Out-Null
}

function Get-InboundText {
    param($Message)
    foreach ($item in @($Message.item_list)) {
        if ([int]$item.type -eq 1 -and
            (Test-BridgeProperty -Object $item -Name 'text_item') -and $item.text_item -and
            (Test-BridgeProperty -Object $item.text_item -Name 'text') -and $null -ne $item.text_item.text) {
            return [string]$item.text_item.text
        }
    }
    return ''
}

function Add-InboundCompletionQuoteCandidate {
    param(
        $Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Parts,
        [int]$Depth = 0
    )
    if ($null -eq $Value -or $Depth -gt 10) { return }
    if ($Value -is [string]) {
        $candidate = ([string]$Value).Trim()
        if ($candidate -match '【(?:已完成|已暂停|执行失败|已创建)】' -and -not $Parts.Contains($candidate)) {
            $Parts.Add($candidate)
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $name = [string]$key
            if ($name -match '(?i)context_token|bot_token|aes|encrypt|download_param|media') { continue }
            Add-InboundCompletionQuoteCandidate -Value $Value[$key] -Parts $Parts -Depth ($Depth + 1)
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in @($Value)) {
            Add-InboundCompletionQuoteCandidate -Value $entry -Parts $Parts -Depth ($Depth + 1)
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ([string]$property.Name -match '(?i)context_token|bot_token|aes|encrypt|download_param|media') { continue }
        Add-InboundCompletionQuoteCandidate -Value $property.Value -Parts $Parts -Depth ($Depth + 1)
    }
}

function Add-InboundReferenceIdCandidate {
    param(
        $Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Ids,
        [int]$Depth = 0
    )
    if ($null -eq $Value -or $Depth -gt 10) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $name = [string]$key
            $entry = $Value[$key]
            if ($name -match '^(?i:msg_id|message_id|client_id|root_id|parent_id)$') {
                $id = ([string]$entry).Trim()
                if ($id -and $id -ne '0' -and -not $Ids.Contains($id)) { $Ids.Add($id) }
            } else {
                Add-InboundReferenceIdCandidate -Value $entry -Ids $Ids -Depth ($Depth + 1)
            }
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($entry in @($Value)) {
            Add-InboundReferenceIdCandidate -Value $entry -Ids $Ids -Depth ($Depth + 1)
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -match '^(?i:msg_id|message_id|client_id|root_id|parent_id)$') {
            $id = ([string]$property.Value).Trim()
            if ($id -and $id -ne '0' -and -not $Ids.Contains($id)) { $Ids.Add($id) }
        } else {
            Add-InboundReferenceIdCandidate -Value $property.Value -Ids $Ids -Depth ($Depth + 1)
        }
    }
}

function Get-InboundReferenceMessageIds {
    param($Message)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Message.item_list)) {
        if ((Test-BridgeProperty -Object $item -Name 'ref_msg') -and $item.ref_msg) {
            Add-InboundReferenceIdCandidate -Value $item.ref_msg -Ids $ids
        }
    }
    foreach ($name in @('parent_id', 'root_id')) {
        if ((Test-BridgeProperty -Object $Message -Name $name) -and $Message.$name) {
            $id = ([string]$Message.$name).Trim()
            if ($id -and $id -ne '0' -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    return @($ids)
}

function Add-InboundReferenceCreateTimeCandidate {
    param(
        $Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[long]]$Times,
        [int]$Depth = 0
    )
    if ($null -eq $Value -or $Depth -gt 8) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if ([string]$key -eq 'create_time_ms') {
                $parsed = 0L
                if ([long]::TryParse([string]$Value[$key], [ref]$parsed) -and $parsed -gt 0 -and -not $Times.Contains($parsed)) {
                    $Times.Add($parsed)
                }
            } else {
                Add-InboundReferenceCreateTimeCandidate -Value $Value[$key] -Times $Times -Depth ($Depth + 1)
            }
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($entry in @($Value)) {
            Add-InboundReferenceCreateTimeCandidate -Value $entry -Times $Times -Depth ($Depth + 1)
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if ([string]$property.Name -eq 'create_time_ms') {
            $parsed = 0L
            if ([long]::TryParse([string]$property.Value, [ref]$parsed) -and $parsed -gt 0 -and -not $Times.Contains($parsed)) {
                $Times.Add($parsed)
            }
        } else {
            Add-InboundReferenceCreateTimeCandidate -Value $property.Value -Times $Times -Depth ($Depth + 1)
        }
    }
}

function Get-InboundReferenceCreateTimeMs {
    param($Message)
    $times = [System.Collections.Generic.List[long]]::new()
    foreach ($item in @($Message.item_list)) {
        if ((Test-BridgeProperty -Object $item -Name 'ref_msg') -and $item.ref_msg) {
            if ((Test-BridgeProperty -Object $item.ref_msg -Name 'message_item') -and $item.ref_msg.message_item -and
                (Test-BridgeProperty -Object $item.ref_msg.message_item -Name 'create_time_ms')) {
                $parsed = 0L
                if ([long]::TryParse([string]$item.ref_msg.message_item.create_time_ms, [ref]$parsed) -and
                    $parsed -gt 0 -and -not $times.Contains($parsed)) {
                    $times.Add($parsed)
                }
            }
            if ($times.Count -eq 0) {
                Add-InboundReferenceCreateTimeCandidate -Value $item.ref_msg -Times $times
            }
        }
    }
    return @($times)
}

function Get-InboundReferenceText {
    param($Message)
    $parts = [System.Collections.Generic.List[string]]::new()
    $primaryTextSkipped = $false
    foreach ($item in @($Message.item_list)) {
        if ((Test-BridgeProperty -Object $item -Name 'ref_msg') -and $item.ref_msg) {
            Add-InboundCompletionQuoteCandidate -Value $item.ref_msg -Parts $parts
        }
        if ((Test-BridgeProperty -Object $item -Name 'text_item') -and $item.text_item) {
            foreach ($property in @($item.text_item.PSObject.Properties)) {
                if ([string]$property.Name -eq 'text' -and -not $primaryTextSkipped) {
                    $primaryTextSkipped = $true
                    continue
                }
                Add-InboundCompletionQuoteCandidate -Value $property.Value -Parts $parts
            }
        }
        foreach ($property in @($item.PSObject.Properties)) {
            if ([string]$property.Name -in @('type', 'text_item', 'ref_msg')) { continue }
            Add-InboundCompletionQuoteCandidate -Value $property.Value -Parts $parts
        }
    }
    foreach ($property in @($Message.PSObject.Properties)) {
        if ([string]$property.Name -in @('item_list', 'context_token')) { continue }
        Add-InboundCompletionQuoteCandidate -Value $property.Value -Parts $parts
    }
    return (@($parts) -join "`n").Trim()
}

function Get-InboundMessageShape {
    param($Message)
    $items = @()
    foreach ($item in @($Message.item_list)) {
        $refItem = if ((Test-BridgeProperty -Object $item -Name 'ref_msg') -and $item.ref_msg -and
            (Test-BridgeProperty -Object $item.ref_msg -Name 'message_item')) { $item.ref_msg.message_item } else { $null }
        $items += [pscustomobject]@{
            type = if (Test-BridgeProperty -Object $item -Name 'type') { [int]$item.type } else { $null }
            properties = @($item.PSObject.Properties.Name)
            text_item_properties = if ((Test-BridgeProperty -Object $item -Name 'text_item') -and $item.text_item) {
                @($item.text_item.PSObject.Properties.Name)
            } else { @() }
            ref_msg_properties = if ((Test-BridgeProperty -Object $item -Name 'ref_msg') -and $item.ref_msg) {
                @($item.ref_msg.PSObject.Properties.Name)
            } else { @() }
            ref_message_item_properties = if ($refItem) { @($refItem.PSObject.Properties.Name) } else { @() }
            ref_message_item_type = if ($refItem -and (Test-BridgeProperty -Object $refItem -Name 'type')) {
                [int]$refItem.type
            } else { $null }
        }
    }
    return [pscustomobject]@{
        top_level_properties = @($Message.PSObject.Properties.Name | Where-Object { $_ -ne 'context_token' })
        item_count = $items.Count
        items = $items
    }
}

function Save-InboundMessage {
    param(
        [Parameter(Mandatory)]$Message,
        [Parameter(Mandatory)][string]$Text
    )
    $root = Initialize-BridgeState
    $activeThread = Read-BridgeJson -Path (Join-Path $root 'active-thread.json') -Default $null
    $targetName = if ($activeThread -and (Test-BridgeProperty -Object $activeThread -Name 'session_id')) {
        Get-CodexThreadDisplayName -SessionId ([string]$activeThread.session_id) -Cwd ([string]$activeThread.cwd)
    } else { $null }
    $record = [ordered]@{
        id = if ($Message.message_id) { [string]$Message.message_id } else { [guid]::NewGuid().ToString('N') }
        from_user_id = [string]$Message.from_user_id
        text = $Text
        create_time_ms = $Message.create_time_ms
        received_at = [DateTimeOffset]::Now.ToString('o')
        relay_state = 'queued_only'
        target_session_id = if ($activeThread) { [string]$activeThread.session_id } else { $null }
        target_cwd = if ($activeThread) { [string]$activeThread.cwd } else { $null }
        target_thread_name = $targetName
        reference_text = Get-InboundReferenceText -Message $Message
        reference_message_ids = @(Get-InboundReferenceMessageIds -Message $Message)
        reference_create_time_ms = @(Get-InboundReferenceCreateTimeMs -Message $Message)
        inbound_shape = Get-InboundMessageShape -Message $Message
    }
    $name = '{0}-{1}.json' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N'))
    $path = Join-Path (Join-Path $root 'inbox') $name
    Write-BridgeJsonAtomic -Path $path -Value $record
    return [pscustomobject]@{ path = $path; record = [pscustomobject]$record }
}

function Register-BridgeInboundMessageId {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MessageId)
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($false, 'Local\CodexWeChatInboundHistory', [ref]$createdNew)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out while updating inbound history.' }
        $path = Join-Path (Initialize-BridgeState) 'inbound-history.json'
        $history = Read-BridgeJson -Path $path -Default @{ messages = @{} } -AsHashtable
        if (-not $history.ContainsKey('messages') -or $null -eq $history.messages) { $history.messages = @{} }
        if ($history.messages.ContainsKey($MessageId)) { return $false }
        $history.messages[$MessageId] = [DateTimeOffset]::Now.ToString('o')
        $limit = [Math]::Max(100, [int](Get-BridgeConfig).inbound_history_limit)
        if ($history.messages.Count -gt $limit) {
            $trimmed = @{}
            foreach ($entry in @($history.messages.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $limit)) {
                $trimmed[[string]$entry.Key] = [string]$entry.Value
            }
            $history.messages = $trimmed
        }
        Write-BridgeJsonAtomic -Path $path -Value $history
        return $true
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

function Update-InboundRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Changes
    )
    $record = Read-BridgeJson -Path $Path -Default $null
    if (-not $record) { throw "Inbound queue record no longer exists: $Path" }
    foreach ($entry in $Changes.GetEnumerator()) {
        if ($record.PSObject.Properties.Name -contains $entry.Key) {
            $record.$($entry.Key) = $entry.Value
        } else {
            $record | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
        }
    }
    Write-BridgeJsonAtomic -Path $Path -Value $record
    return $record
}

function Complete-CodexRelayRecordsForThread {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('completed', 'paused', 'failed')][string]$TerminalState,
        [string]$TurnId,
        [string]$CompletedAt
    )
    $root = Initialize-BridgeState
    $completedAtValue = if ([string]::IsNullOrWhiteSpace($CompletedAt)) {
        [DateTimeOffset]::Now.ToString('o')
    } else { $CompletedAt }
    $updated = 0
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'inbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record) { continue }
        if ([string]$record.relay_state -ne 'relay_submitted') { continue }
        if (-not ([string]$record.target_session_id).Equals($SessionId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        Update-InboundRecord -Path $file.FullName -Changes @{
            relay_state = 'relay_completed'
            relay_completed_at = $completedAtValue
            codex_terminal_state = $TerminalState
            codex_turn_id = $TurnId
        } | Out-Null
        $updated++
    }
    return $updated
}

function Test-CodexRelayPendingForThread {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId)
    $inboxPath = Join-Path (Initialize-BridgeState) 'inbox'
    foreach ($file in @(Get-ChildItem -LiteralPath $inboxPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record -or -not (Test-BridgeProperty -Object $record -Name 'relay_state')) { continue }
        if ([string]$record.relay_state -notin @('relay_running', 'relay_submitted')) { continue }
        $targetId = if ((Test-BridgeProperty -Object $record -Name 'target_session_id') -and $record.target_session_id) {
            [string]$record.target_session_id
        } elseif ((Test-BridgeProperty -Object $record -Name 'created_thread_id') -and $record.created_thread_id) {
            [string]$record.created_thread_id
        } else { '' }
        if ($targetId.Equals($SessionId, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-CodexRelayPendingTurnId {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId)
    $inboxPath = Join-Path (Initialize-BridgeState) 'inbox'
    foreach ($file in @(Get-ChildItem -LiteralPath $inboxPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record -or -not (Test-BridgeProperty -Object $record -Name 'relay_state')) { continue }
        if ([string]$record.relay_state -notin @('relay_running', 'relay_submitted')) { continue }
        $targetId = if ((Test-BridgeProperty -Object $record -Name 'target_session_id') -and $record.target_session_id) {
            [string]$record.target_session_id
        } elseif ((Test-BridgeProperty -Object $record -Name 'created_thread_id') -and $record.created_thread_id) {
            [string]$record.created_thread_id
        } else { '' }
        if (-not $targetId.Equals($SessionId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Test-BridgeProperty -Object $record -Name 'codex_turn_id') -and
            -not [string]::IsNullOrWhiteSpace([string]$record.codex_turn_id)) {
            return [string]$record.codex_turn_id
        }
    }
    return ''
}

function Test-BridgeProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Get-CodexExecutable {
    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        $candidate = Get-ChildItem -LiteralPath $binRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return $command.Source }
    throw 'Could not locate a runnable Codex executable.'
}

function Send-AppServerMessage {
    param(
        [Parameter(Mandatory)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory)]$Message
    )
    $json = $Message | ConvertTo-Json -Depth 60 -Compress
    $Writer.WriteLine($json)
    $Writer.Flush()
}

function Read-AppServerMessage {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline
    )
    $remaining = [int][Math]::Min(
        [int]::MaxValue,
        [Math]::Max(1, [Math]::Ceiling(($Deadline - [DateTimeOffset]::Now).TotalMilliseconds))
    )
    $readTask = $Reader.ReadLineAsync()
    if (-not $readTask.Wait($remaining)) {
        throw 'Codex App Server timed out while waiting for a response.'
    }
    $line = $readTask.GetAwaiter().GetResult()
    if ($null -eq $line) {
        $exitText = if ($Process.HasExited) { " exit code $($Process.ExitCode)" } else { '' }
        throw "Codex App Server closed its output stream unexpectedly.$exitText"
    }
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    try {
        return $line | ConvertFrom-Json
    } catch {
        throw "Codex App Server returned invalid JSON: $($_.Exception.Message)"
    }
}

function Resolve-AppServerRequest {
    param(
        [Parameter(Mandatory)]$Message,
        [Parameter(Mandatory)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory)][ref]$DeclinedApprovalCount
    )
    if (-not (Test-BridgeProperty -Object $Message -Name 'id') -or
        -not (Test-BridgeProperty -Object $Message -Name 'method')) {
        return $false
    }

    $method = [string]$Message.method
    $result = $null
    switch ($method) {
        'item/commandExecution/requestApproval' {
            $DeclinedApprovalCount.Value++
            $result = @{ decision = 'decline' }
        }
        'item/fileChange/requestApproval' {
            $DeclinedApprovalCount.Value++
            $result = @{ decision = 'decline' }
        }
        'item/permissions/requestApproval' {
            $DeclinedApprovalCount.Value++
            $result = @{ permissions = @{}; scope = 'turn' }
        }
        'item/tool/requestUserInput' {
            $result = @{ answers = @{} }
        }
        'mcpServer/elicitation/request' {
            $DeclinedApprovalCount.Value++
            $result = @{ action = 'decline'; content = $null }
        }
        default {
            Send-AppServerMessage -Writer $Writer -Message ([ordered]@{
                id = $Message.id
                error = @{ code = -32601; message = "Unsupported server request: $method" }
            })
            return $true
        }
    }

    Send-AppServerMessage -Writer $Writer -Message ([ordered]@{
        id = $Message.id
        result = $result
    })
    return $true
}

function Wait-AppServerResponse {
    param(
        [Parameter(Mandatory)][long]$RequestId,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][System.IO.StreamReader]$Reader,
        [Parameter(Mandatory)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory)][DateTimeOffset]$Deadline,
        [Parameter(Mandatory)][ref]$DeclinedApprovalCount
    )
    while ($true) {
        $message = Read-AppServerMessage -Process $Process -Reader $Reader -Deadline $Deadline
        if ($null -eq $message) { continue }
        if (Resolve-AppServerRequest -Message $message -Writer $Writer -DeclinedApprovalCount $DeclinedApprovalCount) {
            continue
        }
        if ((Test-BridgeProperty -Object $message -Name 'id') -and [long]$message.id -eq $RequestId) {
            if (Test-BridgeProperty -Object $message -Name 'error') {
                $errorMessage = if (Test-BridgeProperty -Object $message.error -Name 'message') {
                    [string]$message.error.message
                } else {
                    'Unknown App Server request error.'
                }
                throw $errorMessage
            }
            return $message
        }
    }
}

function Refresh-CodexThreadCatalog {
    param([switch]$Force)
    $root = Initialize-BridgeState
    $catalogPath = Join-Path $root 'thread-catalog.json'
    $existing = Read-BridgeJson -Path $catalogPath -Default $null
    $config = Get-BridgeConfig
    $maxAgeSeconds = if ($config.thread_catalog_refresh_seconds) { [int]$config.thread_catalog_refresh_seconds } else { 45 }
    if (-not $Force -and $existing -and (Test-BridgeProperty -Object $existing -Name 'refreshed_at')) {
        try {
            $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$existing.refreshed_at)).TotalSeconds
            if ($age -lt $maxAgeSeconds) { return $existing }
        } catch { }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CodexExecutable
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8NoBom
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    foreach ($argument in @('app-server', '--listen', 'stdio://')) { $startInfo.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $deadline = [DateTimeOffset]::Now.AddSeconds(20)
    $declinedApprovals = 0
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw 'Failed to start Codex App Server for task catalog refresh.' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writer = $process.StandardInput
        $reader = $process.StandardOutput
        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'initialize'
            id = 1
            params = @{ clientInfo = @{ name = 'codex_wechat_catalog'; title = 'Codex WeChat Task Catalog'; version = $script:BridgeVersion } }
        })
        Wait-AppServerResponse -RequestId 1 -Process $process -Reader $reader -Writer $writer `
            -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals) | Out-Null
        Send-AppServerMessage -Writer $writer -Message @{ method = 'initialized'; params = @{} }
        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'thread/list'
            id = 2
            params = @{
                limit = 100
                sortKey = 'updated_at'
                sortDirection = 'desc'
                archived = $false
                useStateDbOnly = $false
            }
        })
        $response = Wait-AppServerResponse -RequestId 2 -Process $process -Reader $reader -Writer $writer `
            -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals)
        $threads = foreach ($thread in @($response.result.data)) {
            [ordered]@{
                session_id = [string]$thread.id
                name = [string]$thread.name
                preview = [string]$thread.preview
                cwd = [string]$thread.cwd
                status_type = if ($thread.status -and (Test-BridgeProperty -Object $thread.status -Name 'type')) { [string]$thread.status.type } else { $null }
                active_flags = if ($thread.status -and (Test-BridgeProperty -Object $thread.status -Name 'activeFlags')) { @($thread.status.activeFlags) } else { @() }
                updated_at = if ($thread.updatedAt) { [DateTimeOffset]::FromUnixTimeSeconds([long]$thread.updatedAt).ToString('o') } else { $null }
            }
        }
        $catalog = [ordered]@{
            refreshed_at = [DateTimeOffset]::Now.ToString('o')
            threads = @($threads)
        }
        Write-BridgeJsonAtomic -Path $catalogPath -Value $catalog
        return [pscustomobject]$catalog
    } catch {
        Write-BridgeLog -Level WARN -Message "Codex task catalog refresh failed: $($_.Exception.Message)"
        if ($existing) { return $existing }
        throw
    } finally {
        if ($process) {
            try { $process.StandardInput.Close() } catch { }
            try {
                if (-not $process.HasExited -and -not $process.WaitForExit(1000)) {
                    $process.Kill($true)
                    $process.WaitForExit(2000) | Out-Null
                }
            } catch { }
            try { if ($stderrTask -and $stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() | Out-Null } } catch { }
            $process.Dispose()
        }
    }
}

function Test-CodexDesktopCatalogThread {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName,
        [int]$TimeoutSeconds = 5
    )
    $deadline = [DateTimeOffset]::Now.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        try {
            $catalog = Refresh-CodexThreadCatalog -Force
            $match = @($catalog.threads | Where-Object {
                [string]$_.session_id -eq $ThreadId -and [string]$_.name -eq $ThreadName
            } | Select-Object -First 1)
            if ($match.Count -gt 0) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 400
    } while ([DateTimeOffset]::Now -lt $deadline)

    # The Desktop and a short-lived bridge App Server can maintain separate
    # metadata views. A Desktop-originated, user-visible persisted rollout is
    # still a valid interactive Desktop task even when the bridge's second
    # App Server has not repaired that catalog row yet.
    try {
        $rolloutPath = Get-CodexRolloutPath -ThreadId $ThreadId
        $metadata = Get-CodexRolloutMetadata -Path $rolloutPath
        if (-not $metadata -or -not [bool]$metadata.user_visible -or
            -not ([string]$metadata.source).Equals('vscode', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $savedName = Get-CodexThreadDisplayName -SessionId $ThreadId -Cwd ([string]$metadata.cwd)
        return $savedName -eq $ThreadName
    } catch {
        return $false
    }
}

function Invoke-CodexAppServerTurn {
    param(
        [string]$ThreadId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [string]$Cwd,
        [int]$TimeoutSeconds = 1200,
        [switch]$NewEphemeral,
        [switch]$NewPersistent,
        [string]$ForkThreadId,
        [string]$ThreadName,
        [scriptblock]$OnThreadCreated,
        [scriptblock]$OnTurnStarted,
        [string]$RelayRecordPath,
        [ValidateSet('', 'continue', 'new', 'fork', 'worktree')][string]$RelayCommandType = ''
    )
    $creationModes = @(@($NewEphemeral.IsPresent, $NewPersistent.IsPresent, -not [string]::IsNullOrWhiteSpace($ForkThreadId)) |
        Where-Object { $_ })
    if ($creationModes.Count -gt 1) { throw 'Choose only one App Server thread creation mode.' }
    if (-not $NewEphemeral -and -not $NewPersistent -and [string]::IsNullOrWhiteSpace($ForkThreadId) -and
        [string]::IsNullOrWhiteSpace($ThreadId)) {
        throw 'No current Codex task is recorded. Open the target Codex task and send one local prompt first.'
    }
    if ([string]::IsNullOrWhiteSpace($Cwd) -or -not (Test-Path -LiteralPath $Cwd -PathType Container)) {
        $Cwd = (Get-Location).Path
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CodexExecutable
    $startInfo.WorkingDirectory = $Cwd
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8NoBom
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    foreach ($argument in @('app-server', '--listen', 'stdio://')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['CODEX_WECHAT_RELAY'] = '1'
    # Match the Codex Desktop client classification so persistent tasks created
    # by the bridge remain visible in the Desktop task list. The protocol-level
    # threadSource below marks the task as user initiated as well.
    $startInfo.Environment['CODEX_INTERNAL_ORIGINATOR_OVERRIDE'] = 'Codex Desktop'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $declinedApprovals = 0
    $finalText = ''
    $turnId = $null
    $turnStatus = 'unknown'
    $turnError = $null
    $stderrTask = $null
    $capturedStderr = ''
    $resolvedThreadId = if ($ThreadId) { $ThreadId } else { '' }

    try {
        if (-not $process.Start()) { throw 'Failed to start Codex App Server.' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writer = $process.StandardInput
        $reader = $process.StandardOutput

        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'initialize'
            id = 1
            params = @{ clientInfo = @{ name = 'codex_wechat_bridge'; title = 'Codex WeChat Bridge'; version = $script:BridgeVersion } }
        })
        Wait-AppServerResponse -RequestId 1 -Process $process -Reader $reader -Writer $writer `
            -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals) | Out-Null
        Send-AppServerMessage -Writer $writer -Message @{ method = 'initialized'; params = @{} }

        if ($NewEphemeral) {
            Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                method = 'thread/start'
                id = 2
                params = @{
                    cwd = $Cwd
                    ephemeral = $true
                    approvalPolicy = 'never'
                    sandbox = 'read-only'
                    serviceName = 'codex_wechat_bridge_test'
                }
            })
        } elseif ($NewPersistent) {
            Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                method = 'thread/start'
                id = 2
                params = @{
                    cwd = $Cwd
                    serviceName = 'codex_wechat_bridge'
                    threadSource = 'user'
                }
            })
        } elseif (-not [string]::IsNullOrWhiteSpace($ForkThreadId)) {
            Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                method = 'thread/fork'
                id = 2
                params = @{
                    threadId = $ForkThreadId
                    cwd = $Cwd
                    threadSource = 'user'
                }
            })
        } else {
            Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                method = 'thread/resume'
                id = 2
                params = @{ threadId = $ThreadId }
            })
        }
        $threadResponse = Wait-AppServerResponse -RequestId 2 -Process $process -Reader $reader -Writer $writer `
            -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals)
        if (-not (Test-BridgeProperty -Object $threadResponse.result -Name 'thread')) {
            throw 'Codex App Server did not return a thread.'
        }
        $resolvedThread = $threadResponse.result.thread
        $resolvedThreadId = [string]$resolvedThread.id
        $resolvedSource = if ((Test-BridgeProperty -Object $resolvedThread -Name 'source') -and
            $resolvedThread.source -is [string]) { [string]$resolvedThread.source } else { '' }
        $resolvedThreadSource = if ((Test-BridgeProperty -Object $resolvedThread -Name 'threadSource') -and
            $resolvedThread.threadSource -is [string]) { [string]$resolvedThread.threadSource } else { '' }
        if (-not $NewEphemeral -and $RelayCommandType -in @('new', 'fork', 'worktree') -and
            ([string]::IsNullOrWhiteSpace($resolvedSource) -or
             -not $resolvedSource.Equals('vscode', [StringComparison]::OrdinalIgnoreCase))) {
            try {
                Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                    method = 'thread/archive'; id = 91; params = @{ threadId = $resolvedThreadId }
                })
                Wait-AppServerResponse -RequestId 91 -Process $process -Reader $reader -Writer $writer `
                    -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals) | Out-Null
            } catch { }
            throw 'Codex 未把新任务登记为桌面可见任务；本次已安全终止，没有提交任务内容。'
        }

        $turnRequestId = 3
        if (-not $NewEphemeral -and -not [string]::IsNullOrWhiteSpace($ThreadName)) {
            Send-AppServerMessage -Writer $writer -Message ([ordered]@{
                method = 'thread/name/set'
                id = 3
                params = @{ threadId = $resolvedThreadId; name = $ThreadName }
            })
            Wait-AppServerResponse -RequestId 3 -Process $process -Reader $reader -Writer $writer `
                -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals) | Out-Null
            Set-CodexThreadDisplayName -SessionId $resolvedThreadId -Name $ThreadName | Out-Null
            $turnRequestId = 4
        }
        if ($OnThreadCreated) {
            & $OnThreadCreated $resolvedThreadId $Cwd $ThreadName
        }
        if (-not [string]::IsNullOrWhiteSpace($RelayRecordPath) -and
            $RelayCommandType -in @('new', 'fork', 'worktree')) {
            Update-InboundRecord -Path $RelayRecordPath -Changes @{
                relay_state = 'relay_running'
                target_session_id = $resolvedThreadId
                created_thread_id = $resolvedThreadId
                created_thread_at = [DateTimeOffset]::Now.ToString('o')
            } | Out-Null
            $runningEvent = [pscustomobject]@{
                session_id = $resolvedThreadId; turn_id = ''; cwd = $Cwd; model = $null
                thread_name = $ThreadName; event_at = [DateTimeOffset]::Now.ToString('o')
            }
            Update-CodexThreadRegistry -HookEvent $runningEvent -State running | Out-Null
        }

        $turnPrompt = $Prompt
        if ($RelayCommandType -eq 'fork') {
            $turnPrompt = @"
[桥接路由说明：当前已经是新分支。不要因“测试分支”等措辞再次创建、等待或终止分支；除非用户明确要求修改桥接代码。]
用户原文：
$Prompt
"@
        }
        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'turn/start'
            id = $turnRequestId
            params = @{
                threadId = $resolvedThreadId
                input = @(@{ type = 'text'; text = $turnPrompt })
            }
        })
        $turnResponse = Wait-AppServerResponse -RequestId $turnRequestId -Process $process -Reader $reader -Writer $writer `
            -Deadline $deadline -DeclinedApprovalCount ([ref]$declinedApprovals)
        if (-not (Test-BridgeProperty -Object $turnResponse.result -Name 'turn')) {
            throw 'Codex App Server did not start a turn.'
        }
        $turnId = [string]$turnResponse.result.turn.id
        if ($OnTurnStarted) { & $OnTurnStarted $resolvedThreadId $turnId $Cwd $ThreadName }
        if (-not [string]::IsNullOrWhiteSpace($RelayRecordPath)) {
            Update-InboundRecord -Path $RelayRecordPath -Changes @{
                relay_state = 'relay_submitted'
                relay_submitted_at = [DateTimeOffset]::Now.ToString('o')
                target_session_id = $resolvedThreadId
                codex_turn_id = $turnId
                codex_started_at = [DateTimeOffset]::Now.ToString('o')
            } | Out-Null
            try {
                $startedDelivery = Send-BridgeText -Text ("【$ThreadName】`n开始处理") `
                    -AllowContextlessRetry -TimeoutSeconds 15
                Update-InboundRecord -Path $RelayRecordPath -Changes @{
                    start_ack_sent_at = [DateTimeOffset]::Now.ToString('o')
                    start_ack_message_id = [string]$startedDelivery.message_id
                } | Out-Null
            } catch {
                Write-BridgeLog -Level WARN -Message "Progress acknowledgement deferred without interrupting Codex: $($_.Exception.Message)"
            }
        }

        while ($true) {
            $message = Read-AppServerMessage -Process $process -Reader $reader -Deadline $deadline
            if ($null -eq $message) { continue }
            if (Resolve-AppServerRequest -Message $message -Writer $writer -DeclinedApprovalCount ([ref]$declinedApprovals)) {
                continue
            }
            if (-not (Test-BridgeProperty -Object $message -Name 'method')) { continue }

            $method = [string]$message.method
            if ($method -eq 'item/completed' -and
                (Test-BridgeProperty -Object $message -Name 'params') -and
                (Test-BridgeProperty -Object $message.params -Name 'item')) {
                $item = $message.params.item
                if ((Test-BridgeProperty -Object $item -Name 'type') -and [string]$item.type -eq 'agentMessage' -and
                    (Test-BridgeProperty -Object $item -Name 'text')) {
                    $phase = if (Test-BridgeProperty -Object $item -Name 'phase') { [string]$item.phase } else { '' }
                    if ($phase -eq 'final_answer' -or [string]::IsNullOrWhiteSpace($finalText)) {
                        $finalText = [string]$item.text
                    }
                }
            } elseif ($method -eq 'error' -and (Test-BridgeProperty -Object $message -Name 'params')) {
                if ((Test-BridgeProperty -Object $message.params -Name 'error') -and
                    (Test-BridgeProperty -Object $message.params.error -Name 'message')) {
                    $turnError = [string]$message.params.error.message
                }
            } elseif ($method -eq 'turn/completed' -and
                (Test-BridgeProperty -Object $message -Name 'params') -and
                (Test-BridgeProperty -Object $message.params -Name 'turn') -and
                [string]$message.params.turn.id -eq $turnId) {
                $turnStatus = [string]$message.params.turn.status
                if ((Test-BridgeProperty -Object $message.params.turn -Name 'error') -and $message.params.turn.error -and
                    (Test-BridgeProperty -Object $message.params.turn.error -Name 'message')) {
                    $turnError = [string]$message.params.turn.error.message
                }
                break
            }
        }

        if ($turnStatus -ne 'completed') {
            $failure = if ($turnError) { $turnError } else { "Turn ended with status $turnStatus." }
            throw $failure
        }
        if ([string]::IsNullOrWhiteSpace($finalText)) {
            $finalText = '任务已经完成，请在 Codex 中查看详细结果。'
        }
        $desktopCatalogVerified = $false
        if (-not $NewEphemeral -and $RelayCommandType -in @('new', 'fork', 'worktree')) {
            $desktopCatalogVerified = Test-CodexDesktopCatalogThread -ThreadId $resolvedThreadId `
                -ThreadName $ThreadName -TimeoutSeconds 5
            if (-not $desktopCatalogVerified) {
                throw 'Codex 已生成任务记录，但桌面任务列表尚未确认收录；本次不会向微信报告成功。'
            }
            if (-not [string]::IsNullOrWhiteSpace($RelayRecordPath)) {
                Update-InboundRecord -Path $RelayRecordPath -Changes @{
                    created_thread_desktop_verified = $true
                    created_thread_desktop_verified_at = [DateTimeOffset]::Now.ToString('o')
                } | Out-Null
            }
        }
        return [pscustomobject]@{
            thread_id = $resolvedThreadId
            turn_id = $turnId
            status = $turnStatus
            final_text = $finalText
            declined_approvals = $declinedApprovals
            cwd = $Cwd
            thread_name = $ThreadName
            forked_from_id = $ForkThreadId
            source = $resolvedSource
            thread_source = $resolvedThreadSource
            desktop_catalog_verified = $desktopCatalogVerified
        }
    } catch {
        try {
            if ($stderrTask) {
                if (-not $stderrTask.IsCompleted) { $stderrTask.Wait(2000) | Out-Null }
                if ($stderrTask.IsCompleted) { $capturedStderr = $stderrTask.GetAwaiter().GetResult().Trim() }
            }
        } catch { }
        $message = $_.Exception.Message
        if ($capturedStderr) {
            if ($capturedStderr.Length -gt 4000) { $capturedStderr = '…' + $capturedStderr.Substring($capturedStderr.Length - 4000) }
            $message += " App Server stderr: $capturedStderr"
        }
        throw $message
    } finally {
        if ($process) {
            try { $process.StandardInput.Close() } catch { }
            try {
                if (-not $process.HasExited -and -not $process.WaitForExit(2000)) {
                    $process.Kill($true)
                    $process.WaitForExit(3000) | Out-Null
                }
            } catch { }
            try { if ($stderrTask -and $stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() | Out-Null } } catch { }
            $process.Dispose()
        }
    }
}

function Get-CodexThreadProgressText {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [int]$MaxChars = 120
    )
    $rolloutPath = $null
    $monitor = Read-BridgeJson -Path (Join-Path (Initialize-BridgeState) 'rollout-monitor.json') `
        -Default $null -AsHashtable
    if ($monitor -and $monitor.ContainsKey('files')) {
        $matches = @($monitor.files.GetEnumerator() | Where-Object {
            [string]$_.Value.session_id -eq $SessionId -and (Test-Path -LiteralPath ([string]$_.Key) -PathType Leaf)
        } | ForEach-Object { Get-Item -LiteralPath ([string]$_.Key) } | Sort-Object LastWriteTimeUtc -Descending)
        if ($matches.Count -gt 0) { $rolloutPath = $matches[0].FullName }
    }
    if ([string]::IsNullOrWhiteSpace($rolloutPath)) {
        try { $rolloutPath = Get-CodexRolloutPath -ThreadId $SessionId } catch { return '' }
    }
    if (-not (Test-Path -LiteralPath $rolloutPath -PathType Leaf)) { return '' }

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($rolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        # Keep enough of the active turn to include its task_started boundary even
        # when tools have emitted a relatively large amount of structured output.
        $maxBytes = 8388608L
        $start = [Math]::Max(0L, $stream.Length - $maxBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new([int]($stream.Length - $start))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    } finally { $stream.Dispose() }
    if ($start -gt 0) {
        $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
        if ($firstNewline -ge 0) { $text = $text.Substring($firstNewline + 1) }
    }
    $lines = @([regex]::Split($text, "\r?\n"))
    if ($lines.Count -eq 0) { return '' }
    $startIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        try {
            $boundary = $lines[$index] | ConvertFrom-Json
            if ((Test-BridgeProperty -Object $boundary -Name 'type') -and [string]$boundary.type -eq 'event_msg' -and
                (Test-BridgeProperty -Object $boundary -Name 'payload') -and $boundary.payload -and
                (Test-BridgeProperty -Object $boundary.payload -Name 'type') -and
                [string]$boundary.payload.type -eq 'task_started') { $startIndex = $index }
        } catch { }
    }
    # A single active turn can exceed the tail window when tools emit large
    # outputs. The caller has already established that the task is running, so
    # scan the available tail for the latest commentary even if task_started is
    # older than this window. A task_complete event below still clears it.
    if ($startIndex -lt 0) { $startIndex = 0 }

    $latestCommentary = ''
    for ($index = $startIndex; $index -lt $lines.Count; $index++) {
        $event = $null
        try { $event = $lines[$index] | ConvertFrom-Json } catch { continue }
        if (-not (Test-BridgeProperty -Object $event -Name 'payload') -or -not $event.payload) { continue }
        $outerType = if (Test-BridgeProperty -Object $event -Name 'type') { [string]$event.type } else { '' }
        $payloadType = if (Test-BridgeProperty -Object $event.payload -Name 'type') { [string]$event.payload.type } else { '' }
        if ($outerType -eq 'event_msg' -and $payloadType -eq 'task_complete') { return '' }
        if ($outerType -eq 'event_msg' -and $payloadType -eq 'agent_message' -and
            (Test-BridgeProperty -Object $event.payload -Name 'message')) {
            $phase = if (Test-BridgeProperty -Object $event.payload -Name 'phase') { [string]$event.payload.phase } else { '' }
            if ($phase -eq 'commentary') { $latestCommentary = [string]$event.payload.message }
            continue
        }
    }

    $progress = if (-not [string]::IsNullOrWhiteSpace($latestCommentary)) {
        $latestCommentary
    } else { '正在处理，尚无新的阶段性说明。' }
    $progress = ([regex]::Replace([string]$progress, '\s+', ' ')).Trim()
    $progress = [regex]::Replace($progress, ':codex-file-citation\{[^}]+\}', '文件')
    if ($progress.Length -gt $MaxChars) { $progress = $progress.Substring(0, $MaxChars) + '…' }
    return $progress
}

function Set-CodexAppServerThreadName {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [string]$Cwd,
        [int]$TimeoutSeconds = 30
    )
    if ([string]::IsNullOrWhiteSpace($Cwd) -or -not (Test-Path -LiteralPath $Cwd -PathType Container)) {
        $Cwd = (Get-Location).Path
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CodexExecutable
    $startInfo.WorkingDirectory = $Cwd
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in @('app-server', '--listen', 'stdio://')) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $declined = 0
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw 'Failed to start Codex App Server for task naming.' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $writer = $process.StandardInput
        $reader = $process.StandardOutput
        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'initialize'; id = 1
            params = @{ clientInfo = @{ name = 'codex_wechat_namer'; title = 'Codex WeChat Task Namer'; version = $script:BridgeVersion } }
        })
        Wait-AppServerResponse -RequestId 1 -Process $process -Reader $reader -Writer $writer -Deadline $deadline `
            -DeclinedApprovalCount ([ref]$declined) | Out-Null
        Send-AppServerMessage -Writer $writer -Message @{ method = 'initialized'; params = @{} }
        Send-AppServerMessage -Writer $writer -Message ([ordered]@{
            method = 'thread/name/set'; id = 2; params = @{ threadId = $ThreadId; name = $Name }
        })
        Wait-AppServerResponse -RequestId 2 -Process $process -Reader $reader -Writer $writer -Deadline $deadline `
            -DeclinedApprovalCount ([ref]$declined) | Out-Null
        Set-CodexThreadDisplayName -SessionId $ThreadId -Name $Name | Out-Null
        return [pscustomobject]@{ renamed = $true; thread_id = $ThreadId; name = $Name }
    } finally {
        try { $process.StandardInput.Close() } catch { }
        try {
            if (-not $process.HasExited -and -not $process.WaitForExit(1000)) { $process.Kill($true) }
        } catch { }
        try { if ($stderrTask -and $stderrTask.IsCompleted) { $stderrTask.GetAwaiter().GetResult() | Out-Null } } catch { }
        $process.Dispose()
    }
}

function Start-BridgeRelayWorkerProcess {
    $config = Get-BridgeConfig
    if ([string]$config.inbound_mode -ne 'codex_relay') { return }
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $workerScript = Join-Path $PSScriptRoot 'Start-WeChatRelayWorker.ps1'
    if (-not (Test-Path -LiteralPath $workerScript -PathType Leaf)) {
        throw "Relay worker script is missing: $workerScript"
    }
    $root = Initialize-BridgeState
    $workerId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N'))
    $stdoutPath = Join-Path (Join-Path $root 'logs') "relay-worker-$workerId.out.log"
    $stderrPath = Join-Path (Join-Path $root 'logs') "relay-worker-$workerId.err.log"
    Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Sta', '-WindowStyle', 'Hidden', '-File', $workerScript
    ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
}

function Initialize-CodexDesktopInterop {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if ($null -ne ('CodexWeChatDesktopNative' -as [type])) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CodexWeChatDesktopNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
'@
}

function Find-CodexDesktopComposerInWindow {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [string]$ExpectedThreadName,
        [string]$RejectedThreadName
    )
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
    if (-not $root) { return $null }
    $editCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )
    $windowBounds = $root.Current.BoundingRectangle
    $titleVerified = [string]::IsNullOrWhiteSpace($ExpectedThreadName)
    if (-not $titleVerified) {
        $titleCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $ExpectedThreadName
        )
        $titleMatches = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $titleCondition)
        for ($index = 0; $index -lt $titleMatches.Count; $index++) {
            $candidate = $titleMatches.Item($index)
            $bounds = $candidate.Current.BoundingRectangle
            $inHeader = $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and
                $bounds.Left -ge ($windowBounds.Left + 280) -and
                $bounds.Top -ge ($windowBounds.Top + 30) -and
                $bounds.Top -le ($windowBounds.Top + 115)
            if ($inHeader) { $titleVerified = $true; break }
        }
    }
    if (-not $titleVerified) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($RejectedThreadName)) {
        $rejectedCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $RejectedThreadName
        )
        $rejectedMatches = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $rejectedCondition)
        for ($index = 0; $index -lt $rejectedMatches.Count; $index++) {
            $candidate = $rejectedMatches.Item($index)
            $bounds = $candidate.Current.BoundingRectangle
            $inHeader = $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and
                $bounds.Left -ge ($windowBounds.Left + 280) -and
                $bounds.Top -ge ($windowBounds.Top + 30) -and
                $bounds.Top -le ($windowBounds.Top + 115)
            if ($inHeader) { return $null }
        }
    }

    # The empty Desktop task page exposes its editor placeholder as Text
    # instead of the ProseMirror Edit used by existing tasks. Require both
    # new-task page markers before using the placeholder's click target.
    if ([string]::IsNullOrWhiteSpace($ExpectedThreadName)) {
        $markerOne = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            '我们应该在'
        )
        $markerTwo = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            '中做些什么？'
        )
        $placeholderCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            '随心输入'
        )
        $selectProjectCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            '选择项目'
        )
        $hasMarkerOne = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $markerOne).Count -gt 0
        $hasMarkerTwo = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $markerTwo).Count -gt 0
        $projectFree = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $selectProjectCondition).Count -gt 0
        if ($projectFree) {
            $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
            for ($index = 0; $index -lt $edits.Count; $index++) {
                $candidate = $edits.Item($index)
                $bounds = $candidate.Current.BoundingRectangle
                $isVisible = $bounds.Width -ge 120 -and $bounds.Height -ge 24 -and
                    $bounds.Left -ge $windowBounds.Left -and $bounds.Right -le $windowBounds.Right -and
                    $bounds.Top -ge $windowBounds.Top -and $bounds.Bottom -le $windowBounds.Bottom
                $isProseMirror = [regex]::IsMatch(
                    [string]$candidate.Current.ClassName,
                    '(?i)(?:^|\s)ProseMirror(?:\s|$)'
                )
                if (-not $isProseMirror -or -not $isVisible -or
                    -not $candidate.Current.IsEnabled -or -not $candidate.Current.IsKeyboardFocusable) { continue }
                return [pscustomobject]@{
                    element = $candidate
                    bounds = $bounds
                    title_verified = $false
                    new_task_verified = $true
                    click_only = $false
                    targeting_mode = 'uia_project_free_new_task_prosemirror'
                    window_handle = $WindowHandle
                    window_process_id = [int]$root.Current.ProcessId
                }
            }
        }
        if ($hasMarkerOne -and $hasMarkerTwo) {
            $placeholders = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $placeholderCondition)
            for ($index = 0; $index -lt $placeholders.Count; $index++) {
                $candidate = $placeholders.Item($index)
                $bounds = $candidate.Current.BoundingRectangle
                $isVisible = $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and
                    $bounds.Left -ge $windowBounds.Left -and $bounds.Right -le $windowBounds.Right -and
                    $bounds.Top -ge $windowBounds.Top -and $bounds.Bottom -le $windowBounds.Bottom
                if (-not $isVisible) { continue }
                return [pscustomobject]@{
                    element = $candidate
                    bounds = $bounds
                    title_verified = $false
                    new_task_verified = $true
                    click_only = $true
                    targeting_mode = 'uia_new_task_placeholder'
                    window_handle = $WindowHandle
                    window_process_id = [int]$root.Current.ProcessId
                }
            }
        }
        return $null
    }

    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
    $composer = $null
    $composerArea = 0.0
    for ($index = 0; $index -lt $edits.Count; $index++) {
        $candidate = $edits.Item($index)
        $bounds = $candidate.Current.BoundingRectangle
        # Current Codex Desktop appends state tokens such as
        # "ProseMirror-focused" to the UIA class list. Match the stable
        # ProseMirror token instead of requiring exact class equality.
        $isProseMirror = [regex]::IsMatch(
            [string]$candidate.Current.ClassName,
            '(?i)(?:^|\s)ProseMirror(?:\s|$)'
        )
        $isVisible = $bounds.Width -ge 120 -and $bounds.Height -ge 24 -and
            $bounds.Left -ge $windowBounds.Left -and $bounds.Right -le $windowBounds.Right -and
            $bounds.Top -ge $windowBounds.Top -and $bounds.Bottom -le $windowBounds.Bottom
        if (-not $isProseMirror -or -not $isVisible -or -not $candidate.Current.IsEnabled -or
            -not $candidate.Current.IsKeyboardFocusable) { continue }
        $area = $bounds.Width * $bounds.Height
        if ($area -gt $composerArea) { $composer = $candidate; $composerArea = $area }
    }
    if (-not $composer) { return $null }
    return [pscustomobject]@{
        element = $composer
        bounds = $composer.Current.BoundingRectangle
        title_verified = $titleVerified
        window_handle = $WindowHandle
        window_process_id = [int]$root.Current.ProcessId
        click_only = $false
        new_task_verified = $false
        targeting_mode = 'uia_existing_task_prosemirror'
    }
}

function Get-CodexDesktopComposer {
    param(
        [string]$ExpectedThreadName,
        [string]$RejectedThreadName,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    do {
        $processIds = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        if ($processIds.Count -gt 0) {
            $desktop = [System.Windows.Automation.AutomationElement]::RootElement
            $windows = $desktop.FindAll(
                [System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.Condition]::TrueCondition
            )
            for ($index = 0; $index -lt $windows.Count; $index++) {
                $window = $windows.Item($index)
                if ([int]$window.Current.ProcessId -notin $processIds) { continue }
                $bounds = $window.Current.BoundingRectangle
                if ($bounds.Width -lt 600 -or $bounds.Height -lt 400) { continue }
                $handle = [IntPtr]([long]$window.Current.NativeWindowHandle)
                if ($handle -eq [IntPtr]::Zero) { continue }
                $match = Find-CodexDesktopComposerInWindow -WindowHandle $handle `
                    -ExpectedThreadName $ExpectedThreadName -RejectedThreadName $RejectedThreadName
                if ($match) { return $match }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::Now -lt $deadline)

    if (-not [string]::IsNullOrWhiteSpace($ExpectedThreadName)) {
        throw "Codex did not expose a verified composer for task '$ExpectedThreadName' in any desktop window within $TimeoutSeconds seconds. Nothing was submitted."
    }
    throw 'Codex did not expose a usable ProseMirror composer. Nothing was submitted.'
}

function Set-CodexDesktopNewTaskProjectFree {
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [int]$TimeoutSeconds = 15
    )
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    do {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
        if ($root) {
            $selectProjectCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                '选择项目'
            )
            if ($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $selectProjectCondition).Count -gt 0) {
                return $true
            }
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                '不在项目中工作'
            )
            $matches = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
            for ($index = 0; $index -lt $matches.Count; $index++) {
                $button = $matches.Item($index)
                if (-not $button.Current.IsEnabled) { continue }
                $pattern = $null
                if (-not $button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                    continue
                }
                ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
                Start-Sleep -Milliseconds 800
                return $true
            }

        }
        Start-Sleep -Milliseconds 400
    } while ([DateTimeOffset]::Now -lt $deadline)
    throw 'Codex 新建页无法切换到“不在项目中工作”；本次未提交。'
}

function Get-CodexRolloutPath {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadId)
    $parsedThreadId = [guid]::Empty
    if (-not [guid]::TryParse($ThreadId, [ref]$parsedThreadId)) {
        throw "Invalid Codex task id: $ThreadId"
    }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $sessionsRoot = Join-Path $codexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) {
        throw "Codex sessions directory was not found: $sessionsRoot"
    }
    $rollout = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter "*-$ThreadId.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $rollout) { throw "Codex rollout was not found for task $ThreadId." }
    return $rollout.FullName
}

function Get-CodexVisibleConversationTranscript {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [int]$MaxChars = 30000
    )
    $rolloutPath = Get-CodexRolloutPath -ThreadId $SessionId
    $messages = [Collections.Generic.List[object]]::new()
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($rolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $event = $null
            try { $event = $line | ConvertFrom-Json -Depth 30 } catch { continue }
            if ([string]$event.type -ne 'response_item' -or -not $event.payload -or
                [string]$event.payload.type -ne 'message') { continue }
            $role = [string]$event.payload.role
            $phase = if (Test-BridgeProperty -Object $event.payload -Name 'phase') { [string]$event.payload.phase } else { '' }
            if ($role -eq 'assistant' -and $phase -eq 'commentary') { continue }
            if ($role -notin @('user', 'assistant')) { continue }
            $parts = @($event.payload.content | ForEach-Object {
                if ((Test-BridgeProperty -Object $_ -Name 'text') -and -not [string]::IsNullOrWhiteSpace([string]$_.text)) {
                    [string]$_.text
                }
            })
            $content = ($parts -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            if ($role -eq 'user') {
                $trimmed = $content.TrimStart()
                if ($trimmed -match '^(?s)<(?:environment_context|permissions instructions|app-context|skills_instructions|collaboration_mode|apps_instructions|plugins_instructions)>' -or
                    $trimmed -match '^(?s)<recommended_plugins>.*# AGENTS\.md instructions') { continue }
            }
            $messages.Add([pscustomobject]@{ role = $role; text = $content })
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    $selected = [Collections.Generic.List[object]]::new()
    $used = 0
    $truncated = $false
    for ($index = $messages.Count - 1; $index -ge 0; $index--) {
        $entry = $messages[$index]
        $label = if ([string]$entry.role -eq 'user') { '用户' } else { 'Codex' }
        $block = "$label：$([string]$entry.text)"
        if (($used + $block.Length + 2) -gt $MaxChars) {
            $truncated = $true
            break
        }
        $selected.Insert(0, $block)
        $used += $block.Length + 2
    }
    if ($selected.Count -eq 0) { throw '被引用任务中没有可复制的可见问答。' }
    $transcript = $selected -join "`n`n"
    if ($truncated) { $transcript = "（较早的可见问答因长度限制已省略）`n`n$transcript" }
    return [pscustomobject]@{
        text = $transcript
        message_count = $selected.Count
        truncated = $truncated
        rollout_path = $rolloutPath
    }
}

function New-CodexVisibleForkPrompt {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceThreadName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Transcript,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt
    )
    return @"
这是从 Codex 任务《$SourceThreadName》复制到新任务的可见上下文。它用于背景参考，只包含用户可见的消息和 Codex 最终回复，不包含隐藏推理、工具进程状态或工作区未提交内容。

<copied_visible_conversation>
$Transcript
</copied_visible_conversation>

现在请在这个新任务中执行：
$Prompt
"@.Trim()
}

function Get-CodexRolloutLatestBoundary {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $startedNeedle = '"type":"event_msg","payload":{"type":"task_started"'
    $completedNeedle = '"type":"event_msg","payload":{"type":"task_complete"'
    $abortedNeedle = '"type":"event_msg","payload":{"type":"turn_aborted"'
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $position = $stream.Length
        $chunkSize = 262144
        $overlap = 512
        while ($position -gt 0) {
            $readStart = [Math]::Max(0L, $position - $chunkSize)
            $contextStart = [Math]::Max(0L, $readStart - $overlap)
            $count = [int]($position - $contextStart)
            $buffer = [byte[]]::new($count)
            [void]$stream.Seek($contextStart, [IO.SeekOrigin]::Begin)
            $read = $stream.Read($buffer, 0, $count)
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $startedIndex = $text.LastIndexOf($startedNeedle, [StringComparison]::Ordinal)
            $completedIndex = $text.LastIndexOf($completedNeedle, [StringComparison]::Ordinal)
            $abortedIndex = $text.LastIndexOf($abortedNeedle, [StringComparison]::Ordinal)
            if ($startedIndex -ge 0 -or $completedIndex -ge 0 -or $abortedIndex -ge 0) {
                $latestIndex = [Math]::Max($startedIndex, [Math]::Max($completedIndex, $abortedIndex))
                $type = if ($latestIndex -eq $startedIndex) { 'task_started' } elseif ($latestIndex -eq $completedIndex) { 'task_complete' } else { 'turn_aborted' }
                return [pscustomobject]@{ type = $type; file_length = $stream.Length }
            }
            $position = $readStart
        }
        return $null
    } finally {
        $stream.Dispose()
    }
}

function Get-CodexSessionIdFromRolloutPath {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $match = [regex]::Match($name, '(?i)([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-CodexRolloutMetadata {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
        try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    try { $meta = $line | ConvertFrom-Json } catch { return $null }
    if ([string]$meta.type -ne 'session_meta' -or -not $meta.payload) { return $null }
    $payload = $meta.payload
    $threadSource = if ((Test-BridgeProperty -Object $payload -Name 'thread_source') -and
        $payload.thread_source -is [string]) { [string]$payload.thread_source } else { '' }
    $sessionId = if (Test-BridgeProperty -Object $payload -Name 'session_id') {
        [string]$payload.session_id
    } elseif (Test-BridgeProperty -Object $payload -Name 'id') {
        [string]$payload.id
    } else { '' }
    return [pscustomobject]@{
        session_id = $sessionId
        cwd = if (Test-BridgeProperty -Object $payload -Name 'cwd') { [string]$payload.cwd } else { '' }
        source = if (Test-BridgeProperty -Object $payload -Name 'source') { [string]$payload.source } else { '' }
        thread_source = $threadSource
        user_visible = $threadSource -eq 'user'
        forked_from_id = if (Test-BridgeProperty -Object $payload -Name 'forked_from_id') {
            [string]$payload.forked_from_id
        } else { '' }
    }
}

function Get-CodexRolloutLifecycleTurnIdSet {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadId)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rolloutPath = Get-CodexRolloutPath -ThreadId $ThreadId
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($rolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line -notmatch '"type":"event_msg"' -or
                    $line -notmatch '"type":"(?:task_started|task_complete|turn_aborted)"') { continue }
                try { $event = $line | ConvertFrom-Json } catch { continue }
                if (-not $event.payload -or [string]::IsNullOrWhiteSpace([string]$event.payload.turn_id)) { continue }
                [void]$ids.Add([string]$event.payload.turn_id)
            }
        } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return ,$ids
}

function Get-CodexCatalogThread {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId)
    $catalog = Read-BridgeJson -Path (Join-Path (Initialize-BridgeState) 'thread-catalog.json') -Default $null
    if (-not $catalog -or -not (Test-BridgeProperty -Object $catalog -Name 'threads')) { return $null }
    $matches = @($catalog.threads | Where-Object { [string]$_.session_id -eq $SessionId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function ConvertFrom-CodexRolloutLifecycleLine {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Line,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [string]$Cwd
    )
    if ($Line -notmatch '"type":"event_msg","payload":\{"type":"(?:task_started|task_complete|turn_aborted)"') { return $null }
    try { $event = $Line | ConvertFrom-Json } catch { return $null }
    if ([string]$event.type -ne 'event_msg' -or -not $event.payload) { return $null }
    $eventType = [string]$event.payload.type
    if ($eventType -notin @('task_started', 'task_complete', 'turn_aborted')) { return $null }
    $catalogThread = Get-CodexCatalogThread -SessionId $SessionId
    $cwd = if ($catalogThread -and -not [string]::IsNullOrWhiteSpace([string]$catalogThread.cwd)) {
        [string]$catalogThread.cwd
    } else { $Cwd }
    $name = Get-CodexThreadDisplayName -SessionId $SessionId -Cwd $cwd
    return [pscustomobject]@{
        event_type = $eventType
        hook_event = [pscustomobject]@{
            session_id = $SessionId
            turn_id = [string]$event.payload.turn_id
            cwd = $cwd
            model = $null
            thread_name = $name
            last_assistant_message = if ($eventType -eq 'task_complete') { [string]$event.payload.last_agent_message } else { '' }
            abort_reason = if ($eventType -eq 'turn_aborted' -and (Test-BridgeProperty -Object $event.payload -Name 'reason')) {
                [string]$event.payload.reason
            } else { '' }
            event_at = [string]$event.timestamp
        }
    }
}

function Initialize-CodexRolloutMonitorState {
    param([Parameter(Mandatory)][string]$StatePath)
    try { Refresh-CodexThreadCatalog -Force | Out-Null } catch { }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $sessionsRoot = Join-Path $codexHome 'sessions'
    $files = @{}
    $rollouts = if (Test-Path -LiteralPath $sessionsRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)
    } else { @() }
    foreach ($file in $rollouts) {
        $sessionId = Get-CodexSessionIdFromRolloutPath -Path $file.FullName
        if (-not $sessionId) { continue }
        $metadata = Get-CodexRolloutMetadata -Path $file.FullName
        $userVisible = $metadata -and [bool]$metadata.user_visible
        $files[$file.FullName] = [ordered]@{
            session_id = $sessionId
            cwd = if ($metadata) { [string]$metadata.cwd } else { '' }
            user_visible = $userVisible
            forked_from_id = if ($metadata) { [string]$metadata.forked_from_id } else { '' }
            fork_replay_from_zero = $false
            fork_baseline_warning_logged = $false
            offset = [long]$file.Length
            carry = ''
        }
        if (-not $userVisible) {
            $internalRecordPath = Get-CodexThreadRecordPath -SessionId $sessionId
            if (Test-Path -LiteralPath $internalRecordPath) { Remove-Item -LiteralPath $internalRecordPath -Force }
        }
    }

    foreach ($file in @($rollouts | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 100)) {
        $sessionId = Get-CodexSessionIdFromRolloutPath -Path $file.FullName
        if (-not $sessionId) { continue }
        $tracked = $files[$file.FullName]
        if (-not [bool]$tracked.user_visible) { continue }
        $latest = Get-CodexRolloutLatestBoundary -Path $file.FullName
        if (-not $latest) { continue }
        $catalogThread = Get-CodexCatalogThread -SessionId $sessionId
        $cwd = if ($catalogThread -and -not [string]::IsNullOrWhiteSpace([string]$catalogThread.cwd)) {
            [string]$catalogThread.cwd
        } else { [string]$tracked.cwd }
        $name = Get-CodexThreadDisplayName -SessionId $sessionId -Cwd $cwd
        $hookEvent = [pscustomobject]@{
            session_id = $sessionId
            turn_id = ''
            cwd = $cwd
            model = $null
            thread_name = $name
            event_at = [DateTimeOffset]$file.LastWriteTimeUtc
        }
        $state = switch ([string]$latest.type) {
            'task_started' { 'running' }
            'turn_aborted' { 'paused' }
            default { 'completed' }
        }
        Update-CodexThreadRegistry -HookEvent $hookEvent -State $state | Out-Null
    }

    $state = [ordered]@{
        schema_version = 1
        initialized_at = [DateTimeOffset]::Now.ToString('o')
        files = $files
    }
    Write-BridgeJsonAtomic -Path $StatePath -Value $state
    return (Read-BridgeJson -Path $StatePath -Default $state -AsHashtable)
}

function Sync-CodexRolloutMonitorNotificationReset {
    param([Parameter(Mandatory)][Collections.IDictionary]$State)
    $reset = Get-BridgeNotificationResetState
    if (-not $reset -or -not (Test-BridgeProperty -Object $reset -Name 'reset_id') -or
        [string]::IsNullOrWhiteSpace([string]$reset.reset_id)) { return $false }
    if ($State.Contains('notification_reset_id') -and
        [string]$State.notification_reset_id -eq [string]$reset.reset_id) { return $false }

    foreach ($entry in @($State.files.GetEnumerator())) {
        $path = [string]$entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $tracked = $entry.Value
        $tracked.offset = [long](Get-Item -LiteralPath $path).Length
        $tracked.carry = ''
        if ($tracked.Contains('fork_replay_from_zero')) { $tracked.fork_replay_from_zero = $false }
    }
    $State.notification_reset_id = [string]$reset.reset_id
    $State.notification_reset_at = [string]$reset.cutoff_at
    $State.initialized_at = [string]$reset.cutoff_at
    Write-BridgeLog -Level INFO -Message "Completion monitor advanced all tracked rollout cursors for notification reset $([string]$reset.reset_id)."
    return $true
}

function Invoke-CodexRolloutMonitorScan {
    param([Parameter(Mandatory)][string]$StatePath)
    $state = Read-BridgeJson -Path $StatePath -Default $null -AsHashtable
    if (-not $state -or -not $state.ContainsKey('files')) {
        $state = Initialize-CodexRolloutMonitorState -StatePath $StatePath
    }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $sessionsRoot = Join-Path $codexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return }
    $config = Get-BridgeConfig
    $maxEventAgeSeconds = [Math]::Max(30, [int]$config.completion_event_max_age_seconds)
    $notificationLimit = [Math]::Max(1, [int]$config.completion_scan_notification_limit)
    $monitorEpoch = [DateTimeOffset]::Now
    if ($state.ContainsKey('initialized_at') -and $state.initialized_at) {
        $parsedEpoch = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$state.initialized_at, [ref]$parsedEpoch)) {
            $monitorEpoch = $parsedEpoch
        }
    }
    $notificationsPublished = 0
    $staleCompletionsSkipped = 0
    $burstCompletionsSkipped = 0
    $inheritedForkEventsSkipped = 0
    $missingForkBaselineEventsSkipped = 0
    $forkSourceTurnIds = @{}
    $changed = $false
    if (Sync-CodexRolloutMonitorNotificationReset -State $state) { $changed = $true }
    foreach ($file in (Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
        $sessionId = Get-CodexSessionIdFromRolloutPath -Path $file.FullName
        if (-not $sessionId) { continue }
        if (-not $state.files.ContainsKey($file.FullName)) {
            $metadata = Get-CodexRolloutMetadata -Path $file.FullName
            # A newly created App Server task can start and terminate between two
            # monitor scans. When an inbound relay still owns that task, replay
            # this one new file from byte zero; the fork turn-id guard below
            # removes copied history and retains only the new terminal event.
            $pendingRelay = Test-CodexRelayPendingForThread -SessionId $sessionId
            $state.files[$file.FullName] = @{
                session_id = $sessionId
                cwd = if ($metadata) { [string]$metadata.cwd } else { '' }
                user_visible = $metadata -and [bool]$metadata.user_visible
                forked_from_id = if ($metadata) { [string]$metadata.forked_from_id } else { '' }
                fork_replay_from_zero = $pendingRelay -and $metadata -and
                    -not [string]::IsNullOrWhiteSpace([string]$metadata.forked_from_id)
                fork_baseline_warning_logged = $false
                offset = if ($pendingRelay) { 0L } else { [long]$file.Length }
                carry = ''
            }
            $changed = $true
            if (-not $pendingRelay) { continue }
        }
        $entry = $state.files[$file.FullName]
        if (-not $entry.ContainsKey('user_visible')) {
            $metadata = Get-CodexRolloutMetadata -Path $file.FullName
            $entry.user_visible = $metadata -and [bool]$metadata.user_visible
            $entry.cwd = if ($metadata) { [string]$metadata.cwd } else { '' }
            $entry.forked_from_id = if ($metadata) { [string]$metadata.forked_from_id } else { '' }
            $changed = $true
        }
        if (-not $entry.ContainsKey('forked_from_id')) {
            $metadata = Get-CodexRolloutMetadata -Path $file.FullName
            $entry.forked_from_id = if ($metadata) { [string]$metadata.forked_from_id } else { '' }
            $changed = $true
        }
        if (-not $entry.ContainsKey('fork_replay_from_zero')) {
            $entry.fork_replay_from_zero = $false
            $changed = $true
        }
        if (-not $entry.ContainsKey('fork_baseline_warning_logged')) {
            $entry.fork_baseline_warning_logged = $false
            $changed = $true
        }
        if (-not [bool]$entry.user_visible) {
            $metadata = Get-CodexRolloutMetadata -Path $file.FullName
            if ($metadata -and [bool]$metadata.user_visible) {
                $entry.user_visible = $true
                $entry.cwd = [string]$metadata.cwd
                $entry.forked_from_id = [string]$metadata.forked_from_id
                if (Test-CodexRelayPendingForThread -SessionId $sessionId) {
                    $entry.offset = 0L
                    $entry.carry = ''
                    $entry.fork_replay_from_zero = -not [string]::IsNullOrWhiteSpace([string]$entry.forked_from_id)
                }
                $changed = $true
            }
        }
        if (-not [bool]$entry.user_visible) {
            if ([long]$entry.offset -ne [long]$file.Length -or [string]$entry.carry) {
                $entry.offset = [long]$file.Length
                $entry.carry = ''
                $changed = $true
            }
            continue
        }
        $offset = [long]$entry.offset
        if ([long]$file.Length -lt $offset) {
            $entry.offset = [long]$file.Length
            $entry.carry = ''
            $changed = $true
            continue
        }
        if ([long]$file.Length -le $offset) { continue }

        $pendingRelay = Test-CodexRelayPendingForThread -SessionId $sessionId
        if ([bool]$entry.fork_replay_from_zero -and -not $pendingRelay) {
            # The relay can fail (or finish through the direct App Server path)
            # before the monitor learns the bridge-owned turn id. In that case
            # there is no safe lifecycle event to select from the copied fork
            # history. Seal the current file at EOF and resume ordinary
            # incremental monitoring from the next append.
            $entry.offset = [long]$file.Length
            $entry.carry = ''
            $entry.fork_replay_from_zero = $false
            $changed = $true
            continue
        }
        $pendingTurnId = if ([bool]$entry.fork_replay_from_zero) {
            Get-CodexRelayPendingTurnId -SessionId $sessionId
        } else { '' }
        if ([bool]$entry.fork_replay_from_zero -and $pendingRelay -and
            [string]::IsNullOrWhiteSpace($pendingTurnId)) {
            # thread/start can make the fork rollout visible just before
            # turn/start returns its id. Keep the zero-replay cursor in place
            # until the exact bridge-owned turn is known; consuming the file
            # here would safely suppress history but could also lose the new
            # completion event on a very fast turn.
            continue
        }
        $sawExpectedReplayTurn = $false

        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $remaining = [long]$stream.Length - $offset
            $buffer = [byte[]]::new([int]$remaining)
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { continue }
            $text = [string]$entry.carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $entry.offset = $offset + $read
            $parts = [regex]::Split($text, "\r?\n")
            $hasTrailingNewline = $text.EndsWith("`n", [StringComparison]::Ordinal)
            $lineCount = [Math]::Max(0, $parts.Count - 1)
            $entry.carry = if ($hasTrailingNewline) { '' } else { [string]$parts[$parts.Count - 1] }
            for ($index = 0; $index -lt $lineCount; $index++) {
                $lifecycle = ConvertFrom-CodexRolloutLifecycleLine -Line ([string]$parts[$index]) `
                    -SessionId $sessionId -Cwd ([string]$entry.cwd)
                if (-not $lifecycle) { continue }
                $forkedFromId = [string]$entry.forked_from_id
                if (-not [string]::IsNullOrWhiteSpace($forkedFromId)) {
                    if (-not $forkSourceTurnIds.ContainsKey($forkedFromId)) {
                        try {
                            $forkSourceTurnIds[$forkedFromId] = Get-CodexRolloutLifecycleTurnIdSet -ThreadId $forkedFromId
                        } catch {
                            $forkSourceTurnIds[$forkedFromId] = $null
                            if (-not [bool]$entry.fork_baseline_warning_logged) {
                                Write-BridgeLog -Level WARN -Message "Could not load source-turn baseline for fork $sessionId from $forkedFromId; the saved rollout cursor and zero-replay guard remain active."
                                $entry.fork_baseline_warning_logged = $true
                                $changed = $true
                            }
                        }
                    }
                    $sourceIds = $forkSourceTurnIds[$forkedFromId]
                    if ($sourceIds -and $sourceIds.Contains([string]$lifecycle.hook_event.turn_id)) {
                        $inheritedForkEventsSkipped++
                        continue
                    }
                    if (-not $sourceIds -and [bool]$entry.fork_replay_from_zero) {
                        $lifecycleTurnId = [string]$lifecycle.hook_event.turn_id
                        if ([string]::IsNullOrWhiteSpace($pendingTurnId) -or
                            -not $lifecycleTurnId.Equals($pendingTurnId, [StringComparison]::OrdinalIgnoreCase)) {
                            $missingForkBaselineEventsSkipped++
                            continue
                        }
                        $sawExpectedReplayTurn = $true
                    }
                }
                if ([string]$lifecycle.event_type -eq 'task_started') {
                    Update-CodexThreadRegistry -HookEvent $lifecycle.hook_event -State running | Out-Null
                } else {
                    $terminalState = if ([string]$lifecycle.event_type -eq 'task_complete') {
                        'completed'
                    } elseif ([string]$lifecycle.hook_event.abort_reason -eq 'interrupted') {
                        'paused'
                    } else {
                        'failed'
                    }
                    $terminalSummary = if ($terminalState -eq 'completed') {
                        [string]$lifecycle.hook_event.last_assistant_message
                    } elseif ($terminalState -eq 'paused') {
                        '本轮已中断，可引用本通知继续。'
                    } else {
                        $reason = [string]$lifecycle.hook_event.abort_reason
                        if ($reason) { "本轮异常结束：$reason" } else { '本轮未正常完成。' }
                    }
                    $eventAtText = [string]$lifecycle.hook_event.event_at
                    $eventAt = ConvertTo-BridgeEventTime -Timestamp $eventAtText
                    $eventTimeValid = $null -ne $eventAt
                    Complete-CodexRelayRecordsForThread -SessionId $sessionId -TerminalState $terminalState `
                        -TurnId ([string]$lifecycle.hook_event.turn_id) `
                        -CompletedAt $(if ($eventTimeValid) { $eventAt.ToString('o') } else { '' }) | Out-Null
                    try { Start-BridgeRelayWorkerProcess } catch {
                        Write-BridgeLog -Level WARN -Message "Deferred relay restart failed after task terminal event: $($_.Exception.Message)"
                    }
                    $freshAfterEpoch = $eventTimeValid -and $eventAt -ge $monitorEpoch.AddSeconds(-5)
                    $freshByAge = $eventTimeValid -and
                        $eventAt -ge [DateTimeOffset]::Now.AddSeconds(-$maxEventAgeSeconds) -and
                        $eventAt -le [DateTimeOffset]::Now.AddMinutes(5)
                    if (-not ($freshAfterEpoch -and $freshByAge)) {
                        Update-CodexThreadRegistry -HookEvent $lifecycle.hook_event -State $terminalState `
                            -Summary $terminalSummary | Out-Null
                        $staleCompletionsSkipped++
                        continue
                    }
                    if ($notificationsPublished -ge $notificationLimit) {
                        Update-CodexThreadRegistry -HookEvent $lifecycle.hook_event -State $terminalState `
                            -Summary $terminalSummary | Out-Null
                        $burstCompletionsSkipped++
                        continue
                    }
                    if ($terminalState -eq 'completed') {
                        Publish-CodexTurnNotification -HookEvent $lifecycle.hook_event | Out-Null
                    } else {
                        Publish-CodexStateNotification -HookEvent $lifecycle.hook_event -State $terminalState `
                            -Reason $terminalSummary | Out-Null
                    }
                    $notificationsPublished++
                }
            }
            if ([bool]$entry.fork_replay_from_zero -and $sawExpectedReplayTurn -and
                [string]::IsNullOrEmpty([string]$entry.carry)) {
                $entry.fork_replay_from_zero = $false
                $changed = $true
            }
            $changed = $true
        } finally {
            $stream.Dispose()
        }
    }
    if ($staleCompletionsSkipped -gt 0) {
        Write-BridgeLog -Level WARN -Message "Replay guard skipped $staleCompletionsSkipped stale completion event(s)."
    }
    if ($burstCompletionsSkipped -gt 0) {
        Write-BridgeLog -Level WARN -Message "Burst guard skipped $burstCompletionsSkipped completion event(s) beyond the per-scan limit."
    }
    if ($inheritedForkEventsSkipped -gt 0) {
        Write-BridgeLog -Level INFO -Message "Fork guard skipped $inheritedForkEventsSkipped inherited lifecycle event(s)."
    }
    if ($missingForkBaselineEventsSkipped -gt 0) {
        Write-BridgeLog -Level INFO -Message "Fork zero-replay guard skipped $missingForkBaselineEventsSkipped lifecycle event(s) while the source baseline was unavailable."
    }
    if ($changed) { Write-BridgeJsonAtomic -Path $StatePath -Value $state }
}

function Start-CodexCompletionMonitor {
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, 'Local\CodexWeChatCompletionMonitor', [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return [pscustomobject]@{ started = $false; reason = 'already_running' }
    }
    $root = Initialize-BridgeState
    $stopPath = Join-Path $root 'stop.request'
    $statePath = Join-Path $root 'rollout-monitor.json'
    $statusPath = Join-Path $root 'completion-status.json'
    try {
        Write-BridgeJsonAtomic -Path $statusPath -Value @{
            state = 'running'
            pid = $PID
            updated_at = [DateTimeOffset]::Now.ToString('o')
        }
        if (-not (Test-Path -LiteralPath $statePath)) {
            Initialize-CodexRolloutMonitorState -StatePath $statePath | Out-Null
        }
        $lastCatalogRefresh = [DateTimeOffset]::MinValue
        while (-not (Test-Path -LiteralPath $stopPath)) {
            try {
                $config = Get-BridgeConfig
                if (([DateTimeOffset]::Now - $lastCatalogRefresh).TotalSeconds -ge [int]$config.thread_catalog_refresh_seconds) {
                    Refresh-CodexThreadCatalog -Force | Out-Null
                    $lastCatalogRefresh = [DateTimeOffset]::Now
                }
                Invoke-CodexRolloutMonitorScan -StatePath $statePath
                Write-BridgeJsonAtomic -Path $statusPath -Value @{
                    state = 'running'
                    pid = $PID
                    updated_at = [DateTimeOffset]::Now.ToString('o')
                }
            } catch {
                Write-BridgeLog -Level WARN -Message "Completion monitor retry: $($_.Exception.Message)"
            }
            $interval = [Math]::Max(500, [int](Get-BridgeConfig).completion_scan_interval_ms)
            Start-Sleep -Milliseconds $interval
        }
    } finally {
        Write-BridgeJsonAtomic -Path $statusPath -Value @{
            state = 'stopped'
            pid = $PID
            updated_at = [DateTimeOffset]::Now.ToString('o')
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Start-BridgeCompletionMonitorProcess {
    $config = Get-BridgeConfig
    if (-not [bool]$config.completion_monitor_enabled) { return }
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $workerScript = Join-Path $PSScriptRoot 'Start-CodexCompletionMonitor.ps1'
    if (-not (Test-Path -LiteralPath $workerScript -PathType Leaf)) {
        throw "Completion monitor script is missing: $workerScript"
    }
    $root = Initialize-BridgeState
    $workerId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmssfff'), ([guid]::NewGuid().ToString('N'))
    $stdoutPath = Join-Path (Join-Path $root 'logs') "completion-monitor-$workerId.out.log"
    $stderrPath = Join-Path (Join-Path $root 'logs') "completion-monitor-$workerId.err.log"
    Start-Process -FilePath $pwsh -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $workerScript
    ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
}

function Wait-CodexThreadIdle {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RolloutPath,
        [int]$TimeoutSeconds = 1200
    )
    $latest = Get-CodexRolloutLatestBoundary -Path $RolloutPath
    if (-not $latest -or [string]$latest.type -ne 'task_started') { return }

    $completeNeedle = '"type":"event_msg","payload":{"type":"task_complete"'
    $offset = [long](Get-Item -LiteralPath $RolloutPath).Length
    $carry = ''
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($RolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        do {
            $length = $stream.Length
            while ($offset -lt $length) {
                $count = [int][Math]::Min(1048576L, $length - $offset)
                $buffer = [byte[]]::new($count)
                [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $read = $stream.Read($buffer, 0, $count)
                if ($read -le 0) { break }
                $offset += $read
                $text = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                if ($text.Contains($completeNeedle, [StringComparison]::Ordinal)) { return }
                $carry = if ($text.Length -gt 256) { $text.Substring($text.Length - 256) } else { $text }
            }
            Start-Sleep -Milliseconds 700
        } while ([DateTimeOffset]::Now -lt $deadline)
    } finally {
        $stream.Dispose()
    }
    throw "Target Codex task is still running after $TimeoutSeconds seconds."
}

function Test-CodexThreadIdle {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RolloutPath)
    $latest = Get-CodexRolloutLatestBoundary -Path $RolloutPath
    return -not $latest -or [string]$latest.type -ne 'task_started'
}

function Submit-CodexDesktopPromptToUri {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [string]$ThreadId,
        [string]$ExpectedThreadName,
        [string]$RejectedThreadName,
        [switch]$NoProject,
        [int]$NavigationDelayMs = 2200
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw 'Codex desktop relay requires an STA PowerShell process.'
    }
    Initialize-CodexDesktopInterop

    Start-Process $Uri
    Start-Sleep -Milliseconds $NavigationDelayMs
    $composer = Get-CodexDesktopComposer -ExpectedThreadName $ExpectedThreadName `
        -RejectedThreadName $RejectedThreadName -TimeoutSeconds 30
    $windowHandle = [IntPtr]$composer.window_handle
    $windowProcessId = [int]$composer.window_process_id
    $projectFreeVerified = $false
    if ($NoProject) {
        Set-CodexDesktopNewTaskProjectFree -WindowHandle $windowHandle | Out-Null
        $projectFreeVerified = $true
        $composer = $null
        $composerDeadline = [DateTimeOffset]::Now.AddSeconds(15)
        do {
            $composer = Find-CodexDesktopComposerInWindow -WindowHandle $windowHandle `
                -ExpectedThreadName $ExpectedThreadName -RejectedThreadName $RejectedThreadName
            if ($composer) { break }
            Start-Sleep -Milliseconds 400
        } while ([DateTimeOffset]::Now -lt $composerDeadline)
        if (-not $composer) { throw 'Codex project-free new-task composer could not be verified. Nothing was submitted.' }
    }
    [void][CodexWeChatDesktopNative]::ShowWindow($windowHandle, 9)
    try { [void]([System.Activator]::CreateInstance([type]::GetTypeFromProgID('WScript.Shell')).AppActivate($windowProcessId)) } catch { }
    [void][CodexWeChatDesktopNative]::SetForegroundWindow($windowHandle)
    Start-Sleep -Milliseconds 500
    if ([CodexWeChatDesktopNative]::GetForegroundWindow() -ne $windowHandle) {
        throw 'Could not activate the Codex desktop window. Keep the Windows session unlocked and retry.'
    }

    $composer = Find-CodexDesktopComposerInWindow -WindowHandle $windowHandle `
        -ExpectedThreadName $ExpectedThreadName -RejectedThreadName $RejectedThreadName
    if (-not $composer) {
        throw "Codex task '$ExpectedThreadName' changed before submission. Nothing was submitted."
    }
    $inputX = [int][Math]::Round($composer.bounds.Left + ($composer.bounds.Width / 2))
    $inputY = [int][Math]::Round($composer.bounds.Top + ($composer.bounds.Height / 2))
    $originalClipboard = $null
    try {
        if ([bool]$composer.click_only) {
            [void][CodexWeChatDesktopNative]::SetCursorPos($inputX, $inputY)
            [CodexWeChatDesktopNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
            [CodexWeChatDesktopNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        } else {
            $composer.element.SetFocus()
        }
        Start-Sleep -Milliseconds 160
        try { $originalClipboard = [System.Windows.Forms.Clipboard]::GetDataObject() } catch { }
        $clipboardSet = $false
        for ($attempt = 0; $attempt -lt 8 -and -not $clipboardSet; $attempt++) {
            try {
                [System.Windows.Forms.Clipboard]::SetText($Prompt)
                $clipboardSet = $true
            } catch {
                Start-Sleep -Milliseconds 120
            }
        }
        if (-not $clipboardSet) { throw 'Could not acquire the Windows clipboard for Codex input.' }
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Start-Sleep -Milliseconds 350
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 500
    } finally {
        if ($originalClipboard) {
            try { [System.Windows.Forms.Clipboard]::SetDataObject($originalClipboard, $true) } catch { }
        }
    }
    return [pscustomobject]@{
        submitted = $true
        thread_id = $ThreadId
        window_pid = $windowProcessId
        input_x = $inputX
        input_y = $inputY
        targeting_mode = if (Test-BridgeProperty -Object $composer -Name 'targeting_mode') {
            [string]$composer.targeting_mode
        } else { 'uia_all_windows_prosemirror' }
        title_verified = [bool]$composer.title_verified
        new_task_verified = [bool]$composer.new_task_verified
        project_free_verified = $projectFreeVerified
    }
}

function Submit-CodexDesktopPrompt {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [string]$ExpectedThreadName,
        [int]$NavigationDelayMs = 2200
    )
    $parsedThreadId = [guid]::Empty
    if (-not [guid]::TryParse($ThreadId, [ref]$parsedThreadId)) {
        throw "Invalid Codex task id: $ThreadId"
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedThreadName)) {
        $ExpectedThreadName = Get-CodexThreadDisplayName -SessionId $ThreadId
    }
    return Submit-CodexDesktopPromptToUri -Uri "codex://threads/$ThreadId" -Prompt $Prompt `
        -ThreadId $ThreadId -ExpectedThreadName $ExpectedThreadName -NavigationDelayMs $NavigationDelayMs
}

function Submit-CodexDesktopNewPrompt {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Cwd,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [string]$SourceThreadName,
        [switch]$NoProject,
        [int]$NavigationDelayMs = 2200
    )
    $resolvedCwd = [IO.Path]::GetFullPath($Cwd)
    if (-not (Test-Path -LiteralPath $resolvedCwd -PathType Container)) { throw "任务目录不存在：$resolvedCwd" }
    # Always include a known path because current Desktop builds do not
    # reliably refresh UI Automation for a bare codex://threads/new URI.
    # NoProject is enforced after navigation through the explicit UI control.
    $uri = "codex://threads/new?path=$([Uri]::EscapeDataString($resolvedCwd))"
    return Submit-CodexDesktopPromptToUri -Uri $uri -Prompt $Prompt `
        -RejectedThreadName $SourceThreadName -NoProject:$NoProject -NavigationDelayMs $NavigationDelayMs
}

function Get-CodexRolloutSnapshot {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $sessionsRoot = Join-Path $codexHome 'sessions'
    $paths = @{}
    if (Test-Path -LiteralPath $sessionsRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)) {
            $paths[$file.FullName] = [long]$file.Length
        }
    }
    return $paths
}

function Wait-CodexNewDesktopThreadRollout {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Cwd,
        [int]$TimeoutSeconds = 45
    )
    $expectedCwd = if ([string]::IsNullOrWhiteSpace($Cwd)) {
        ''
    } else {
        [IO.Path]::GetFullPath($Cwd).TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $sessionsRoot = Join-Path $codexHome 'sessions'
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    do {
        foreach ($file in @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 40)) {
            if ($Before.ContainsKey($file.FullName)) { continue }
            $metadata = Get-CodexRolloutMetadata -Path $file.FullName
            if (-not $metadata -or -not [bool]$metadata.user_visible) { continue }
            $candidateCwd = try { [IO.Path]::GetFullPath([string]$metadata.cwd).TrimEnd([IO.Path]::DirectorySeparatorChar) } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($expectedCwd) -and
                -not $candidateCwd.Equals($expectedCwd, [StringComparison]::OrdinalIgnoreCase)) { continue }
            return [pscustomobject]@{
                path = $file.FullName
                session_id = Get-CodexSessionIdFromRolloutPath -Path $file.FullName
                cwd = $candidateCwd
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::Now -lt $deadline)
    throw 'Codex 桌面端未创建新的用户任务；请确认窗口已解锁并可操作。'
}

function Get-CodexRolloutCompletionHookEvent {
    param(
        [Parameter(Mandatory)][string]$RolloutPath,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$ThreadName
    )
    $lines = @(Get-Content -LiteralPath $RolloutPath -Tail 400 -ErrorAction Stop)
    [array]::Reverse($lines)
    foreach ($line in $lines) {
        if ($line -notmatch '"type":"event_msg","payload":\{"type":"task_complete"') { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        return [pscustomobject]@{
            session_id = $SessionId
            turn_id = [string]$event.payload.turn_id
            cwd = $Cwd
            model = $null
            thread_name = $ThreadName
            last_assistant_message = [string]$event.payload.last_agent_message
            event_at = [string]$event.timestamp
        }
    }
    throw '未能从新任务记录中读取完成结果。'
}

function Wait-CodexDesktopTurnCompletion {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RolloutPath,
        [Parameter(Mandatory)][long]$StartOffset,
        [int]$SubmitTimeoutSeconds = 30,
        [int]$CompletionTimeoutSeconds = 1200
    )
    $startedNeedle = '"type":"event_msg","payload":{"type":"task_started"'
    $completedNeedle = '"type":"event_msg","payload":{"type":"task_complete"'
    $submitDeadline = [DateTimeOffset]::Now.AddSeconds($SubmitTimeoutSeconds)
    $completionDeadline = $null
    $startedAt = $null
    $offset = $StartOffset
    $carry = ''
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($RolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        while ($true) {
            $length = $stream.Length
            while ($offset -lt $length) {
                $count = [int][Math]::Min(1048576L, $length - $offset)
                $buffer = [byte[]]::new($count)
                [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $read = $stream.Read($buffer, 0, $count)
                if ($read -le 0) { break }
                $offset += $read
                $text = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                $events = [regex]::Matches($text, '"type":"event_msg","payload":\{"type":"task_(started|complete)"')
                foreach ($event in $events) {
                    $eventType = [string]$event.Groups[1].Value
                    if (-not $startedAt -and $eventType -eq 'started') {
                        $startedAt = [DateTimeOffset]::Now
                        $completionDeadline = [DateTimeOffset]::Now.AddSeconds($CompletionTimeoutSeconds)
                    } elseif ($startedAt -and $eventType -eq 'complete') {
                        return [pscustomobject]@{ started_at = $startedAt; completed_at = [DateTimeOffset]::Now }
                    }
                }
                $carry = if ($text.Length -gt 256) { $text.Substring($text.Length - 256) } else { $text }
            }
            if (-not $startedAt -and [DateTimeOffset]::Now -ge $submitDeadline) {
                throw 'Codex did not start the submitted desktop task. The input box may not have been available.'
            }
            if ($startedAt -and [DateTimeOffset]::Now -ge $completionDeadline) {
                throw "Codex desktop task did not complete within $CompletionTimeoutSeconds seconds. It may be waiting for your input or approval."
            }
            Start-Sleep -Milliseconds 600
        }
    } finally {
        $stream.Dispose()
    }
}

function Wait-CodexDesktopTurnStarted {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RolloutPath,
        [Parameter(Mandatory)][long]$StartOffset,
        [int]$SubmitTimeoutSeconds = 30
    )
    $startedNeedle = '"type":"event_msg","payload":{"type":"task_started"'
    $deadline = [DateTimeOffset]::Now.AddSeconds($SubmitTimeoutSeconds)
    $offset = $StartOffset
    $carry = ''
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($RolloutPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        do {
            $length = $stream.Length
            while ($offset -lt $length) {
                $count = [int][Math]::Min(1048576L, $length - $offset)
                $buffer = [byte[]]::new($count)
                [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $read = $stream.Read($buffer, 0, $count)
                if ($read -le 0) { break }
                $offset += $read
                $text = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                if ($text.Contains($startedNeedle, [StringComparison]::Ordinal)) {
                    return [DateTimeOffset]::Now
                }
                $carry = if ($text.Length -gt 256) { $text.Substring($text.Length - 256) } else { $text }
            }
            Start-Sleep -Milliseconds 400
        } while ([DateTimeOffset]::Now -lt $deadline)
    } finally {
        $stream.Dispose()
    }
    throw 'Codex did not start the submitted desktop task. The input box may not have been available.'
}

function Invoke-CodexRelayQueueItem {
    param([Parameter(Mandatory)][string]$Path)
    $record = Read-BridgeJson -Path $Path -Default $null
    if (-not $record) { return }
    if ([string]$record.relay_state -ne 'relay_queued') { return }

    $config = Get-BridgeConfig
    $commandType = if ((Test-BridgeProperty -Object $record -Name 'command_type') -and $record.command_type) {
        [string]$record.command_type
    } else { 'continue' }
    $targetName = if ((Test-BridgeProperty -Object $record -Name 'target_thread_name') -and $record.target_thread_name) {
        [string]$record.target_thread_name
    } else {
        Get-CodexThreadDisplayName -SessionId ([string]$record.target_session_id) -Cwd ([string]$record.target_cwd)
    }
    if ($commandType -in @('new', 'fork', 'worktree') -and
        (Test-BridgeProperty -Object $record -Name 'new_thread_name') -and $record.new_thread_name) {
        $targetName = [string]$record.new_thread_name
    }
    $rolloutPath = $null
    try {
        if ($commandType -eq 'continue') {
            $rolloutPath = Get-CodexRolloutPath -ThreadId ([string]$record.target_session_id)
            if (-not (Test-CodexThreadIdle -RolloutPath $rolloutPath)) {
                Update-InboundRecord -Path $Path -Changes @{
                    relay_wait_reason = 'target_busy'
                    relay_last_deferred_at = [DateTimeOffset]::Now.ToString('o')
                } | Out-Null
                return [pscustomobject]@{ deferred = $true; reason = 'target_busy' }
            }
        }
        Update-InboundRecord -Path $Path -Changes @{
            relay_state = 'relay_running'
            relay_started_at = [DateTimeOffset]::Now.ToString('o')
            relay_wait_reason = ''
        } | Out-Null

        if ($commandType -in @('new', 'fork', 'worktree')) {
            $taskCwd = [string]$record.target_cwd
            $worktree = $null
            if ($commandType -eq 'worktree') {
                $worktree = New-BridgeManagedWorktree -SourceCwd $taskCwd -Name $targetName
                $taskCwd = [string]$worktree.path
                Update-InboundRecord -Path $Path -Changes @{
                    managed_worktree_path = $taskCwd
                    managed_worktree_repository = [string]$worktree.repository
                } | Out-Null
            }

            # A new task has no active Desktop writer yet, so the official App
            # Server create/fork methods are safe here. The process exits after
            # completion and never attaches to an existing Desktop-owned task.
            $appServerParams = @{
                Cwd = $taskCwd
                Prompt = [string]$record.relay_prompt
                ThreadName = $targetName
                TimeoutSeconds = [int]$config.relay_timeout_seconds
                RelayRecordPath = $Path
                RelayCommandType = $commandType
            }
            if ($commandType -eq 'new') {
                $appServerParams.NewPersistent = $true
            } else {
                $appServerParams.ForkThreadId = [string]$record.source_session_id
            }
            $result = Invoke-CodexAppServerTurn @appServerParams
            $newThreadId = [string]$result.thread_id
            if ($commandType -eq 'worktree') {
                Set-BridgeManagedWorktreeThread -WorktreePath $taskCwd -ThreadId $newThreadId
            }
            $completedAt = [DateTimeOffset]::Now
            $hookEvent = [pscustomobject]@{
                session_id = $newThreadId
                turn_id = [string]$result.turn_id
                cwd = $taskCwd
                model = $null
                thread_name = $targetName
                last_assistant_message = [string]$result.final_text
                event_at = $completedAt.ToString('o')
            }
            Publish-CodexTurnNotification -HookEvent $hookEvent | Out-Null
            Update-InboundRecord -Path $Path -Changes @{
                relay_state = 'relay_completed'
                relay_completed_at = $completedAt.ToString('o')
                relay_transport = 'app_server_new_task'
                created_thread_source = [string]$result.source
                created_thread_user_source = [string]$result.thread_source
            } | Out-Null
            Write-BridgeLog -Level INFO -Message "WeChat $commandType command completed in verified Desktop task $newThreadId."
            return [pscustomobject]@{ submitted = $true; completed = $true; session_id = $newThreadId }
        }

        # Existing desktop tasks already have a writer owned by the Codex app.
        # Never attach an independent App Server to them: doing so can make the
        # desktop report "already has an active writer" and temporarily block
        # opening the task. Submit through the desktop's own composer so it
        # remains the single writer for this thread.
        $startOffset = [long](Get-Item -LiteralPath $rolloutPath).Length
        $submitResult = Submit-CodexDesktopPrompt -ThreadId ([string]$record.target_session_id) `
            -Prompt ([string]$record.relay_prompt) `
            -ExpectedThreadName $targetName `
            -NavigationDelayMs ([int]$config.desktop_navigation_delay_ms)
        $startedAt = Wait-CodexDesktopTurnStarted -RolloutPath $rolloutPath -StartOffset $startOffset `
            -SubmitTimeoutSeconds ([int]$config.desktop_submit_timeout_seconds)
        Update-InboundRecord -Path $Path -Changes @{
            relay_state = 'relay_submitted'
            relay_submitted_at = [DateTimeOffset]::Now.ToString('o')
            codex_started_at = $startedAt.ToString('o')
            desktop_window_pid = [int]$submitResult.window_pid
            relay_transport = 'desktop_single_writer'
            desktop_targeting_mode = [string]$submitResult.targeting_mode
            desktop_title_verified = [bool]$submitResult.title_verified
        } | Out-Null
        try {
            $startedDelivery = Send-BridgeText -Text ("【$targetName】`n开始处理") `
                -AllowContextlessRetry -TimeoutSeconds 15
            Update-InboundRecord -Path $Path -Changes @{
                start_ack_sent_at = [DateTimeOffset]::Now.ToString('o')
                start_ack_message_id = [string]$startedDelivery.message_id
            } | Out-Null
        } catch {
            Write-BridgeLog -Level WARN -Message "Desktop start acknowledgement deferred without interrupting Codex: $($_.Exception.Message)"
        }
        Write-BridgeLog -Level INFO -Message "WeChat desktop single-writer relay submitted to task $($record.target_session_id); completion monitor owns terminal state."
        return [pscustomobject]@{ submitted = $true; completed = $false; session_id = [string]$record.target_session_id }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage.Length -gt 800) { $errorMessage = $errorMessage.Substring(0, 800) + '…' }
        $userError = switch -Regex ($errorMessage) {
            '(?i)SSL connection|TLS|name resolution|network' { '微信或网络连接失败，请稍后重试。'; break }
            '(?i)already has an active writer' { '目标任务正在其他位置执行，本次没有提交内容。'; break }
            '(?i)composer|input box|ProseMirror' { 'Codex 桌面输入框当前不可用，本次没有提交内容。'; break }
            '(?i)Cannot bind argument.*Cwd|working directory|sessions directory|rollout was not found' { 'Codex 任务的工作目录或会话记录不可用，本次没有提交内容。'; break }
            'Codex 未把新任务登记为桌面可见任务' { $errorMessage; break }
            default { '任务未能成功提交，详细原因已记录在本地诊断日志中。' }
        }
        $latestRecord = Read-BridgeJson -Path $Path -Default $record
        $terminalThreadId = if ((Test-BridgeProperty -Object $latestRecord -Name 'target_session_id') -and $latestRecord.target_session_id) {
            [string]$latestRecord.target_session_id
        } elseif ((Test-BridgeProperty -Object $latestRecord -Name 'created_thread_id') -and $latestRecord.created_thread_id) {
            [string]$latestRecord.created_thread_id
        } else { '' }
        $terminalTurnId = if ((Test-BridgeProperty -Object $latestRecord -Name 'codex_turn_id') -and $latestRecord.codex_turn_id) {
            [string]$latestRecord.codex_turn_id
        } else { '' }
        $creationTurnStarted = $commandType -in @('new', 'fork', 'worktree') -and
            -not [string]::IsNullOrWhiteSpace($terminalThreadId) -and
            -not [string]::IsNullOrWhiteSpace($terminalTurnId)
        $alreadyRecovered = (Test-BridgeProperty -Object $latestRecord -Name 'relay_state') -and
            [string]$latestRecord.relay_state -eq 'relay_completed'
        $terminalState = if ($creationTurnStarted -and $errorMessage -match '(?i)closed its output stream|timed out|interrupted|Turn ended with status') {
            'paused'
        } else { 'failed' }
        if (-not $alreadyRecovered) {
            Update-InboundRecord -Path $Path -Changes @{
                relay_state = 'relay_failed'
                relay_completed_at = [DateTimeOffset]::Now.ToString('o')
                relay_error = $errorMessage
                codex_terminal_state = $terminalState
            } | Out-Null
        }
        if ($alreadyRecovered) {
            Write-BridgeLog -Level INFO -Message "Completion monitor already recovered terminal state for $terminalThreadId; worker error was not re-published."
        } elseif ($creationTurnStarted) {
            $stateReason = if ($terminalState -eq 'paused') {
                '本轮执行器意外退出，任务已中断；可以引用本通知，在这个新分支中继续。'
            } else {
                '新任务未正常完成；可以引用本通知，在已经创建的新任务中重试。'
            }
            $hookEvent = [pscustomobject]@{
                session_id = $terminalThreadId
                turn_id = $terminalTurnId
                cwd = if ((Test-BridgeProperty -Object $latestRecord -Name 'target_cwd') -and $latestRecord.target_cwd) {
                    [string]$latestRecord.target_cwd
                } else { '' }
                model = $null
                thread_name = $targetName
                event_at = [DateTimeOffset]::Now.ToString('o')
            }
            Publish-CodexStateNotification -HookEvent $hookEvent -State $terminalState -Reason $stateReason | Out-Null
        } else {
            try {
                $failedName = if ($targetName) { $targetName } else { 'Codex 对话' }
                $recovery = if ($commandType -eq 'continue') {
                    '本次内容未提交。请保持 Windows 已解锁、Codex 窗口可操作，再重新引用原任务通知；桥接不会启动第二个 App Server 抢占该任务。'
                } else {
                    '新任务未成功创建；请重新引用原任务的桥接通知后重试。'
                }
                Send-BridgeText -Text ("【执行失败】$failedName`n$userError`n`n$recovery") `
                    -AllowContextlessRetry -TimeoutSeconds 15 | Out-Null
            } catch { }
        }
        Write-BridgeLog -Level WARN -Message "WeChat relay failed: $errorMessage"
    }
}

function Start-CodexWeChatRelayWorker {
    $root = Initialize-BridgeState
    $next = Get-ChildItem -LiteralPath (Join-Path $root 'inbox') -Filter '*.json' -File |
        Sort-Object Name |
        Where-Object {
            $candidate = Read-BridgeJson -Path $_.FullName -Default $null
            $candidate -and [string]$candidate.relay_state -eq 'relay_queued'
        } |
        Select-Object -First 1
    if (-not $next) { return [pscustomobject]@{ started = $true; drained = $true; deferred = 0 } }

    $record = Read-BridgeJson -Path $next.FullName -Default $null
    $key = if ($record -and -not [string]::IsNullOrWhiteSpace([string]$record.target_session_id)) {
        [string]$record.target_session_id
    } else { [string]$next.BaseName }
    $keyBytes = [Text.Encoding]::UTF8.GetBytes($key)
    $keyHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($keyBytes)).Substring(0, 24)
    $createdNew = $false
    $mutex = [Threading.Mutex]::new($true, "Local\CodexWeChatRelayTarget-$keyHash", [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return [pscustomobject]@{ started = $false; reason = 'target_worker_running' }
    }
    try {
        $result = Invoke-CodexRelayQueueItem -Path $next.FullName
        return [pscustomobject]@{
            started = $true
            drained = -not ($result -and (Test-BridgeProperty -Object $result -Name 'deferred') -and [bool]$result.deferred)
            deferred = $(if ($result -and (Test-BridgeProperty -Object $result -Name 'deferred') -and [bool]$result.deferred) { 1 } else { 0 })
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
        try { Start-BridgeRelayWorkerProcess } catch { }
    }
}

function ConvertTo-BridgeTaskName {
    param([Parameter(Mandatory)][string]$Name)
    $clean = [regex]::Replace($Name, '[\x00-\x1f\x7f|]+', ' ')
    $clean = [regex]::Replace($clean, '\s+', ' ').Trim()
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60).Trim() }
    return $clean
}

function New-BridgeGeneratedTaskName {
    param(
        [Parameter(Mandatory)][ValidateSet('new', 'fork', 'worktree')][string]$CommandType,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Prompt,
        [string]$SourceThreadName
    )
    $name = switch ($CommandType) {
        'fork' {
            $source = if ([string]::IsNullOrWhiteSpace($SourceThreadName)) { '任务' } else { $SourceThreadName }
            "$source-分支-$(Get-Date -Format 'HHmm')"
        }
        'worktree' {
            $source = if ([string]::IsNullOrWhiteSpace($SourceThreadName)) { '任务' } else { $SourceThreadName }
            "$source-worktree-$(Get-Date -Format 'HHmm')"
        }
        default { $Prompt }
    }
    $name = ConvertTo-BridgeTaskName -Name $name
    if ($CommandType -eq 'new' -and $name.Length -gt 28) { $name = $name.Substring(0, 28).Trim() }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "微信任务-$(Get-Date -Format 'MMdd-HHmm')" }
    return $name
}

function Parse-BridgeExecutionCommand {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $trimmed = $Text.Trim()
    $match = [regex]::Match($trimmed, '^/(?<command>新建|new|分支|fork|工作树|worktree)(?:\s+(?<body>[\s\S]+))?$', 'IgnoreCase')
    if (-not $match.Success) {
        return [pscustomobject]@{ valid = $true; command_type = 'continue'; prompt = $trimmed; name = $null; error = $null }
    }
    $rawCommand = $match.Groups['command'].Value.ToLowerInvariant()
    $command = switch ($rawCommand) {
        '新建' { 'new' }
        '分支' { 'fork' }
        '工作树' { 'worktree' }
        default { $rawCommand }
    }
    $displayCommand = switch ($command) {
        'new' { '/新建' }
        'fork' { '/分支' }
        default { '/工作树' }
    }
    $body = $match.Groups['body'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($body) -and $command -eq 'new') {
        return [pscustomobject]@{
            valid = $false
            command_type = $command
            prompt = $null
            name = $null
            error = "格式错误：$displayCommand 后面需要填写任务内容"
        }
    }
    $name = $null
    $prompt = if (-not [string]::IsNullOrWhiteSpace($body)) {
        $body
    } elseif ($command -eq 'fork') {
        '请确认已复制引用任务的可见上下文，并等待我的下一步指令。'
    } else {
        '请检查这个新工作树的仓库状态，并等待我的下一步指令。'
    }
    # Keep the old explicit-name form working for existing users, while the
    # simple form treats the whole body as the task and derives a title later.
    $separator = $body.IndexOf('|')
    if ($separator -ge 1 -and $separator -lt ($body.Length - 1)) {
        $name = ConvertTo-BridgeTaskName -Name $body.Substring(0, $separator)
        $prompt = $body.Substring($separator + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($prompt)) {
            return [pscustomobject]@{
                valid = $false
                command_type = $command
                prompt = $null
                name = $null
                error = "格式错误：$displayCommand 后面需要填写任务内容"
            }
        }
    }
    return [pscustomobject]@{ valid = $true; command_type = $command; prompt = $prompt; name = $name; error = $null }
}

function Invoke-BridgeNativeProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 60
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start $FileName." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "$FileName timed out after $TimeoutSeconds seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw "$FileName exited with code $($process.ExitCode): $stderr"
        }
        return [pscustomobject]@{ exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    } finally {
        $process.Dispose()
    }
}

function Get-BridgeGitRepositoryRoot {
    param([Parameter(Mandatory)][string]$Cwd)
    if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw "任务目录不存在：$Cwd" }
    $git = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { $git = (Get-Command git -ErrorAction Stop | Select-Object -First 1).Source }
    $result = Invoke-BridgeNativeProcess -FileName $git -ArgumentList @('-C', $Cwd, 'rev-parse', '--show-toplevel') `
        -WorkingDirectory $Cwd -TimeoutSeconds 20
    $repo = [IO.Path]::GetFullPath($result.stdout.Trim())
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        throw "当前任务目录不在 Git 仓库中：$Cwd"
    }
    return $repo
}

function New-BridgeManagedWorktree {
    param(
        [Parameter(Mandatory)][string]$SourceCwd,
        [Parameter(Mandatory)][string]$Name
    )
    $repoRoot = Get-BridgeGitRepositoryRoot -Cwd $SourceCwd
    $config = Get-BridgeConfig
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $managedRoot = if (-not [string]::IsNullOrWhiteSpace([string]$config.managed_worktree_root)) {
        [IO.Path]::GetFullPath([string]$config.managed_worktree_root)
    } else {
        [IO.Path]::GetFullPath((Join-Path $codexHome 'worktrees\wechat-bridge'))
    }
    [IO.Directory]::CreateDirectory($managedRoot) | Out-Null
    $slug = [regex]::Replace($Name.ToLowerInvariant(), '[^\p{L}\p{Nd}._-]+', '-')
    $slug = $slug.Trim('-', '.', '_')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'task' }
    if ($slug.Length -gt 36) { $slug = $slug.Substring(0, 36).Trim('-', '.', '_') }
    $target = [IO.Path]::GetFullPath((Join-Path $managedRoot ("$slug-$([guid]::NewGuid().ToString('N').Substring(0, 8))")))
    $rootPrefix = $managedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝创建超出桥接托管目录的 worktree。'
    }
    $git = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { $git = (Get-Command git -ErrorAction Stop | Select-Object -First 1).Source }
    Invoke-BridgeNativeProcess -FileName $git -ArgumentList @('-C', $repoRoot, 'worktree', 'add', '--detach', $target, 'HEAD') `
        -WorkingDirectory $repoRoot -TimeoutSeconds 120 | Out-Null
    $path = Join-Path (Initialize-BridgeState) 'managed-worktrees.json'
    $state = Read-BridgeJson -Path $path -Default ([pscustomobject]@{ worktrees = @() })
    $entries = @($state.worktrees) + [pscustomobject]@{
        path = $target
        repository = $repoRoot
        name = $Name
        thread_id = $null
        created_at = [DateTimeOffset]::Now.ToString('o')
    }
    Write-BridgeJsonAtomic -Path $path -Value @{ worktrees = @($entries | Select-Object -Last 200) }
    return [pscustomobject]@{ path = $target; repository = $repoRoot; record_path = $path }
}

function Set-BridgeManagedWorktreeThread {
    param([Parameter(Mandatory)][string]$WorktreePath, [Parameter(Mandatory)][string]$ThreadId)
    $path = Join-Path (Initialize-BridgeState) 'managed-worktrees.json'
    $state = Read-BridgeJson -Path $path -Default ([pscustomobject]@{ worktrees = @() })
    foreach ($entry in @($state.worktrees)) {
        if ([string]$entry.path -eq $WorktreePath) {
            if (Test-BridgeProperty -Object $entry -Name 'thread_id') { $entry.thread_id = $ThreadId }
            else { $entry | Add-Member -NotePropertyName thread_id -NotePropertyValue $ThreadId }
        }
    }
    Write-BridgeJsonAtomic -Path $path -Value $state
}

function Enable-CodexWeChatRelay {
    $config = Get-BridgeConfig
    $config.inbound_mode = 'codex_relay'
    $config.relay_enabled_at = [DateTimeOffset]::Now.ToString('o')
    Save-BridgeConfig -Config $config
    Initialize-CodexThreadRegistryFromActive
    Save-BridgeStatus -State 'monitor_running' -Detail 'Long-poll monitor and controlled Codex relay are active'
    Start-BridgeRelayWorkerProcess
    return Get-CodexWeChatBridgeStatus
}

function Disable-CodexWeChatRelay {
    $config = Get-BridgeConfig
    $config.inbound_mode = 'queue_only'
    Save-BridgeConfig -Config $config
    return Get-CodexWeChatBridgeStatus
}

function Get-BridgeRelayHelpText {
    return @'
Codex 微信双向命令：
引用状态通知          引用桥接通知，再输入内容以继续原任务
/新建 <任务>          新建无项目桌面对话；无需引用
/分支 [任务]          复制被引用对话，在同一目录继续
/附件                 引用任务通知，查看附件发送状态
/附件 重试            立即重试该任务未发送的附件
/附件 <序号>          发送该任务识别到的指定附件
/附件 全部            把超过自动上限的附件也加入队列
/状态                 查看任务状态和阶段性进展
/状态 最近            查看最近任务
/状态 完整            查看最近任务及结果摘要
/桥接状态             查看微信桥接器状态
/诊断                 诊断后台服务、Codex 与队列
/清空                 归档全部未发送内容，并从当前时刻重新开始
/刷新                 刷新微信上下文并补发通知
/在线                 检查桥接是否在线
/帮助                 显示本帮助

英文旧命令仍兼容：/new、/fork、/tasks、/status、/doctor、/clear、/refresh、/ping、/help。

安全规则：普通微信消息不会执行；继续、/分支和/附件必须引用桥接状态通知，/新建和/清空无需引用。/清空不停止 Codex 任务，也不删除本地文件。仅扫码绑定的微信用户可用。
'@.Trim()
}

function Get-BridgeAttachmentStatusText {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [string]$TurnId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ThreadName
    )
    $catalogMatch = @(Get-BridgeAttachmentCatalog -SessionId $SessionId -TurnId $TurnId)
    $records = @(Get-BridgeAttachmentQueueRecords -SessionId $SessionId -TurnId $TurnId -State all)
    $queued = @($records | Where-Object { $_.folder -eq 'attachment-outbox' }).Count
    $sent = @($records | Where-Object { $_.folder -eq 'attachment-sent' }).Count
    $failed = @($records | Where-Object { $_.folder -eq 'attachment-failed' }).Count
    if ($catalogMatch.Count -eq 0 -and $records.Count -eq 0) {
        return "【附件】$ThreadName`n没有找到本轮可发送的附件记录。只会识别最终回复中明确列出的文件。"
    }
    $catalog = if ($catalogMatch.Count -gt 0) { $catalogMatch[0].record } else { $null }
    $recognized = if ($catalog) { [int]$catalog.recognized } else { $records.Count }
    $excluded = if ($catalog) { @($catalog.filtered).Count + @($catalog.oversized).Count } else { 0 }
    $overLimit = if ($catalog) { @($catalog.over_limit).Count } else { 0 }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("【附件】$ThreadName")
    $lines.Add("识别 $recognized 个；已发送 $sent 个；等待/重试 $queued 个；失败 $failed 个；已排除 $excluded 个；超出自动上限 $overLimit 个。")
    $index = 0
    if ($catalog) {
        foreach ($item in @($catalog.eligible) + @($catalog.over_limit)) {
            if (-not (Test-BridgeAttachmentExtensionAllowed -Path ([string]$item.path))) { continue }
            $index++
            $lines.Add("$index. $([string]$item.name)")
        }
    }
    if ($overLimit -gt 0) { $lines.Add('引用本通知发送 /附件 全部，可把超限附件加入队列。') }
    if ($queued -gt 0 -or $failed -gt 0) { $lines.Add('引用本通知发送 /附件 重试，可立即重试未发送附件。') }
    return $lines -join "`n"
}

function Invoke-BridgeAttachmentCommand {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CommandText,
        [Parameter(Mandatory)]$Route
    )
    $catalogMatch = @(Get-BridgeAttachmentCatalog -SessionId ([string]$Route.session_id) -TurnId ([string]$Route.turn_id))
    $catalog = if ($catalogMatch.Count -gt 0) { $catalogMatch[0].record } else { $null }
    $argument = ([regex]::Replace($CommandText.Trim(), '^/(?:附件|attachments?)\s*', '', 'IgnoreCase')).Trim()
    if ([string]::IsNullOrWhiteSpace($argument)) {
        return Get-BridgeAttachmentStatusText -SessionId ([string]$Route.session_id) `
            -TurnId ([string]$Route.turn_id) -ThreadName ([string]$Route.thread_name)
    }
    if ($argument -in @('重试', 'retry')) {
        foreach ($entry in @(Get-BridgeAttachmentQueueRecords -SessionId ([string]$Route.session_id) `
            -TurnId ([string]$Route.turn_id) -State queued)) {
            $entry.record.next_attempt_at = [DateTimeOffset]::Now.ToString('o')
            $entry.record.updated_at = $entry.record.next_attempt_at
            Write-BridgeJsonAtomic -Path $entry.file.FullName -Value $entry.record
        }
        foreach ($entry in @(Get-BridgeAttachmentQueueRecords -SessionId ([string]$Route.session_id) `
            -TurnId ([string]$Route.turn_id) -State failed)) {
            if (-not (Test-BridgeAttachmentExtensionAllowed -Path ([string]$entry.record.path))) { continue }
            $entry.record.state = 'queued'
            $entry.record.next_attempt_at = [DateTimeOffset]::Now.ToString('o')
            $entry.record.updated_at = $entry.record.next_attempt_at
            $destination = Join-Path (Join-Path (Initialize-BridgeState) 'attachment-outbox') $entry.file.Name
            Write-BridgeJsonAtomic -Path $destination -Value $entry.record
            Remove-Item -LiteralPath $entry.file.FullName -Force -ErrorAction SilentlyContinue
        }
        $flush = Flush-BridgeAttachmentOutbox
        return "【附件】$([string]$Route.thread_name)`n已启动重试：本轮尝试 $($flush.attempted) 个，发送成功 $($flush.sent) 个，继续等待 $($flush.deferred) 个，永久失败 $($flush.failed) 个。"
    }
    if (-not $catalog) { return "【附件】$([string]$Route.thread_name)`n没有找到可重新加入队列的附件清单。" }
    $available = @(@($catalog.eligible) + @($catalog.over_limit) | Where-Object {
        Test-BridgeAttachmentExtensionAllowed -Path ([string]$_.path)
    })
    $selected = if ($argument -in @('全部', 'all')) {
        @($catalog.over_limit | Where-Object { Test-BridgeAttachmentExtensionAllowed -Path ([string]$_.path) })
    } elseif ($argument -match '^\d+$') {
        $index = [int]$argument - 1
        if ($index -ge 0 -and $index -lt $available.Count) { @($available[$index]) } else { @() }
    } else { @() }
    if ($argument -in @('全部', 'all') -and $selected.Count -gt 0) {
        $config = Get-BridgeConfig
        $maxBytes = [long]$config.completion_attachment_max_bytes
        $selected = @($selected | Where-Object {
            [long]$_.bytes -le $maxBytes -and (Test-Path -LiteralPath ([string]$_.path) -PathType Leaf)
        } | Select-Object -First 40)
    }
    if ($selected.Count -eq 0) {
        return "【附件】$([string]$Route.thread_name)`n没有匹配的附件。请先发送 /附件 查看序号。"
    }
    $result = Add-BridgeAttachmentQueueRecords -SessionId ([string]$Route.session_id) `
        -TurnId ([string]$Route.turn_id) -ThreadName ([string]$Route.thread_name) -Cwd ([string]$Route.cwd) `
        -Attachments $selected -Source 'wechat_attachment_command'
    Flush-BridgeAttachmentOutbox | Out-Null
    return "【附件】$([string]$Route.thread_name)`n已加入队列 $($result.queued) 个，已存在或已发送 $($result.duplicates) 个。"
}

function Complete-BridgeMaintenanceCommand {
    param(
        [Parameter(Mandatory)]$SavedMessage,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Command,
        [string]$ReplyText,
        [string]$ReplyMessageId
    )
    Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
        relay_state = 'maintenance_completed'
        command_type = $Command
        bridge_version = $script:BridgeVersion
        reply_text = $ReplyText
        reply_message_id = $ReplyMessageId
        relay_completed_at = [DateTimeOffset]::Now.ToString('o')
    } | Out-Null
}

function Invoke-BridgeInboundCommand {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$SavedMessage
    )
    $config = Get-BridgeConfig
    $trimmed = $Text.Trim()
    $prefix = [string]$config.relay_command_prefix

    if ($trimmed -in @('/清空', '/clear')) {
        $cleared = Clear-CodexWeChatNotificationBacklog
        $reply = "【已清空】`n已归档未发送通知 $($cleared.text_archived) 条、附件 $($cleared.attachments_archived) 个。`n从现在开始只发送新完成内容。Codex 任务没有停止，本地文件没有删除。"
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 15
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'clear' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }

    if ($trimmed -in @('/刷新', '/refresh', '刷新通知', '恢复通知', '补发通知')) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'notification_refresh_completed'
            relay_completed_at = [DateTimeOffset]::Now.ToString('o')
        } | Out-Null
        Flush-BridgeOutbox
        $script:BridgeOutboxFlushedThisPoll = $true
        return
    }

    if ($trimmed -in @('/在线', '/ping')) {
        $reply = 'Codex 微信桥接在线。'
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 10
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'ping' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }
    if ($trimmed -in @('/桥接状态', '/status')) {
        $status = Get-CodexWeChatBridgeStatus
        $modeText = if ([string]$status.inbound_mode -eq 'codex_relay') { '双向任务已启用' } else { '仅排队，不执行' }
        $deliveryText = if ([string]$status.delivery_state -eq 'waiting_for_wechat') {
            "等待微信上下文；给机器人发任意消息即可补发（积压 $($status.notification_pending_count)）"
        } else {
            "正常（积压 $($status.notification_pending_count)）"
        }
        $executionRule = if ([bool]$status.require_completion_quote) {
            '引用续接和分支已启用；新建无需引用'
        } else { '允许直接执行' }
        $resetText = if ($status.notification_reset_at) { "`n最近清空：$($status.notification_reset_at)" } else { '' }
        $reply = "微信桥接在线。`n版本：$script:BridgeVersion`n模式：$modeText`n执行：$executionRule`n通知：$deliveryText$resetText`n待选择对话：$($status.reply_pending_count)`n待执行：$($status.relay_queued_count)`n执行中：$($status.relay_running_count)"
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 10
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'status' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }
    if ($trimmed -in @('/状态', '/状态 最近', '/状态 完整', '/tasks', '/tasks recent', '/tasks full')) {
        $tasksRecent = $trimmed -in @('/状态 最近', '/状态 完整', '/tasks recent', '/tasks full')
        $tasksFull = $trimmed -in @('/状态 完整', '/tasks full')
        $reply = Get-BridgeTasksText `
            -IncludeCompleted:$tasksRecent `
            -IncludeSummary:$tasksFull
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 10
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage `
            -Command $(if ($tasksFull) { 'tasks_full' } elseif ($tasksRecent) { 'tasks_recent' } else { 'tasks' }) `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }
    if ($trimmed -in @('/诊断', '/doctor')) {
        $reply = Get-BridgeDoctorText
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 15
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'doctor' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }
    if ($trimmed -in @('/帮助', '/help') -or $trimmed -eq $prefix) {
        $reply = Get-BridgeRelayHelpText
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 10
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'help' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }

    if ([string]$config.inbound_mode -ne 'codex_relay') {
        Send-BridgeText -Text 'Codex 双向任务模式尚未启用。' -TimeoutSeconds 10 | Out-Null
        return
    }

    $referenceText = if (Test-BridgeProperty -Object $SavedMessage.record -Name 'reference_text') {
        [string]$SavedMessage.record.reference_text
    } else { '' }
    $referenceMessageIds = @(if (Test-BridgeProperty -Object $SavedMessage.record -Name 'reference_message_ids') {
        @($SavedMessage.record.reference_message_ids)
    } else { @() })
    $referenceCreateTimeMs = @(if (Test-BridgeProperty -Object $SavedMessage.record -Name 'reference_create_time_ms') {
        @($SavedMessage.record.reference_create_time_ms)
    } else { @() })
    $hasCompletionQuote = ($referenceMessageIds.Count -gt 0) -or
        (-not [string]::IsNullOrWhiteSpace($referenceText) -and
            [regex]::IsMatch($referenceText, '【(?:已完成|已暂停|执行失败|已创建)】[^\r\n]+'))

    $looksLikeAttachmentCommand = [regex]::IsMatch($trimmed, '^/(?:附件|attachments?)(?:\s|$)', 'IgnoreCase')
    if ($looksLikeAttachmentCommand) {
        if (-not $hasCompletionQuote) {
            Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
                relay_state = 'not_executed_unquoted_attachment'
                relay_prompt = $trimmed
            } | Out-Null
            Send-BridgeText -Text '未执行：/附件必须引用对应任务的【已完成】通知。' -TimeoutSeconds 10 | Out-Null
            return
        }
        $attachmentRoute = Resolve-BridgeReplyTarget -ReferenceText $referenceText `
            -ReferenceMessageIds $referenceMessageIds -ReferenceCreateTimeMs $referenceCreateTimeMs `
            -InboundMessageId ([string]$SavedMessage.record.id) -InboundCreateTimeMs ([long]$SavedMessage.record.create_time_ms) `
            -RequireQuotedReference
        if (-not $attachmentRoute.resolved) {
            Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
                relay_state = 'not_executed_attachment_target_not_found'
                relay_prompt = $trimmed
            } | Out-Null
            Send-BridgeText -Text '未执行：没有从引用内容中找到对应的附件任务。请直接引用桥接发送的完整【已完成】通知后重试。' `
                -TimeoutSeconds 10 | Out-Null
            return
        }
        $reply = Invoke-BridgeAttachmentCommand -CommandText $trimmed -Route $attachmentRoute
        $delivery = Send-BridgeText -Text $reply -TimeoutSeconds 15
        Complete-BridgeMaintenanceCommand -SavedMessage $SavedMessage -Command 'attachments' `
            -ReplyText $reply -ReplyMessageId ([string]$delivery.message_id)
        return
    }

    $commandStart = $prefix + ' '
    $explicitCommand = $trimmed.StartsWith($commandStart, [StringComparison]::OrdinalIgnoreCase)
    $prompt = if ($explicitCommand) { $trimmed.Substring($commandStart.Length).Trim() } else { $trimmed }
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        Send-BridgeText -Text (Get-BridgeRelayHelpText) -TimeoutSeconds 10 | Out-Null
        return
    }
    $looksLikeNew = [regex]::IsMatch($prompt, '^/(?:新建|new)(?:\s|$)', 'IgnoreCase')
    $looksLikeSourceCommand = [regex]::IsMatch($prompt, '^/(?:分支|fork|工作树|worktree)(?:\s|$)', 'IgnoreCase')
    if ([bool]$config.require_completion_quote -and -not $hasCompletionQuote -and $looksLikeSourceCommand) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'not_executed_unquoted'
            relay_prompt = $trimmed
        } | Out-Null
        Send-BridgeText -Text '未执行：/分支必须引用源任务的桥接通知。请先引用对应的【已完成】或【已暂停】消息，再发送命令。' `
            -TimeoutSeconds 10 | Out-Null
        return
    }
    $execution = Parse-BridgeExecutionCommand -Text $prompt
    if (-not [bool]$execution.valid) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'not_executed_bad_command'
            relay_prompt = $prompt
            relay_error = [string]$execution.error
        } | Out-Null
        Send-BridgeText -Text ("未执行：$($execution.error)`n示例：/新建 整理用户需求并给出实施方案") `
            -TimeoutSeconds 10 | Out-Null
        return
    }
    $unquotedNew = $looksLikeNew -and -not $hasCompletionQuote
    if ([bool]$config.require_completion_quote -and -not $hasCompletionQuote -and -not $unquotedNew) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'not_executed_unquoted'
            relay_prompt = $trimmed
        } | Out-Null
        Send-BridgeText -Text '未执行：请引用对应的桥接状态通知，再发送任务内容。普通消息、继续和/分支必须引用；只有/新建可以不引用。' `
            -TimeoutSeconds 10 | Out-Null
        return
    }

    if (-not $explicitCommand -and -not [bool]$config.direct_reply_enabled -and -not $hasCompletionQuote -and -not $unquotedNew) {
        Send-BridgeText -Text '消息已安全记录，但不会执行。请引用对应的【已完成】通知后再发送。' -TimeoutSeconds 10 | Out-Null
        return
    }

    if ($prompt.Length -gt [int]$config.relay_max_input_chars) {
        Send-BridgeText -Text "任务过长；请控制在 $($config.relay_max_input_chars) 个字符以内。" -TimeoutSeconds 10 | Out-Null
        return
    }
    $route = if ($unquotedNew) {
        $defaultTarget = Get-BridgeDefaultNewThreadTarget
        [pscustomobject]@{
            resolved = $true
            ambiguous = $false
            selection = [string]$defaultTarget.selection
            session_id = [string]$defaultTarget.session_id
            thread_name = [string]$defaultTarget.thread_name
            cwd = [string]$defaultTarget.cwd
        }
    } else {
        Resolve-BridgeReplyTarget -ReferenceText $referenceText -ReferenceMessageIds $referenceMessageIds `
            -ReferenceCreateTimeMs $referenceCreateTimeMs `
            -InboundMessageId ([string]$SavedMessage.record.id) -InboundCreateTimeMs ([long]$SavedMessage.record.create_time_ms) `
            -RequireQuotedReference:([bool]$config.require_completion_quote)
    }
    if ($route.ambiguous) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'awaiting_target_selection'
            relay_prompt = [string]$execution.prompt
            routing_pending_count = [int]$route.pending_count
        } | Out-Null
        $names = @($route.names | Select-Object -Unique | Select-Object -First 6)
        $nameLines = @($names | ForEach-Object { "• $_" }) -join "`n"
        Send-BridgeText -Text ("有 $($route.pending_count) 个对话等待续接。`n请引用要继续的那条【已完成】消息，再输入内容。`n$nameLines") `
            -TimeoutSeconds 10 | Out-Null
        return
    }
    if (-not $route.resolved) {
        Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
            relay_state = 'not_executed_quote_target_not_found'
            relay_prompt = [string]$execution.prompt
            routing_selection = 'quote_target_not_found'
        } | Out-Null
        Send-BridgeText -Text '未执行：没有从引用内容中找到对应的 Codex 对话。请直接引用桥接发送的完整【已完成】通知后重试。' -TimeoutSeconds 10 | Out-Null
        return
    }

    $newThreadName = if (-not [string]::IsNullOrWhiteSpace([string]$execution.name)) {
        [string]$execution.name
    } elseif ([string]$execution.command_type -in @('new', 'fork', 'worktree')) {
        New-BridgeGeneratedTaskName -CommandType ([string]$execution.command_type) `
            -Prompt ([string]$execution.prompt) -SourceThreadName ([string]$route.thread_name)
    } else { '' }

    if ([string]$execution.command_type -eq 'worktree') {
        try { Get-BridgeGitRepositoryRoot -Cwd ([string]$route.cwd) | Out-Null } catch {
            $reason = if ($_.Exception.Message -match '(?i)not a git repository') {
                "被引用任务的目录不是 Git 仓库，不能创建 worktree：$([string]$route.cwd)"
            } else { $_.Exception.Message }
            Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
                relay_state = 'not_executed_worktree_unavailable'
                relay_prompt = [string]$execution.prompt
                relay_error = $reason
                source_session_id = [string]$route.session_id
                target_cwd = [string]$route.cwd
            } | Out-Null
            Send-BridgeText -Text ("未执行：$reason`n/工作树只适用于位于 Git 仓库中的任务；本次没有创建目录或新任务。") `
                -TimeoutSeconds 10 | Out-Null
            return
        }
    }

    $updatedRecord = Update-InboundRecord -Path ([string]$SavedMessage.path) -Changes @{
        relay_state = 'relay_queued'
        relay_prompt = [string]$execution.prompt
        command_type = [string]$execution.command_type
        new_thread_name = $newThreadName
        source_session_id = [string]$route.session_id
        relay_queued_at = [DateTimeOffset]::Now.ToString('o')
        target_session_id = [string]$route.session_id
        target_cwd = [string]$route.cwd
        target_thread_name = [string]$route.thread_name
        routing_selection = [string]$route.selection
    }
    $SavedMessage.record = $updatedRecord
    $targetName = [string]$route.thread_name
    $receiptName = if ($newThreadName) { $newThreadName } else { $targetName }
    $receiptAction = switch ([string]$execution.command_type) {
        'new' { '已接收新建任务命令，等待执行' }
        'fork' { '已接收分支任务命令，等待执行' }
        'worktree' { '已接收工作树任务命令，等待执行' }
        default { '已接收，等待执行' }
    }
    Start-BridgeRelayWorkerProcess
    try {
        Send-BridgeText -Text "【$receiptName】`n$receiptAction" `
            -TimeoutSeconds 10 | Out-Null
    } catch {
        Write-BridgeLog -Level WARN -Message "Queue acknowledgement deferred; relay worker was still started: $($_.Exception.Message)"
    }
}

function Get-QueuedCompletionSummary {
    param([Parameter(Mandatory)]$Message)
    if ((Test-BridgeProperty -Object $Message -Name 'summary') -and
        -not [string]::IsNullOrWhiteSpace([string]$Message.summary)) {
        return [string]$Message.summary
    }
    $summary = if (Test-BridgeProperty -Object $Message -Name 'text') { [string]$Message.text } else { '' }
    $summary = [regex]::Replace($summary, '^\[Codex\]\s+.+?\s+已完成\r?\n', '')
    $summary = [regex]::Replace($summary, '\r?\n\r?\n回复 /codex[\s\S]*$', '')
    return $summary.Trim()
}

function Move-LegacyBridgeAttachmentsToQueue {
    $root = Initialize-BridgeState
    $outboxPath = Join-Path $root 'outbox'
    $migrated = 0
    $duplicates = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $outboxPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $message = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $message -or [string]$message.type -ne 'codex_turn_complete') { continue }
        $attachments = @(if ((Test-BridgeProperty -Object $message -Name 'attachments') -and $null -ne $message.attachments) {
            @($message.attachments)
        } else { @() })
        if ($attachments.Count -eq 0) {
            if ((Test-BridgeProperty -Object $message -Name 'text_sent') -and [bool]$message.text_sent) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        $nextIndex = if (Test-BridgeProperty -Object $message -Name 'next_attachment_index') {
            [Math]::Max(0, [int]$message.next_attachment_index)
        } else { 0 }
        $remaining = @($attachments | Select-Object -Skip $nextIndex)
        if ($remaining.Count -gt 0 -and $message.session_id -and $message.turn_id) {
            $result = Add-BridgeAttachmentQueueRecords -SessionId ([string]$message.session_id) `
                -TurnId ([string]$message.turn_id) -ThreadName ([string]$message.thread_name) `
                -Cwd ([string]$message.cwd) -Attachments $remaining -Source 'v0923_active_outbox_migration'
            $migrated += [int]$result.queued
            $duplicates += [int]$result.duplicates
        }
        $message.attachments = @()
        if (Test-BridgeProperty -Object $message -Name 'next_attachment_index') { $message.next_attachment_index = 0 }
        if (Test-BridgeProperty -Object $message -Name 'format_version') { $message.format_version = 7 }
        else { $message | Add-Member -NotePropertyName format_version -NotePropertyValue 7 }
        Write-BridgeJsonAtomic -Path $file.FullName -Value $message
        if ((Test-BridgeProperty -Object $message -Name 'text_sent') -and [bool]$message.text_sent) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if ($migrated -gt 0 -or $duplicates -gt 0) {
        Write-BridgeLog -Level INFO -Message "Migrated active legacy attachments: queued=$migrated, duplicates=$duplicates. Superseded history was not touched."
    }
    return [pscustomobject]@{ migrated = $migrated; duplicates = $duplicates }
}

function Flush-BridgeAttachmentOutbox {
    return Invoke-WithBridgeNotificationGate -Action { Invoke-BridgeAttachmentOutboxFlushCore }
}

function Invoke-BridgeAttachmentOutboxFlushCore {
    $root = Initialize-BridgeState
    Move-BridgeQueuedRecordsAtOrBeforeReset -Queue 'attachment-outbox' | Out-Null
    Remove-BridgeDisallowedQueuedAttachments | Out-Null
    $config = Get-BridgeConfig
    $budget = [Math]::Max(1, [int]$config.completion_attachment_send_batch_size)
    $now = [DateTimeOffset]::Now
    $due = @(Get-BridgeAttachmentQueueRecords -State queued | Where-Object {
        $nextAt = [DateTimeOffset]::MinValue
        -not (Test-BridgeProperty -Object $_.record -Name 'next_attempt_at') -or
        [string]::IsNullOrWhiteSpace([string]$_.record.next_attempt_at) -or
        -not [DateTimeOffset]::TryParse([string]$_.record.next_attempt_at, [ref]$nextAt) -or
        $nextAt -le $now
    } | Sort-Object { [DateTimeOffset]$_.record.next_attempt_at }, { [DateTimeOffset]$_.record.created_at })
    $attempted = 0
    $sent = 0
    $deferred = 0
    $failed = 0
    foreach ($entry in $due) {
        if ($attempted -ge $budget) { break }
        $attempted++
        $record = $entry.record
        $attempt = if (Test-BridgeProperty -Object $record -Name 'attempts') { [int]$record.attempts + 1 } else { 1 }
        $record.attempts = $attempt
        $record.last_attempt_at = [DateTimeOffset]::Now.ToString('o')
        $record.updated_at = $record.last_attempt_at
        try {
            Send-BridgeFile -Path ([string]$record.path) -AllowContextlessRetry -TimeoutSeconds 90 | Out-Null
            if (Test-BridgeProperty -Object $record -Name 'sent_at') { $record.sent_at = [DateTimeOffset]::Now.ToString('o') }
            else { $record | Add-Member -NotePropertyName sent_at -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) }
            $record.last_error = $null
            Move-BridgeAttachmentQueueRecord -Path $entry.file.FullName -State sent -Record $record | Out-Null
            $sent++
        } catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage.Length -gt 800) { $errorMessage = $errorMessage.Substring(0, 800) + '…' }
            $record.last_error = $errorMessage
            if (Test-BridgeAttachmentPermanentError -Message $errorMessage) {
                if (Test-BridgeProperty -Object $record -Name 'failed_at') { $record.failed_at = [DateTimeOffset]::Now.ToString('o') }
                else { $record | Add-Member -NotePropertyName failed_at -NotePropertyValue ([DateTimeOffset]::Now.ToString('o')) }
                Move-BridgeAttachmentQueueRecord -Path $entry.file.FullName -State failed -Record $record | Out-Null
                $failed++
                Write-BridgeLog -Level WARN -Message "Attachment permanently failed and was isolated: $([string]$record.name): $errorMessage"
            } else {
                $delay = Get-BridgeAttachmentRetryDelaySeconds -Attempt $attempt
                $record.next_attempt_at = [DateTimeOffset]::Now.AddSeconds($delay).ToString('o')
                Write-BridgeJsonAtomic -Path $entry.file.FullName -Value $record
                $deferred++
                Write-BridgeLog -Level WARN -Message "Attachment retry scheduled in ${delay}s: $([string]$record.name): $errorMessage"
            }
            # Continue with other due files. One failed CDN upload must not block
            # attachments belonging to other turns or conversations.
        }
    }
    return [pscustomobject]@{ attempted = $attempted; sent = $sent; deferred = $deferred; failed = $failed }
}

function Compact-BridgeOutbox {
    $root = Initialize-BridgeState
    $outboxPath = Join-Path $root 'outbox'
    $archivePath = Join-Path $root 'outbox-superseded'
    [IO.Directory]::CreateDirectory($archivePath) | Out-Null
    $records = foreach ($file in (Get-ChildItem -LiteralPath $outboxPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $message = Read-BridgeJson -Path $file.FullName -Default $null
        if ($message -and [string]$message.type -eq 'codex_turn_complete' -and $message.session_id) {
            [pscustomobject]@{ file = $file; message = $message }
        }
    }
    foreach ($group in @($records | Group-Object { [string]$_.message.session_id })) {
        $ordered = @($group.Group | Sort-Object { [DateTimeOffset]$_.message.created_at } -Descending)
        if ($ordered.Count -eq 0) { continue }
        $latest = $ordered[0]
        $sessionId = [string]$latest.message.session_id
        $name = Get-CodexThreadDisplayName -SessionId $sessionId
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'Codex 对话') {
            $name = [string]$latest.message.thread_name
        }
        $summary = Get-QueuedCompletionSummary -Message $latest.message
        $config = Get-BridgeConfig
        $chunkChars = if ($config.completion_text_chunk_chars) { [int]$config.completion_text_chunk_chars } else { 1100 }
        $maxChunks = if ($config.completion_text_max_chunks) { [int]$config.completion_text_max_chunks } else { 6 }
        $textBundle = New-CodexCompletionTextBundle -Name $name -Summary $summary `
            -ChunkChars $chunkChars -MaxChunks $maxChunks
        $summary = [string]$textBundle.summary
        $latest.message.text = [string]$textBundle.parts[0]
        if (Test-BridgeProperty -Object $latest.message -Name 'thread_name') { $latest.message.thread_name = $name }
        else { $latest.message | Add-Member -NotePropertyName thread_name -NotePropertyValue $name }
        if (Test-BridgeProperty -Object $latest.message -Name 'summary') { $latest.message.summary = $summary }
        else { $latest.message | Add-Member -NotePropertyName summary -NotePropertyValue $summary }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'attachments')) {
            $latest.message | Add-Member -NotePropertyName attachments -NotePropertyValue @()
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'text_sent')) {
            $latest.message | Add-Member -NotePropertyName text_sent -NotePropertyValue $false
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'next_text_index')) {
            $latest.message | Add-Member -NotePropertyName next_text_index -NotePropertyValue 0
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'text_parts')) {
            $latest.message | Add-Member -NotePropertyName text_parts -NotePropertyValue @($textBundle.parts)
        } elseif (-not [bool]$latest.message.text_sent -and [int]$latest.message.next_text_index -eq 0) {
            $latest.message.text_parts = @($textBundle.parts)
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'wechat_message_ids')) {
            $latest.message | Add-Member -NotePropertyName wechat_message_ids -NotePropertyValue @()
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'wechat_message_id')) {
            $latest.message | Add-Member -NotePropertyName wechat_message_id -NotePropertyValue $null
        }
        if (-not (Test-BridgeProperty -Object $latest.message -Name 'next_attachment_index')) {
            $latest.message | Add-Member -NotePropertyName next_attachment_index -NotePropertyValue 0
        }
        if (Test-BridgeProperty -Object $latest.message -Name 'format_version') { $latest.message.format_version = 7 }
        else { $latest.message | Add-Member -NotePropertyName format_version -NotePropertyValue 7 }
        Write-BridgeJsonAtomic -Path $latest.file.FullName -Value $latest.message

        foreach ($superseded in @($ordered | Select-Object -Skip 1)) {
            $destination = Join-Path $archivePath $superseded.file.Name
            Move-Item -LiteralPath $superseded.file.FullName -Destination $destination -Force
            if ($superseded.message.turn_id) {
                Set-CodexNotificationState -SessionId ([string]$superseded.message.session_id) `
                    -TurnId ([string]$superseded.message.turn_id) -State suppressed
            }
        }
    }
}

function Flush-BridgeOutbox {
    return Invoke-WithBridgeNotificationGate -Action { Invoke-BridgeOutboxFlushCore }
}

function Invoke-BridgeOutboxFlushCore {
    $root = Initialize-BridgeState
    Move-BridgeQueuedRecordsAtOrBeforeReset -Queue 'all' | Out-Null
    Move-LegacyBridgeAttachmentsToQueue | Out-Null
    # Local policy cleanup must run even when WeChat delivery is paused for a
    # missing context token. Disallowed files must never remain sendable while
    # the bridge waits for a future inbound message.
    Remove-BridgeDisallowedQueuedAttachments | Out-Null
    Compact-BridgeOutbox
    $delivery = Get-BridgeDeliveryState
    if ([string]$delivery.state -eq 'waiting_for_wechat' -and
        -not (Test-BridgeDeliveryRetryDue -DeliveryState $delivery)) { return }
    $config = Get-BridgeConfig
    $batchSize = [Math]::Max(1, [int]$config.outbox_send_batch_size)
    $outboxPath = Join-Path $root 'outbox'
    $allFiles = @(Get-ChildItem -LiteralPath $outboxPath -Filter '*.json' -File | Sort-Object Name)
    $files = @($allFiles | Where-Object {
        $candidate = Read-BridgeJson -Path $_.FullName -Default $null
        $candidate -and ($candidate.text -or $candidate.text_parts) -and -not (
            (Test-BridgeProperty -Object $candidate -Name 'text_sent') -and [bool]$candidate.text_sent
        )
    } | Select-Object -First $batchSize)

    # Pass 1: deliver every completion/state text before trying any attachment.
    # A large or rejected attachment must never block later task notifications.
    foreach ($file in $files) {
        $message = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $message -or (-not $message.text -and -not $message.text_parts)) { continue }
        $textSent = (Test-BridgeProperty -Object $message -Name 'text_sent') -and [bool]$message.text_sent
        if ($textSent) { continue }
        try {
            $textParts = @(if ((Test-BridgeProperty -Object $message -Name 'text_parts') -and $null -ne $message.text_parts) {
                @($message.text_parts)
            } else { @([string]$message.text) })
            $nextTextIndex = if (Test-BridgeProperty -Object $message -Name 'next_text_index') {
                [int]$message.next_text_index
            } else { 0 }
            if (-not (Test-BridgeProperty -Object $message -Name 'wechat_message_ids')) {
                $message | Add-Member -NotePropertyName wechat_message_ids -NotePropertyValue @()
            }
            while ($nextTextIndex -lt $textParts.Count) {
                $textDelivery = Send-BridgeRoutableText -Text ([string]$textParts[$nextTextIndex]) `
                    -AllowContextlessRetry -TimeoutSeconds 15
                $nextTextIndex++
                if (Test-BridgeProperty -Object $message -Name 'next_text_index') {
                    $message.next_text_index = $nextTextIndex
                } else {
                    $message | Add-Member -NotePropertyName next_text_index -NotePropertyValue $nextTextIndex
                }
                $message.wechat_message_ids = @($message.wechat_message_ids) + [string]$textDelivery.message_id
                if (Test-BridgeProperty -Object $message -Name 'wechat_message_id') {
                    $message.wechat_message_id = [string]$textDelivery.message_id
                } else {
                    $message | Add-Member -NotePropertyName wechat_message_id -NotePropertyValue ([string]$textDelivery.message_id)
                }
                Register-BridgeReplyTarget -SessionId ([string]$message.session_id) `
                    -ThreadName ([string]$message.thread_name) -Cwd ([string]$message.cwd) `
                    -TurnId ([string]$message.turn_id) -WeChatMessageId ([string]$textDelivery.message_id) `
                    -SendStartedAt ([string]$textDelivery.send_started_at) -SendCompletedAt ([string]$textDelivery.send_completed_at)
                # Checkpoint each successful part. A transient failure resumes
                # from the next part instead of replaying the beginning.
                Write-BridgeJsonAtomic -Path $file.FullName -Value $message
            }
            if (Test-BridgeProperty -Object $message -Name 'text_sent') { $message.text_sent = $true }
            else { $message | Add-Member -NotePropertyName text_sent -NotePropertyValue $true }
            Write-BridgeJsonAtomic -Path $file.FullName -Value $message
            if ($message.session_id -and $message.turn_id) {
                Set-CodexNotificationState -SessionId ([string]$message.session_id) `
                    -TurnId ([string]$message.turn_id) -State sent
            }
            $messageAttachments = @(if ((Test-BridgeProperty -Object $message -Name 'attachments') -and $null -ne $message.attachments) {
                @($message.attachments)
            } else { @() })
            if ($messageAttachments.Count -eq 0) {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        } catch {
            $delivery = Get-BridgeDeliveryState
            if ([string]$delivery.state -ne 'waiting_for_wechat') {
                Write-BridgeLog -Level WARN -Message "Outbox text delivery deferred: $($_.Exception.Message)"
            }
            break
        }
    }

    $delivery = Get-BridgeDeliveryState
    if ([string]$delivery.state -eq 'waiting_for_wechat') { return }

    Flush-BridgeAttachmentOutbox | Out-Null
    Publish-BridgeCompletedAttachmentSummaries
}

function Invoke-BridgePollOnce {
    param([int]$TimeoutSeconds = 40)
    $root = Initialize-BridgeState
    $config = Get-BridgeConfig
    $token = Get-BridgeSecret -Name 'bot_token'
    if (-not $token) { throw 'WeChat bridge is not logged in.' }
    $script:BridgeOutboxFlushedThisPoll = $false
    $syncPath = Join-Path $root 'sync.json'
    $sync = Get-BridgeSyncState -Path $syncPath
    if (-not [bool]$sync.valid) {
        $repair = Repair-BridgeSyncCursor -Path $syncPath -BaseUrl ([string]$config.base_url) `
            -Token $token -TimeoutSeconds $TimeoutSeconds
        if (-not $script:BridgeOutboxFlushedThisPoll) { Flush-BridgeOutbox }
        return [pscustomobject]@{
            sync_recovered = [bool]$repair.recovered
            discarded_message_count = [int]$repair.discarded_message_count
            get_updates_buf = [string]$repair.cursor
            msgs = @()
        }
    }
    $response = Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/getupdates' `
        -Method POST -Body @{ get_updates_buf = [string]$sync.cursor; base_info = Get-BridgeBaseInfo } `
        -Token $token -TimeoutSeconds $TimeoutSeconds

    $errcode = if ($response.PSObject.Properties.Name -contains 'errcode') { [int]$response.errcode } else { 0 }
    if ($errcode -ne 0) {
        throw "WeChat getUpdates failed with errcode=$errcode."
    }
    Save-BridgeSyncCursorFromResponse -Path $syncPath -Response $response | Out-Null

    $messages = @(if ($response.PSObject.Properties.Name -contains 'msgs') { @($response.msgs) })
    foreach ($message in $messages) {
        if ([int]$message.message_type -ne 1) { continue }
        $from = [string]$message.from_user_id
        if ($config.scanner_user_id -and $from -ne [string]$config.scanner_user_id) {
            Write-BridgeLog -Level WARN -Message 'Ignored inbound message from a non-authorized WeChat user.'
            continue
        }
        if ($message.context_token) {
            Set-BridgeContextToken -Token ([string]$message.context_token) -Source inbound
        }
        if (-not $config.target_user_id) { $config.target_user_id = $from }
        $text = Get-InboundText -Message $message
        $savedMessage = Save-InboundMessage -Message $message -Text $text
        if (-not (Register-BridgeInboundMessageId -MessageId ([string]$savedMessage.record.id))) {
            Update-InboundRecord -Path ([string]$savedMessage.path) -Changes @{
                relay_state = 'duplicate_ignored'
                relay_completed_at = [DateTimeOffset]::Now.ToString('o')
            } | Out-Null
            Write-BridgeLog -Level WARN -Message "Ignored duplicate inbound WeChat message $($savedMessage.record.id)."
            continue
        }

        if (-not $config.peer_confirmed -and $message.context_token) {
            $config.peer_confirmed = $true
            Save-BridgeConfig -Config $config
            try {
                Send-BridgeText -Text 'Codex 微信桥接已连接。当前已启用任务结束通知；你从微信发送的消息会安全进入待处理队列，暂不会自动执行。' -TimeoutSeconds 10 | Out-Null
            } catch {
                Write-BridgeLog -Level WARN -Message "Initial acknowledgement failed: $($_.Exception.Message)"
            }
        }
        Invoke-BridgeInboundCommand -Text $text -SavedMessage $savedMessage
    }
    if (-not $script:BridgeOutboxFlushedThisPoll) { Flush-BridgeOutbox }
    return $response
}

function Start-CodexWeChatBridgeMonitor {
    param([switch]$Once)
    Initialize-BridgeState | Out-Null
    try { Remove-BridgeExpiredLogs | Out-Null } catch { }
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, 'Local\CodexWeChatBridgeMonitor', [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        throw 'The Codex WeChat Bridge monitor is already running.'
    }
    $root = Get-BridgeStateRoot
    $stopPath = Join-Path $root 'stop.request'
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -Force }
    try {
        $config = Get-BridgeConfig
        $token = Get-BridgeSecret -Name 'bot_token'
        if (-not $token) { throw 'WeChat bridge is not logged in.' }
        try {
            Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/msg/notifystart' `
                -Method POST -Body @{ base_info = Get-BridgeBaseInfo } -Token $token -TimeoutSeconds 10 | Out-Null
        } catch { Write-BridgeLog -Level WARN -Message "notifyStart failed: $($_.Exception.Message)" }
        Save-BridgeStatus -State 'monitor_running' -Detail 'Long-poll monitor is active' -Extra @{ pid = $PID }
        if (-not $Once -and [bool]$config.completion_monitor_enabled) {
            try { Start-BridgeCompletionMonitorProcess } catch {
                Write-BridgeLog -Level WARN -Message "Completion monitor start failed: $($_.Exception.Message)"
            }
        }
        if ([string]$config.inbound_mode -eq 'codex_relay') {
            try { Start-BridgeRelayWorkerProcess } catch {
                Write-BridgeLog -Level WARN -Message "Relay worker start failed: $($_.Exception.Message)"
            }
        }
        $consecutiveFailures = 0
        $lastLoggedError = ''
        $lastErrorLoggedAt = [DateTimeOffset]::MinValue
        do {
            try {
                Invoke-BridgePollOnce -TimeoutSeconds 40 | Out-Null
                if ($consecutiveFailures -gt 0) {
                    Write-BridgeLog -Level INFO -Message "Monitor recovered after $consecutiveFailures consecutive failure(s)."
                }
                $consecutiveFailures = 0
                $lastLoggedError = ''
                $lastErrorLoggedAt = [DateTimeOffset]::MinValue
                Save-BridgeStatus -State 'monitor_running' -Detail 'Long-poll monitor is active' -Extra @{
                    pid = $PID
                    consecutive_failures = 0
                }
            } catch {
                $consecutiveFailures++
                $errorMessage = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                $retryDelay = [Math]::Min(30, 3 * [Math]::Pow(2, [Math]::Min(4, $consecutiveFailures - 1)))
                Save-BridgeStatus -State 'monitor_retrying' -Detail $errorMessage -Extra @{
                    pid = $PID
                    consecutive_failures = $consecutiveFailures
                    retry_delay_seconds = [int]$retryDelay
                }
                $now = [DateTimeOffset]::Now
                if ($errorMessage -ne $lastLoggedError -or ($now - $lastErrorLoggedAt).TotalMinutes -ge 5) {
                    Write-BridgeLog -Level WARN -Message "Monitor retry #$consecutiveFailures in $([int]$retryDelay)s: $errorMessage"
                    $lastLoggedError = $errorMessage
                    $lastErrorLoggedAt = $now
                }
                if (-not $Once) { Start-Sleep -Seconds ([int]$retryDelay) }
            }
            if ($Once) { break }
        } while (-not (Test-Path -LiteralPath $stopPath))
    } finally {
        try {
            $config = Get-BridgeConfig
            $token = Get-BridgeSecret -Name 'bot_token'
            if ($token) {
                Invoke-IlinkRequest -BaseUrl ([string]$config.base_url) -Endpoint 'ilink/bot/msg/notifystop' `
                    -Method POST -Body @{ base_info = Get-BridgeBaseInfo } -Token $token -TimeoutSeconds 5 | Out-Null
            }
        } catch { }
        Save-BridgeStatus -State 'monitor_stopped' -Detail 'Monitor process exited'
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Get-CodexWeChatBridgeStatus {
    $root = Initialize-BridgeState
    $config = Get-BridgeConfig
    $status = Read-BridgeJson -Path (Join-Path $root 'status.json') -Default ([pscustomobject]@{
        state = 'not_started'
        detail = 'The bridge has not been started.'
    })
    $inboxFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'inbox') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $inboxCount = $inboxFiles.Count
    $outboxCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $attachmentQueuedCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-outbox') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $attachmentFailedCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-failed') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $attachmentSkippedCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'attachment-skipped') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $completionStatus = Read-BridgeJson -Path (Join-Path $root 'completion-status.json') -Default ([pscustomobject]@{ state = 'not_started' })
    $notificationReset = Get-BridgeNotificationResetState
    $deliveryStatus = Get-BridgeDeliveryState
    $syncState = Get-BridgeSyncState -Path (Join-Path $root 'sync.json')
    $syncRecovery = Read-BridgeJson -Path (Join-Path $root 'sync-recovery.json') -Default $null
    $replyRouting = Get-BridgeReplyRoutingState
    $relayQueuedCount = 0
    $relayRunningCount = 0
    foreach ($file in $inboxFiles) {
        $record = Read-BridgeJson -Path $file.FullName -Default $null
        if (-not $record -or -not (Test-BridgeProperty -Object $record -Name 'relay_state')) { continue }
        if ([string]$record.relay_state -eq 'relay_queued') { $relayQueuedCount++ }
        if ([string]$record.relay_state -in @('relay_running', 'relay_submitted')) { $relayRunningCount++ }
    }
    return [pscustomobject]@{
        bridge_version = $script:BridgeVersion
        http_transport_mode = $script:HttpTransportMode
        state = [string]$status.state
        detail = [string]$status.detail
        logged_in = [bool](Get-BridgeSecret -Name 'bot_token')
        peer_confirmed = [bool]$config.peer_confirmed
        account_id = [string]$config.account_id
        target_configured = [bool]$config.target_user_id
        inbound_mode = [string]$config.inbound_mode
        direct_reply_enabled = [bool]$config.direct_reply_enabled
        require_completion_quote = [bool]$config.require_completion_quote
        completion_attachments_enabled = [bool]$config.completion_attachments_enabled
        reply_pending_count = @($replyRouting.pending_targets).Count
        relay_transport = [string]$config.relay_transport
        inbox_count = $inboxCount
        outbox_count = $outboxCount
        attachment_queued_count = $attachmentQueuedCount
        attachment_failed_count = $attachmentFailedCount
        attachment_skipped_count = $attachmentSkippedCount
        relay_queued_count = $relayQueuedCount
        relay_running_count = $relayRunningCount
        completion_monitor_state = [string]$completionStatus.state
        delivery_state = [string]$deliveryStatus.state
        sync_state = if ([bool]$syncState.valid) { 'healthy' } else { "repair_pending:$($syncState.reason)" }
        sync_last_recovered_at = if ($syncRecovery -and (Test-BridgeProperty -Object $syncRecovery -Name 'recovered_at')) {
            [string]$syncRecovery.recovered_at
        } else { '' }
        notification_pending_count = $outboxCount + $attachmentQueuedCount
        notification_reset_at = if ($notificationReset -and (Test-BridgeProperty -Object $notificationReset -Name 'cutoff_at')) {
            [string]$notificationReset.cutoff_at
        } else { '' }
        state_root = $root
    }
}

function Test-BridgeProcessAlive {
    param($ProcessId)
    $parsed = 0
    if ($null -eq $ProcessId -or -not [int]::TryParse([string]$ProcessId, [ref]$parsed) -or $parsed -le 0) { return $false }
    return $null -ne (Get-Process -Id $parsed -ErrorAction SilentlyContinue)
}

function Get-BridgeDoctorText {
    $root = Initialize-BridgeState
    $status = Get-CodexWeChatBridgeStatus
    $monitor = Read-BridgeJson -Path (Join-Path $root 'status.json') -Default $null
    $completion = Read-BridgeJson -Path (Join-Path $root 'completion-status.json') -Default $null
    $monitorAlive = $monitor -and (Test-BridgeProperty -Object $monitor -Name 'pid') -and (Test-BridgeProcessAlive $monitor.pid)
    $completionAlive = $completion -and (Test-BridgeProperty -Object $completion -Name 'pid') -and (Test-BridgeProcessAlive $completion.pid)
    $codexOk = $false
    $codexPath = ''
    try { $codexPath = Get-CodexExecutable; $codexOk = Test-Path -LiteralPath $codexPath -PathType Leaf } catch { }
    $pwshOk = $null -ne (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
    $taskState = '未安装或不可读取'
    try {
        $task = Get-ScheduledTask -TaskName 'CodexWeChatBridge' -ErrorAction Stop
        $taskState = [string]$task.State
    } catch { }
    $worktreeState = Read-BridgeJson -Path (Join-Path $root 'managed-worktrees.json') -Default ([pscustomobject]@{ worktrees = @() })
    $lastError = ''
    $latestLog = Get-ChildItem -LiteralPath (Join-Path $root 'logs') -Filter 'bridge-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($latestLog) {
        $lastRecord = Get-Content -LiteralPath $latestLog.FullName -Tail 80 -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
            Where-Object { [string]$_.level -in @('WARN', 'ERROR') } | Select-Object -Last 1
        if ($lastRecord) {
            $lastError = ([string]$lastRecord.message -replace '\s+', ' ').Trim()
            if ($lastError.Length -gt 180) { $lastError = $lastError.Substring(0, 180) + '…' }
        }
    }
    $lines = @(
        "微信桥接诊断（v$($status.bridge_version)）",
        "主监控：$(if ($monitorAlive) { '正常' } else { '未运行' })",
        "完成监控：$(if ($completionAlive) { '正常' } else { '未运行' })",
        "计划任务：$taskState",
        "Codex：$(if ($codexOk) { '可用' } else { '未找到' })",
        "PowerShell 7：$(if ($pwshOk) { '可用' } else { '未找到' })",
        "微信网络：$($status.http_transport_mode)",
        "微信游标：$(if ($status.sync_state -eq 'healthy') { '正常' } else { '等待自动恢复' })",
        "微信投递：$($status.delivery_state)（文字积压 $($status.outbox_count)，附件等待 $($status.attachment_queued_count)，附件失败 $($status.attachment_failed_count)，附件跳过 $($status.attachment_skipped_count)）",
        "执行队列：等待 $($status.relay_queued_count)，执行中 $($status.relay_running_count)",
        "托管 worktree：$(@($worktreeState.worktrees).Count)"
    )
    if ($lastError) { $lines += "最近警告：$lastError" }
    if (-not $monitorAlive -or -not $completionAlive) { $lines += '建议：重新运行 Install-WeChatBridgeService.ps1 -StartNow。' }
    return $lines -join "`n"
}

Export-ModuleMember -Function @(
    'Clear-CodexWeChatNotificationBacklog',
    'Connect-CodexWeChatBridge',
    'Disable-CodexWeChatRelay',
    'Enable-CodexWeChatRelay',
    'Get-CodexWeChatBridgeStatus',
    'Get-BridgeDoctorText',
    'Refresh-CodexThreadCatalog',
    'Initialize-BridgeState',
    'Invoke-CodexAppServerTurn',
    'Invoke-BridgePollOnce',
    'Publish-CodexTurnNotification',
    'Register-CodexPromptStart',
    'Parse-BridgeExecutionCommand',
    'New-BridgeManagedWorktree',
    'Send-BridgeFile',
    'Send-BridgeText',
    'Set-CodexThreadDisplayName',
    'Start-CodexCompletionMonitor',
    'Submit-CodexDesktopPrompt',
    'Start-CodexWeChatBridgeMonitor',
    'Start-CodexWeChatRelayWorker'
)
