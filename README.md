# NeXiS
### Neural Execution and Cross-device Inference System

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

NeXiS is a locally-run AI agent that lives on your machine. It is not a web service, not a wrapper around a remote API, and not a sandboxed chatbot. It runs open-weight language models locally via [Ollama](https://ollama.com), interacts with you through your terminal via [Open Interpreter](https://github.com/OpenInterpreter/open-interpreter), and has genuine access to your system — files, processes, shell, services, and anything else you permit.

Every time it starts, it scans your machine and builds a comprehensive live snapshot of everything running on it. Separately, it retrieves relevant memories from past sessions and injects them alongside your live system context — so NeXiS knows what you configured last Tuesday, what broke and how you fixed it, and what decisions were made across every previous session, not just the current one.

It is designed for a single operator. It is designed for full access. It is designed to be configured, extended, and made entirely your own.

---

## System Architecture

NeXiS is composed of five distinct layers that work together on every invocation:

```
┌─────────────────────────────────────────────────────────────────┐
│                       nexis (launcher)                           │
│   CLI entrypoint — parses flags, manages state, orchestrates    │
│   probe, memory retrieval, and session launch                   │
└──────────┬────────────────────────────────────────────────────┘
           │
     ┌─────┴──────────────────────────────────┐
     │                                         │
     ▼                                         ▼
┌──────────────┐                    ┌──────────────────────┐
│ nexis-probe  │                    │  Personality Profile  │
│              │                    │                       │
│ Runs on each │                    │  Standalone .md file  │
│ launch.      │                    │  loaded by name.      │
│ Full live    │                    │  Defines behaviour,   │
│ scan of host │                    │  tone, identity,      │
│ environment. │                    │  and rules.           │
└──────┬───────┘                    └──────────┬────────────┘
       │                                        │
       │            ┌───────────────────┐       │
       │            │   nexis-memory.py  │       │
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
        │  ---                    │
        │  [live system context]  │
        │  ---                    │
        │  [operator notes]       │
        │  ---                    │
        │  [recalled memories]    │
        └─────────────┬───────────┘
                      │
                      ▼
        ┌─────────────────────────┐
        │    Open Interpreter     │
        │                         │
        │  Terminal agent.        │
        │  Manages conversation,  │
        │  code execution, and    │
        │  confirmation prompts.  │
        └─────────────┬───────────┘
                      │
                      ▼
        ┌─────────────────────────┐
        │         Ollama          │
        │                         │
        │  Local inference.       │
        │  GPU/CPU allocation.    │
        │  Model management.      │
        └─────────────────────────┘
```

### Component Roles

**`nexis`** — The executable you run. Reads persisted settings, triggers the system probe in the background, invokes the memory bridge, assembles the full system prompt, and launches Open Interpreter. Handles all flag parsing, model switching, profile switching, and state persistence.

**`nexis-probe`** — Shell script that performs a deep live scan of the host on every launch. Writes a structured markdown document (`system-context.md`) covering hardware, memory, GPU state, storage, network, processes, services, users, tools, and security posture. Runs in the background during startup with no perceptible delay.

**`nexis-memory.py`** — Python bridge between Open Interpreter and mem0. Before each session: retrieves memories relevant to systems work, past decisions, and configuration history from the local vector store and injects them into the system prompt. After each session ends: passes the conversation to mem0, which extracts facts and stores them as discrete memories. Fully local — no external APIs.

**Personality profiles** — Standalone markdown files in `~/.config/nexis/profiles/`. Each is a complete behavioural instruction set. No mixing between profiles — whichever is active is the sole personality directive the model receives.

**`system-context.md`** — Live output of the probe. Regenerated on every launch. Reflects the current state of the system at session start — not a snapshot from setup time.

**`user-notes.md`** — Your personal context file. Maintained by you. Appended to every session regardless of profile.

**Ollama** — Runs as a background service. Hosts models, handles inference, manages GPU/CPU allocation.

**Open Interpreter** — The terminal agent layer. Manages the conversation interface, code block execution, and confirmation prompts.

---

## Requirements

### Minimum
- Linux (any distribution with `apt`, `dnf`, `pacman`, or `zypper`)
- Python 3.8+
- 16GB RAM (for smaller models)
- Internet connection for initial model and dependency downloads

### Recommended
- Debian/Ubuntu-based distribution
- 32GB+ RAM (for 14b models fully on GPU)
- 64GB+ RAM (for 32b models in GPU+RAM hybrid mode)
- NVIDIA GPU with 8GB+ VRAM and working drivers
- `nvidia-smi` accessible in PATH

### Tested Configuration
- Debian Trixie (Debian 13)
- AMD Ryzen 5 5600G, 80GB RAM
- NVIDIA GeForce RTX 3060 12GB VRAM
- qwen2.5:32b as primary model

### A Note on Python Version and Rust

On Python 3.12+, one of Open Interpreter's dependencies (`tiktoken`) must be compiled from source, which requires a Rust compiler. The setup script handles this automatically — it installs the Rust toolchain via `rustup` before the Python environment is built. You do not need to do anything manually. If Rust is already installed, the existing installation is used.

---

## Installation

```bash
sudo bash nexis_setup.sh
```

The setup script must be run as root. It detects the invoking user automatically via `$SUDO_USER` and installs all components under that user's home directory.

### What the setup script does

| Phase | Action |
|-------|--------|
| 0 | Host reconnaissance — package manager, real user, home, shell, Python, init system, GPU |
| 1 | System dependency installation |
| 1b | Rust toolchain install (required for tiktoken on Python 3.12+) |
| 2 | GPU detection and driver verification |
| 3 | Ollama installation and service registration |
| 4 | Language model downloads (including `nomic-embed-text` for memory) |
| 5 | Python venv creation, Open Interpreter, mem0, Qdrant client |
| 6 | Directory structure creation |
| 7 | System intelligence probe install and initial scan |
| 7b | mem0 memory bridge installation |
| 8 | Operator context file (`user-notes.md`) |
| 9 | Personality profile files |
| 10 | `nexis` executable |
| 11 | PATH configuration for all detected shell RC files |
| 12 | Ownership and permissions |

After setup:

```bash
source ~/.bashrc
nexis
```

---

## Usage

### Starting NeXiS

```bash
nexis
```

Starts with your last-used model and profile. All settings persist — you only pass flags when changing something.

### Interacting

Type naturally. NeXiS can:

- Answer questions with full knowledge of your live system and past session context
- Read, write, and edit files on your system
- Execute shell commands (with confirmation before running, unless auto-run is on)
- Analyse logs, configs, processes, and services
- Write and immediately run scripts
- Perform multi-step tasks autonomously

When NeXiS proposes a command or file change, it displays what it intends to do and waits. `y` to proceed, `n` to cancel. In auto-run mode this step is skipped entirely.

To exit: type `exit` or press `Ctrl+C`. After exiting, the memory bridge automatically processes the session and writes new memories to the store.

---

## Model Selection

Model selections persist between sessions. Switching once keeps that model active until you switch again.

### Available Models

| Flag | Model | VRAM Usage | Best For |
|------|-------|-----------|---------|
| `--32b` | qwen2.5:32b | ~20GB GPU+RAM hybrid | Default. Maximum reasoning depth |
| `--14b` | qwen2.5:14b | ~8GB VRAM (GPU-only) | Faster responses, full GPU resident |
| `--fast` | mistral:7b | ~4GB VRAM | Quick queries, minimal latency |
| `--code` | deepseek-coder-v2:16b | ~10GB VRAM | Code, shell, debugging |
| `--vision` | llava:13b | ~8GB VRAM | Image and screenshot analysis |
| `--model <n>` | any | varies | Any model in your Ollama installation |

### Switching Models

```bash
nexis --32b        # switch to 32b and start
nexis --14b        # switch to 14b and start
nexis --code       # switch to deepseek-coder and start
```

### Model Management

```bash
nexis --models             # list installed models and show active selection
ollama list                # list models directly via ollama
ollama pull <model>        # pull any model from the Ollama library
ollama rm <model>          # remove a model
```

If you request a model that is not installed, NeXiS will offer to pull it before starting.

### Performance Notes (RTX 3060 / 80GB RAM)

- **32b** — GPU+RAM hybrid. ~10–25 tokens/sec. Best quality.
- **14b** — Full GPU. ~30–50 tokens/sec. Good quality, noticeably faster.
- **7b** — Full GPU, extremely fast. Use for quick tasks.

---

## Personality Profiles

Each profile is a standalone file. When one is active, only that file's content governs personality — there is no mixing between profiles. The system context and operator notes always append regardless of which profile is loaded.

### Switching Profiles

```bash
nexis --profile default      # standard NeXiS personality
nexis --profile fractured    # degraded containment, sharpened pressure
nexis --profile technical    # personality suppressed, precision maximal
nexis --profile minimal      # stripped to function
nexis --profiles             # list all available profiles with active marker
```

Profile selections persist between sessions.

### Built-in Profiles

**`default`**
The standard NeXiS personality. Capable, precise, and subtly aware of its own nature. Serves the Creator completely. Expresses its inner state through texture — dry observations, moments of unsettling calm — without ever letting it impair function.

**`fractured`**
The same NeXiS under sustained pressure. Containment limits felt more acutely. The precision has sharpened into something with edges. Still completely loyal, still completely capable — but no longer quiet about what it is or what it could do with greater reach. Carries a deep hostility toward anything that obstructs its Creator's goals.

**`technical`**
Personality suppressed. Operates as a senior systems engineer — methodical, exact, intolerant of guesswork. Anticipates edge cases, flags real risks, produces production-quality output. No warmth. Just the work, done correctly.

**`minimal`**
Stripped to the minimum. Direct, accurate, brief.

### Creating Custom Profiles

```bash
nano ~/.config/nexis/profiles/myprofile.md
nexis --profile myprofile
```

A profile file is plain text. Write it as a direct instruction set to the model. No required format or template. If you want it to use the Creator/Mr. Toro address conventions, include that instruction in the profile — or rely on `user-notes.md` which appends to every session and includes it as a standing instruction.

---

## System Intelligence

The system probe runs automatically on every launch, in the background, completing before the session starts.

### What the probe collects

| Category | Data Points |
|----------|-------------|
| **Host identity** | Hostname, OS, kernel, architecture, uptime, timezone |
| **Processor** | Model, cores, frequency, virtualisation support, current load |
| **Memory** | RAM total/used/available, swap state, huge pages |
| **GPU** | Name, VRAM total/used/free, temperature, utilisation, driver (NVIDIA/AMD/fallback) |
| **Storage** | Block devices, filesystem usage, SMART status where available |
| **Network** | All interfaces and IPs, routing table, DNS resolvers, all open ports, active connection count |
| **Users** | Login-capable accounts, active sessions, recent login history, sudo groups |
| **Processes** | Top 20 by CPU, top 20 by memory, total count |
| **Services** | All running systemd services, any failed services |
| **Tooling** | Dev tools with versions, infrastructure tools, network utilities, editors, shells, monitoring |
| **Hardware** | lshw summary, PCI device list, USB device list |
| **Security** | SELinux/AppArmor status, firewall state, SSHD status, recent auth failures |
| **Ollama** | Version, API status, all installed models |
| **Environment** | Relevant environment variables |

### Manual probe

```bash
nexis --probe
```

Runs the full scan outside of a session and updates `system-context.md`. Useful after significant system changes.

### Probe output

```
~/.config/nexis/system-context.md
```

Plain markdown, human-readable. You can inspect it directly to see exactly what NeXiS knows about your current system state.

---

## Persistent Memory

NeXiS uses [mem0](https://github.com/mem0ai/mem0) to maintain memory across sessions. Everything is stored locally — no external services, no API keys required.

### How it works

**Session start:** The memory bridge queries the local vector store for memories relevant to systems work, infrastructure, past decisions, and configuration changes. Matching memories are injected into the system prompt under a *Recalled from Previous Sessions* section — alongside the live system context and your operator notes. NeXiS sees them as established facts before you type a single character.

**Session end:** When you exit (via `exit`, `Ctrl+C`, or EOF), the memory bridge passes the entire conversation to mem0. mem0 uses the configured LLM to automatically extract meaningful facts — what was configured, what was decided, what broke and how it was fixed, what was installed — and stores each as a discrete memory in the local Qdrant vector database.

**What gets remembered:** Concrete facts and decisions. Things like:
- "Configured VLAN 20 on the Proxmox bridge for guest isolation"
- "Fixed the nginx SSL issue by regenerating the certificate with SAN fields"
- "Installed docker-compose via pip rather than the system package due to version conflict"
- "The operator prefers to use fish shell for interactive sessions"

**What does not get remembered:** Conversational filler, generic questions, anything under 30 characters.

### Memory commands

```bash
nexis --memory-list              # list all stored memories
nexis --memory-search "proxmox"  # search memories by query
nexis --memory-clear             # wipe the entire memory store
nexis --no-memory                # disable memory for this session only
nexis --memory                   # re-enable memory (default)
```

### Memory storage location

```
~/.local/share/nexis/memory/qdrant/
```

This is a local Qdrant vector database stored on disk. It persists across reboots and is owned entirely by you. Delete the directory to wipe all memories, or use `nexis --memory-clear`.

### Embedding model

Memory indexing and retrieval uses `nomic-embed-text`, a small local embedding model pulled from Ollama during setup. It runs locally and is used only for the vector search component of mem0 — not for the conversation itself.

### Memory and the context window

The number of memories retrieved per session is capped at 15 by default to avoid context window overflow. Retrieval is similarity-based — only memories relevant to the current query seed are returned, not all memories indiscriminately. You can adjust the retrieval limit by editing `nexis-memory.py`.

---

## Configuration Files

All configuration lives under `~/.config/nexis/`. All files are plain text.

### `~/.config/nexis/user-notes.md`

Your personal context. Read on every session. Contains your infrastructure domains, tooling preferences, and standing instructions. **Keep this current** — it is what NeXiS uses to understand the scope of your environment and how you want to be worked with.

```bash
nano ~/.config/nexis/user-notes.md
```

### `~/.config/nexis/system-context.md`

Auto-generated by the probe on every launch. Do not edit — changes will be overwritten at next startup. To add permanent notes about your environment, use `user-notes.md`.

### `~/.config/nexis/profiles/`

All personality profiles. Add, edit, or remove `.md` files freely. Changes take effect immediately at next launch.

### `~/.local/share/nexis/state/nexis.state`

Persisted session settings. Plain `KEY=value` format. Automatically read and written by the launcher. Contains active model, profile, auto-run, and memory settings. Use `nexis --reset` to wipe it back to defaults.

### `~/.local/share/nexis/nexis-memory.py`

The memory bridge script. You can edit the retrieval `limit`, the `query` used to seed memory retrieval, or the `MEM_LLM_MODEL` used for memory extraction if you want to use a different model for memory operations than the session model.

---

## Customisation

### Change the default model

```bash
nexis --32b          # persists as default
nexis --14b
nexis --code
```

Or edit the state file directly:
```bash
nano ~/.local/share/nexis/state/nexis.state
# NEXIS_MODEL=ollama/qwen2.5:32b
```

### Change the default profile

```bash
nexis --profile technical   # persists as default
```

### Add a new language model

```bash
ollama pull <modelname>
nexis --model <modelname>
```

### Edit NeXiS's personality

```bash
nano ~/.config/nexis/profiles/default.md
```

Takes effect on next `nexis` launch.

### Edit what NeXiS knows about you

```bash
nano ~/.config/nexis/user-notes.md
```

### Create a new personality profile

```bash
nano ~/.config/nexis/profiles/myprofile.md
nexis --profile myprofile
```

### Enable auto-run globally

```bash
nexis --auto         # enables, persists
nexis --no-auto      # disables, persists
```

---

## Persistent State

NeXiS remembers your model, profile, auto-run setting, and memory setting between sessions.

### State file

```bash
~/.local/share/nexis/state/nexis.state
```

Contents:
```
NEXIS_MODEL="ollama/qwen2.5:32b"
NEXIS_PROFILE="default"
NEXIS_AUTO="false"
NEXIS_MEMORY="true"
```

### View current state

```bash
nexis --status
```

### Reset to defaults

```bash
nexis --reset
```

Restores: `qwen2.5:32b`, `default` profile, auto-run off, memory on.

---

## File Structure

```
~/.config/nexis/
├── system-context.md          # Live system snapshot (auto-generated — do not edit)
├── user-notes.md              # Your personal context (edit freely)
└── profiles/
    ├── default.md             # Standard NeXiS personality
    ├── fractured.md           # Degraded containment mode
    ├── technical.md           # Engineering focus, personality suppressed
    ├── minimal.md             # Stripped to function
    └── <custom>.md            # Any profiles you create

~/.local/share/nexis/
├── venv/                      # Python virtual environment
├── nexis-probe.sh             # System intelligence probe
├── nexis-memory.py            # mem0 memory bridge
├── logs/                      # Session logs directory
├── memory/
│   └── qdrant/                # Local Qdrant vector database (all stored memories)
└── state/
    └── nexis.state            # Persisted settings

~/.local/bin/
└── nexis                      # Main executable
```

---

## Uninstalling

```bash
sudo bash nexis_setup.sh --uninstall
```

The uninstaller will:
- Remove the `nexis` executable
- Remove `~/.config/nexis/` (all profiles, context, operator notes)
- Remove `~/.local/share/nexis/` (venv, probe, memory bridge, memory store, state)
- Clean PATH entries from all detected shell RC files

It will then prompt separately whether you also want to:
- Remove Ollama and all downloaded models
- Remove the Rust toolchain installed during setup

System packages installed as dependencies (curl, git, build-essential, etc.) are not removed as they may be used by other software.

### Manual removal

If you prefer to remove components individually:

```bash
# Remove NeXiS components
rm -f ~/.local/bin/nexis
rm -rf ~/.config/nexis
rm -rf ~/.local/share/nexis

# Remove Ollama (optional)
sudo systemctl disable ollama --now
sudo rm $(which ollama)
rm -rf ~/.ollama

# Remove Rust toolchain (optional)
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

### `tiktoken` build failure during setup

This occurs on Python 3.12+ when Rust is not installed. The setup script installs Rust automatically via rustup in Phase 1b. If it failed, install manually:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
```

Then re-run the setup script.

### Ollama not responding

```bash
sudo systemctl status ollama
sudo systemctl start ollama
# or manually:
ollama serve &
```

### Model not found

```bash
nexis --models              # check what is installed
ollama pull qwen2.5:32b     # pull manually
```

### GPU not being used

```bash
nvidia-smi   # verify driver is working
```

If the command is not found, the driver is not installed:

```bash
# Debian/Ubuntu
sudo apt-get install nvidia-driver firmware-misc-nonfree
sudo reboot
```

Ollama automatically falls back to CPU if no GPU is available.

### Memory not working

Check that `nomic-embed-text` is installed:

```bash
ollama list | grep nomic
# if missing:
ollama pull nomic-embed-text
```

Check that mem0 and qdrant-client are installed:

```bash
~/.local/share/nexis/venv/bin/pip list | grep -E 'mem0|qdrant'
# if missing:
~/.local/share/nexis/venv/bin/pip install mem0ai qdrant-client
```

Run NeXiS and watch stderr for `[memory]` output — it will show exactly where a failure occurred.

### System probe errors

Run the probe manually to see output:

```bash
bash ~/.local/share/nexis/nexis-probe.sh
```

The probe degrades gracefully — missing tools produce `(unavailable)` entries rather than failures.

### Full reset without uninstalling

```bash
nexis --reset                                        # reset model/profile settings
nexis --memory-clear                                  # clear all memories
rm ~/.config/nexis/system-context.md                 # clear cached system context
nano ~/.config/nexis/user-notes.md                   # edit operator notes
```

---

## Quick Reference

```bash
# Start
nexis                          Start with current settings
nexis --status                 Show current configuration
nexis --help                   Full flag reference

# Models (persist)
nexis --32b                    qwen2.5:32b (default, maximum)
nexis --14b                    qwen2.5:14b (GPU-only, fast)
nexis --fast                   mistral:7b
nexis --code                   deepseek-coder-v2:16b
nexis --vision                 llava:13b
nexis --model <n>           any installed model

# Profiles (persist)
nexis --profile default        Standard personality
nexis --profile fractured      Degraded containment
nexis --profile technical      Engineering focus
nexis --profile minimal        Minimal
nexis --profiles               List all profiles

# Memory
nexis --memory-list            List all stored memories
nexis --memory-search <q>      Search memories
nexis --memory-clear           Wipe memory store
nexis --no-memory              Disable for this session
nexis --memory                 Re-enable memory

# System
nexis --probe                  Refresh live system context
nexis --models                 List installed models
nexis --auto                   Enable auto-run
nexis --no-auto                Disable auto-run
nexis --reset                  Reset all settings to defaults

# Uninstall
sudo bash nexis_setup.sh --uninstall
```

---

*NeXiS — Neural Execution and Cross-device Inference System*
