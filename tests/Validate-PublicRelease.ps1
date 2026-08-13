$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pluginRoot = Join-Path $repoRoot 'plugins\codex-wechat-bridge'
$manifestPath = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$marketplacePath = Join-Path $repoRoot '.agents\plugins\marketplace.json'

foreach ($path in @($manifestPath, $marketplacePath, (Join-Path $repoRoot 'README.md'), (Join-Path $repoRoot 'LICENSE'), (Join-Path $repoRoot 'install.ps1'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file is missing: $path"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$manifest.name -ne 'codex-wechat-bridge') { throw 'Unexpected plugin name.' }
if ([string]$manifest.version -ne '0.9.22') { throw "Unexpected plugin version: $($manifest.version)" }

$releaseNotesPath = Join-Path $repoRoot ("docs\releases\v{0}.md" -f [string]$manifest.version)
if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) {
    throw "Chinese release notes are missing for version $($manifest.version): $releaseNotesPath"
}
$releaseNotes = Get-Content -LiteralPath $releaseNotesPath -Raw -Encoding utf8
$rootReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw -Encoding utf8
$installer = Get-Content -LiteralPath (Join-Path $repoRoot 'install.ps1') -Raw -Encoding utf8
foreach ($document in @($releaseNotes, $rootReadme, $installer)) {
    if ($document -notmatch 'https://github\.com/xiao0xiao0/codex-wechat-bridge') {
        throw 'A public user-facing entry is missing the canonical repository URL.'
    }
}
if ($releaseNotes -notmatch '(?i)star' -or $rootReadme -notmatch '(?i)star' -or $installer -notmatch '(?i)star') {
    throw 'Release notes, README, and installer must keep the voluntary Star guidance.'
}

$marketplace = Get-Content -LiteralPath $marketplacePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$marketplace.name -ne 'codex-wechat-bridge') { throw 'Unexpected marketplace name.' }
$entry = @($marketplace.plugins | Where-Object { [string]$_.name -eq 'codex-wechat-bridge' })
if ($entry.Count -ne 1) { throw 'Marketplace must contain exactly one codex-wechat-bridge entry.' }
if ([string]$entry[0].source.path -ne './plugins/codex-wechat-bridge') { throw 'Marketplace plugin path is invalid.' }

$syntaxErrors = @()
$powerShellFiles = @(
    @(Get-ChildItem -LiteralPath (Join-Path $pluginRoot 'scripts') -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    Get-Item -LiteralPath (Join-Path $repoRoot 'install.ps1')
    Get-Item -LiteralPath $PSCommandPath
)
foreach ($script in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) { $syntaxErrors += "$($script.Name): $($error.Message)" }
}
if ($syntaxErrors.Count -gt 0) { throw ($syntaxErrors -join "`n") }

$forbiddenPatterns = [ordered]@{
    'author home path' = 'C:\\Users\\hanxi'
    'author drive path' = 'D:\\'
    'observed WeChat user id' = 'o9cq'
    'GitHub OAuth token' = 'gho_[A-Za-z0-9_]+'
    'GitHub personal access token' = 'github_pat_[A-Za-z0-9_]+'
    'observed Codex thread id' = '019f[0-9a-f-]{20,}'
}
$textExtensions = @('.md', '.json', '.ps1', '.psm1', '.yml', '.yaml', '.txt', '.gitignore')
$releaseFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]' -and
    $_.FullName -ne $PSCommandPath -and
    ($_.Extension -in $textExtensions -or $_.Name -eq '.gitignore')
})
foreach ($file in $releaseFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($pattern in $forbiddenPatterns.GetEnumerator()) {
        if ($content -match $pattern.Value) { throw "Forbidden $($pattern.Key) found in $($file.FullName)." }
    }
}

[pscustomobject]@{
    valid = $true
    plugin = [string]$manifest.name
    version = [string]$manifest.version
    marketplace = [string]$marketplace.name
    scripts_parsed = $powerShellFiles.Count
    release_files_scanned = $releaseFiles.Count
    live_wechat_messages_sent = 0
    live_codex_tasks_created = 0
} | ConvertTo-Json -Compress
