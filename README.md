# Nexis Controller

Local AI assistant and device management hub for Linux. Handles LLM inference via Ollama, persistent memory, voice synthesis via Piper, speech recognition via Whisper, scheduled tasks, desktop automation, a sandboxed code interpreter, and real-time system monitoring. Accessed via a terminal CLI, web browser, the [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) Android/desktop app, or a connected [nexis-hypervisor](https://github.com/santiagotoro2023/nexis-hypervisor) node.

Part of the Nexis ecosystem.

---

## Requirements

- Linux (systemd)
- Python 3.11+
- [Ollama](https://ollama.ai) with at least one model pulled
- `pip install piper-tts faster-whisper sounddevice psutil`
- `sudo apt install sox ffmpeg xdotool wmctrl` (optional -- voice effects, desktop automation)

---

## Install

```bash
git clone https://github.com/santiagotoro2023/nexis-controller
cd nexis-controller
sudo bash nexis_setup.sh
```

Sets up a systemd service, downloads the voice model, generates a self-signed TLS cert. On first access the web UI walks you through setting a password and configuring the node.

---

## Access

| Client | Address |
|---|---|
| Web UI | `https://localhost:8443` |
| CLI | `nexis` (after install) |
| Android / Desktop | Set URL to `https://<your-ip>:8443` in the app |

The self-signed cert is auto-pinned (TOFU) by the apps on first connection.

---

## CLI Commands

| Command | Description |
|---|---|
| `//brief` | Morning briefing |
| `//memory list/search/add/clear` | Manage persistent facts |
| `//voice on/off` | Toggle TTS |
| `//stt on/off` | Toggle microphone (Whisper) |
| `//stt mode wake/always` | Wake-word vs always-on |
| `//model fast/deep/code` | Switch active LLM |
| `//schedule list/add/delete/run` | Manage scheduled tasks |
| `//history` | Recent session history |
| `//reset` | Clear shared conversation |
| `//help` | Full command reference |

Anything without `//` is sent to the AI.

---

## Models

| Key | Default model | Use |
|---|---|---|
| `fast` | `qwen2.5:14b` | Everyday chat |
| `deep` | 22B GGUF | Complex reasoning |
| `code` | `qwen3-coder-next` | Code tasks |
| `vision` | `qwen2.5vl:7b` | Image / screenshot analysis |

Switch with `//model <key>` from any client. Switching affects all connected devices instantly.

---

## Desktop Automation

The daemon can control the desktop it runs on. Send actions via `POST /api/desktop`:

| Action | Description |
|---|---|
| `screenshot` | Capture screen and analyse with vision model |
| `mouse_move / click / double_click` | Mouse control |
| `type_text / key_press` | Keyboard input |
| `open` | Launch app or URL |
| `clip / clip_read` | Write or read clipboard |
| `notify` | Desktop notification |
| `volume` | Set output volume |
| `lock / sleep` | Lock screen or suspend |

---

## Code Interpreter

Execute Python, Bash, or Node.js in a sandboxed subprocess:

```bash
curl -sk -X POST https://localhost:8443/api/exec \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"lang":"python","code":"print(2**32)","timeout":10}'
```

---

## Hypervisor Integration

When a Nexis Hypervisor node registers itself (via `POST /api/devices/register`), it appears in the **Hypervisor** section of the web UI and in the worker apps. The controller:

- Displays live VM and container counts, CPU/RAM/disk from the node
- Proxies power commands to the hypervisor via `POST /api/hv/*`
- Relays natural language commands from the worker apps to the hypervisor

---

## API Reference

All endpoints require `Authorization: Bearer <token>` except `/api/token` and `/api/ping`.

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/token` | Exchange password for Bearer token |
| `GET` | `/api/ping` | Unauthenticated health check |
| `GET` | `/api/system/info` | Hostname, version, build string |
| `POST` | `/api/chat` | Send message -- SSE token stream |
| `GET` | `/api/sync` | SSE -- typing state and alert events |
| `GET` | `/api/history` | Conversation history |
| `GET` | `/api/models` | List models |
| `POST` | `/api/model` | Switch model |
| `GET` | `/api/devices` | List registered devices (workers + hypervisor) |
| `POST` | `/api/device/register` | Register a worker device |
| `POST` | `/api/devices/register` | Register a hypervisor node |
| `POST` | `/api/devices/status` | Hypervisor live status push |
| `GET` | `/api/hv/*` | Proxy GET to registered hypervisor |
| `POST` | `/api/hv/*` | Proxy POST to registered hypervisor |
| `GET` | `/api/monitor` | Live CPU / memory / disk |
| `POST` | `/api/desktop` | Execute desktop action |
| `POST` | `/api/exec` | Run code in sandbox |
| `GET` | `/api/schedules` | List schedules |
| `POST` | `/api/schedules` | Add / delete / toggle schedule |

---

## Service Management

```bash
sudo systemctl status nexis-daemon
sudo systemctl restart nexis-daemon
sudo journalctl -u nexis-daemon -f
```

---

## Versioning

`NX-CTL · BUILD 1.0.0` -- tags follow `vMAJOR.MINOR.PATCH`. See [nexis-hypervisor VERSIONING.md](https://github.com/santiagotoro2023/nexis-hypervisor/blob/main/.github/VERSIONING.md).

## Releases

Each tagged release produces `nexis-controller_X.X.X_amd64.deb`.

### Required GitHub Secrets

| Secret | Value |
|---|---|
| None required | The .deb build uses no signing secrets |
