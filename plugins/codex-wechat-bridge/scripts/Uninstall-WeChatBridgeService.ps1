param([switch]$RemoveLocalState)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
$root = Initialize-BridgeState
$stopPath = Join-Path $root 'stop.request'
[IO.File]::WriteAllText($stopPath, [DateTimeOffset]::Now.ToString('o'), [Text.UTF8Encoding]::new($false))
try { Stop-ScheduledTask -TaskName 'CodexWeChatBridge' -ErrorAction SilentlyContinue } catch { }
try { Unregister-ScheduledTask -TaskName 'CodexWeChatBridge' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
if ($RemoveLocalState) {
    throw '为避免误删微信凭据和审计记录，本脚本不自动删除本地状态；请手动备份后删除状态目录。'
}
[pscustomobject]@{ uninstalled = $true; state_preserved = $true; state_root = $root } | ConvertTo-Json
