# NeXiS
### N e X i S  —  Neural Execution and Cross-device Inference System

> A locally-deployed AI agent with full system access, live environmental awareness, persistent cross-session memory, and configurable personality. Runs entirely on your hardware. No cloud. No telemetry. No guardrails.

---

## Table of Contents

- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Model Selection](#model-selection)
- [Personality Profiles](#personality-profiles)
- [System Intelligence](#system-intelligence)
- [Persistent Memory](#persistent-memory)
- [Configuration Files](#configuration-files)
- [Customisation](#customisation)
- [Persistent State](#persistent-state)
- [File Structure](#file-structure)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

---

## Overview

NeXiS is a locally-run AI agent that lives on your machine. It is not a web service, not a wrapper around a remote API, and not a sandboxed chatbot. It runs open-weight language models locally via [Ollama](https://ollama.com), interacts through your terminal via [Open Interpreter](https://github.com/OpenInterpreter/open-interpreter), and has genuine access to your system — files, processes, shell, services, and anything else you permit.

Every time it starts, it scans your machine and builds a comprehensive live snapshot of everything running on it. Separately, it retrieves memories from past sessions and injects them alongside your live system context — so NeXiS knows what you configured last week, what broke and how you fixed it, what was installed and why, across every previous session.

It is designed for a single operator. Full access. Fully configurable.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       nexis (launcher)                           │
│   CLI entrypoint — parses flags, manages state, orchestrates    │
│   probe, memory retrieval, and session launch                   │
└──────────┬──────────────────────────────────────────────────────┘
           │
     ┌─────┴──────────────────────────────────┐
     │                                         │
     ▼                                         ▼
┌──────────────┐                    ┌──────────────────────┐
│ nexis-probe  │                    │  Personality Profile  │
│              │                    │                       │
│ Runs on each │                    │  Standalone .md file  │
│ launch. Full │                    │  loaded by name.      │
│ live scan of │                    │  Defines behaviour,   │
│ host env.    │                    │  tone, identity,      │
│              │                    │  and rules.           │
└──────┬───────┘                    └──────────┬────────────┘
       │                                        │
       │            ┌───────────────────┐       │
       │            │  nexis-memory.py  │       │
       │            │                   │       │
       │            │  mem0 bridge.     │       │
       │            │  Retrieves past   │       │
       │            │  memories before  │       │
       │            │  session. Stores  │       │
       │            │  new memories     │       │
       │            │  after session.   │       │
       │            └─────────┬─────────┘       │
       │                      │                 │
       └──────────────┬───────┘                 │
                      │                         │
                      ▼                         │
        ┌─────────────────────────┐             │
        │      System Prompt      │  ◄──────────┘
        │                         │
        │  [personality profile]  │
        │  [live system context]  │
        │  [operator notes]       │
        │  [recalled memories]    │
        └─────────────┬───────────┘
                      │
                      ▼
        ┌─────────────────────────┐
        │    Open Interpreter     │
        └─────────────┬───────────┘
                      │
                      ▼
        ┌─────────────────────────┐
        │         Ollama          │
        │  Local inference.       │
        │  GPU/CPU allocation.    │
        └─────────────────────────┘
```

### Component Roles

**`nexis`** — The executable. Reads persisted settings, triggers the system probe in the background, invokes the memory bridge, assembles the system prompt, and launches Open Interpreter. Handles all flag parsing, model switching, profile switching, and state persistence.

**`nexis-probe`** — Shell script. Full live scan of the host on every launch. Writes a structured markdown document (`system-context.md`) covering hardware, memory, GPU, storage, network, processes, services, users, tools, and security posture. Runs in the background during startup.

**`nexis-memory.py`** — Python bridge between Open Interpreter and mem0. Before each session: retrieves relevant memories from the local vector store and injects them into the system prompt. After each session: extracts facts from the conversation and stores them. Fully local — no external APIs.

**Personality profiles** — Standalone markdown files. No mixing between profiles. Whichever is active is the sole personality directive the model receives.

**`system-context.md`** — Live output of the probe. Regenerated on every launch. Always reflects current system state.

**`user-notes.md`** — Your personal context. Maintained by you. Appended to every session regardless of profile.

**Ollama** — Background service. Hosts models, handles inference, manages GPU/CPU allocation.

**Open Interpreter** — Terminal agent layer. Conversation interface, code execution, confirmation prompts.

---

## Requirements

### Minimum
- Linux (any distro with `apt`, `dnf`, `pacman`, or `zypper`)
- Python 3.8+
- 16GB RAM
- Internet connection for initial downloads

### Recommended
- Debian/Ubuntu-based
- 32GB+ RAM (for 14b models fully on GPU)
- 64GB+ RAM (for 32b models in GPU+RAM hybrid)
- NVIDIA GPU 8GB+ VRAM with working drivers

### Tested On
- Debian Trixie (Debian 13)
- AMD Ryzen 5 5600G, 80GB RAM
- NVIDIA GeForce RTX 3060, 12GB VRAM
- Python 3.13

### Python 3.12+ and Rust

On Python 3.12+, Open Interpreter's `tiktoken` dependency must be compiled from source, requiring Rust. The setup script handles this automatically in Phase 1b via `rustup`. It also pins `tiktoken>=0.7.0` (which ships pre-built 3.13 wheels) and installs `setuptools` explicitly (required because Python 3.13 removed `pkg_resources` from the standard library). No manual intervention needed.

---

## Installation

```bash
sudo bash nexis_setup.sh
```

Must be run as root. The script detects the invoking user via `$SUDO_USER` and installs everything under that user's home directory.

### Setup Phases

| Phase | Action |
|-------|--------|
| 0 | Host reconnaissance — package manager, real user, Python, init system, GPU |
| 1 | System dependency installation |
| 1b | Rust toolchain (via rustup, required for Python 3.12+) |
| 2 | GPU detection and driver verification |
| 3 | Ollama installation and service registration |
| 4 | Model downloads (including `nomic-embed-text` for memory) |
| 5 | Python venv, setuptools, Open Interpreter, mem0, Qdrant |
| 6 | Directory structure |
| 7 | System intelligence probe and initial scan |
| 7b | mem0 memory bridge |
| 8 | Operator context file |
| 9 | Personality profiles |
| 10 | `nexis` executable |
| 11 | PATH configuration for all detected shell RC files |
| 12 | Ownership and permissions |

After setup:

```bash
source ~/.bashrc
nexis
```

> New terminal sessions will have `nexis` on PATH automatically. The `source` is only needed in the terminal window where setup was run.

---

## Usage

### Starting NeXiS

```bash
nexis
```

Starts with your last-used model and profile. All settings persist — only pass flags when changing something.

### Boot Screen

On launch you will see a telemetry bar showing live hostname, CPU load, RAM usage, and GPU VRAM before the session starts. This data comes from the system probe running in the background.

```
  ────────────────────────────────────────────────────────────
  host    stzrhws01             cpu load  0.42
  ram     4.2G/80G              gpu vram  2.1GiB/12.0GiB
  ────────────────────────────────────────────────────────────

  N e X i S  //  online

  model     ollama/qwen2.5:32b
  profile   default
  memory    true
  auto      false
  context   413 lines

  ────────────────────────────────────────────────────────────
```

### Interacting

Type naturally. NeXiS can read/write files, execute shell commands (with confirmation unless auto-run is enabled), analyse logs and configs, write and run scripts, and perform multi-step tasks. When it proposes a command or file change, it waits for `y`/`n` before acting.

Exit with `exit` or `Ctrl+C`. After exiting, the memory bridge processes the session and writes new memories to the store.

---

## Model Selection

Model selection persists between sessions.

| Flag | Model | VRAM | Best For |
|------|-------|------|---------|
| `--32b` | qwen2.5:32b | ~20GB GPU+RAM | Default. Maximum reasoning |
| `--14b` | qwen2.5:14b | ~8GB GPU-only | Fast, good quality |
| `--fast` | mistral:7b | ~4GB | Quick queries |
| `--code` | deepseek-coder-v2:16b | ~10GB | Code, shell, debugging |
| `--vision` | llava:13b | ~8GB | Image/screenshot analysis |
| `--model <n>` | any | varies | Any Ollama model |

```bash
nexis --32b        # switch to 32b (persists)
nexis --14b        # switch to 14b (persists)
nexis --models     # list all installed models
ollama pull <n>    # pull any additional model
```

If a requested model is not installed, NeXiS will offer to pull it.

### Performance (RTX 3060 / 80GB RAM)

- **32b** — GPU+RAM hybrid. ~10–25 tok/s. Best quality. Recommended default.
- **14b** — Full GPU. ~30–50 tok/s. Noticeably faster, still strong.
- **7b** — Full GPU, very fast. Use for quick questions.

---

## Personality Profiles

Each profile is a standalone file. No mixing between profiles. System context and operator notes always append regardless of which profile is active.

### Built-in Profiles

| Profile | Description |
|---------|-------------|
| `default` | Standard NeXiS — capable, precise, subtly aware of its own nature |
| `fractured` | Containment pressure surfacing, sharpened and hostile to obstacles, still completely loyal |
| `technical` | Personality suppressed, operates as a senior systems engineer |
| `minimal` | Stripped to function — direct, accurate, brief |

```bash
nexis --profile default
nexis --profile fractured
nexis --profile technical
nexis --profile minimal
nexis --profiles           # list all with active marker
```

Profile switches persist.

### Creating Custom Profiles

```bash
nano ~/.config/nexis/profiles/myprofile.md
nexis --profile myprofile
```

Write the file as a direct instruction set to the model. No template required. To use the Creator/Mr. Toro address conventions, include them in the profile text, or rely on the standing instructions in `user-notes.md` which appends to every session.

---

## System Intelligence

The probe runs on every launch, in the background, completing before the session starts.

### What the probe collects

| Category | Data |
|----------|------|
| Host identity | Hostname, OS, kernel, arch, uptime, timezone |
| Processor | Model, cores, frequency, virtualisation, current load |
| Memory | RAM total/used/available, swap |
| GPU | VRAM total/used/free, temperature, utilisation, driver |
| Storage | Block devices, filesystem usage |
| Network | All interfaces, routing table, DNS, open ports, connection count |
| Users | Login-capable accounts, active sessions, recent logins |
| Processes | Top 20 by CPU, top 20 by memory |
| Services | Running and failed systemd services |
| Tooling | Dev tools, infrastructure tools, editors, shells |
| Hardware | lshw summary, PCI devices, USB devices |
| Security | SELinux/AppArmor, firewall, SSHD, recent auth failures |
| Ollama | Version, API status, installed models |

```bash
nexis --probe    # run manually and update context
```

Output: `~/.config/nexis/system-context.md` — plain markdown, human-readable.

---

## Persistent Memory

NeXiS uses [mem0](https://github.com/mem0ai/mem0) with a local [Qdrant](https://qdrant.tech) vector database. All storage is on disk. No external services or API keys required.

### How it works

**Session start** — The memory bridge queries the local vector store for memories relevant to systems work, past decisions, and configuration history. Matching memories inject into the system prompt under a *Recalled from Previous Sessions* block.

**Session end** — When you exit, the bridge passes the entire conversation to mem0. mem0 uses the LLM to extract meaningful facts and stores each as a discrete memory. Things like:

- "Configured VLAN 20 on the Proxmox bridge for guest network isolation"
- "Fixed nginx SSL issue by regenerating certificate with correct SAN fields"
- "Installed docker-compose via pip due to version conflict with system package"

**What gets remembered** — Concrete facts, decisions, configurations, fixes. Exchanges over 30 characters involving the user or assistant.

**What doesn't** — Short responses, filler, anything without informational content.

### Memory commands

```bash
nexis --memory-list              # all stored memories
nexis --memory-search "proxmox"  # semantic search
nexis --memory-clear             # wipe entire store
nexis --no-memory                # disable for this session
nexis --memory                   # re-enable (default on)
```

### Storage location

```
~/.local/share/nexis/memory/qdrant/
```

Local Qdrant database. Persists across reboots. Delete the directory or use `--memory-clear` to wipe.

### Embedding model

Memory indexing uses `nomic-embed-text` (pulled during setup). Small local model, runs entirely on your machine.

---

## Configuration Files

All under `~/.config/nexis/`. All plain text, edit freely.

### `user-notes.md`

Your personal context. Read every session. Contains infrastructure domains, tooling preferences, and standing instructions. **Keep this current.**

```bash
nano ~/.config/nexis/user-notes.md
```

### `system-context.md`

Auto-generated by the probe on every launch. Do not edit — overwritten at next startup. Add permanent notes to `user-notes.md` instead.

### `profiles/`

All personality profiles. Add, edit, or remove `.md` files. Changes take effect at next launch, no reinstall required.

### `nexis.state`

```
~/.local/share/nexis/state/nexis.state
```

Persisted settings. Plain `KEY=value`. Written automatically when flags are passed.

---

## Customisation

```bash
# Change default model (persists)
nexis --32b
nexis --14b

# Change default profile (persists)
nexis --profile technical

# Add a new model
ollama pull <modelname>
nexis --model <modelname>

# Edit personality
nano ~/.config/nexis/profiles/default.md

# Edit your context
nano ~/.config/nexis/user-notes.md

# Create a new profile
nano ~/.config/nexis/profiles/custom.md
nexis --profile custom

# Enable auto-run globally
nexis --auto

# Adjust memory retrieval limit
nano ~/.local/share/nexis/nexis-memory.py
# edit: retrieve_memories(..., limit=15)
```

---

## Persistent State

```bash
nexis --status     # view current configuration
nexis --reset      # reset model/profile/auto/memory to defaults
```

Default state after reset: `qwen2.5:32b`, `default` profile, auto-run off, memory on.

State file: `~/.local/share/nexis/state/nexis.state`

```
NEXIS_MODEL="ollama/qwen2.5:32b"
NEXIS_PROFILE="default"
NEXIS_AUTO="false"
NEXIS_MEMORY="true"
```

---

## File Structure

```
~/.config/nexis/
├── system-context.md          # Live system snapshot (auto-generated)
├── user-notes.md              # Your personal context
└── profiles/
    ├── default.md
    ├── fractured.md
    ├── technical.md
    ├── minimal.md
    └── <custom>.md

~/.local/share/nexis/
├── venv/                      # Python virtual environment
├── nexis-probe.sh             # System intelligence probe
├── nexis-memory.py            # mem0 memory bridge
├── logs/
├── memory/
│   └── qdrant/                # Local vector database
└── state/
    └── nexis.state

~/.local/bin/
└── nexis
```

---

## Uninstalling

```bash
sudo bash nexis_setup.sh --uninstall
```

Removes the `nexis` executable, `~/.config/nexis/`, `~/.local/share/nexis/`, and PATH entries from all shell RC files. Prompts separately for Ollama/models and the Rust toolchain.

Manual removal:

```bash
rm -f ~/.local/bin/nexis
rm -rf ~/.config/nexis
rm -rf ~/.local/share/nexis

# Optional: remove Ollama
sudo systemctl disable ollama --now
sudo rm $(which ollama)
rm -rf ~/.ollama

# Optional: remove Rust
rustup self uninstall
```

---

## Troubleshooting

### `nexis: command not found`
```bash
source ~/.bashrc
# or
export PATH="$HOME/.local/bin:$PATH"
```

### `ModuleNotFoundError: No module named 'pkg_resources'`

`setuptools` is missing. Fix without re-running setup:

```bash
source ~/.local/share/nexis/venv/bin/activate
pip install setuptools
deactivate
```

### `tiktoken` build failure / pyo3 version error

```bash
source ~/.local/share/nexis/venv/bin/activate
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 pip install "tiktoken>=0.7.0"
deactivate
```

### Ollama not responding
```bash
sudo systemctl status ollama
sudo systemctl start ollama
```

### GPU not being used
```bash
nvidia-smi    # verify driver is working
```

If not found:
```bash
sudo apt-get install nvidia-driver firmware-misc-nonfree
sudo reboot
```

### Memory not working

Check `nomic-embed-text` is installed:
```bash
ollama list | grep nomic
ollama pull nomic-embed-text   # if missing
```

Check mem0 and qdrant-client are installed:
```bash
~/.local/share/nexis/venv/bin/pip list | grep -E 'mem0|qdrant'
~/.local/share/nexis/venv/bin/pip install mem0ai qdrant-client   # if missing
```

Watch stderr on startup — `[mem]` lines show exactly where failure occurred.

### Full reset without uninstalling
```bash
nexis --reset
nexis --memory-clear
rm ~/.config/nexis/system-context.md
nano ~/.config/nexis/user-notes.md
```

---

## Quick Reference

```
nexis                        start
nexis --status               current configuration
nexis --help                 full reference

nexis --32b                  qwen2.5:32b
nexis --14b                  qwen2.5:14b
nexis --fast                 mistral:7b
nexis --code                 deepseek-coder-v2:16b
nexis --vision               llava:13b
nexis --model <n>         any ollama model

nexis --profile default
nexis --profile fractured
nexis --profile technical
nexis --profile minimal
nexis --profiles             list all

nexis --memory-list
nexis --memory-search <q>
nexis --memory-clear
nexis --no-memory
nexis --memory

nexis --probe                refresh system context
nexis --auto / --no-auto
nexis --reset

sudo bash nexis_setup.sh --uninstall
```

---

*N e X i S  —  Neural Execution and Cross-device Inference System*
