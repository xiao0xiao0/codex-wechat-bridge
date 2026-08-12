param([switch]$Once)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Start-CodexWeChatBridgeMonitor -Once:$Once
