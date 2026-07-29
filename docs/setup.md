# On-Air Light — Setup Guide

End-to-end setup, in the order you should do it. Everything except Part 6 can
be done before the hardware arrives.

- [Part 1 — Deploy the Portainer stack](#part-1--deploy-the-portainer-stack)
- [Part 2 — Load the Home Assistant config](#part-2--load-the-home-assistant-config)
- [Part 3 — Microsoft 365 calendar integration](#part-3--microsoft-365-calendar-integration)
- [Part 4 — Windows mic detector](#part-4--windows-mic-detector)
- [Part 5 — End-to-end test (no hardware)](#part-5--end-to-end-test-no-hardware)
- [Part 6 — When the hardware arrives](#part-6--when-the-hardware-arrives)
- [Troubleshooting](#troubleshooting)

---

## Part 1 — Deploy the Portainer stack

1. On the Pi, create the config directories the stack bind-mounts:

   ```bash
   sudo mkdir -p /srv/on-air-light/homeassistant /srv/on-air-light/esphome
   ```

2. In Portainer: **Stacks → Add stack → Repository**.
   - Repository URL: this repo's GitHub URL.
   - Compose path: `docker/docker-compose.yml`.

3. Before deploying, review the `EDIT` comments in
   [docker-compose.yml](../docker/docker-compose.yml) — timezone and volume
   paths — and adjust via Portainer's environment/compose editing if yours
   differ.

4. Deploy. After a minute or two:
   - Home Assistant: `http://<pi-ip>:8123` — walk through onboarding (create
     your account, name the home).
   - ESPHome dashboard: `http://<pi-ip>:6052`.

## Part 2 — Load the Home Assistant config

1. Copy the three files from this repo's `homeassistant/` directory into
   `/srv/on-air-light/homeassistant/` on the Pi, replacing the auto-generated
   `configuration.yaml`. From your PC:

   ```bash
   scp homeassistant/*.yaml pi@<pi-ip>:/tmp/
   ssh pi@<pi-ip> "sudo mv /tmp/configuration.yaml /tmp/automations.yaml /tmp/input_boolean_test.yaml /srv/on-air-light/homeassistant/"
   ```

2. Restart the container (Portainer → Containers → `homeassistant` → Restart).

3. Verify: in HA, **Developer Tools → States** should now show
   `input_boolean.on_air_test`, `input_boolean.mic_active_laptop`, and
   `input_boolean.mic_active_gaming`. Add them to a dashboard so you can watch
   them flip during testing.

## Part 3 — Microsoft 365 calendar integration

Meeting detection uses the [MS365 Calendar](https://github.com/RogerSelwyn/MS365-Calendar)
custom integration, which polls the Graph API. It needs an Azure app
registration (free) and HACS (the custom-integration store).

### 3a. Azure app registration

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID →
   App registrations → New registration**. Sign in with your work (M365)
   account.
2. Name: `Home Assistant On-Air` (anything works).
3. Supported account types: **Accounts in this organizational directory only**.
4. Redirect URI: platform **Web**, value:
   `https://login.microsoftonline.com/common/oauth2/nativeclient`
5. Register, then from the **Overview** page copy:
   - **Application (client) ID**
   - **Directory (tenant) ID**
6. **Certificates & secrets → New client secret**. Copy the secret **Value**
   immediately (it's only shown once). Note the expiry you chose — you'll need
   to rotate it then.
7. **API permissions → Add a permission → Microsoft Graph → Delegated
   permissions** → add `Calendars.Read`.

> **Work-tenant caveat:** on a corporate tenant, the sign-in step later may
> stop with *"Need admin approval."* If so, ask IT to grant admin consent to
> the app registration for `Calendars.Read` (delegated, read-only).

### 3b. Install HACS

```bash
ssh pi@<pi-ip>
docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
```

Restart the HA container, then in HA: **Settings → Devices & Services → Add
Integration → HACS** and follow the GitHub device-login flow.

### 3c. Add the integration

1. **HACS → search "Microsoft 365 Calendar" → Download**, then restart HA.
2. **Settings → Devices & Services → Add Integration → Microsoft 365
   Calendar**. Enter an account name (e.g. `work`), the client ID, and client
   secret from 3a.
3. The flow shows a login link: open it, sign in, accept the consent prompt.
   You'll land on a blank page — copy that page's **full URL** and paste it
   back into the HA dialog to finish.
4. Find your calendar entity under **Developer Tools → States** (filter
   `calendar.`) — e.g. `calendar.work_calendar`. If it's missing, edit
   `ms365_calendars_<account>.yaml` (created in the HA config directory), set
   `track: true` for your calendar, and restart HA.

### 3d. Point the automation at it

Edit `/srv/on-air-light/homeassistant/automations.yaml` and replace
`calendar.on_air_calendar` with your real entity id — it appears **twice**
(once in the triggers, once in the template). Then reload automations
(**Developer Tools → YAML → Automations**).

## Part 4 — Windows mic detector

The watcher can run on any number of PCs (laptop, gaming PC, ...). All of them
POST to the same webhook; each identifies itself with a `source` name that maps
to its own `input_boolean.mic_active_<source>` in HA. The repo ships with two
sources allowed: `laptop` and `gaming` (to add more, see the comment at the top
of [automations.yaml](../homeassistant/automations.yaml)).

Do the following on **each** PC:

1. Clone (or copy) this repo onto the PC.
2. Edit `windows-mic-detector/mic_watcher.ps1` at the top:
   - `$WebhookUrl`: `http://<pi-ip>:8123/api/webhook/mic_active` with your
     Pi's real IP.
   - `$SourceName`: this PC's name — `laptop` or `gaming`.
3. First, prove the webhook path works with a manual POST from PowerShell:

   ```powershell
   Invoke-RestMethod -Uri 'http://<pi-ip>:8123/api/webhook/mic_active' -Method Post -ContentType 'application/json' -Body '{"active": true, "source": "laptop"}'
   ```

   `input_boolean.mic_active_laptop` (and `on_air_test`, via the light
   automation) should flip on in HA. Send `{"active": false, "source": "laptop"}`
   to flip it back.

4. Run the watcher interactively:

   ```powershell
   cd windows-mic-detector
   .\mic_watcher.ps1
   ```

   Join a Discord/Teams/Zoom call or just open Sound Recorder and hit record —
   within a couple of seconds the console logs `Mic ACTIVE (...)` and the HA
   booleans flip. Stop recording and they flip back.

5. Once happy, install it as a background task (no admin prompt):

   ```powershell
   .\install-startup-task.ps1
   ```

   It starts immediately, runs with no visible window (via a small VBScript
   launcher), and re-starts at every login. Logs go to
   `%LOCALAPPDATA%\on-air-light\mic_watcher.log`. To remove:
   `.\install-startup-task.ps1 -Uninstall`.

## Part 5 — End-to-end test (no hardware)

With `input_boolean.on_air_test` on a dashboard:

- **Mic path:** start/stop a mic-using app (on each PC) → `on_air_test`
  follows within a few seconds.
- **Calendar path:** create a short Outlook meeting starting now →
  `on_air_test` turns on within a minute or so (the integration polls Graph),
  and off after the meeting ends.
- **OR logic:** with a meeting in progress, stopping the mic must NOT turn the
  light off, and vice versa.

## Part 6 — When the hardware arrives

### 6a. Wire the strip

| WS2812B strip | D1 Mini pin |
|---------------|-------------|
| 5V            | 5V          |
| GND           | G           |
| DIN (data in) | RX (GPIO3)  |

- Connect to the **DIN** end of the strip (arrows on the strip point away from
  the input).
- **Power:** through the D1 Mini's USB port is fine for a short strip (~10
  LEDs) at the automation's default 60% brightness. Each LED can draw up to
  ~60 mA at full white — if you ever go longer/brighter, feed the strip's
  5V/GND directly from a beefier 5V supply and keep all grounds common.
- Optional but good practice: a 330–470 Ω resistor in the data line and a
  470–1000 µF capacitor across 5V/GND at the strip.

### 6b. Flash the firmware

1. Copy `esphome/on-air-light.yaml` into `/srv/on-air-light/esphome/` on the
   Pi. Copy `esphome/secrets.yaml.example` to `secrets.yaml` alongside it and
   fill in real values (or use the **Secrets** editor in the dashboard,
   top-right menu).
2. In the ESPHome dashboard (`http://<pi-ip>:6052`) the `on-air-light` node
   appears. First flash must be over USB — two options:
   - **From your PC (easiest):** dashboard → ⋮ → **Install → Manual
     download → Modern format**. Then plug the D1 Mini into your PC, open
     [web.esphome.app](https://web.esphome.app) in Chrome/Edge, connect, and
     install the downloaded `.bin`. (Clone boards usually need the CH340 USB
     driver on Windows.)
   - **From the Pi:** plug the board into the Pi, uncomment the `devices:`
     mapping in `docker/docker-compose.yml`, redeploy the stack, then
     dashboard → Install → the serial port.
3. Every update after this is over-the-air — just hit Install in the dashboard.

### 6c. Adopt it in Home Assistant

Once the device joins WiFi, HA discovers it automatically: **Settings →
Devices & Services** shows the ESPHome device — click **Configure** and enter
the API encryption key from your `secrets.yaml`. Note the light's entity id on
the device page (e.g. `light.on_air_light`).

### 6d. Swap the automation target

In `/srv/on-air-light/homeassistant/automations.yaml`, in the
`on_air_light_control` automation: delete the `input_boolean` action lines and
uncomment the `light.turn_on` / `light.turn_off` blocks (adjusting the entity
id if yours differs). Reload automations. Done — the test helper can be
removed whenever you like.

## Troubleshooting

- **`on_air_test` never flips for meetings** — check the calendar entity state
  directly in Developer Tools → States during a meeting. All-day events also
  count as "busy"; to ignore them, extend the template to
  `is_state('calendar.X', 'on') and not state_attr('calendar.X', 'all_day')`.
- **Webhook POST returns 200 but nothing happens** — webhook IDs must match
  exactly (`mic_active`), the payload's `source` must be one of the allowed
  names in the automation's guard condition (`laptop`, `gaming`), and the
  automation must be loaded (Settings → Automations should list both). HA
  returns 200 even for unknown webhook ids and dropped sources.
- **Mic never reads active** — check the log file, then inspect
  `HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone`
  in `regedit` while on a call: some subkey should have `LastUsedTimeStop = 0`.
- **ESPHome device offline in HA after flashing** — it may have failed to join
  WiFi; look for the `On-Air-Light Setup` hotspot, connect, and fix the
  credentials in the captive portal.
- **Light flickers or shows wrong colors** — confirm DIN is on RX/GPIO3, and
  the strip is genuinely WS2812B (`variant: WS2812X`, `type: GRB` in
  [on-air-light.yaml](../esphome/on-air-light.yaml)).
