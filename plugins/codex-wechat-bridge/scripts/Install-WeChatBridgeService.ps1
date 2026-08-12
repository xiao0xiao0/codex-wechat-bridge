param([switch]$StartNow)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CodexWeChatBridge.psm1') -Force
Initialize-BridgeState | Out-Null

# Register-ScheduledTask -Force does not replace an already-running instance
# when MultipleInstances is IgnoreNew. Stop the old task and its bridge-only
# child processes before changing the executable path, otherwise two plugin
# cache versions can keep polling the same WeChat account concurrently.
$existingTask = Get-ScheduledTask -TaskName 'CodexWeChatBridge' -ErrorAction SilentlyContinue
if ($existingTask) {
    Stop-ScheduledTask -TaskName 'CodexWeChatBridge' -ErrorAction SilentlyContinue
}
$selfPid = $PID
$bridgeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $selfPid -and $_.Name -in @('pwsh.exe', 'powershell.exe') -and
    ([string]$_.CommandLine -match 'codex-wechat-bridge.+\\scripts\\(Start-WeChatBridge|Start-CodexCompletionMonitor|Start-WeChatRelayWorker)\.ps1')
})
foreach ($process in $bridgeProcesses) {
    Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
}

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$serviceScript = Join-Path $PSScriptRoot 'Start-WeChatBridge.ps1'
$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File `"$serviceScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 99 `
    -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'CodexWeChatBridge' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Maintains the local Codex to WeChat ClawBot transport and restarts it after unexpected exits.' -Force | Out-Null

if ($StartNow) {
    Start-ScheduledTask -TaskName 'CodexWeChatBridge'
}

[pscustomobject]@{
    installed = $true
    task_name = 'CodexWeChatBridge'
    started = [bool]$StartNow
    stopped_previous_instances = $bridgeProcesses.Count
} | ConvertTo-Json
