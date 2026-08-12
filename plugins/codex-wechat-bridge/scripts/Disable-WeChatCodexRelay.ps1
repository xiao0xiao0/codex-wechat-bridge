$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Disable-CodexWeChatRelay | ConvertTo-Json -Depth 10
