# nexis-controller

Local AI assistant daemon running on your PC. Handles LLM inference, persistent memory, voice synthesis, speech recognition, web search, and scheduling. Accessed via a terminal CLI, a web browser, or the [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) Android app — all in sync in real time.

---

## Requirements

- Linux (systemd)
- Python 3.11+
- [Ollama](https://ollama.ai) with at least one model pulled
- `piper-tts` — `pip install piper-tts`
- `faster-whisper` — `pip install faster-whisper`
- `sounddevice` — `pip install sounddevice`
- `sox` (optional, for voice effects) — `sudo apt install sox`

---

## Install

```bash
git clone https://github.com/santiagotoro2023/nexis-controller
cd nexis-controller
sudo bash nexis_setup.sh
```

The setup script installs the daemon as a systemd service, downloads the GlaDOS voice model, and sets a default password (`Asdf1234!` — change it immediately via the web UI).

---

## Access

### Web UI

```
https://localhost:8443
```

The daemon generates a self-signed TLS certificate automatically on first start — accept the browser warning once. The Android app pins the certificate on first connection (TOFU) and trusts it permanently after that.

Default password: `Asdf1234!` — change it at **Status → Change password**.

### CLI

Connect via the Unix socket using the alias installed by the setup script:

```bash
nexis
```

Or directly:

```bash
socat - UNIX-CONNECT:/run/nexis/nexis.sock
```

---

## CLI commands

| Command | Description |
|---|---|
| `//help` | Show all commands |
| `//brief` | Morning briefing: time, weather, pending memories |
| `//memory list` | Show all stored facts |
| `//memory search <term>` | Search memories by keyword |
| `//memory add <text>` | Manually add a fact |
| `//memory clear` | Wipe all memories |
| `//voice on/off` | Toggle TTS output |
| `//voice speed <0.4–2.0>` | Adjust speaking rate |
| `//stt on/off` | Toggle microphone listening |
| `//stt mode wake/always` | Wake-word vs always-on mode |
| `//watch <service>` | Watch a systemd service for state changes |
| `//watch list` | Show active watchers |
| `//watch stop <service>` | Stop a watcher |
| `//index <path>` | Index a file or directory for RAG retrieval |
| `//model fast/deep/code` | Switch active LLM |
| `//schedule list` | Show scheduled tasks |
| `//history` | Print recent session history |
| `//reset` | Clear shared conversation history |
| `//clear` | Wipe all memories |

Anything without a `//` prefix is sent to the AI as a message.

---

## Exposing remotely (for the Android app)

The controller already runs HTTPS on port **8443** — no nginx or Certbot required. To make it reachable from outside your home network:

1. **Port-forward 8443** on your router to the PC running the controller.
2. Use your public IP or a dynamic-DNS hostname as the server URL in the Android app (e.g. `https://nexis.yourdomain.com:8443`).

If you want port 443 (no port number in the URL), either port-forward 443→8443 on your router, or put nginx in front:

```nginx
server {
    listen 443 ssl; http2 on;
    server_name nexis.yourdomain.com;
    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    proxy_buffering off;
    proxy_read_timeout 300s;
    location / { proxy_pass https://127.0.0.1:8443; proxy_ssl_verify off; }
}
```

> The self-signed cert is fine for the Android app (TOFU pinning). Browser users will see a warning on first visit only.

---

## Wake word (always-on "Hey Nexis" on Android)

The Android app supports always-on wake word detection via [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx), which runs entirely on-device.

**No setup required.** The app downloads the detection model (~15 MB) automatically on first use. No accounts, no API keys, no extra files.

To enable: open Settings in the app → toggle "hey nexis" on. A persistent notification appears while listening.

---

## Managing the service

```bash
sudo systemctl status nexis-daemon
sudo systemctl restart nexis-daemon
sudo journalctl -u nexis-daemon -f      # live logs
```

---

## API

All endpoints require a session cookie (browser) **or** a `Authorization: Bearer <token>` header (Android app / scripts).

**Get a Bearer token:**
```bash
curl -k -X POST https://localhost:8443/api/token \
  -H 'Content-Type: application/json' \
  -d '{"password":"YourPassword"}'
# → {"token": "abc123..."}
```

**Use the token:**
```bash
curl -k https://localhost:8443/api/models \
  -H 'Authorization: Bearer abc123...'
```

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/token` | Get Bearer token (password in body, no auth needed) |
| `POST` | `/api/chat` | Send message → SSE token stream |
| `POST` | `/api/chat/abort` | Abort current generation |
| `GET` | `/api/history` | Full conversation history (user + assistant) |
| `GET` | `/api/sync` | SSE stream — `{typing, hist_len}` events for cross-device sync |
| `POST` | `/api/clear` | Clear conversation history and disconnect CLI sessions |
| `GET` | `/api/models` | List LLM models and which is active |
| `POST` | `/api/model` | Switch model `{"model":"fast"}` |
| `GET` | `/api/voice` | Voice status |
| `POST` | `/api/voice` | Enable/disable TTS `{"on":true}` |
| `GET` | `/api/audio/{id}` | Fetch a TTS audio chunk (WAV) |
| `GET` | `/api/memories` | List memories |
| `POST` | `/api/memories` | Add / delete / clear memories |
| `GET` | `/api/schedules` | List scheduled tasks |
| `POST` | `/api/schedules` | Add / delete / toggle / run a schedule |
