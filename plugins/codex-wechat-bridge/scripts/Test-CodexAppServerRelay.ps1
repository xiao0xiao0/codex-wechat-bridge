param([string]$Cwd = (Get-Location).Path)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
$result = Invoke-CodexAppServerTurn -NewEphemeral -Prompt '只回复：Codex App Server relay smoke test passed' -Cwd $Cwd -TimeoutSeconds 300
$result | ConvertTo-Json -Depth 10
