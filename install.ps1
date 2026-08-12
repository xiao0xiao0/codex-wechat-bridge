param(
    [switch]$Configure,
    [switch]$StartNow,
    [switch]$EnableRelay
)

$ErrorActionPreference = 'Stop'
$repository = 'xiao0xiao0/codex-wechat-bridge'
$marketplace = 'codex-wechat-bridge'
$pluginName = 'codex-wechat-bridge'

$codex = Get-Command codex -ErrorAction Stop
$configured = @(& $codex.Source plugin marketplace list --json | ConvertFrom-Json).marketplaces |
    Where-Object { [string]$_.name -eq $marketplace }
if ($configured) {
    & $codex.Source plugin marketplace upgrade $marketplace | Out-Host
} else {
    & $codex.Source plugin marketplace add $repository | Out-Host
}
if ($LASTEXITCODE -ne 0) { throw 'Codex marketplace registration or upgrade failed.' }

& $codex.Source plugin add "$pluginName@$marketplace" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Codex plugin installation failed.' }

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$cacheRoot = Join-Path $codexHome "plugins\cache\$marketplace\$pluginName"
$plugin = Get-ChildItem -LiteralPath $cacheRoot -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $plugin) { throw "Installed plugin directory was not found under $cacheRoot." }

if ($Configure) {
    & pwsh -NoProfile -File (Join-Path $plugin.FullName 'scripts\Connect-WeChatBridge.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'WeChat QR configuration failed.' }
}
if ($StartNow) {
    & pwsh -NoProfile -File (Join-Path $plugin.FullName 'scripts\Install-WeChatBridgeService.ps1') -StartNow
    if ($LASTEXITCODE -ne 0) { throw 'Background service installation failed.' }
}
if ($EnableRelay) {
    & pwsh -NoProfile -File (Join-Path $plugin.FullName 'scripts\Enable-WeChatCodexRelay.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Two-way relay opt-in failed.' }
}

[pscustomobject]@{
    installed = $true
    marketplace = $marketplace
    plugin = $pluginName
    version = $plugin.Name
    path = $plugin.FullName
    configured = [bool]$Configure
    service_started = [bool]$StartNow
    relay_enabled = [bool]$EnableRelay
} | ConvertTo-Json -Depth 5
