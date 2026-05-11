# NeXiS Controller

The intelligence layer of the NeXiS ecosystem. A self-hosted AI assistant and central management plane that runs on a dedicated Linux host. It connects to NeXiS Hypervisor nodes, manages NeXiS Worker clients, and provides a single authenticated endpoint for the entire ecosystem.

---

## Ecosystem

```
NeXiS Controller  — central intelligence · SSO · management plane  ← you are here
        ↕ authenticated API + LLM tool calls
NeXiS Hypervisor  — one per compute node
        ↑
NeXiS Worker      — Android / Linux desktop client
```

| Repo | Role |
|------|------|
| **nexis-controller** | Central AI assistant · SSO provider · management plane |
| [nexis-hypervisor](https://github.com/santiagotoro2023/nexis-hypervisor) | Per-node compute management |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client |

Workers and Hypervisors authenticate against the Controller. One set of credentials reaches everything.

---

## Capabilities

**AI Assistant**
- Local LLM inference via Ollama — no data leaves the host
- Configurable model selection; swap models at runtime
- Persistent conversation memory across sessions and devices
- Voice interface: text-to-speech (Piper/GLaDOS TTS) and speech-to-text (Whisper)
- Hypervisor tool calls: the LLM can start, stop, create, snapshot, and inspect VMs on any paired hypervisor node, directly from conversation

**Web UI**
- Dark-themed, monospace interface with inline SVG icons throughout
- Sections: Chat, Remote, History, Memory, Schedules, Devices, Hypervisor, Users, Status
- Software update via the Status page — async background download, live progress polling

**SSO — Single Sign-On**
- Authenticate once; credentials are valid across hypervisor nodes and Workers
- Hypervisors delegate all login to the Controller — no separate per-node passwords
- Workers connect with the same Controller URL, username, and password

**Hypervisor Integration**
- Pair one or more NeXiS Hypervisor nodes (they self-register during their setup wizard)
- Aggregate VM and container view across all nodes
- Live resource metrics from all nodes
- Issue VM power actions from the Controller or via LLM tool calls

**Device Management**
- Remote desktop and command execution on connected Worker clients
- Real-time cross-device sync via SSE

**Automation**
- Task scheduler with cron-style triggers
- Home Assistant integration
- Code execution sandbox

---

## Requirements

- Debian 12 (Bookworm) or Ubuntu 22.04+ · x86_64
- Root / sudo access
- 8 GB RAM minimum (16 GB recommended for LLM inference)
- Internet connectivity (for installation and model download)

---

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-controller/main/install-nexis-controller.sh | sudo bash
```

The installer handles: system packages, Python environment, Ollama, Piper TTS, Whisper STT, GLaDOS voice model download, and the systemd service.

---

## Uninstallation

An interactive uninstall script prompts you individually about what data to keep:

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-controller/main/uninstall-nexis-controller.sh | sudo bash
```

Always removed: service, package, binary, install directory.

Prompted individually: voice/TTS models, Ollama models, registered devices, stored memories, chat history, config directory (TLS certs, credentials, schedules).

---

## First Access

1. Open `https://<host-ip>:8443` in a browser
2. Accept the self-signed certificate
3. Complete the setup wizard — set a username and password
4. Hypervisor nodes appear in **Hypervisor** as they pair via their own setup wizards

---

## Pairing a Hypervisor Node

Hypervisor nodes pair themselves automatically during their own setup wizard:

1. On the hypervisor machine, open `https://<node-ip>:8443`
2. Enter this Controller's URL, your username, and password
3. The hypervisor authenticates and self-registers
4. The node appears in **Hypervisor** in the Controller web UI

---

## Software Updates

Updates can be applied from the **Status** page in the web UI (Check & Update button). The download and install run in a background thread — the UI polls for progress and reloads automatically when the service restarts.

---

## CLI

The `nexis` command is installed to `/usr/local/bin/nexis` and provides quick service management from the terminal:

```bash
nexis --status      # service and web UI status
nexis --start       # start the service
nexis --stop        # stop the service
nexis --restart     # restart the service
nexis --logs [n]    # tail the last n lines of the journal (default 50)
nexis --web         # open the web UI in a browser
nexis               # interactive session (requires socat)
```

---

## API

All endpoints require `Authorization: Bearer <token>` unless marked **public**.

### Auth

| Endpoint | Description |
|----------|-------------|
| `POST /api/auth/login` | Authenticate; returns session token (public) |
| `GET /api/health` | Service liveness check (public) |

### AI

| Endpoint | Description |
|----------|-------------|
| `POST /api/chat` | AI conversation (SSE streaming) |
| `GET /api/models` | List available Ollama models |
| `POST /api/model` | Switch active model |
| `GET /api/history` | Conversation history |
| `GET /api/memories` | Persistent memory entries |

### Devices & Sync

| Endpoint | Description |
|----------|-------------|
| `GET /api/devices` | List registered Worker clients |
| `POST /api/device/register` | Register a Worker client (public) |
| `GET /api/sync` | Real-time cross-device state (SSE) |

### Hypervisor Integration

| Endpoint | Description |
|----------|-------------|
| `GET /api/hyp/nodes` | List paired hypervisor nodes |
| `POST /api/hyp/nodes` | Manually add a hypervisor node |
| `POST /api/hyp/nodes/register` | Hypervisor self-registration (public) |
| `DELETE /api/hyp/nodes/{id}` | Remove a paired node |
| `GET /api/hyp/vms` | All VMs across all paired nodes |
| `GET /api/hyp/metrics` | Live metrics from all nodes |
| `POST /api/hyp/nodes/{id}/vms/{vm_id}/{action}` | VM power action on a specific node |

### Automation & Integrations

| Endpoint | Description |
|----------|-------------|
| `GET /api/schedules` | Automation schedules |
| `GET /api/ha/*` | Home Assistant bridge |
| `POST /api/exec` | Remote code execution |

### System

| Endpoint | Description |
|----------|-------------|
| `POST /api/update` | Start background software update |
| `GET /api/update/status` | Poll update progress |

---

## Stack

| Layer | Technology |
|-------|------------|
| Daemon | Python 3.11 · stdlib `http.server` · `ThreadingMixIn` |
| LLM | Ollama (local inference) |
| Voice | Piper TTS (GLaDOS model) · Faster-Whisper STT |
| Storage | SQLite · `~/.local/share/nexis/` |
| Config | `~/.config/nexis/` (TLS certs, auth, schedules, integrations) |
| Auth | Bearer token · SHA-256 hashing · SQLite sessions |
| Realtime | Server-Sent Events (SSE) |
| Web UI | Inline HTML/CSS/JS served directly by the daemon |
| Service | systemd `nexis-controller.service` |
