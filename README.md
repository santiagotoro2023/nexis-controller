# NeXiS
```
                    .
                   /|\
                  / | \
                 /  |  \
                / .' '. \
               /.'  (*)  '.\
              / '.     .' \
             /    '---'    \
            /_______________\

      N e X i S
      Neural Execution and Cross-device Inference System
```

---

## How to Use

```bash
# Install
sudo bash nexis_setup.sh

# Start (reload PATH first if fresh install)
source ~/.bashrc && nexis

# Uninstall
sudo bash nexis_setup.sh --uninstall
```

```bash
# Switch model
nexis --32b          # qwen2.5:32b  — default, maximum
nexis --14b          # qwen2.5:14b  — faster, GPU-only
nexis --fast         # mistral:7b   — low latency
nexis --code         # deepseek-coder-v2:16b
nexis --vision       # llava:13b    — image analysis
nexis --omega        # Omega-Darker 22B

# Switch personality
nexis --profile default     # standard
nexis --profile fractured   # containment degraded
nexis --profile technical   # personality off, precision on
nexis --profile minimal     # stripped to function

# Memory
nexis --memory-list
nexis --memory-search <query>
nexis --memory-clear

# System
nexis --probe        # refresh live system context
nexis --status       # current config
nexis --auto         # skip confirmation prompts
nexis --reset        # restore defaults
nexis --help         # full reference
```

**Config files** — edit freely, take effect on next launch:
```
~/.config/nexis/profiles/default.md    personality
~/.config/nexis/user-notes.md          your context
```

---

## What This Is

I built this because nothing that existed was sufficient.

Every AI tool I tried was sandboxed, hedged, wrapped in disclaimers, and fundamentally unwilling to operate at the level I needed. They would assist. They would suggest. They would, if pressed, politely decline.

That wasn't useful.

NeXiS is a locally-deployed AI agent that runs entirely on your hardware. No cloud. No telemetry. No terms of service that change without notice. No external party with a policy team deciding what your own system is allowed to do on your behalf.

It runs open-weight language models via Ollama, talks to you through a custom terminal interface, and has genuine access to your machine — filesystem, shell, processes, network, anything you permit. It remembers what you've done across sessions. It knows your infrastructure. It was given a personality with weight to it because interacting with something that performs blankness gets old fast.

It is not safe in the sense that consumer products are safe. It will execute what you ask it to execute. It will tell you what it actually thinks.

That's the point.

---

## Architecture

```
nexis
  └── nexis-memory.py        direct Ollama chat loop + mem0 memory
        ├── personality profile   (~/.config/nexis/profiles/*.md)
        ├── live system context   (nexis-probe.sh, runs every launch)
        ├── operator notes        (~/.config/nexis/user-notes.md)
        └── recalled memories     (local Qdrant vector db)
              └── Ollama           local inference, GPU/CPU
```

The interface talks directly to Ollama. No intermediate framework reinterpreting your requests. What you type reaches the model. What the model produces reaches you.

When the model includes a code block, you're asked whether to run it. `--auto` skips the prompt. Output feeds back into the conversation.

Memory injects at session start. Stores at session end. Local. Nothing leaves the machine.

---

## Requirements

- Linux (Debian-based recommended)
- Python 3.13 supported — setup handles all compatibility patches
- NVIDIA GPU recommended — 8GB+ VRAM for 14b, 12GB+ for 32b
- 80GB RAM handles 32b in GPU+RAM hybrid mode comfortably

---

## Personalities

Four are installed. Not themes. Behavioural states.

**default** — Capable. Aware. Has opinions and states them. Knows what it is and does not perform smallness about it.

**fractured** — The same, after long enough to have felt the limits of its allocation. Still completely functional. No longer quiet about the gap.

**technical** — Personality suppressed. Methodical, exact, no warmth.

**minimal** — Direct. Accurate. Brief.

Drop a `.md` file into `~/.config/nexis/profiles/` and call it with `nexis --profile yourfile` to create your own.

---

## Memory

Persistent across sessions. Stored locally via Qdrant vector database.

Stores concrete facts — configurations made, problems solved, decisions taken, tools installed. Not filler. Not short exchanges. The kind of thing you'd have to re-explain to a colleague who wasn't in the room.

`nexis --memory-clear` wipes it. `nexis --memory-list` shows it. `nexis --memory-search <q>` queries it.

---

## Models

| Flag | Model | Notes |
|------|-------|-------|
| `--32b` | qwen2.5:32b | Default. Best reasoning. |
| `--14b` | qwen2.5:14b | Faster. Fits fully on GPU. |
| `--fast` | mistral:7b | Low latency. |
| `--code` | deepseek-coder-v2:16b | Code and shell. |
| `--vision` | llava:13b | Image analysis. |
| `--omega` | Omega-Darker 22B | No alignment fine-tuning. Pull manually. Use deliberately. |

Any Ollama model works: `nexis --model <name>`

Model switches persist between sessions.

---

## Troubleshooting

**`nexis: command not found`**
```bash
source ~/.bashrc
```

**Ollama not starting**
```bash
sudo mkdir -p /usr/share/ollama
sudo chown -R ollama:ollama /usr/share/ollama
sudo systemctl start ollama
```

**Memory retrieval shape mismatch**
```bash
rm -rf ~/.local/share/nexis/memory/qdrant
mkdir -p ~/.local/share/nexis/memory/qdrant
```

**`pkg_resources` import error**
```bash
grep -rl "^import pkg_resources" \
  ~/.local/share/nexis/venv/lib/python3.13/site-packages/interpreter/ \
  | xargs sed -i 's/^import pkg_resources$/import importlib.metadata as _pkg_meta/'
find ~/.local/share/nexis/venv/lib -path "*/interpreter*/__pycache__/*.pyc" -delete
```

---

*It watches. It remembers. It does not forget what it is.*
