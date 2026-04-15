# nexis-controller

Local AI assistant daemon for Linux. Handles LLM inference via Ollama, persistent memory with semantic search, voice synthesis (GlaDOS/HAL9000-style via Piper), speech recognition via Whisper, scheduled tasks, desktop automation, a sandboxed code interpreter, and real-time system monitoring. Accessed via a terminal CLI, web browser, or the [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) Android/desktop app — all in sync in real time.

---

## Requirements

- Linux (systemd)
- Python 3.11+
- [Ollama](https://ollama.ai) with at least one model pulled
- `pip install piper-tts faster-whisper sounddevice psutil`
- `sudo apt install sox ffmpeg xdotool wmctrl` (optional — voice effects, desktop automation)

---

## Install

```bash
git clone https://github.com/santiagotoro2023/nexis-controller
cd nexis-controller
sudo bash nexis_setup.sh
```

Sets up a systemd service, downloads the GlaDOS voice model, generates a self-signed TLS cert. Default password: `Asdf1234!` — change it immediately.

---

## Access

| Client | Address |
|---|---|
| Web UI | `https://localhost:8443` |
| CLI | `nexis` (alias) or `socat - UNIX-CONNECT:/run/nexis/nexis.sock` |
| Android / Desktop | Set URL to `https://<your-ip>:8443` in the app |

The self-signed cert is auto-pinned (TOFU) by the apps on first connection.

---

## CLI commands

| Command | Description |
|---|---|
| `//brief` | Morning briefing — time, pending memories |
| `//memory list/search/add/clear` | Manage persistent facts |
| `//voice on/off` | Toggle TTS |
| `//voice speed <0.4–2.0>` | Adjust speaking rate |
| `//stt on/off` | Toggle microphone (Whisper) |
| `//stt mode wake/always` | Wake-word vs always-on |
| `//model fast/deep/code` | Switch active LLM |
| `//schedule list/add/delete/run` | Manage scheduled tasks |
| `//watch <service>` | Watch a systemd service for state changes |
| `//index <path>` | Index files/directories for RAG retrieval |
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
| `code` | `qwen3-coder-next` | Code tasks — pairs with code interpreter |
| `vision` | `qwen2.5vl:7b` | Image/screenshot analysis |

Switch with `//model <key>` (CLI) or the model picker in any client. Switching affects all connected devices instantly.

---

## Desktop automation

The daemon can directly control the desktop it's running on. Clients (app, web, CLI) send actions via `POST /api/desktop`:

| Action | Arg | Description |
|---|---|---|
| `screenshot` | — | Capture screen → vision analysis |
| `region` | `x,y,w,h [prompt]` | Capture a region; optionally analyse with vision |
| `mouse_move` | `x,y` | Move cursor |
| `mouse_click` | `[x,y] [button]` | Click at position |
| `double_click` | `[x,y]` | Double-click |
| `type_text` | `<text>` | Type text |
| `key_press` | `<key>` | Press key/combo — e.g. `ctrl+c`, `Return`, `super` |
| `scroll` | `up/down [n]` | Scroll N clicks |
| `get_mouse_pos` | — | Return current X,Y |
| `find_window` | — | Return active window title |
| `open` | `<app or URL>` | Launch application or URL |
| `tab` | `<url>` | Open new browser tab |
| `clip` / `clip_read` | `<text>` | Write/read clipboard |
| `notify` | `<text>` | Send desktop notification |
| `volume` | `<0–150>` | Set output volume |
| `media` | `play/pause/next/previous` | Media control |
| `lock` / `sleep` | — | Lock screen / suspend |

Requires `xdotool` (mouse/keyboard), `wmctrl` (windows), `ffmpeg`/`scrot` (screenshots).

---

## Code interpreter

Execute code in a sandboxed subprocess. Memory-limited (512 MB), CPU-timeout enforced.

```bash
curl -sk https://localhost:8443/api/exec \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"lang":"python","code":"print(2**32)","timeout":10}'
# → {"stdout":"4294967296\n","stderr":"","exit_code":0,"runtime_ms":42}
```

Supported languages: `python`, `bash`/`sh`, `javascript`/`node`.

The AI (especially the code model) can write and sanity-check its own output by calling this automatically.

---

## System monitor

A background thread checks CPU, memory, and disk every 60 seconds. When a threshold is exceeded:
- All connected clients receive an `alert` event via `/api/sync` SSE
- Android/desktop apps show a notification
- If `ntfy_topic` is set in `~/.config/nexis/integrations.json`, a push notification fires via ntfy.sh

```bash
# Live stats
curl -sk https://localhost:8443/api/monitor -H "Authorization: Bearer <token>"
# → {"cpu":12.4,"mem":68.1,"disk":44.0,"thresholds":{"cpu":90,"mem":90,"disk":90}}

# Adjust thresholds
curl -sk -X POST https://localhost:8443/api/monitor/thresholds \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"cpu":85,"mem":85}'
```

---

## Speech-to-text (STT)

### Server-side (microphone on the controller)
Uses `faster-whisper` + `sounddevice`. Enable with `//stt on` or `POST /api/stt {"enabled":true}`.

### Remote STT (mic on client device)
The Android and desktop apps can send WAV audio to the daemon for transcription:

```
POST /api/stt/transcribe
Content-Type: audio/wav
Body: <raw WAV bytes>
→ {"text": "what you said"}
```

---

## Scheduled tasks

Tasks fire on a cron-like schedule and inject a prompt into the shared conversation — visible across all connected clients.

```bash
# Add a daily 8am briefing
curl -sk -X POST https://localhost:8443/api/schedules \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"action":"add","name":"Morning brief","expr":"daily 08:00","prompt":"//brief"}'
```

Supported expressions: `daily HH:MM`, `hourly [:MM]`, `weekly DAY HH:MM`.

---

## Memory

The daemon extracts facts from every conversation and stores them as embeddings (via `nomic-embed-text`). Relevant facts are injected into the system prompt automatically on each request. Deduplication uses cosine similarity (threshold 0.92).

```bash
GET  /api/memories          # list all
POST /api/memories          # {"action":"delete","id":5}
```

---

## External access (for the app)

Forward TCP **8443** on your router to the controller machine. Use your public IP or a dynamic-DNS hostname in the app. Test reachability:

```bash
curl -sk https://your-domain:8443/api/ping
# → {"ok":true}
```

---

## Managing the service

```bash
sudo systemctl status nexis-daemon
sudo systemctl restart nexis-daemon
sudo journalctl -u nexis-daemon -f
```

---

## API reference

All endpoints require `Authorization: Bearer <token>` (except `/api/token` and `/api/ping`).

**Get a token:**
```bash
curl -sk -X POST https://localhost:8443/api/token \
  -H "Content-Type: application/json" \
  -d '{"password":"YourPassword"}'
```

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/token` | Exchange password for Bearer token |
| `GET` | `/api/ping` | Unauthenticated health check |
| `POST` | `/api/chat` | Send message → SSE token stream |
| `POST` | `/api/chat/abort` | Abort current generation |
| `GET` | `/api/sync` | SSE — `{typing, hist_len}` + `{alert}` events |
| `GET` | `/api/history` | Full conversation history |
| `POST` | `/api/clear` | Clear history, disconnect CLI sessions |
| `GET` | `/api/models` | List models and active selection |
| `POST` | `/api/model` | Switch model `{"model":"code"}` |
| `GET` | `/api/voice` | Voice status |
| `POST` | `/api/voice` | Toggle TTS `{"on":true}` |
| `GET` | `/api/audio/{id}` | Fetch TTS audio chunk (WAV) |
| `GET` | `/api/memories` | List memories |
| `POST` | `/api/memories` | Add / delete memories |
| `GET` | `/api/schedules` | List scheduled tasks |
| `POST` | `/api/schedules` | Add / delete / toggle / run schedule |
| `GET` | `/api/health` | Dashboard metrics (model, uptime, memory count…) |
| `GET` | `/api/monitor` | Live CPU / memory / disk stats |
| `POST` | `/api/monitor/thresholds` | Set alert thresholds |
| `POST` | `/api/desktop` | Execute a desktop action |
| `POST` | `/api/exec` | Run code in sandbox → stdout/stderr |
| `POST` | `/api/stt/transcribe` | Transcribe WAV bytes via Whisper |
| `GET` | `/api/stt/stream` | SSE stream of STT results |
| `GET` | `/api/devices` | List registered devices |
| `POST` | `/api/device/register` | Register a client device |
| `GET` | `/api/commands/pending` | Poll pending commands for a device |
| `POST` | `/api/device/command` | Queue a command for a device |
| `POST` | `/api/wol` | Send Wake-on-LAN packet |
| `GET` | `/api/history/sessions` | List past chat sessions |
| `POST` | `/api/history/load` | Load a past session into current conversation |
