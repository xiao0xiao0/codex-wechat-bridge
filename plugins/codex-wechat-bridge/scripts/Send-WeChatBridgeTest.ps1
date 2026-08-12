param(
    [string]$Message = '[Codex] 微信通知测试成功。'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Send-BridgeText -Text $Message -AllowContextlessRetry | ConvertTo-Json -Depth 10
