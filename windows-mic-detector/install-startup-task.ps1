<#
install-startup-task.ps1 — registers mic_watcher.ps1 as a Windows Scheduled
Task that runs at YOUR login, in your own user context. No admin rights
required (the task is created under the current user, not SYSTEM).

Usage (from a normal, non-elevated PowerShell prompt in this directory):
    .\install-startup-task.ps1              # install (or update) and start now
    .\install-startup-task.ps1 -Uninstall   # stop and remove the task

Notes:
  - The watcher runs hidden; a console window may flash briefly at logon —
    that's the PowerShell host starting before -WindowStyle Hidden kicks in.
  - The task only runs while you're logged in, which is exactly right: mic
    usage on this PC only matters when you're at it.
#>
param(
    [switch]$Uninstall
)

$TaskName    = 'On-Air Light Mic Watcher'
$WatcherPath = Join-Path $PSScriptRoot 'mic_watcher.ps1'

if ($Uninstall) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Removed scheduled task '$TaskName'."
    } catch {
        Write-Host "Task '$TaskName' was not installed; nothing to do."
    }
    exit 0
}

if (-not (Test-Path $WatcherPath)) {
    Write-Error "mic_watcher.ps1 not found next to this script ($WatcherPath)."
    exit 1
}

# Refuse to install a watcher that still points at the placeholder URL.
# Only inspect the $WebhookUrl assignment line — the placeholder string also
# appears in the watcher's own runtime guard and comments.
if (Select-String -Path $WatcherPath -Pattern '^\s*\$WebhookUrl\s*=\s*.*<pi-ip>' -Quiet) {
    Write-Error 'Edit $WebhookUrl at the top of mic_watcher.ps1 first (it still contains the <pi-ip> placeholder).'
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $WatcherPath)

# Trigger only on this user's logon.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings `
    -Description 'Watches the microphone ConsentStore registry keys and reports active/idle to Home Assistant (on-air light).' `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' (runs at logon for $env:USERNAME)."

Start-ScheduledTask -TaskName $TaskName
Write-Host 'Started the watcher now. Log file:'
Write-Host "  $env:LOCALAPPDATA\on-air-light\mic_watcher.log"
