$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Enable-CodexWeChatRelay | ConvertTo-Json -Depth 10
