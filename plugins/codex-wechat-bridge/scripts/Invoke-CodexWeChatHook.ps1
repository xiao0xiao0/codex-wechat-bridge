param(
    [ValidateSet('UserPromptSubmit', 'Stop')]
    [string]$EventName = 'Stop'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $hookEvent = $raw | ConvertFrom-Json
        if ($EventName -eq 'UserPromptSubmit') {
            Register-CodexPromptStart -HookEvent $hookEvent
        } elseif ($env:CODEX_WECHAT_RELAY -eq '1') {
            Publish-CodexTurnNotification -HookEvent $hookEvent -SuppressNotification | Out-Null
        } else {
            Publish-CodexTurnNotification -HookEvent $hookEvent | Out-Null
        }
    }
} catch {
    # Hooks must never block or continue a Codex turn because notification delivery failed.
    try {
        $stateRoot = if ($env:CODEX_WECHAT_BRIDGE_HOME) {
            [System.IO.Path]::GetFullPath($env:CODEX_WECHAT_BRIDGE_HOME)
        } else {
            Join-Path $env:LOCALAPPDATA 'CodexWeChatBridge'
        }
        $logRoot = Join-Path $stateRoot 'logs'
        [System.IO.Directory]::CreateDirectory($logRoot) | Out-Null
        $record = [ordered]@{
            ts = [DateTimeOffset]::Now.ToString('o')
            level = 'ERROR'
            event = $EventName
            message = $_.Exception.Message
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText(
            (Join-Path $logRoot 'hook-errors.jsonl'),
            $record + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    } catch { }
}

[Console]::Out.WriteLine('{}')
exit 0
