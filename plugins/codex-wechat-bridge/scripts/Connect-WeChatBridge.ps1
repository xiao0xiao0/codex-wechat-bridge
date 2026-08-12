param(
    [int]$TimeoutSeconds = 480,
    [string]$VerifyCode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
$result = Connect-CodexWeChatBridge -TimeoutSeconds $TimeoutSeconds -OpenBrowser -VerifyCode $VerifyCode
$result | ConvertTo-Json -Depth 10
