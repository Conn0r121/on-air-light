# on-air-light

An inconspicuous "on air" light for my office doorframe. A WS2812B LED strip
(driven by an ESP8266 D1 Mini running ESPHome) turns on when I'm either in a
scheduled Outlook/Microsoft 365 meeting **or** actively on a mic (Discord,
Teams, Zoom, …) on my Windows PC — and stays completely dark otherwise.

```
Outlook / M365 calendar ──(Graph API poll)──┐
                                            ├── Home Assistant ──(WiFi)── ESPHome D1 Mini + LED strip
Windows PC mic usage ──(webhook POST)───────┘        (Pi, Docker)
```

- **Home Assistant** (Docker on a Raspberry Pi, deployed as a Portainer stack)
  runs the `calendar busy OR mic active → light` automation.
- **Calendar trigger:** the MS365 Calendar integration polls the Graph API for
  the current meeting state.
- **Mic trigger:** a tiny PowerShell watcher on the PC monitors the microphone
  ConsentStore registry keys and POSTs state changes to an HA webhook.
- Until the hardware arrives, `input_boolean.on_air_test` stands in for the
  light so the whole pipeline is testable in the HA UI.

## Repo layout

| Path | Purpose |
|------|---------|
| [docker/docker-compose.yml](docker/docker-compose.yml) | Portainer stack: Home Assistant + ESPHome dashboard |
| [homeassistant/](homeassistant/) | HA config: automations, webhook, test helpers |
| [esphome/on-air-light.yaml](esphome/on-air-light.yaml) | D1 Mini + WS2812B firmware, ready to flash |
| [windows-mic-detector/](windows-mic-detector/) | Mic watcher script + startup-task installer |
| [docs/setup.md](docs/setup.md) | **Step-by-step setup guide** |

## Getting started

Follow [docs/setup.md](docs/setup.md). No real credentials live in this repo:
secrets go in `esphome/secrets.yaml` (see `secrets.yaml.example`), which is
gitignored.
