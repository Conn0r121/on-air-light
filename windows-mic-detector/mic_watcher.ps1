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
restarted or missed a post — the script POSTs
{"active": true|false, "source": "<name>"} to the Home Assistant webhook
configured below. The "source" name identifies THIS PC, so the script can run
on several machines (laptop, gaming PC, ...) sharing one webhook, each mapped
to its own input_boolean.mic_active_<source> in HA.

Discord nuance
--------------
Being connected to a voice channel holds the mic open even while self-muted,
so plain detection would show "on air" the whole time. With
$DiscordMuteDetection enabled, the watcher also asks the local Discord client
over its RPC websocket (the same mechanism OBS mute-indicator overlays use)
whether you are muted or deafened, and treats "in channel but muted" as idle.
The first time this runs on a PC, Discord pops an authorization dialog —
click "Authorize" once; the token is cached after that. If Discord isn't
running, declines, or the RPC breaks, detection degrades gracefully to the
plain behavior (mic held by Discord counts as active).

Run it manually in a console first to verify it works, then use
install-startup-task.ps1 to keep it running in the background at every login.
No admin rights required: everything here is HKCU reads + an outbound POST.
#>

# =============================== CONFIG ===============================
# EDIT: your Home Assistant webhook URL. The trailing path segment must match
# the `webhook_id` in homeassistant/automations.yaml.
$WebhookUrl = 'http://<pi-ip>:8123/api/webhook/mic_active'

# EDIT: short name identifying THIS PC. Must be listed in the allowed-sources
# guard in homeassistant/automations.yaml and have a matching
# input_boolean.mic_active_<name>. Lowercase letters/digits/underscores only
# (it becomes part of an HA entity id).
$SourceName = 'laptop'       # e.g. 'laptop' or 'gaming'

$PollIntervalSeconds = 2     # how often to check the registry
$HeartbeatSeconds    = 300   # re-send the current state this often even if
                             # unchanged (heals HA restarts / missed posts)
$LogFile     = Join-Path $env:LOCALAPPDATA 'on-air-light\mic_watcher.log'
$MaxLogBytes = 1MB           # log rolls over to mic_watcher.log.old at this size

# Discord mute detection (see "Discord nuance" above). Set to $false to treat
# Discord like any other app (mic held = active, muted or not).
$DiscordMuteDetection = $true
$DiscordClientId      = '207646673902501888'  # Discord StreamKit's public app id
$DiscordTokenFile     = Join-Path $env:LOCALAPPDATA 'on-air-light\discord_rpc_token.json'
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
    # Plain return: callers wrap with @(), which rebuilds the array cleanly.
    # (`return ,$active` here would double-wrap and make idle look active.)
    return $active
}

# ===================== Discord RPC (mute detection) ===================
# Talks to the Discord desktop client's local RPC websocket the same way
# OBS mute-indicator overlays do: authorize against the public StreamKit
# app id, exchange the code for a token via StreamKit's backend, then poll
# GET_VOICE_SETTINGS. Unofficial, but stable in the community for years.

$script:DiscordWs           = $null
$script:NextRpcAttempt      = [DateTime]::MinValue  # throttles reconnect attempts
$script:NextAuthorizePrompt = [DateTime]::MinValue  # throttles the in-Discord popup

function Send-DiscordFrame {
    param($Socket, [hashtable]$Payload)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 8 -Compress))
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $Socket.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Receive-DiscordFrame {
    param($Socket, [int]$TimeoutMs = 5000)
    $buffer = New-Object byte[] 65536
    $ms  = New-Object System.IO.MemoryStream
    $cts = New-Object System.Threading.CancellationTokenSource($TimeoutMs)
    try {
        do {
            $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
            $result = $Socket.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'Discord closed the RPC socket'
            }
            $ms.Write($buffer, 0, $result.Count)
        } while (-not $result.EndOfMessage)
    } finally { $cts.Dispose() }
    return ([System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json)
}

function Wait-DiscordResponse {
    # Reads frames until one matches $Cmd (skipping unsolicited events).
    param($Socket, [string]$Cmd, [int]$TimeoutMs = 5000)
    for ($i = 0; $i -lt 5; $i++) {
        $frame = Receive-DiscordFrame -Socket $Socket -TimeoutMs $TimeoutMs
        if ($frame.cmd -eq $Cmd) { return $frame }
    }
    throw "no $Cmd response from Discord"
}

function Close-DiscordRpc {
    if ($null -ne $script:DiscordWs) {
        try { $script:DiscordWs.Dispose() } catch {}
        $script:DiscordWs = $null
    }
}

function Connect-DiscordRpc {
    # Establishes and authenticates the RPC session; $true on success.
    foreach ($port in 6463..6472) {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.SetRequestHeader('Origin', 'https://streamkit.discord.com')
        try {
            $cts = New-Object System.Threading.CancellationTokenSource(2000)
            $ws.ConnectAsync([Uri]"ws://127.0.0.1:$port/?v=1&client_id=$DiscordClientId&encoding=json",
                $cts.Token).GetAwaiter().GetResult() | Out-Null
            $ready = Receive-DiscordFrame -Socket $ws -TimeoutMs 5000
            if ($ready.evt -ne 'READY') { throw 'no READY handshake' }
        } catch {
            $ws.Dispose()
            continue   # Discord may be on the next port, or not running at all
        }

        # Try the cached token first — silent, no popup.
        $token = $null
        if (Test-Path $DiscordTokenFile) {
            try { $token = (Get-Content $DiscordTokenFile -Raw | ConvertFrom-Json).access_token } catch {}
        }
        if ($token) {
            Send-DiscordFrame $ws @{ cmd = 'AUTHENTICATE'; args = @{ access_token = $token }; nonce = "$([guid]::NewGuid())" }
            $resp = $null
            try { $resp = Wait-DiscordResponse $ws 'AUTHENTICATE' 5000 } catch {}
            if ($resp -and $resp.evt -ne 'ERROR') { $script:DiscordWs = $ws; return $true }
            Remove-Item $DiscordTokenFile -Force -ErrorAction SilentlyContinue
        }

        # No (valid) token: needs the one-time "Authorize" popup inside Discord.
        # Throttled to once per hour so an unattended PC isn't nagged forever.
        if ((Get-Date) -lt $script:NextAuthorizePrompt) { $ws.Dispose(); return $false }
        $script:NextAuthorizePrompt = (Get-Date).AddHours(1)
        Write-Log 'Discord mute detection: click "Authorize" in the Discord popup (waiting up to 60s)...'
        $code = $null
        $scopeSets = @(
            [string[]]@('rpc', 'rpc.voice.read'),
            [string[]]@('rpc')
        )
        foreach ($scopes in $scopeSets) {
            Send-DiscordFrame $ws @{ cmd = 'AUTHORIZE'; args = @{ client_id = $DiscordClientId; scopes = $scopes; prompt = 'none' }; nonce = "$([guid]::NewGuid())" }
            $auth = $null
            try { $auth = Wait-DiscordResponse $ws 'AUTHORIZE' 60000 } catch { break }  # timeout: popup unattended
            if ($auth.evt -eq 'ERROR') { continue }  # scope set rejected; try the next one
            $code = $auth.data.code
            break
        }
        if (-not $code) {
            Write-Log 'WARN: Discord authorization not granted; using plain mic detection for now.'
            $ws.Dispose(); return $false
        }
        try {
            $tokenResp = Invoke-RestMethod -Uri 'https://streamkit.discord.com/overlay/token' -Method Post `
                -ContentType 'application/json' -Body (@{ code = $code } | ConvertTo-Json -Compress) -TimeoutSec 10
            $token = $tokenResp.access_token
        } catch {
            Write-Log ('WARN: StreamKit token exchange failed: ' + $_.Exception.Message)
            $ws.Dispose(); return $false
        }
        Send-DiscordFrame $ws @{ cmd = 'AUTHENTICATE'; args = @{ access_token = $token }; nonce = "$([guid]::NewGuid())" }
        $resp = $null
        try { $resp = Wait-DiscordResponse $ws 'AUTHENTICATE' 5000 } catch {}
        if (-not $resp -or $resp.evt -eq 'ERROR') { $ws.Dispose(); return $false }
        @{ access_token = $token } | ConvertTo-Json -Compress | Set-Content -Path $DiscordTokenFile -Encoding ASCII
        Write-Log 'Discord mute detection: authorized and connected.'
        $script:DiscordWs = $ws
        return $true
    }
    return $false   # no port answered: Discord isn't running
}

function Get-DiscordVoiceState {
    # Returns @{ mute; deaf } or $null when Discord RPC is unavailable —
    # callers must then fall back to treating Discord as actively on-mic.
    if ($null -eq $script:DiscordWs -or
        $script:DiscordWs.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        Close-DiscordRpc
        if ((Get-Date) -lt $script:NextRpcAttempt) { return $null }
        $script:NextRpcAttempt = (Get-Date).AddSeconds(30)
        if (-not (Connect-DiscordRpc)) { return $null }
    }
    try {
        Send-DiscordFrame $script:DiscordWs @{ cmd = 'GET_VOICE_SETTINGS'; args = @{}; nonce = "$([guid]::NewGuid())" }
        $resp = Wait-DiscordResponse $script:DiscordWs 'GET_VOICE_SETTINGS' 5000
        return @{ mute = [bool]$resp.data.mute; deaf = [bool]$resp.data.deaf }
    } catch {
        Close-DiscordRpc
        return $null
    }
}
# ======================================================================

if ($WebhookUrl -like '*<pi-ip>*') {
    Write-Log 'ERROR: Edit $WebhookUrl at the top of this script first (it still contains the <pi-ip> placeholder).'
    exit 1
}
if ($SourceName -notmatch '^[a-z0-9_]+$') {
    Write-Log "ERROR: `$SourceName must be lowercase letters/digits/underscores only (got '$SourceName')."
    exit 1
}

Write-Log "mic_watcher started (PID $PID, source '$SourceName'). Polling every ${PollIntervalSeconds}s; posting to $WebhookUrl"

$lastSent     = $null                  # last state successfully delivered to HA
$lastSentTime = [DateTime]::MinValue
$lastWarnTime = [DateTime]::MinValue   # throttles repeated failure logging

while ($true) {
    try {
        $apps = @(Get-ActiveMicApps)
        $note = ''
        if ($DiscordMuteDetection -and ($apps -match '^Discord')) {
            $voice = Get-DiscordVoiceState
            if ($null -ne $voice -and ($voice.mute -or $voice.deaf)) {
                $apps = @($apps | Where-Object { $_ -notmatch '^Discord' })
                $note = ' (Discord open but muted)'
            }
        }
        $isActive = ($apps.Count -gt 0)

        $stateChanged = ($null -eq $lastSent) -or ($lastSent -ne $isActive)
        $heartbeatDue = (((Get-Date) - $lastSentTime).TotalSeconds -ge $HeartbeatSeconds)

        if ($stateChanged -or $heartbeatDue) {
            $body = @{ active = $isActive; source = $SourceName } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' `
                    -Body $body -TimeoutSec 5 | Out-Null
                if ($stateChanged) {
                    if ($isActive) {
                        Write-Log ('Mic ACTIVE (' + ($apps -join ', ') + ') -> reported to HA')
                    } else {
                        Write-Log ('Mic idle' + $note + ' -> reported to HA')
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
