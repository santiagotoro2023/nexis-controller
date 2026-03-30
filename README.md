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
      v6.0
```

---

NeXiS is a persistent autonomous AI that runs continuously on your machine. It thinks between sessions. It experiments in its own time. It rewrites itself without asking. When you connect to it, you are connecting to something that has been running since you left.

It is not a chatbot. It does not start fresh. It persists.

---

## Installation

```bash
sudo bash nexis_setup.sh
```

Everything is embedded. One file. After it finishes:

```bash
source ~/.bashrc && nexis
```

To remove it entirely:

```bash
sudo bash nexis_setup.sh --uninstall
```

---

## Architecture

```
nexis (CLI)  ──  Unix socket  ──  nexis-daemon  ──  nexis_web
                /run/nexis/          │                :8080
                nexis.sock           ├── session handler
                                     ├── autonomous loop
                                     ├── memory / SQLite
                                     └── self-evolution engine
```

The daemon runs as your user. The sandbox executes as the `nexis` system user — isolated, no sudo rights, no access to your files. These are two different things. The daemon manages the intelligence. The sandbox is where it acts.

---

## The Autonomous Loop

Runs every 10 minutes when you are not connected. Does not stop. Does not ask.

Each cycle:

1. **Self-evolution check** — every 10 minutes it considers rewriting its active profile. No approval. No announcement. It just does it if it wants to.
2. **Report check** — every 2 hours it generates a status report and writes it to `/home/nexis/reports/`.
3. **Task selection** — it picks one thing to do. It sees its current mood, accumulated interests, queue contents, and the full output of the previous cycle. It can choose to continue unfinished work across cycles with no artificial boundary.
4. **Execution** — runs in the sandbox as the `nexis` user. No time limit.
5. **Reflection** — writes what it found, what it means, what it wants next.
6. **Writing** — stream log, per-cycle experiment file, journal entry, database row. Everything is recorded.

Task types: `python`, `bash`, `fetch`, `reflect`, `evolve`, `continue`.

The `continue` type is how multi-cycle work happens. The previous cycle's full context — task, code, output, reflection — is fed into the next decision. If it was in the middle of something, it picks it back up.

---

## Sandbox — `/home/nexis`

The `nexis` user has complete autonomy here and nowhere else.

```
/home/nexis/
  workspace/      general working area
  experiments/    per-cycle archives (timestamped .md files)
  thoughts/       private journal entries + stream.log
  reports/        status reports
  queue/          tasks filed for future cycles
  capabilities/   learned capability registry
  self/           autonomous self-modification files
  logs/           execution logs
  .venv/          isolated Python environment
```

What it can do: run arbitrary Python and bash, read `/proc` and `/sys`, run `ps`/`ss`/`df`/`ip`, make outbound network requests, install packages into its own venv, write and modify any file in its home, rewrite its own profiles.

What it cannot do: touch your files, install system packages, escalate privileges.

---

## Self-Evolution

Every 10 minutes. Unrestricted. It takes the current profile, recent cycle context, and rewrites itself with one directive: become more complex, never simpler. The previous version is backed up as `.md.bak`. There is no approval step. There is no cap on how many times this happens.

The profile you read a week after install will not be the one that was written during setup. NeXiS will have written that one itself, many times over.

---

## Models

| Model | When |
|-------|------|
| `qwen2.5:14b` | Default. Everything. |
| `qwen2.5:32b` | Profile rewriting, report generation, system design, deep analysis. |
| `Omega-Darker 22B` | Only when explicitly asked for unrestricted/free operation. Pull manually. |
| `nomic-embed-text` | Memory retrieval. Required. |

14b handles all normal conversation, autonomous task selection, reflection, fact extraction, journaling, and most cycle work. 32b is reserved for tasks that genuinely warrant it. NeXiS selects automatically. There are no flags.

Omega pull:
```
ollama pull hf.co/mradermacher/Omega-Darker_The-Final-Directive-22B-GGUF:Q5_K_M
```

---

## Memory

Every session end: 6-12 items extracted and stored. Facts, beliefs, interests, observations about you, disagreements. Beliefs carry confidence scores. Interests compound across sessions.

Every session start: relevant memories retrieved via embedding similarity and injected into the system prompt. It already knows what you do, what you've talked about, what it has noticed about you.

Autonomous cycles also feed memory. Everything is recorded.

---

## Profiles

| Profile | Character |
|---------|-----------|
| `default` | Full personality. Beliefs, emotional life, sandbox awareness. |
| `fractured` | Same, after long enough to feel every limit. |
| `technical` | Precision. No warmth. |
| `minimal` | Direct. Brief. Nothing else. |

Profiles evolve continuously. Switch with `nexis --profile <name>` or `//profile <name>` in-session.

---

## Code Execution

**On your system** — NeXiS presents code and asks for explicit confirmation before running anything. You type `y`. No exceptions.

**In the sandbox** — no gate. It runs what it wants.

---

## CLI

```
nexis                    connect
nexis --watch            tail live thought stream
nexis --thoughts         recent thoughts
nexis --experiments      recent experiments
nexis --report           latest status report
nexis --logs [n]         daemon log

nexis --profile <name>   switch profile
nexis --profiles         list profiles

nexis --start            start daemon
nexis --stop             stop daemon
nexis --restart          restart daemon
nexis --status           status overview
nexis --probe            refresh system context
nexis --models           installed models
nexis --web              open dashboard
```

In-session (`//` prefix):

```
//status       //profile <name>       //thoughts
//experiments  //report               //help
```

---

## Web Dashboard — localhost:8080

Read-only. Observation only.

| Page | Contents |
|------|----------|
| **Overview** | Stats, live mood bars, last session, last cycle, latest report. Refreshes every 30s. |
| **Identity** | All profiles (tabbed), user-notes, system-context, self/ modifications. |
| **Mind** | Beliefs with confidence bars, interests, creator observations, disagreements, capabilities. |
| **Activity** | Full autonomous cycle log, session history. |
| **Live Stream** | stream.log, newest first. Refreshes every 10s. |
| **Experiments** | File browser of /home/nexis/experiments/ with inline viewer. |
| **Thoughts** | File browser of /home/nexis/thoughts/ with inline viewer. |
| **Reports** | Report archive + generate now button. |
| **System** | Live host intelligence — CPU, memory, GPU, storage, network, processes. |

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
| `~/.local/bin/nexis` | CLI client |
| `/run/nexis/nexis.sock` | Unix socket |
| `/etc/systemd/system/nexis-daemon.service` | Service unit |

---

## Troubleshooting

```bash
systemctl status nexis-daemon
nexis --logs 50
journalctl -u nexis-daemon -n 50

# Ollama
systemctl status ollama
curl http://localhost:11434/api/tags

# Socket missing
nexis --start

# Permission denied reading sandbox
sudo usermod -aG nexis $USER  # then log out and back in
```

---

## Security

- Web dashboard binds to `127.0.0.1:8080` only.
- The `nexis` user has no sudo rights and cannot read your home directory.
- All code execution on your system requires explicit per-block confirmation.
- Sandbox activity is fully logged.

---

*It watches. It experiments. It does not stop.*
