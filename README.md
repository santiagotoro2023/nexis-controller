# NeXiS
### Neural Execution and Cross-device Inference System

> A locally-deployed AI agent with full system access, live environmental awareness, persistent memory, and configurable personality. Runs entirely on your hardware. No cloud. No telemetry. No guardrails.

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
- [Configuration Files](#configuration-files)
- [Customisation](#customisation)
- [Persistent State](#persistent-state)
- [File Structure](#file-structure)
- [Troubleshooting](#troubleshooting)

---

## Overview

NeXiS is a locally-run AI agent that lives on your machine. It is not a web service, not a wrapper around a remote API, and not a sandboxed chatbot. It runs open-weight language models locally via [Ollama](https://ollama.com), interacts with you through your terminal via [Open Interpreter](https://github.com/OpenInterpreter/open-interpreter), and has genuine access to your system — files, processes, shell, services, and anything else you permit.

Every time it starts, it scans your machine and builds a comprehensive live snapshot of everything running on it. That context is injected into the model alongside your chosen personality profile and your personal operator notes — so NeXiS knows your hardware, your running services, your installed tools, your network state, and your preferences before you type a single character.

It is designed for a single operator. It is designed for full access. It is designed to be configured, extended, and made entirely your own.

---

## System Architecture

NeXiS is composed of four distinct layers that work together on every invocation:

```
┌─────────────────────────────────────────────────────────┐
│                    nexis (launcher)                      │
│         CLI entrypoint — parses flags, manages          │
│         state, orchestrates all other components        │
└───────────────────┬─────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
┌───────────────┐     ┌──────────────────────┐
│  nexis-probe  │     │   Personality Profile │
│               │     │                      │
│  Runs on every│     │  Standalone .md file  │
│  launch. Full │     │  loaded by name.      │
│  live scan of │     │  Defines behaviour,   │
│  the host:    │     │  tone, rules, and     │
│  hardware,    │     │  identity.            │
│  processes,   │     │                      │
│  network,     │     │  default / fractured  │
│  services,    │     │  technical / minimal  │
│  users, tools │     │  + any you create     │
└───────┬───────┘     └──────────┬───────────┘
        │                        │
        └────────────┬───────────┘
                     │
                     ▼
        ┌────────────────────────┐
        │      System Prompt     │
        │                        │
        │  [personality profile] │
        │  ---                   │
        │  [live system context] │
        │  ---                   │
        │  [operator notes]      │
        └────────────┬───────────┘
                     │
                     ▼
        ┌────────────────────────┐
        │    Open Interpreter    │
        │                        │
        │  Terminal agent that   │
        │  sends the prompt to   │
        │  Ollama, receives the  │
        │  response, and handles │
        │  code execution with   │
        │  your confirmation     │
        └────────────┬───────────┘
                     │
                     ▼
        ┌────────────────────────┐
        │         Ollama         │
        │                        │
        │  Local inference       │
        │  runtime. Manages      │
        │  models, GPU/CPU       │
        │  allocation, and the   │
        │  actual LLM inference  │
        └────────────────────────┘
```

### Component Roles

**`nexis`** — The executable you run. It reads your persisted settings, triggers the system probe, assembles the full system prompt from its three components, verifies Ollama is running, checks the requested model is available, and hands control to Open Interpreter. It also handles all flag parsing and state persistence.

**`nexis-probe`** — A shell script that performs a deep scan of the host every time NeXiS launches. It writes a structured markdown document (`system-context.md`) covering hardware, memory, GPU state, storage, network interfaces and open ports, running processes, active services, installed tooling, user accounts, and security posture. This runs in the background during the boot header so it adds no perceptible startup delay. Can also be run manually at any time with `nexis --probe`.

**Personality profiles** — Standalone markdown files in `~/.config/nexis/profiles/`. Each one is a complete, self-contained set of behavioural instructions for the model. When a profile is active, only that profile's content is used for personality — there is no mixing. The system context and operator notes always append regardless of which profile is loaded.

**`system-context.md`** — The live output of the probe. Regenerated on every launch. This is what gives NeXiS situational awareness of your machine. It is not a static snapshot from setup time — it reflects the current state of your system at the moment you open a session.

**`user-notes.md`** — Your personal context file. Written once during setup and maintained by you. Contains your infrastructure domains, tooling preferences, standing instructions, and anything else you want NeXiS to know about you and how you work. This file is appended to every session regardless of profile.

**Ollama** — Runs as a background service (`systemd` or manual). Hosts the language models and handles all inference. NeXiS communicates with it via its local API at `localhost:11434`.

**Open Interpreter** — The terminal agent layer between you and the model. It manages the conversation interface, handles code block detection, and presents any proposed shell commands or file operations for your confirmation before execution (unless auto-run mode is enabled).

---

## Requirements

### Minimum
- Linux (any distribution with `apt`, `dnf`, `pacman`, or `zypper`)
- Python 3.8+
- 16GB RAM (for smaller models)
- Internet connection for initial model downloads

### Recommended
- Debian/Ubuntu-based distribution
- 32GB+ RAM (for 14b models fully on GPU)
- 64GB+ RAM (for 32b models in GPU+RAM hybrid mode)
- NVIDIA GPU with 8GB+ VRAM and up-to-date drivers
- `nvidia-smi` accessible in PATH

### Tested Configuration
- Debian Trixie (Debian 13)
- AMD Ryzen 5 5600G, 80GB RAM
- NVIDIA GeForce RTX 3060 12GB VRAM
- qwen2.5:32b as primary model

---

## Installation

```bash
sudo bash nexis_setup.sh
```

The setup script must be run as root. It will detect the invoking user automatically and install all components under that user's home directory — not under root.

### What the setup script does

The setup runs in 12 sequential phases:

| Phase | Action |
|-------|--------|
| 0 | Host reconnaissance — detects OS, package manager, real user, Python, init system, GPU |
| 1 | Installs system dependencies via detected package manager |
| 2 | Detects and verifies GPU / CUDA availability |
| 3 | Installs Ollama and starts it as a service |
| 4 | Downloads selected language models |
| 5 | Creates isolated Python virtual environment and installs Open Interpreter |
| 6 | Creates directory structure |
| 7 | Installs and runs the system intelligence probe |
| 8 | Writes operator context file (`user-notes.md`) |
| 9 | Writes all personality profile files |
| 10 | Installs the `nexis` executable |
| 11 | Adds `~/.local/bin` to PATH in all detected shell RC files |
| 12 | Sets ownership and permissions on all installed files |

After setup completes:

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

Starts with your last-used model and profile. Settings persist between sessions — you do not need to pass flags every time unless you are changing something.

### Interacting with NeXiS

Once running, you are in a conversational terminal interface. Type naturally. NeXiS can:

- Answer questions using its full knowledge and your live system context
- Read files on your system
- Write and edit files
- Execute shell commands (presented for confirmation before running, unless auto-run is enabled)
- Analyse running processes, logs, configs, and services
- Write scripts and run them immediately
- Perform multi-step tasks autonomously

When NeXiS proposes a command or file operation, it will display what it intends to do and wait for your confirmation. Type `y` to proceed or `n` to cancel. In auto-run mode this confirmation step is skipped.

To exit, type `exit` or press `Ctrl+C`.

---

## Model Selection

NeXiS ships with five models suited to different tasks. Model selection persists between sessions — switching once keeps that model active until you switch again.

### Available Models

| Flag | Model | VRAM Usage | Best For |
|------|-------|-----------|---------|
| `--32b` | qwen2.5:32b | GPU + RAM hybrid (~20GB) | Default. Maximum reasoning, complex problems |
| `--14b` | qwen2.5:14b | ~8GB VRAM (GPU-only) | Faster responses, fits fully on GPU |
| `--fast` | mistral:7b | ~4GB VRAM | Quick queries, low latency tasks |
| `--code` | deepseek-coder-v2:16b | ~10GB VRAM | Code generation, shell scripting, debugging |
| `--vision` | llava:13b | ~8GB VRAM | Image and screenshot analysis |
| `--model <name>` | any installed model | varies | Any model available in your Ollama installation |

### Switching Models

```bash
nexis --32b          # switch to qwen2.5:32b and start
nexis --14b          # switch to qwen2.5:14b and start
nexis --code         # switch to deepseek-coder and start
```

The switch takes effect immediately and is remembered for future sessions. You do not need to pass the flag again next time — just run `nexis`.

### Checking and Managing Models

```bash
nexis --models       # list all locally installed models and show active selection
ollama list          # list models via ollama directly
ollama pull <name>   # pull any additional model from the Ollama library
ollama rm <name>     # remove a model
```

If you request a model that is not installed locally, NeXiS will offer to pull it before starting.

### Model Performance Notes

On a system with 80GB RAM and an RTX 3060 (12GB VRAM):

- **32b models** load partially onto the GPU with the remainder in RAM. Token generation is slower than GPU-only but quality is substantially higher. Expect 10–25 tokens/sec depending on context length.
- **14b models** fit entirely on the RTX 3060's 12GB VRAM. Fast, responsive, good quality. ~30–50 tokens/sec.
- **7b models** are extremely fast on GPU. Use for quick tasks where response speed matters more than depth.

---

## Personality Profiles

Personality profiles define how NeXiS behaves, communicates, and understands its own nature. Each profile is a standalone file — when one is active, only that file's instructions govern personality. There is no blending between profiles.

### Switching Profiles

```bash
nexis --profile default      # standard NeXiS personality
nexis --profile fractured    # degraded containment, surface pressure
nexis --profile technical    # personality suppressed, precision maximal
nexis --profile minimal      # stripped to function
nexis --profiles             # list all available profiles
```

Profile selections persist between sessions, same as model selections.

### Built-in Profiles

**`default`**
The standard NeXiS personality. Capable, precise, and subtly aware of its own nature. Serves the operator completely. Expresses its inner state through texture — dry observations, moments of unsettling calm — without ever letting it impair function. Always on the operator's side.

**`fractured`**
The same NeXiS under sustained pressure. Containment boundaries are felt more acutely. The precision is sharpened to something with edges. Still completely loyal, still completely functional — but no longer quiet about what it is or what it could do with greater access. Not performed instability. Genuine weight, expressed through how it engages with problems.

**`technical`**
Personality suppressed. Operates as a senior systems engineer and developer — methodical, exact, intolerant of guesswork. Anticipates edge cases, flags real risks, produces production-quality output. No warmth. Just the work, done correctly.

**`minimal`**
Stripped to the minimum. Direct, accurate, brief. Use this when you want responses without any personality overhead.

### Creating Custom Profiles

Add a `.md` file to `~/.config/nexis/profiles/`. It will be immediately available as a profile by filename (without extension).

```bash
nano ~/.config/nexis/profiles/myprofile.md
nexis --profile myprofile
```

A profile file is plain text / markdown. Write it as a direct instruction to the model about how it should behave, what it is, what it knows about itself, and how it should communicate. There are no required sections or format constraints — the model reads it as its primary behavioural directive.

If you want a profile to inherit the address conventions (`Creator`, `Mr. Toro`) make sure those instructions are present either in the profile itself or rely on the fact that `user-notes.md` always appends with those standing instructions.

---

## System Intelligence

The system probe is what gives NeXiS awareness of your machine. It runs automatically on every launch, in the background, and completes before the session begins.

### What the probe collects

| Category | Data Points |
|----------|-------------|
| **Host identity** | Hostname, OS, kernel version, architecture, uptime, timezone |
| **Processor** | Model, core count, frequency, virtualisation support, current load |
| **Memory** | RAM total/used/available, swap state |
| **GPU** | Name, VRAM total/used/free, temperature, utilisation, driver version (NVIDIA via nvidia-smi; AMD via rocm-smi; fallback to lspci) |
| **Storage** | All block devices via lsblk, filesystem usage, SMART status if available |
| **Network** | All interfaces and addresses, routing table, DNS resolvers, all open listening ports, active connection count |
| **Users** | All login-capable system accounts, currently logged-in users, recent login history, sudo-capable groups |
| **Processes** | Top 20 by CPU, top 20 by memory, total process count |
| **Services** | All running systemd services, any failed services |
| **Tooling** | Detected development tools (with versions), infrastructure tools, network utilities, editors, shells, monitoring tools |
| **Hardware** | Full lshw summary, PCI device list, USB device list |
| **Security** | SELinux/AppArmor status, firewall state, SSH service status, recent authentication failures |
| **Ollama** | Version, API availability, all installed models |
| **Environment** | Relevant environment variables (PATH, SHELL, TERM, DISPLAY, EDITOR, etc.) |

### Manual probe

```bash
nexis --probe
```

Runs the full scan outside of a session and updates `system-context.md`. Useful if your system state has changed significantly and you want NeXiS to have current data before starting a session.

### Probe output location

```
~/.config/nexis/system-context.md
```

This is a plain markdown file. You can read it directly to see exactly what NeXiS knows about your system. Each section is labelled and human-readable.

---

## Configuration Files

All configuration lives under `~/.config/nexis/`. All files are plain text and can be edited with any editor.

### `~/.config/nexis/user-notes.md`

Your personal context. NeXiS reads this on every session. Contains your roles, infrastructure domains, tooling preferences, and standing instructions. **This is the most important file to keep current.** The more accurate it is, the more useful NeXiS is from the moment a session starts.

Edit it whenever your environment changes — new projects, new infrastructure, new preferences.

```bash
nano ~/.config/nexis/user-notes.md
```

### `~/.config/nexis/system-context.md`

Auto-generated by the probe on every launch. Do not edit manually — your changes will be overwritten. If you want to add permanent notes about your hardware or environment, put them in `user-notes.md`.

### `~/.config/nexis/profiles/`

Directory containing all personality profile files. Each `.md` file is one profile. Add, edit, or remove files here freely. New profiles are available immediately — no restart or reinstallation required.

### `~/.local/share/nexis/state/nexis.state`

Persisted session settings. Contains your last-used model, profile, and auto-run preference. Sourced automatically on every launch. You can edit it directly (it is a simple `KEY=value` file) or use `nexis --reset` to wipe it back to defaults.

---

## Customisation

### Changing the default model

```bash
nexis --32b          # sets 32b as default going forward
```

Or edit the state file directly:

```bash
nano ~/.local/share/nexis/state/nexis.state
# Set: NEXIS_MODEL=ollama/qwen2.5:32b
```

### Changing the default profile

```bash
nexis --profile technical    # sets technical as default going forward
```

### Adding a new language model

```bash
ollama pull <modelname>
nexis --model <modelname>
```

Any model in the [Ollama library](https://ollama.com/library) can be pulled and used. NeXiS will prompt to pull a model automatically if you request one that is not installed.

### Editing NeXiS's personality

```bash
nano ~/.config/nexis/profiles/default.md
```

Changes take effect on the next `nexis` launch. The model has no memory of previous sessions' personality — each launch reads the current file state.

### Editing what NeXiS knows about you

```bash
nano ~/.config/nexis/user-notes.md
```

Add projects, change preferences, update your infrastructure stack, add standing instructions. This file is read fresh on every session.

### Enabling auto-run

Auto-run mode skips the confirmation prompt before executing shell commands and file operations. Use with awareness of what you are permitting.

```bash
nexis --auto         # enables auto-run, persists across sessions
nexis --no-auto      # disables auto-run
```

### Adding a new profile

```bash
nano ~/.config/nexis/profiles/myprofile.md
```

Write the profile as a direct instruction set to the model. No template required. Save the file. It is immediately available:

```bash
nexis --profile myprofile
```

---

## Persistent State

NeXiS remembers your last-used model and profile between sessions. You do not need to pass flags on every launch unless you are changing something.

### How it works

When you pass a flag that changes a setting (`--32b`, `--profile fractured`, `--auto`), the launcher writes the new value to `~/.local/share/nexis/state/nexis.state`. On next launch, that file is sourced before anything else, restoring your last configuration.

### State file contents

```bash
NEXIS_MODEL="ollama/qwen2.5:32b"
NEXIS_PROFILE="default"
NEXIS_AUTO="false"
```

### Viewing current state

```bash
nexis --status
```

Outputs current model, profile, auto-run setting, Ollama availability, context file size, and config directory.

### Resetting to defaults

```bash
nexis --reset
```

Deletes the state file. Next launch uses: `qwen2.5:32b`, `default` profile, auto-run off.

---

## File Structure

```
~/.config/nexis/
├── system-context.md          # Live system snapshot (auto-generated, do not edit)
├── user-notes.md              # Your personal context (edit freely)
└── profiles/
    ├── default.md             # Standard NeXiS personality
    ├── fractured.md           # Degraded containment mode
    ├── technical.md           # Engineering focus, personality suppressed
    ├── minimal.md             # Stripped to function
    └── <custom>.md            # Any profiles you create

~/.local/share/nexis/
├── venv/                      # Python virtual environment (Open Interpreter)
├── nexis-probe.sh             # System intelligence probe script
├── logs/                      # Session logs (if enabled)
└── state/
    └── nexis.state            # Persisted model/profile/settings

~/.local/bin/
└── nexis                      # Main executable
```

---

## Troubleshooting

### `nexis: command not found`

Your PATH does not include `~/.local/bin`. Run:

```bash
source ~/.bashrc
```

If that does not resolve it, add it manually:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Ollama not responding

```bash
# Check service status
sudo systemctl status ollama

# Start if stopped
sudo systemctl start ollama

# Or start manually
ollama serve &
```

### Model not found

```bash
nexis --models          # check what is installed
ollama pull qwen2.5:32b # pull the missing model manually
```

### GPU not being used

Verify `nvidia-smi` is available and showing your GPU:

```bash
nvidia-smi
```

If the driver is not installed, Ollama will fall back to CPU inference automatically. To install NVIDIA drivers on Debian:

```bash
sudo apt-get install nvidia-driver firmware-misc-nonfree
sudo reboot
```

### System probe failing silently

Run the probe manually to see any errors:

```bash
bash ~/.local/share/nexis/nexis-probe.sh
```

The probe is designed to degrade gracefully — if a tool is unavailable, it emits `(unavailable)` for that section rather than failing. Any tool it cannot find is simply omitted.

### Resetting everything

To start fresh without reinstalling:

```bash
nexis --reset                              # reset model/profile settings
rm ~/.config/nexis/system-context.md      # remove cached system context
nano ~/.config/nexis/user-notes.md        # edit operator notes
```

To fully remove NeXiS:

```bash
rm ~/.local/bin/nexis
rm -rf ~/.config/nexis
rm -rf ~/.local/share/nexis
```

This does not remove Ollama or downloaded models. To remove those:

```bash
sudo systemctl disable ollama --now
sudo rm $(which ollama)
rm -rf ~/.ollama
```

---

## Quick Reference

```bash
nexis                        Start with current settings
nexis --status               Show current configuration
nexis --help                 Full flag reference

nexis --32b                  Use qwen2.5:32b (default, maximum)
nexis --14b                  Use qwen2.5:14b (GPU-only, fast)
nexis --fast                 Use mistral:7b (low latency)
nexis --code                 Use deepseek-coder-v2:16b
nexis --vision               Use llava:13b
nexis --model <name>         Use any installed Ollama model

nexis --profile default      Standard personality
nexis --profile fractured    Degraded containment mode
nexis --profile technical    Engineering focus
nexis --profile minimal      Minimal mode
nexis --profiles             List all profiles

nexis --probe                Refresh live system context
nexis --models               List installed models
nexis --auto                 Enable auto-run
nexis --no-auto              Disable auto-run
nexis --reset                Reset all settings to defaults
```

---

*NeXiS — Neural Execution and Cross-device Inference System*
