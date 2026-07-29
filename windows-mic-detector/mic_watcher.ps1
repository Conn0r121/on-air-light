<#
mic_watcher.ps1 — reports whether ANY app is actively using the microphone.

How it works
------------
Windows tracks per-app microphone usage in the "ConsentStore" registry keys
(the same data that drives the mic icon in the system tray). Every app that
has ever used the mic gets a subkey holding two QWORD FILETIME values:

    LastUsedTimeStart  - when the app last started using the mic
    LastUsedTimeStop   - when it stopped; 0 while the app is STILL using it

So "any subkey with Start != 0 and Stop == 0" means the mic is hot right now.
Store/UWP apps live directly under ...\ConsentStore\microphone\, classic
desktop apps (Discord, Zoom, etc.) under ...\microphone\NonPackaged\.

On every state change — and every $HeartbeatSeconds as a re-sync in case HA
restarted or missed a post — the script POSTs {"active": true|false} to the
Home Assistant webhook configured below.

Run it manually in a console first to verify it works, then use
install-startup-task.ps1 to keep it running in the background at every login.
No admin rights required: everything here is HKCU reads + an outbound POST.
#>

# =============================== CONFIG ===============================
# EDIT: your Home Assistant webhook URL. The trailing path segment must match
# the `webhook_id` in homeassistant/automations.yaml.
$WebhookUrl = 'http://<pi-ip>:8123/api/webhook/mic_active'

$PollIntervalSeconds = 2     # how often to check the registry
$HeartbeatSeconds    = 300   # re-send the current state this often even if
                             # unchanged (heals HA restarts / missed posts)
$LogFile     = Join-Path $env:LOCALAPPDATA 'on-air-light\mic_watcher.log'
$MaxLogBytes = 1MB           # log rolls over to mic_watcher.log.old at this size
# ======================================================================

function Write-Log {
    param([string]$Message)
    $line = ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogBytes)) {
            Move-Item -Path $LogFile -Destination ($LogFile + '.old') -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {
        # Logging must never kill the watcher loop.
    }
    Write-Host $line
}

function Get-ActiveMicApps {
    # Returns the names of apps currently holding the mic (empty array = idle).
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged'
    )
    $active = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            # The NonPackaged container itself shows up as a child of the first
            # root; its contents are enumerated via the second root.
            if ($key.PSChildName -eq 'NonPackaged') { continue }
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $start = $props.LastUsedTimeStart
            $stop  = $props.LastUsedTimeStop
            if (($null -ne $start) -and ($start -gt 0) -and (($null -eq $stop) -or ($stop -eq 0))) {
                # NonPackaged key names encode the exe path with '#' in place
                # of '\'; keep just the executable name for readable logs.
                $active += (($key.PSChildName -split '#')[-1])
            }
        }
    }
    return ,$active
}

if ($WebhookUrl -like '*<pi-ip>*') {
    Write-Log 'ERROR: Edit $WebhookUrl at the top of this script first (it still contains the <pi-ip> placeholder).'
    exit 1
}

Write-Log "mic_watcher started (PID $PID). Polling every ${PollIntervalSeconds}s; posting to $WebhookUrl"

$lastSent     = $null                  # last state successfully delivered to HA
$lastSentTime = [DateTime]::MinValue
$lastWarnTime = [DateTime]::MinValue   # throttles repeated failure logging

while ($true) {
    try {
        $apps     = @(Get-ActiveMicApps)
        $isActive = ($apps.Count -gt 0)

        $stateChanged = ($null -eq $lastSent) -or ($lastSent -ne $isActive)
        $heartbeatDue = (((Get-Date) - $lastSentTime).TotalSeconds -ge $HeartbeatSeconds)

        if ($stateChanged -or $heartbeatDue) {
            $body = @{ active = $isActive } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' `
                    -Body $body -TimeoutSec 5 | Out-Null
                if ($stateChanged) {
                    if ($isActive) {
                        Write-Log ('Mic ACTIVE (' + ($apps -join ', ') + ') -> reported to HA')
                    } else {
                        Write-Log 'Mic idle -> reported to HA'
                    }
                }
                $lastSent     = $isActive
                $lastSentTime = Get-Date
            } catch {
                # HA down or unreachable: keep looping. Because $lastSent was
                # not updated, the POST retries on the next poll automatically.
                if (((Get-Date) - $lastWarnTime).TotalSeconds -ge 60) {
                    Write-Log ('WARN: webhook POST failed: ' + $_.Exception.Message + ' (retrying; warnings suppressed for 60s)')
                    $lastWarnTime = Get-Date
                }
            }
        }
    } catch {
        if (((Get-Date) - $lastWarnTime).TotalSeconds -ge 60) {
            Write-Log ('ERROR: ' + $_.Exception.Message)
            $lastWarnTime = Get-Date
        }
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
