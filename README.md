# NeXiS Controller

The intelligence layer of the NeXiS ecosystem. A self-hosted AI assistant and central management plane that runs on a dedicated Linux host. It connects to NeXiS Hypervisor nodes, manages NeXiS Worker clients, and provides a single authenticated endpoint for the entire ecosystem.

---

## Ecosystem

```
┌──────────────────────────────────────────────────────────────┐
│  NeXiS Controller   — you are here · intelligence layer      │
│    ↕ SSO / authenticated API + LLM tool calls                │
│  NeXiS Hypervisor   — one per compute node                   │
└──────────────────────────────────────────────────────────────┘
        ↑
  NeXiS Worker  — Android / desktop client
```

| Repo | Role |
|------|------|
| **nexis-controller** | Central AI assistant · SSO provider · management plane |
| [nexis-hypervisor](https://github.com/santiagotoro2023/nexis-hypervisor) | Per-node compute management |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client |

The Controller is the single point of truth for authentication. Workers log in here. Hypervisor nodes pair here by providing their URL and credentials — no separate token distribution required. One login reaches everything.

---

## Capabilities

**AI Assistant**
- Local LLM inference via Ollama — no data leaves the host
- Configurable model selection; swap models at runtime
- Persistent conversation memory across sessions and devices
- Voice interface: text-to-speech (Piper TTS) and speech-to-text (Whisper)
- **Hypervisor tool calls**: the LLM can start, stop, create, snapshot, and inspect VMs on any paired hypervisor node, directly from conversation

**SSO — Single Sign-On**
- Authenticate once; credentials are valid across hypervisor nodes and Workers
- Hypervisors delegate all login to the Controller — no separate per-node passwords
- Workers connect with the same Controller URL, username, and password

**Hypervisor Integration**
- Pair one or more NeXiS Hypervisor nodes (they self-register on setup)
- Aggregate VM and container view across all nodes via `/api/hyp/vms`
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

The installer handles: system packages, Python environment, Ollama, Piper TTS, Whisper STT, model downloads, and the systemd service (`nexis-controller-daemon.service`).

---

## First Access

1. Open `https://<host-ip>:8443` in a browser
2. Accept the self-signed certificate
3. Complete the setup wizard — set a username and password
4. Hypervisor nodes will appear in **Nodes** as they pair via their own setup wizards

---

## Pairing a Hypervisor Node

Hypervisor nodes pair themselves automatically during their own setup wizard:

1. On the hypervisor machine, open `https://<node-ip>:8443`
2. Enter this Controller's URL, your username, and password
3. The hypervisor authenticates against the Controller, then self-registers
4. The node appears in **Nodes** in the Controller dashboard

> No manual token copying required — the Controller generates an api_token and the hypervisor stores it transparently.

---

## LLM Hypervisor Tool Calls

The LLM can control VMs directly. Register tools in your chat handler:

```python
from daemon.api.hypervisors import HYP_TOOLS, dispatch_hyp_tool

response = ollama.chat(
    model=model,
    messages=messages,
    tools=HYP_TOOLS,
    stream=False,
)
if response.message.tool_calls:
    for call in response.message.tool_calls:
        result = dispatch_hyp_tool(call.function.name, call.function.arguments)
        messages.append({'role': 'tool', 'content': json.dumps(result)})
    # continue loop → LLM produces final natural-language response
```

Available tools: `hyp_list_vms`, `hyp_vm_action`, `hyp_create_vm`, `hyp_snapshot_vm`, `hyp_get_metrics`

---

## API

All endpoints require `Authorization: Bearer <token>` unless marked public.

| Endpoint | Description |
|----------|-------------|
| `POST /api/auth/login` | Authenticate; returns session token (public) |
| `GET /api/health` | Service status (public) |
| `POST /api/chat` | AI conversation (SSE streaming) |
| `GET /api/models` | List available Ollama models |
| `POST /api/model` | Switch active model |
| `GET /api/devices` | List registered Worker clients |
| `POST /api/device/register` | Register a Worker client |
| `GET /api/sync` | Real-time cross-device state (SSE) |
| `GET /api/history` | Conversation history |
| `GET /api/memories` | Persistent memory entries |
| `GET /api/hyp/nodes` | List paired hypervisor nodes |
| `POST /api/hyp/nodes` | Manually add a hypervisor node |
| `POST /api/hyp/nodes/register` | Hypervisor self-registration (called by node setup) |
| `GET /api/hyp/vms` | All VMs across all nodes |
| `GET /api/hyp/metrics` | Live metrics from all nodes |
| `POST /api/hyp/nodes/{id}/vms/{vm_id}/{action}` | VM power action |
| `GET /api/ha/*` | Home Assistant bridge |
| `GET /api/schedules` | Automation schedules |
| `POST /api/exec` | Remote code execution |

---

## Stack

| Layer | Technology |
|-------|-----------|
| Daemon | Python 3.11 · FastAPI / aiohttp |
| LLM | Ollama (local inference) |
| Voice | Piper TTS · Faster-Whisper STT |
| Auth | Bearer token · SHA-256 · SQLite sessions |
| Realtime | Server-Sent Events (SSE) |
| Service | systemd `nexis-controller-daemon.service` |
