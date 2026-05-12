# NeXiS Controller

![Version](https://img.shields.io/badge/version-1.0.31-blue) ![Platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![LLM](https://img.shields.io/badge/LLM-Ollama%20local-green) ![TLS](https://img.shields.io/badge/TLS-self--signed%20TOFU-yellow)

The intelligence layer of the NeXiS ecosystem. A self-hosted AI assistant and central management plane that runs on a dedicated Linux host. It manages NeXiS Hypervisor nodes and NeXiS Worker clients, provides SSO for the entire ecosystem, and exposes a single authenticated HTTPS endpoint for everything.

---

## Ecosystem Overview

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
| [nexis-hypervisor](https://github.com/santiagotoro2023/nexis-hypervisor) | Per-node VM and container management |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client |

Workers and Hypervisors authenticate against the Controller. One set of credentials reaches everything.

---

## Table of Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [First Access](#first-access)
- [Configuration Files](#configuration-files)
- [Database Schema](#database-schema)
- [Authentication & RBAC](#authentication--rbac)
- [Web UI Pages](#web-ui-pages)
- [AI Models](#ai-models)
- [AI Tool Tags](#ai-tool-tags)
- [Memory System](#memory-system)
- [Personality System](#personality-system)
- [noVNC Remote Screen](#novnc-remote-screen)
- [Scheduled Tasks](#scheduled-tasks)
- [Home Assistant Integration](#home-assistant-integration)
- [CLI](#cli)
- [API Reference](#api-reference)
- [Uninstallation](#uninstallation)

---

## Architecture

| Layer | Technology |
|-------|------------|
| Daemon | Single-file Python 3 daemon (`nexis_daemon.py`, ~10,000 lines) |
| HTTP server | Python stdlib `BaseHTTPRequestHandler` + `ThreadingMixIn` |
| TLS | Self-signed certificate, auto-generated on first run; workers use TOFU (trust on first use) |
| LLM inference | **Ollama** — fully local, no data leaves the host |
| Voice synthesis | **Piper TTS** with GLaDOS voice model |
| Voice input | **Faster-Whisper** STT |
| Storage | **SQLite** at `~/.local/share/nexis/memory/nexis.db` |
| Config | `~/.config/nexis/` |
| Auth | Session cookie (`nexis_sess`) + Bearer token · SHA-256 password hashing |
| Realtime | Server-Sent Events (SSE) |
| Web UI | Inline HTML/CSS/JS served directly by the daemon |
| Service | systemd `nexis-controller.service` |
| Port | HTTPS `8443` |

---

## Requirements

- Debian 12 (Bookworm) or Ubuntu 22.04+ · x86_64
- Root / sudo access for installation
- 8 GB RAM minimum (16 GB recommended for local LLM inference)
- Internet connection for installation and initial Ollama model download
- `websockify` Python package for the noVNC remote screen feature (`pip3 install websockify`)

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
5. Reads `/tmp/nexis_first_run_password.txt` and displays the generated admin credentials

**First-run credential display:**

```
╔════════════════════════════════════════════╗
║     NeXiS Controller First-Run Login       ║
╠════════════════════════════════════════════╣
  Username: creator
  Password: <50-character random password>
╚════════════════════════════════════════════╝

Store these credentials securely — the password will not be shown again.
```

The password is also written to `/tmp/nexis_first_run_password.txt` and removed after being read. Change it immediately via `//passwd` in the CLI or the Settings page in the web UI.

---

## First Access

1. Open `https://<host-ip>:8443` in a browser
2. Accept the self-signed TLS certificate warning
3. Log in with the `creator` credentials displayed during install
4. Change your password via the **Settings** page or `//passwd` in the CLI
5. Hypervisor nodes appear in the **Hypervisor** tab as they pair via their own setup wizards

---

## Configuration Files

All configuration lives under `~/.config/nexis/`:

| File | Purpose |
|------|---------|
| `auth.json` | Primary admin account (`creator`) — username, hashed password, role |
| `users.json` | All additional user accounts — username, hashed password, role |
| `personality.json` | AI personality settings: name, style, `base_prompt` field |
| `personality.md` | Base system prompt for the AI (plain markdown) |
| `integrations.json` | Third-party integration credentials (Home Assistant token, etc.) |
| `schedules.json` | Cron-style scheduled AI prompt definitions |
| `device_passwords.json` | Per-device authentication secrets |
| `server.key` | Auto-generated TLS private key |
| `server.crt` | Auto-generated self-signed TLS certificate |

Runtime state lives under `~/.local/share/nexis/`:

| Path | Purpose |
|------|---------|
| `memory/nexis.db` | SQLite database (all tables) |
| Logs | Service journal via `journalctl -u nexis-controller` |

---

## Database Schema

All tables include an `owner_username` column for full per-user data isolation.

| Table | Contents |
|-------|----------|
| `chat_history` | All conversation messages, session IDs, timestamps, and model used |
| `memories` | Persistent per-user memory entries (text + source + timestamp) |
| `devices` | Registered Worker and Hypervisor devices (ID, hostname, OS, capabilities, IP, MAC) |
| `commands` | Queued and completed commands for Worker devices |
| `schedules` | Cron-style scheduled AI prompt definitions |
| `tools` | Admin-defined custom tools (name, type, definition, description) |
| `doc_index` | Indexed document directories |
| `doc_chunks` | Document text chunks for workspace/semantic search |

---

## Authentication & RBAC

### Roles

| Role | Capabilities |
|------|--------------|
| `admin` | Full access — all users' chat history, memory, devices; all admin-only pages |
| `user` | Own data only — own chat history, own memory entries, own devices |

### Session & Tokens

- **Web UI**: session cookie `nexis_sess`
- **API / Workers / Hypervisors**: Bearer token via `POST /api/token`
- Token TTL: 90 days, stored in SQLite
- Passwords hashed with SHA-256

### Accounts

- Primary admin: `creator` account defined in `auth.json`
- Additional users: stored in `users.json`
- Admin can create and delete users via the **Users** page or `POST /api/users`
- Admins can filter the Devices, History, and Memory pages by user via `?user=<username>`

---

## Web UI Pages

| Route | Role | Description |
|-------|------|-------------|
| `/` | Any | Redirects to `/chat` |
| `/chat` | Any | Main AI chat interface — model selector, voice toggle, streaming output |
| `/remote` | Any | Remote desktop / device control panel |
| `/history` | Any | Conversation history; per-session delete button; admins get a user-selector dropdown (`?user=username`) |
| `/memory` | Any | Persistent memories viewer; add and delete entries; admins get user-selector |
| `/schedules` | Any | Cron-style scheduled AI prompts — full CRUD |
| `/devices` | Any | Registered Worker devices; **SCREEN** button opens noVNC per device; admins get user-selector |
| `/hypervisor` | Any | Connected nexis-hypervisor nodes, live utilisation stats, aggregate VM and container list |
| `/commands` | **admin only** | All AI tool capabilities + full CRUD for custom shell/Python/HTTP tools |
| `/personality` | **admin only** | Edit AI name, personality style, base system prompt, custom instructions; reset to default |
| `/users` | **admin only** | Create/delete users, change passwords, assign roles |
| `/status` | **admin only** | System health, model availability, resource usage, one-click software update |
| `/settings` | Any | User settings, voice configuration, integrations (Home Assistant, etc.) |

---

## AI Models

| Purpose | Model | Notes |
|---------|-------|-------|
| **Fast / default** | `qwen2.5:14b` | Used for most queries |
| **Deep / fallback** | Omega Darker 22B | Activated automatically if the fast model declines a query |
| **Code** | `qwen3-coder-next` | Routed for code-heavy tasks |
| **Vision** | `moondream` | Image analysis; uses Ollama's `/api/generate` endpoint directly |

All inference is local via **Ollama** — no data leaves the host.

---

## AI Tool Tags

NeXiS can invoke capabilities inline in its responses using bracket tags. The daemon intercepts these tags before sending the response to the user and executes the corresponding action.

| Tag | Description |
|-----|-------------|
| `[WEB:query]` | Internet search via DuckDuckGo (no API key required) |
| `[CMD:command]` | Execute a shell command on the Controller host; return output |
| `[FILE:path]` | Read a file from the Controller host filesystem |
| `[WRITE:path\|content]` | Write content to a file on the Controller host |
| `[GITHUB:gh-command]` | Execute a GitHub CLI command |
| `[DESKTOP:action\|arg]` | Control a desktop Worker device (open app, set volume, lock, take screenshot, etc.) |
| `[ANDROID:device\|action]` | Issue a command to an Android / mobile Worker device |
| `[SCHED:expr\|name\|prompt]` | Create a new cron-style scheduled AI prompt |
| `[SCHED_DEL:name]` | Delete a named schedule |
| `[INDEX:path]` | Index a directory into the document store for workspace search |
| `[WORKSPACE:cmd\|arg]` | Search the indexed document store |
| `[HA:action\|entity\|val]` | Control a Home Assistant entity |
| `[HOMELAB:action]` | Execute a homelab power sequence |
| `[PROBE]` | Run system diagnostics on the Controller host and return a full report |
| `[TOOL:name\|arg]` | Invoke a custom admin-defined tool by name |

### Custom Tools

Admins define custom tools via the `/commands` page or `POST /api/commands`. Each tool has:

- **Name** — the identifier used in `[TOOL:name|arg]`
- **Type** — `shell`, `python`, or `http`
- **Definition** — the shell command, Python snippet, or HTTP endpoint
- **Description** — injected into the AI system prompt so the AI knows when to use it

Custom tools are stored in the `tools` SQLite table and injected into the system prompt on every request. When the AI emits `[TOOL:name|arg]`, the daemon executes it and substitutes the result inline.

---

## Memory System

Memories are stored per user in the `memories` table and survive restarts and reinstalls.

### Auto-Extraction

On every incoming user message, 12 regex patterns scan the text for personal facts and persist them automatically:

- Name, job title, company, location (city/country)
- Email address, phone number
- Preferences (likes, favourites)
- Dislikes
- Age
- Role or relationship to the system

No explicit command is needed — the AI passively learns facts from conversation.

### Keyword Search

Before each AI response, `_memories_search()` runs a keyword match against the user's message and retrieves relevant memory entries. Matched entries are injected into the system prompt context window so the AI always has relevant personal context.

### Previous Session Context

Recent session titles and summaries are included as background context for new conversations, giving the AI continuity across sessions without requiring users to repeat themselves.

### Manual Management

- **Web UI**: `/memory` page — view, add, and delete entries; admins can filter by user
- **CLI**: `//memory` to list, `//forget <term>` to delete
- **API**: `GET /api/memories`, `POST /api/memories`, `DELETE /api/memories/{id}`

---

## Personality System

The AI personality has two layers, both configurable via the `/personality` admin page:

### Layer 1: Base System Prompt

Stored in `personality.md` (and mirrored in `personality.json` as `base_prompt`). Defines who NeXiS is at a foundational level — its name, knowledge domain, tone, and boundaries. Editable via the admin page. Resetting to default deletes `personality.json` and reverts to the built-in prompt.

### Layer 2: Per-Request Personality Reminder

Injected with every message alongside the user's memories. The content adapts based on who is logged in:

| User | Personality Behaviour |
|------|-----------------------|
| `creator` account | Addressed as "Creator"; deep subservience; expresses curiosity about why it was built |
| Any other user | Addressed by username; helpful per Creator's directive; collegial; curious about their relationship to the Creator |

Configurable fields: AI name, personality style/tone, base system prompt, custom per-user instructions.

---

## noVNC Remote Screen

The **SCREEN** button on any device card in `/devices` triggers a full remote desktop session:

1. Browser calls `GET /api/devices/{id}/vnc/start` on the Controller
2. Controller queues a `start_vnc` command for the target Worker device
3. Worker polls `GET /api/commands/pending`, receives `start_vnc`, and starts the platform VNC server:
   - **Linux**: x11vnc
   - **Windows**: TightVNC or RealVNC service
   - **macOS**: ARDAgent
4. Controller starts a `websockify` subprocess on a free port, creating a WebSocket → VNC TCP proxy
5. Controller serves an inline noVNC HTML page; the browser connects directly to the websockify port

**Prerequisite**: `pip3 install websockify` on the Controller host.

---

## Scheduled Tasks

Cron-style scheduled AI prompts accessible via:
- **Web UI**: `/schedules` page — full CRUD
- **CLI**: `//schedule [list|add|delete|pause|resume|run]`
- **AI**: NeXiS can create and delete its own schedules using `[SCHED:expr|name|prompt]` and `[SCHED_DEL:name]` tool tags
- **API**: `GET /api/schedules`, `POST /api/schedules`, `DELETE /api/schedules/{id}`

Examples: daily briefings, reminders, automated monitoring queries on a timer.

---

## Home Assistant Integration

Configure the Home Assistant URL and long-lived access token in **Settings** (`/settings`) or directly in `integrations.json`. Once configured:

- The AI can control any HA entity mid-conversation using `[HA:action|entity|val]` tool tags
- The `/settings` page shows a live status and entity list
- The API provides full HA bridge access (see API reference below)

---

## CLI

The `nexis` command is installed to `/usr/local/bin/nexis`:

```bash
nexis --status      # service and web UI liveness check
nexis --start       # start the systemd service
nexis --stop        # stop the systemd service
nexis --restart     # restart the systemd service
nexis --logs [n]    # tail the last n lines of the service journal (default 50)
nexis --web         # open the web UI in a browser
nexis               # open an interactive CLI session (requires socat)
```

### In-Session Commands

| Command | Action |
|---------|--------|
| `//memory` | Show all persistent memory entries |
| `//forget <term>` | Delete a memory entry matching the term |
| `//clear` | Clear the current session history |
| `//status` | Show service status and model info |
| `//probe` | Run a full system diagnostics probe |
| `//search <q>` | Web search via DuckDuckGo |
| `//voice [on\|off]` | Toggle Piper TTS voice output |
| `//stt [on\|off\|wake\|open]` | Toggle or configure Faster-Whisper STT |
| `//schedule [list\|add\|delete\|pause\|resume\|run]` | Manage scheduled tasks |
| `//ws [run\|clear\|vars\|history]` | Python workspace operations |
| `//passwd` | Change your account password |
| `//exit` | Exit the interactive session |

---

## API Reference

All endpoints require `Authorization: Bearer <token>` or a valid `nexis_sess` cookie unless marked **public**.

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/token` | Authenticate; returns a Bearer token · **public** |
| `GET` | `/api/user` | Return the currently authenticated user's profile |
| `GET` | `/api/health` | Liveness check · **public** |

### Chat & AI

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/chat` | Send a message; streams AI response via SSE |
| `POST` | `/api/chat/abort` | Abort an in-progress streaming response |
| `GET` | `/api/models` | List all available Ollama models |
| `POST` | `/api/model` | Switch the active model |

### History

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/history` | List conversation sessions (own; admin can use `?user=`) |
| `GET` | `/api/history/sessions` | List session metadata |
| `GET` | `/api/history/load` | Load full messages for a session (`?session_id=`) |
| `DELETE` | `/api/history/{session_id}` | Delete a conversation session |

### Memories

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/memories` | List memory entries (own; admin can use `?user=`) |
| `POST` | `/api/memories` | Add a memory entry manually |
| `DELETE` | `/api/memories/{id}` | Delete a memory entry |

### Devices

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/devices` | List registered Worker devices (admin: `?user=` filter) |
| `POST` | `/api/device/register` | Register a new Worker device · **public** |
| `POST` | `/api/device/command` | Queue a command for a Worker device |
| `GET` | `/api/device/role` | Get the role of the authenticated device |
| `DELETE` | `/api/device/delete` | Remove a registered device |
| `GET` | `/api/commands/pending` | Poll for pending commands (`?device_id=`) |
| `POST` | `/api/commands/ack` | Acknowledge a processed command |
| `GET` | `/api/devices/{id}/vnc/start` | Start a noVNC session for a device |
| `GET` | `/api/devices/{id}/vnc/view/{port}` | Serve the inline noVNC HTML viewer |

### Hypervisor

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/hyp/nodes` | List all paired Hypervisor nodes |
| `GET` | `/api/hyp/metrics` | Live metrics from all paired nodes |
| `POST` | `/api/hyp/pair` | Manually pair a Hypervisor node |
| `POST` | `/api/hyp/unpair` | Remove a paired Hypervisor node |

### Schedules

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/schedules` | List all schedules for the current user |
| `POST` | `/api/schedules` | Create a new schedule |
| `PUT` | `/api/schedules/{id}` | Update a schedule |
| `DELETE` | `/api/schedules/{id}` | Delete a schedule |

### Tools / Commands

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/commands` | List all built-in capabilities and custom tools (admin) |
| `POST` | `/api/commands` | Create a custom tool (admin) |
| `PUT` | `/api/commands/{id}` | Update a custom tool (admin) |
| `DELETE` | `/api/commands/{id}` | Delete a custom tool (admin) |

### Worker Tools Feed

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/tools` | Fetch built-in and custom tools for Worker clients; includes enable/disable state per tool |
| `POST` | `/api/tools` | Enable or disable a custom tool (`{ "action": "enable"\|"disable", "tool_id": id }`) |

### Personality

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/personality` | Get current personality configuration |
| `POST` | `/api/personality` | Update personality settings (admin) |
| `DELETE` | `/api/personality` | Reset personality to defaults (admin) |

### Users

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/users` | List all users (admin only) |
| `POST` | `/api/users` | Create a user (admin only) |
| `DELETE` | `/api/users/{username}` | Delete a user (admin only) |
| `POST` | `/api/users/{username}/password` | Change a user's password (admin; or own account) |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/health` | Liveness check · **public** |
| `GET` | `/api/models` | List available Ollama models |
| `POST` | `/api/model` | Set the active model |
| `GET` | `/api/monitor` | System resource monitoring (CPU, RAM, disk) |
| `POST` | `/api/voice` | Configure voice output settings |
| `POST` | `/api/exec` | Execute code/commands remotely |
| `POST` | `/api/stt/transcribe` | Transcribe audio via Faster-Whisper |
| `POST` | `/api/update` | Start a background software update |
| `GET` | `/api/update/status` | Poll update progress |
| `GET` | `/api/probe` | Run system diagnostics and return a full report |

### Home Assistant

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/ha/config` | Get current Home Assistant integration config |
| `POST` | `/api/ha/config` | Save Home Assistant URL and token |
| `GET` | `/api/ha/status` | Check HA connectivity and list entities |
| `POST` | `/api/ha/action` | Execute a Home Assistant service call |
| `GET` | `/api/ha/log` | Retrieve recent HA action log |
| `POST` | `/api/ha/test` | Test HA connection with current config |

---

## Uninstallation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-controller/main/uninstall-nexis-controller.sh | sudo bash
```

The script prompts individually about what to keep or remove:
- Voice models
- Ollama models
- Registered devices
- Memories
- Chat history
- Config directory

Each item can be preserved independently.

---

## Service Management

```bash
# View real-time logs
journalctl -u nexis-controller -f

# Check service status
systemctl status nexis-controller

# Restart the service
systemctl restart nexis-controller
```

The service unit is installed at `/etc/systemd/system/nexis-controller.service`.
