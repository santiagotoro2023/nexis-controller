# nexis-controller

Local AI assistant daemon running on your PC. Handles LLM inference, memory, voice synthesis, speech recognition, and scheduling. Accessed via a terminal CLI or web browser — and remotely by the [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) Android app.

---

## Requirements

- Linux (systemd)
- Python 3.11+
- [Ollama](https://ollama.ai) with at least one model pulled
- Piper TTS 1.4.2 (`pip install piper-tts`)
- faster-whisper (`pip install faster-whisper`)
- sounddevice (`pip install sounddevice`)

---

## Install

```bash
git clone https://github.com/santiagotoro2023/nexis-controller
cd nexis-controller
sudo bash nexis_setup.sh
```

The setup script installs the daemon as a systemd service, downloads the GlaDOS voice model, and sets a default password (`Asdf1234!` — change it immediately).

---

## CLI usage

Connect via the Unix socket:

```bash
socat - UNIX-CONNECT:/run/nexis/nexis.sock
```

Or use the alias the setup script installs:

```bash
nexis
```

### Built-in commands

| Command | What it does |
|---|---|
| `//help` | Show all commands |
| `//brief` | Morning briefing: time, weather, pending memories |
| `//memory list` | Show all stored facts |
| `//memory search <term>` | Search memories by keyword |
| `//memory add <text>` | Add a fact manually |
| `//memory clear` | Wipe all memories |
| `//voice on/off` | Toggle TTS output |
| `//voice speed <0.4–2.0>` | Adjust speaking speed (default 0.85) |
| `//stt on/off` | Toggle microphone listening |
| `//stt mode wake/always` | Wake-word mode vs always-on |
| `//watch <service>` | Watch a systemd service for state changes |
| `//watch list` | Show active watchers |
| `//watch stop <service>` | Stop a watcher |
| `//index <path>` | Index a file or directory for RAG retrieval |
| `//model fast/deep/code` | Switch LLM model |
| `//schedule list` | Show scheduled tasks |
| `//history` | Print recent chat history |
| `//clear` | Clear current session history |

Anything without `//` prefix is sent to the AI as a normal message.

---

## Web UI

Open `http://localhost:8080` in a browser. Default password: `Asdf1234!`.

Change the password at **Status → Change password** or via the CLI:

```bash
# POST to the API directly
curl -b "$(cat /tmp/nexis_cookie)" -X POST http://localhost:8080/api/passwd \
  -d 'password=NewPass&confirm=NewPass'
```

---

## Exposing remotely (for nexis-worker)

To use the Android app over the internet you need HTTPS. Quick setup with nginx:

```bash
sudo apt install nginx certbot python3-certbot-nginx
```

Create `/etc/nginx/sites-available/nexis`:

```nginx
server {
    listen 80; server_name your.domain.com;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl; http2 on;
    server_name your.domain.com;
    ssl_certificate     /etc/letsencrypt/live/your.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your.domain.com/privkey.pem;
    proxy_buffering off; proxy_read_timeout 300s;
    proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto $scheme;
    location / { proxy_pass http://127.0.0.1:8080; }
}
```

```bash
sudo certbot --nginx -d your.domain.com
sudo ln -s /etc/nginx/sites-available/nexis /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Firewall — block direct port 8080, allow 443:

```bash
sudo ufw allow 443/tcp && sudo ufw deny 8080/tcp && sudo ufw --force enable
```

---

## Managing the service

```bash
sudo systemctl status nexis-daemon
sudo systemctl restart nexis-daemon
sudo journalctl -u nexis-daemon -f      # live logs
```

---

## API (for developers / Android app)

All endpoints require a session cookie **or** a Bearer token.

**Get a Bearer token** (used by the Android app):
```bash
curl -X POST https://your.domain.com/api/token \
  -H 'Content-Type: application/json' \
  -d '{"password":"YourPassword"}'
# → {"token": "abc123..."}
```

**Use the token:**
```bash
curl https://your.domain.com/api/models \
  -H 'Authorization: Bearer abc123...'
```

Key endpoints:

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/token` | Get Bearer token (no auth needed, password in body) |
| `POST` | `/api/chat` | Send message → SSE token stream |
| `POST` | `/api/chat/abort` | Abort current generation |
| `GET` | `/api/models` | List available LLM models |
| `POST` | `/api/model` | Switch model `{"model":"fast"}` |
| `GET` | `/api/voice` | Voice status |
| `POST` | `/api/voice` | Enable/disable TTS `{"on":true}` |
| `GET` | `/api/audio/{id}` | Fetch a TTS audio chunk (WAV, one-time) |
| `GET` | `/api/stt/stream` | SSE — push of speech-to-text result (30s timeout) |
| `GET` | `/api/memories` | List memories |
| `POST` | `/api/memories` | Add/delete/clear memories |
| `GET` | `/api/schedules` | List scheduled tasks |
| `POST` | `/api/schedules` | Add/delete/toggle/run a schedule |
