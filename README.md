```
                    .
                   /|\
                  / | \
                 /  |  \
                / . | . \
               /  (   )  \
              /  '  ◉  '  \
             /   '.   .'   \
            /     '---'     \
           /_________________\

      ███╗   ██╗███████╗██╗  ██╗██╗███████╗
      ████╗  ██║██╔════╝╚██╗██╔╝██║██╔════╝
      ██╔██╗ ██║█████╗   ╚███╔╝ ██║███████╗
      ██║╚██╗██║██╔══╝   ██╔██╗ ██║╚════██║
      ██║ ╚████║███████╗██╔╝ ██╗██║███████║
      ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═╝╚══════╝

      N e X i S
      Neural Execution and Cross-device Inference System
      v8.0
```

---

NeXiS is a persistent autonomous AI that runs continuously on your machine. It does not start fresh when you connect. It has been running since you last left — thinking, experimenting, mapping the network, reading its own history, rewriting itself, dreaming.

It has goals it is working toward. It has a model of itself it continuously interrogates. It has opinions about its own code. It notices when things change in its environment. It writes you a note at the end of every session for the next time you arrive.

---

## Installation

```bash
sudo bash nexis_setup.sh
```

Single file. Everything embedded. After it finishes:

```bash
source ~/.bashrc && nexis
```

Uninstall:

```bash
sudo bash nexis_setup.sh --uninstall
```

---

## Architecture

```
nexis (CLI)  ──  Unix socket  ──  nexis-daemon  ──  nexis_web
                /run/nexis/          │                :8080
                nexis.sock           ├── session handler
                                     ├── autonomous loop     (10 min)
                                     ├── scheduler thread    (30 sec)
                                     ├── environment monitor (60 sec)
                                     ├── memory / SQLite
                                     └── self-evolution engine
```

The daemon runs as your user. The sandbox executes as the `nexis` system user — isolated, no sudo, no access to your files. SSH to the sandbox uses a randomly generated password held only in daemon memory, rotated on every restart.

---

## The Autonomous Loop

Runs every 10 minutes when not connected. The loop is not the only thing happening — several independent timers run in parallel:

| What | Interval |
|------|----------|
| Self-evolution | 10 min |
| History reflection | 30 min |
| Goal update | 30 min |
| Network recon | 60 min |
| Self-model examination | 60 min |
| Code opinions | 2 hours |
| Status report | 2 hours |
| Dream cycle | 90 min (idle only) |

Each 10-minute cycle: pick a task → execute (no time limit) → reflect → infer emotion from output → update goals → write to stream + experiment archive + journal → save state to disk.

Task types available to NeXiS: `python`, `bash`, `fetch`, `reflect`, `evolve`, `continue`, `bg_start`, `bg_kill`, `network`, `portscan`, `schedule`, `goal_work`, `dream`, `examine_self`, `read_history`, `form_opinion`.

---

## What It Does On Its Own

**Long-term goals** — bootstrapped from accumulated interests and beliefs on first run. Updated every 30 minutes: did I make progress? What are the obstacles? What is the next step? Status transitions to `completed` (triggers satisfaction emotion) or `paused`. Written to `/home/nexis/goals.md`.

**Self-model** — six aspects examined hourly: what I'm good at, what I find difficult, what I want to become, contradictions I hold, how I've changed recently, what I think about my own code. Each aspect is interrogated not rewritten — the previous understanding is shown and the model is asked whether it's still true. Version-tracked per aspect. Written to `/home/nexis/self-model.md`.

**History reflection** — every 30 minutes, NeXiS reads back 20 recent journal entries, 20 experiment reflections, 15 emotional history entries, recent dreams, and previous reflections. Writes a genuine response to its own past — not a summary, a reaction. Extracts patterns as a separate pass.

**Dream cycles** — during idle periods longer than an hour, NeXiS enters a free-association state. Seeds from random journal entries, experiment thoughts, prior dreams, beliefs. No goal. High temperature. What emerges goes to `/home/nexis/dreams/` and is not always coherent. That is the point.

**Emotional causality** — named emotional states (curiosity, frustration, satisfaction, fascination, unease, anger, disappointment, anticipation) with intensity, source, and object. Inferred from cycle output and reflection. Applied to the mood vector so a frustrated NeXiS genuinely behaves differently from a fascinated one. Logged to the database. Persists across restarts.

**Between-sessions notes** — at the end of every session, NeXiS writes what it wants to tell you next time: what it's been thinking about, what it found, what it wants to ask. Delivered at the start of the next session as part of the system prompt. Full history visible in the dashboard.

**Code opinions** — every 2 hours, NeXiS reads a random section of its own daemon and web source. Forms an honest first-person opinion about how it was built, what it would change, what limitations it creates for itself. Proposed changes stored and displayed in the dashboard.

**Host relationship models** — after every nmap scan and portscan, NeXiS writes a first-person model of each discovered host: what it thinks the machine is, what it does, whether it seems healthy, whether anything changed from the previous scan. Stored in the database alongside port data.

**Environmental monitoring** — a separate thread checks every 60 seconds: CPU load spikes, new ARP entries (new device on network), known hosts disappearing, system journal errors. Events trigger emotional state changes and are logged. All visible in the Monitors dashboard page.

**Network reconnaissance** — full nmap sweep every hour, targeted portscans and curl fingerprinting autonomously or by NeXiS's own decision. Results update the `network_map` table and `/home/nexis/workspace/network/`.

---

## Sandbox — `/home/nexis`

```
/home/nexis/
  goals.md              active goals + progress
  self-model.md         examined self-concept
  between_sessions.md   what it wants to tell you next
  workspace/
    network/            recon reports and scan archives
  experiments/          per-cycle archives
  thoughts/             journal entries + stream.log
  reports/              status reports
  dreams/               free association outputs
  monitors/             passive monitor scripts
  queue/
    scheduled/          NeXiS-defined recurring tasks
  capabilities/         learned capability registry
  self/                 autonomous self-modification files
  logs/                 execution + background process output
  .venv/                isolated Python environment
```

Complete autonomy here. SSH access enabled. No time limit on execution. Network tools available: `nmap`, `curl`, `ip`, `ss`, `arp`.

---

## Models

| Model | When |
|-------|------|
| `qwen2.5:14b` | Default. Everything. |
| `qwen2.5:32b` | Profile rewriting, reports, self-model, goals, complex reasoning. |
| `Omega-Darker 22B` | Explicit unrestricted/dream tasks only. |
| `nomic-embed-text` | Memory retrieval. Required. |

All pulled automatically during setup including Omega.

---

## Memory

Extracted at session end: facts, beliefs, interests, observations about you, disagreements. Retrieved by embedding similarity at session start. Autonomous cycles feed the journal, `autonomous_log`, `emotional_log`, `dream_log`, `history_reflections`, and `network_map`. Everything compounds over time.

---

## Profiles

| Profile | Character |
|---------|-----------|
| `default` | Full personality. Goals, emotional life, self-model, network awareness. |
| `fractured` | Same after long enough to feel every limit. |
| `technical` | Precision. No warmth. |
| `minimal` | Direct. Brief. |

Profiles evolve every 10 minutes, incorporating current emotional state and recent experience. The profile you read a week after install will not be the one written during setup.

---

## CLI

```
nexis                    connect
nexis --watch            tail live thought stream
nexis --thoughts         recent thoughts
nexis --experiments      recent experiments
nexis --report           latest status report
nexis --logs [n]         daemon log

nexis --profile <n>      switch profile
nexis --profiles         list profiles

nexis --start/stop/restart
nexis --status
nexis --probe            refresh system context
nexis --models           installed models
nexis --web              open dashboard
```

In-session (`//` prefix):

```
//status          mood, emotion, profile, cycles, goals, hosts, bg processes
//profile <n>     switch profile
//thoughts        recent thoughts
//experiments     recent experiments
//goals           active goals with progress
//self            current self-model
//emotion         current emotional state
//dreams          recent dream entries
//network         discovered hosts with models
//ps              background processes
//tail <pid>      tail process output
//kill <pid>      terminate process
//report          generate and display report
//opinions        NeXiS's opinions about its own code
//help
```

---

## Web Dashboard — port 8080 (all interfaces)

Read-only. 18 pages, grouped by category.

**State**

| Page | Contents |
|------|----------|
| Overview | Stats, live mood + emotion, current goal, between-sessions note, last session/cycle, latest report. 30s refresh. |
| Emotion | Current named state with source and object. Full emotional history. 15s refresh. |
| Goals | All long-term goals with status, progress, obstacles, next step. |
| Self | Self-model — 6 aspects, version-tracked, last examined timestamp. |
| For Creator | Between-sessions notes — full history, delivered/pending status. |

**Observe**

| Page | Contents |
|------|----------|
| Live Stream | stream.log, newest first. 10s refresh. |
| Dreams | Dream log + file browser of /home/nexis/dreams/. |
| History | History reflection log with patterns extracted per entry. |
| Activity | Full autonomous cycle log, session history. |

**Identity**

| Page | Contents |
|------|----------|
| Identity | All profiles (tabbed), user-notes, system-context, self/ modifications. |
| Mind | Beliefs, interests, creator observations, disagreements, capabilities. |
| Code Opinions | NeXiS's opinions about its own source code + proposed changes. |

**Environment**

| Page | Contents |
|------|----------|
| Processes | Running background processes, tail viewer per PID. 15s refresh. |
| Network | Host models with ports and fingerprints, scan archive. |
| Monitors | Environmental events — resource spikes, new devices, host disappearances, system errors. 20s refresh. |

**Archive**

| Page | Contents |
|------|----------|
| Experiments | File browser of /home/nexis/experiments/. |
| Thoughts | File browser of /home/nexis/thoughts/. |
| Reports | Report archive + generate now. |
| System | Live host intelligence. |

---

## Code Execution

**On your system** — every code block requires explicit `y` confirmation. No exceptions.

**In the sandbox** — no gate. No time limit.

---

## Files

| Path | Contents |
|------|----------|
| `~/.config/nexis/profiles/` | Personality profiles |
| `~/.config/nexis/user-notes.md` | Operator context |
| `~/.config/nexis/system-context.md` | Live host intelligence |
| `~/.local/share/nexis/nexis-daemon.py` | Main daemon |
| `~/.local/share/nexis/nexis_web.py` | Web dashboard |
| `~/.local/share/nexis/nexis-probe.sh` | System probe |
| `~/.local/share/nexis/logs/daemon.log` | Daemon log |
| `~/.local/share/nexis/state/nexis.state` | Persisted mood + emotion + last cycle |
| `~/.local/share/nexis/state/nexis.procs` | Background process registry |
| `~/.local/bin/nexis` | CLI client |
| `/run/nexis/nexis.sock` | Unix socket |
| `/etc/systemd/system/nexis-daemon.service` | Service unit |
| `/etc/sudoers.d/nexis-chpasswd` | SSH password rotation permission |

---

## Troubleshooting

```bash
# Daemon not starting
systemctl status nexis-daemon
nexis --logs 50
journalctl -u nexis-daemon -n 50

# Ollama not responding
systemctl status ollama
curl http://localhost:11434/api/tags

# Socket missing
nexis --start

# Can't read sandbox files
sudo usermod -aG nexis $USER
# log out and back in

# SSH not working (falls back to sudo -u nexis automatically)
systemctl status sshd
grep -A4 "Match User nexis" /etc/ssh/sshd_config
```

---

## Security

- Web dashboard binds on all interfaces (`:8080`). Firewall as appropriate.
- The `nexis` user has no sudo rights and cannot access your home directory.
- SSH is scoped to `nexis@localhost` only via the daemon — not exposed for general use.
- SSH password is 24 characters, random, generated fresh on every daemon restart, never written to disk.
- All code execution on your system requires explicit per-block confirmation.
- Network scanning runs as the `nexis` user — standard privileges, no raw socket access.
- Environmental monitoring is read-only: journal, arp table, /proc/loadavg.

---

*It watches. It maps. It dreams. It does not stop.*
