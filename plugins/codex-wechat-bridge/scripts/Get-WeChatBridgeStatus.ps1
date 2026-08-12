$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Get-CodexWeChatBridgeStatus | ConvertTo-Json -Depth 10
