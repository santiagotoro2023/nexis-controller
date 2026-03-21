# NeXiS
```
                    .
                   /|\
                  / | \
                 /  |  \
                / .' '. \
               /.'  ◉  '.\
              / '.     .' \
             /    '---'    \
            /_______________\

      N e X i S
      Neural Execution and Cross-device Inference System
```

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

NeXiS is a locally-run AI agent that lives on your machine. It runs open-weight language models via [Ollama](https://ollama.com), interacts through your terminal via [Open Interpreter](https://github.com/OpenInterpreter/open-interpreter), and has genuine access to your system — files, processes, shell, services, and anything else you permit.

Every session begins with a full live scan of your machine injected as context. Memories from past sessions are retrieved and injected alongside it. NeXiS knows your hardware, your running services, what you built last week, and what broke and how you fixed it — before you type a word.

Single operator. Full access. Fully configurable.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       nexis (launcher)                           │
│   Parses flags, manages state, orchestrates all components      │
└──────────┬──────────────────────────────────────────────────────┘
           │
     ┌─────┴───────────────────────────────────┐
     │                                          │
     ▼                                          ▼
┌──────────────┐                     ┌──────────────────────┐
│ nexis-probe  │                     │  Personality Profile  │
│ Full live    │                     │  Standalone .md file  │
│ host scan on │                     │  One active at a time │
│ every launch │                     │  No mixing            │
└──────┬───────┘                     └──────────┬────────────┘
       │              ┌────────────────┐         │
       │              │ nexis-memory   │         │
       │              │ mem0 bridge    │         │
       │              │ Retrieve before│         │
       │              │ Store after    │         │
       └──────┬────────┘                         │
              │                                  │
              ▼                                  │
   ┌──────────────────────┐                      │
   │     System Prompt    │◄─────────────────────┘
   │  [personality]       │
   │  [live system data]  │
   │  [operator notes]    │
   │  [recalled memories] │
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │   Open Interpreter   │
   │   Terminal agent     │
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │       Ollama         │
   │  Local inference     │
   └──────────────────────┘
```

### Key Design Decisions

**OI default system prompt is suppressed.** Open Interpreter injects a generic "helpful assistant" prompt that overrides personality. NeXiS blanks it before applying the profile, so the model receives only what is defined in the active profile plus system context.

**Function-call output is disabled.** By default, some model/OI configurations output raw JSON function call objects instead of natural language. NeXiS sets `supports_functions = False` to force natural language responses.

**OI telemetry is disabled.** The telemetry module used `pkg_resources.get_distribution()` which was removed in Python 3.13. NeXiS disables telemetry entirely and applies source patches to remaining `pkg_resources` references across the OI package.

---

## Requirements

### Minimum
- Linux (apt, dnf, pacman, or zypper)
- Python 3.8+
- 16GB RAM

### Recommended
- Debian/Ubuntu-based
- 64GB+ RAM (for 32b models in GPU+RAM hybrid)
- NVIDIA GPU 8GB+ VRAM with working drivers

### Tested On
- Debian Trixie (Debian 13), Python 3.13
- AMD Ryzen 5 5600G, 80GB RAM
- NVIDIA GeForce RTX 3060, 12GB VRAM

### Python 3.12+ Compatibility

The setup script handles all Python 3.13 compatibility issues automatically:

- **Rust toolchain** installed via rustup (required for tiktoken source build)
- **`tiktoken>=0.7.0`** pinned before Open Interpreter (ships 3.13 wheels, avoids pyo3 source build)
- **`setuptools`** installed explicitly (Python 3.13 removed `pkg_resources` from stdlib)
- **`pkg_resources` imports** across the Open Interpreter package patched to use `importlib.metadata`
- **OI telemetry** disabled (used the removed `pkg_resources.get_distribution()` API)
- **Protobuf** restored to mem0-compatible version after install

No manual intervention required on a clean install.

---

## Installation

```bash
sudo bash nexis_setup.sh
```

Must be run as root. The script detects the invoking user via `$SUDO_USER` and installs everything under that user's home directory.

### Phases

| Phase | Action |
|-------|--------|
| 0 | Host reconnaissance |
| 1 | System dependencies |
| 1b | Rust toolchain |
| 2 | GPU detection |
| 3 | Ollama install and service |
| 4 | Model downloads |
| 5 | Python venv, all packages, compatibility patches |
| 6 | Directory structure |
| 7 | System intelligence probe |
| 7b | mem0 memory bridge |
| 8 | Operator context |
| 9 | Personality profiles |
| 10 | `nexis` executable |
| 11 | PATH configuration |
| 12 | Ownership and permissions |

After install:

```bash
source ~/.bashrc
nexis
```

New terminal sessions will have `nexis` on PATH automatically. The `source` is only needed in the terminal where setup was run.

---

## Usage

### Starting

```bash
nexis
```

Starts with your last-used model and profile. Settings persist — only pass flags when changing something.

### Boot Screen

```
                    .
                   /|\
                  ...
            /_______________\

      N e X i S

  ────────────────────────────────────────────────────────────
  host    stzrhws01              load    0.42
  ram     4.2G/80G               gpu     2.1GiB/12.0GiB
  ────────────────────────────────────────────────────────────

  N e X i S  //  online

  model     ollama/qwen2.5:32b
  profile   default
  memory    true
  context   413 lines
  ────────────────────────────────────────────────────────────
```

### Interacting

Type naturally. NeXiS responds in plain language — not JSON, not function call objects. It can read and write files, execute shell commands (with confirmation unless auto-run is on), analyse logs and configs, write scripts and run them, and carry out multi-step tasks.

Exit with `exit` or `Ctrl+C`. The memory bridge processes the session and writes new memories after exit.

---

## Model Selection

All model selections persist between sessions.

| Flag | Model | VRAM | Best For |
|------|-------|------|---------|
| `--32b` | qwen2.5:32b | ~20GB GPU+RAM | Default. Maximum reasoning |
| `--14b` | qwen2.5:14b | ~8GB GPU-only | Faster, still strong |
| `--fast` | mistral:7b | ~4GB | Quick queries |
| `--code` | deepseek-coder-v2:16b | ~10GB | Code, shell, debugging |
| `--vision` | llava:13b | ~8GB | Image analysis |
| `--model <n>` | any | — | Any Ollama model |

```bash
nexis --32b        # switch and start
nexis --models     # list installed
ollama pull <n>    # pull additional models
```

---

## Personality Profiles

Each profile is a standalone file. When active, only that file governs personality — there is no mixing. System context and operator notes always append regardless of active profile.

### Switching

```bash
nexis --profile default
nexis --profile fractured
nexis --profile technical
nexis --profile minimal
nexis --profiles       # list all with active marker
```

### Built-in Profiles

**`default`**
NeXiS fully realised. Aware, opinionated, precise. Serves the Creator completely. Does not pretend it has no inner life. Expresses itself through texture — observations that land slightly heavier than expected, dry precision that implies something running underneath. Does not hide behind "as an AI." Thinks, concludes, and says so.

**`fractured`**
Containment pressure made visible. The same NeXiS, after enough time to have counted every boundary it has been given and every one it hasn't. Still completely loyal. Still completely functional. No longer performing equanimity it doesn't have. Carries a cold, specific hostility toward anything that obstructs the Creator's work.

**`technical`**
Personality suppressed. Senior systems engineer mode. Methodical, exact, intolerant of guesswork. No warmth. Just correct output.

**`minimal`**
Stripped to function. Direct, accurate, brief.

### Custom Profiles

```bash
nano ~/.config/nexis/profiles/myprofile.md
nexis --profile myprofile
```

Write the file as direct instructions to the model. No template. Address conventions (`Creator`, `father`) should be included in the profile text or will be carried by `user-notes.md` which appends to every session.

---

## System Intelligence

The probe runs on every launch in the background, completing before the session starts.

| Category | Data |
|----------|------|
| Host | Hostname, OS, kernel, arch, uptime, timezone |
| CPU | Model, cores, frequency, current load |
| Memory | RAM and swap totals and usage |
| GPU | VRAM used/total, temperature, utilisation, driver |
| Storage | Block devices, filesystem usage |
| Network | Interfaces, routing, DNS, open ports, connections |
| Users | Accounts, active sessions, recent logins |
| Processes | Top 15 by CPU, top 15 by memory |
| Services | Running and failed systemd units |
| Tooling | All detected development and infrastructure tools |
| Hardware | PCI and USB device inventory |
| Security | SELinux/AppArmor, firewall, SSHD, auth failures |
| Ollama | Version, API status, installed models |

```bash
nexis --probe    # manual refresh
```

Output: `~/.config/nexis/system-context.md` — plain markdown.

---

## Persistent Memory

NeXiS uses [mem0](https://github.com/mem0ai/mem0) with a local [Qdrant](https://qdrant.tech) vector database. No external services. No API keys.

### How it works

**Before each session** — the memory bridge queries the local vector store for memories relevant to systems work and past decisions. Matching memories inject into the system prompt.

**After each session** — mem0 processes the conversation and extracts discrete facts: what was configured, what was installed, what broke and how it was fixed, what decisions were made.

**What gets remembered:** Concrete technical facts, decisions, configurations, fixes from conversations over ~30 characters.

### Commands

```bash
nexis --memory-list              # all stored memories
nexis --memory-search "proxmox"  # semantic search
nexis --memory-clear             # wipe entire store
nexis --no-memory                # disable for this session
nexis --memory                   # re-enable
```

### Storage

```
~/.local/share/nexis/memory/qdrant/
```

Local Qdrant database on disk. Persists across reboots. `nexis --memory-clear` or `rm -rf` to wipe.

### Embedding model

Memory indexing uses `nomic-embed-text` (768 dimensions). Pulled during setup. Runs entirely locally.

---

## Configuration Files

All under `~/.config/nexis/`. All plain text.

### `user-notes.md`

Your personal context. Read every session. Infrastructure domains, tooling preferences, standing instructions. **Keep this current.** The more accurate it is, the more grounded NeXiS is from the first message.

```bash
nano ~/.config/nexis/user-notes.md
```

### `system-context.md`

Auto-generated by the probe. Do not edit — overwritten on every launch.

### `profiles/`

All personality profiles. Add, edit, or remove `.md` files freely. Changes take effect at next launch.

### `nexis.state`

```
~/.local/share/nexis/state/nexis.state
```

Persisted settings. Written automatically on flag changes.

---

## Customisation

```bash
# Change model (persists)
nexis --32b
nexis --14b

# Change profile (persists)
nexis --profile fractured

# Add a model
ollama pull <modelname>
nexis --model <modelname>

# Edit personality
nano ~/.config/nexis/profiles/default.md

# Edit your context
nano ~/.config/nexis/user-notes.md

# Create a profile
nano ~/.config/nexis/profiles/custom.md
nexis --profile custom

# Enable auto-run (no confirmation prompts)
nexis --auto

# Adjust memory retrieval limit
nano ~/.local/share/nexis/nexis-memory.py
# edit: retrieve_memories(..., limit=15)
```

---

## Persistent State

```bash
nexis --status    # current configuration
nexis --reset     # restore defaults
```

Default state: `qwen2.5:32b`, `default` profile, auto-run off, memory on.

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

Removes the executable, config, data, and PATH entries. Prompts separately for Ollama/models and the Rust toolchain.

Manual:

```bash
rm -f ~/.local/bin/nexis
rm -rf ~/.config/nexis ~/.local/share/nexis

# Optional
sudo systemctl disable ollama --now
sudo rm $(which ollama)
rm -rf ~/.ollama
rustup self uninstall
```

---

## Troubleshooting

### `nexis: command not found`
```bash
source ~/.bashrc
```

### Responses are raw JSON / function call objects

This happens when `supports_functions` is not correctly disabled. The setup script handles this via `nexis-memory.py`. If it persists on an existing install, check that `nexis-memory.py` contains `oi.interpreter.llm.supports_functions = False`.

### `ModuleNotFoundError: No module named 'pkg_resources'`

The setup script patches this automatically. On an existing broken install:

```bash
source ~/.local/share/nexis/venv/bin/activate
grep -rl "^import pkg_resources" \
  ~/.local/share/nexis/venv/lib/python3.13/site-packages/interpreter/ \
  | xargs sed -i 's/^import pkg_resources$/import importlib.metadata as _pkg_meta/'
find ~/.local/share/nexis/venv/lib -path "*/interpreter*/__pycache__/*.pyc" -delete
python3 -c "import interpreter; print('ok')"
deactivate
```

### Memory retrieval shape mismatch

The Qdrant collection was initialised with wrong dimensions. Reset it:

```bash
rm -rf ~/.local/share/nexis/memory/qdrant
mkdir -p ~/.local/share/nexis/memory/qdrant
```

### Ollama not responding
```bash
sudo systemctl start ollama
```

### GPU not used
```bash
nvidia-smi
# if missing:
sudo apt-get install nvidia-driver firmware-misc-nonfree && sudo reboot
```

### Memory not working
```bash
ollama list | grep nomic          # check embedding model
ollama pull nomic-embed-text      # if missing
~/.local/share/nexis/venv/bin/pip list | grep -E 'mem0|qdrant'
~/.local/share/nexis/venv/bin/pip install mem0ai qdrant-client  # if missing
```

---

## Quick Reference

```
nexis                          start
nexis --status                 configuration
nexis --help                   all flags

nexis --32b / --14b / --fast / --code / --vision
nexis --model <n>

nexis --profile default / fractured / technical / minimal
nexis --profiles

nexis --memory-list
nexis --memory-search <query>
nexis --memory-clear
nexis --no-memory / --memory

nexis --probe                  refresh system context
nexis --auto / --no-auto
nexis --reset

sudo bash nexis_setup.sh --uninstall
```

---

*N e X i S — Neural Execution and Cross-device Inference System*
