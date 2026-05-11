# NeXiS Controller

The intelligence layer of the NeXiS ecosystem. A self-hosted AI assistant and central management plane that runs on a dedicated Linux host. It connects to NeXiS Hypervisor nodes, manages NeXiS Worker clients, and provides a single authenticated endpoint for the entire ecosystem.

---

## Ecosystem

```
NeXiS Controller  — central intelligence · SSO · management plane  ← you are here
        ↕ authenticated API + LLM tool calls
NeXiS Hypervisor  — one per compute node
        ↑
NeXiS Worker      — Android / Linux / Windows desktop client
```

| Repo | Role |
|------|------|
| **nexis-controller** | Central AI assistant · SSO provider · management plane |
| [nexis-hypervisor](https://github.com/santiagotoro2023/nexis-hypervisor) | Per-node compute management |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client |

Workers and Hypervisors authenticate against the Controller. One set of credentials reaches everything.

---

## What's New in v1.0.20

- **Memory keyword search** — `_memories_search()` runs on every incoming message; relevant memories are retrieved by keyword and injected as context before the LLM sees the query
- **Auto-extract memories** — 12 regex patterns scan user messages in real time and automatically persist personal facts (name, job title, location, preferences, dislikes, email, phone, role)
- **Previous conversation context** — recent session summaries are included as context for new conversations, giving the AI continuity across sessions
- **Tools & Capabilities admin tab** — new admin-only sidebar section; lists all 18 built-in capabilities; full CRUD for custom shell, Python, and HTTP tools; custom tools are injected into the AI system prompt and can be invoked by name mid-conversation
- **noVNC remote screen** — every device card on the Devices page now has a **SCREEN** button; clicking it sends a `start_vnc` command to the target Worker, starts a `websockify` subprocess on the Controller host (WebSocket → VNC TCP proxy), and serves an inline noVNC viewer; requires `pip3 install websockify` on the Controller host
- **Delete conversations** — the History page has a per-session Delete button
- **Admin data filter** — `/devices` and `/history` pages include a user-selector dropdown for admin accounts (driven by `?user=` query parameter)
- **Secure first-run password** — a 50-character random password is generated on first boot, written to `/tmp/nexis_first_run_password.txt`, and displayed prominently by the install script
- **Vision model changed to `moondream`** — replaces `qwen2.5vl:7b`; uses the `/api/generate` endpoint directly

---

## What It Is

NeXiS Controller is a single Python daemon (`nexis_daemon.py`) that serves as:

- A **local AI assistant** backed by Ollama — chat, memory, voice I/O, scheduled briefings
- A **device management hub** for all NeXiS Workers and Hypervisors registered to it
- An **SSO provider** — Workers and Hypervisors delegate all login to the Controller
- A **remote desktop control** plane for connected Worker devices

The daemon runs as a systemd service and exposes an HTTPS web UI on port 8443, backed by a self-signed TLS certificate generated on first run.

---

## Architecture

| Layer | Technology |
|-------|------------|
| Daemon | Python 3 · stdlib `http.server` + `ThreadingMixIn` |
| TLS | Self-signed certificate, auto-generated on first run |
| LLM inference | Ollama (local — no data leaves the host) |
| Voice synthesis | Piper TTS (GLaDOS voice model) |
| Voice input | Faster-Whisper STT |
| Storage | SQLite · `~/.local/share/nexis/` |
| Config | `~/.config/nexis/` (TLS certs, schedules, integrations) |
| Auth | Bearer token · SHA-256 password hashing · SQLite sessions |
| Realtime | Server-Sent Events (SSE) |
| Web UI | Inline HTML/CSS/JS served directly by the daemon |
| Service | systemd `nexis-controller.service` |

---

## Features

### AI Assistant
- Local LLM inference via Ollama — models: `qwen2.5:14b` (fast), `moondream` (vision, uses `/api/generate`), Omega-Darker 22B (deep/fallback)
- Streaming token output in both CLI and web UI
- Automatic model routing — switches to the deep model if the fast model declines a query
- Web search via DuckDuckGo (no API key required)
- File pipeline: read, diff, edit, git commit, push
- Image analysis via `moondream` (inline path or upload)
- System probe: CPU / RAM / GPU / processes / network
- Desktop actions: open URLs, launch/close apps, send desktop notifications, copy to clipboard

### Conversation & Memory
- Per-user chat history with full session continuity across CLI and web
- Persistent memory stored in SQLite — survives restarts and reinstalls
- **Keyword memory search** (`_memories_search()`) — on every user message, memories are searched by keyword and injected as context automatically
- **Auto-extraction** — 12 regex patterns parse user messages for personal facts (name, job, location, preferences, dislikes, email, phone, role) and persist them without any explicit command
- **Previous conversation context** — recent sessions are summarised and included as background context for the current conversation
- Memory backup/restore on uninstall
- `//memory`, `//forget <term>`, `//clear` session commands

### Voice Interface
- Text-to-speech via Piper TTS with GLaDOS voice model (high + medium quality)
- Speech-to-text via Faster-Whisper; supports wake word, open mic, and STT-on-demand
- Disabled by default — enable with `//voice on` / `//stt on`

### User Management & RBAC
- **admin** role: full access to all data, all devices, all users
- **user** role: sees only their own chat history, memory, and devices
- Admin can filter the Devices, History, and Memory pages by user
- Creator account password is a 50-character random string generated on first run, written to `/tmp/nexis_first_run_password.txt`, and displayed by the install script; change it immediately via `//passwd` or the web UI

### Device Management
- Workers register via `POST /api/devices/register` with a device ID, name, type, and URL
- Controller queues commands for Workers; Workers poll `GET /api/devices/commands`
- **noVNC remote screen** — **SCREEN** button on each device card on the Devices page; sends `start_vnc` to the Worker, Controller starts a `websockify` WebSocket→TCP proxy, serves an inline noVNC viewer; requires `pip3 install websockify` on the Controller host
- Remote desktop control via the **Remote** page
- Real-time cross-device sync via SSE

### Tools & Capabilities
- Admin-only **Tools & Capabilities** sidebar tab (v1.0.20+)
- Lists all 18 built-in capabilities (web search, system probe, file edit, VM control, etc.)
- Full CRUD for custom tools:
  - **Shell tools** — arbitrary shell commands exposed to the AI
  - **Python tools** — Python snippets the AI can execute
  - **HTTP tools** — outbound HTTP calls the AI can make
- Custom tool definitions are injected into the AI system prompt; the AI can call them by name mid-conversation

### Hypervisor Integration
- Hypervisor nodes self-register at `POST /api/hyp/nodes/register` during their setup wizard
- Controller polls each node's `GET /api/status` for live metrics (CPU, memory, disk, VM/container counts)
- Aggregate VM and container view across all paired nodes
- VM power actions (start, stop, reboot, force-stop) from the Controller UI or via LLM tool calls
- LLM can directly control VMs mid-conversation using `[HYP: ...]` tool tags

### Scheduled Tasks
- Cron-style task scheduler accessible via `//schedule` in CLI and the **Schedules** page in the web UI
- NeXiS can create its own schedules via `[SCHED: ...]` response tags
- Briefings, reminders, and automated AI queries on a timer

### Software Updates
- One-click update from the **Status** page in the web UI
- Download and install run in a background thread; UI polls for progress and reloads automatically

---

## Requirements

- Debian 12 (Bookworm) or Ubuntu 22.04+ · x86_64
- Root / sudo access for installation
- 8 GB RAM minimum (16 GB recommended for local LLM inference)
- Internet connection for installation and initial model download
- `websockify` Python package required for the noVNC remote screen feature (`pip3 install websockify`)

---

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-controller/main/install-nexis-controller.sh | sudo bash
```

The installer:
1. Downloads and installs the latest `.deb` release package
2. Downloads the GLaDOS Piper TTS voice model (~63 MB)
3. Starts the `nexis-controller` systemd service
4. Waits for the daemon to initialise
5. Reads `/tmp/nexis_first_run_password.txt` (if present) and displays the generated admin credentials prominently

**First-run credential display:**
```
╔══════════════════════════════════════════════╗
║       NeXiS Controller First-Run Login        ║
╠══════════════════════════════════════════════╣
  Username: admin
  Password: <50-char random password>
╚══════════════════════════════════════════════╝

Store these credentials securely — the password will not be shown again.
```

Change the password immediately after first login via `//passwd` in the CLI or the web UI.

---

## Uninstallation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-controller/main/uninstall-nexis-controller.sh | sudo bash
```

The script prompts individually about what to keep: voice models, Ollama models, registered devices, memories, chat history, config directory.

---

## First Access

1. Open `https://<host-ip>:8443` in a browser
2. Accept the self-signed TLS certificate
3. Log in with the credentials displayed during install
4. Change your password via `//passwd` or the web UI Settings page
5. Hypervisor nodes appear in **Hypervisor** as they pair via their own setup wizards

---

## Authentication

The Controller uses **session cookies** in the web UI and **Bearer tokens** for API access (including Workers and Hypervisors). Tokens are 90-day TTL and stored in SQLite.

- The first account (creator) password is a 50-character random string generated on first run and written to `/tmp/nexis_first_run_password.txt`
- The file is removed after it has been read
- Change it via `//passwd` in the CLI or the Settings page in the web UI
- Subsequent accounts are created via the **Users** admin page

### RBAC

| Role | Capabilities |
|------|-------------|
| `admin` | Full access — all users' history, memory, devices, and admin pages |
| `user` | Own data only — own chat history, own memory entries, own devices |

Admins see a user filter dropdown on the Devices, History, and Memory pages.

---

## Configuration

| Path | Purpose |
|------|--------|
| `~/.config/nexis/` | TLS certificates, schedules, integrations, personality config |
| `~/.local/share/nexis/` | SQLite database, logs, voice models, state |
| `/etc/systemd/system/nexis-controller.service` | Service unit |

---

## CLI

The `nexis` command is installed to `/usr/local/bin/nexis`:

```bash
nexis --status      # service and web UI liveness check
nexis --start       # start the service
nexis --stop        # stop the service
nexis --restart     # restart the service
nexis --logs [n]    # tail the last n lines of the service journal (default 50)
nexis --web         # open the web UI in a browser
nexis               # open an interactive CLI session (requires socat)
```

**In-session commands:**

| Command | Action |
|---------|--------|
| `//memory` | Show persistent memory entries |
| `//forget <term>` | Delete a memory entry |
| `//clear` | Clear current session history |
| `//status` | Show service status |
| `//probe` | Run system probe |
| `//search <q>` | Web search |
| `//voice [on\|off]` | Toggle TTS voice output |
| `//stt [on\|off\|wake\|open]` | Toggle/configure STT |
| `//schedule [list\|add\|delete\|pause\|resume\|run]` | Manage scheduled tasks |
| `//ws [run\|clear\|vars\|history]` | Python workspace |
| `//passwd` | Change your password |
| `//exit` | Exit the session |

---

## API

All endpoints require `Authorization: Bearer <token>` unless marked **public**.

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/auth/login` | Authenticate · returns session token · **public** |
| `GET` | `/api/health` | Liveness check · **public** |

### AI

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/chat` | AI conversation · SSE streaming |
| `GET` | `/api/models` | List available Ollama models |
| `POST` | `/api/model` | Switch active model |
| `GET` | `/api/history` | Conversation history (own, or any user for admin) |
| `DELETE` | `/api/history/{session_id}` | Delete a conversation session |
| `GET` | `/api/memories` | Persistent memory entries |

### Devices

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/devices` | List registered Worker devices (admin: `?user=` filter) |
| `POST` | `/api/devices/register` | Register a Worker or Hypervisor device · **public** |
| `POST` | `/api/devices/status` | Worker/Hypervisor status update |
| `GET` | `/api/devices/commands` | Poll for queued commands (Workers poll this) |
| `POST` | `/api/devices/{id}/vnc/start` | Start noVNC session for a device |
| `GET` | `/api/sync` | Real-time cross-device state via SSE |

### Hypervisor

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/hyp/nodes` | List paired hypervisor nodes |
| `POST` | `/api/hyp/nodes` | Manually add a hypervisor node |
| `POST` | `/api/hyp/nodes/register` | Hypervisor self-registration · **public** |
| `DELETE` | `/api/hyp/nodes/{id}` | Remove a paired node |
| `GET` | `/api/hyp/vms` | All VMs across all paired nodes |
| `GET` | `/api/hyp/metrics` | Live metrics from all nodes |
| `POST` | `/api/hyp/nodes/{id}/vms/{vm_id}/{action}` | VM power action on a specific node |

### Tools

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/tools` | List built-in capabilities and custom tools (admin) |
| `POST` | `/api/tools` | Create a custom tool (admin) |
| `PUT` | `/api/tools/{id}` | Update a custom tool (admin) |
| `DELETE` | `/api/tools/{id}` | Delete a custom tool (admin) |

### Automation

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/schedules` | List automation schedules |
| `POST` | `/api/schedules` | Create a schedule |
| `GET` | `/api/ha/*` | Home Assistant bridge |
| `POST` | `/api/exec` | Remote code execution |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/update` | Start background software update |
| `GET` | `/api/update/status` | Poll update progress |
| `GET` | `/api/users` | List users (admin only) |
| `POST` | `/api/users` | Create user (admin only) |

---

## Pairing a Hypervisor Node

1. On the Hypervisor machine, open `https://<node-ip>:8443`
2. The setup wizard prompts for this Controller's URL, username, and password
3. The Hypervisor authenticates against the Controller's `/api/auth/login`, then self-registers at `/api/hyp/nodes/register`
4. The node appears in the **Hypervisor** tab of the Controller web UI

From that point, all logins to the Hypervisor node are proxied to the Controller — no separate per-node passwords.

---

## Web UI Sections

| Section | Description |
|---------|-------------|
| Chat | AI conversation with streaming output |
| Remote | Remote desktop control for connected Worker devices |
| History | Per-user conversation history with per-session Delete button (admin can filter by user) |
| Memory | Persistent memory entries with auto-extraction and keyword search (admin can filter by user) |
| Schedules | Automated tasks and briefings |
| Devices | Connected Workers and Hypervisors with noVNC SCREEN button per device (admin can filter by user) |
| Hypervisor | Aggregate VM/container view and live metrics across all nodes |
| Tools & Capabilities | Built-in capability list + CRUD for custom shell/Python/HTTP tools — **admin only** |
| Users | User management — admin only |
| Status | Service health, version, and one-click software update |
