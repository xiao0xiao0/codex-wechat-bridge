$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Start-CodexWeChatRelayWorker | ConvertTo-Json -Compress
