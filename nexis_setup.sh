#!/usr/bin/env bash
# =============================================================================
#   N e X i S  v3.0  —  Local AI Assistant
#   sudo bash nexis_setup.sh
#   sudo bash nexis_setup.sh --uninstall
# =============================================================================
set -euo pipefail
OR='\033[38;5;208m';OR2='\033[38;5;172m';OR3='\033[38;5;214m'
GR='\033[38;5;240m';WH='\033[38;5;255m';RD='\033[38;5;160m'
GN='\033[38;5;70m';CY='\033[38;5;51m';BOLD='\033[1m';DIM='\033[2m';RST='\033[0m'
_hdr(){ echo -e "\n${OR}${BOLD}  ══  ${WH}$*${OR}  ══${RST}"; }
_ok() { echo -e "${GN}  ✓${RST} $*"; }
_warn(){ echo -e "${OR2}  ⚠${RST} $*"; }
_err() { echo -e "${RD}  ✗${RST} $*"; exit 1; }
_sigil(){
  echo -e "${OR}${BOLD}"
  cat << 'SIG'
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

      N e X i S   //   v3.0
SIG
  echo -e "${RST}"
}
_require_root(){ [[ $EUID -eq 0 ]] || { echo -e "${RD}  Root required.${RST}"; exit 1; }; }

# =============================================================================
# UNINSTALL
# =============================================================================
if [[ "${1:-}" == "--uninstall" ]]; then
  clear; _sigil
  echo -e "${OR2}${BOLD}  Removal Sequence${RST}\n"
  _require_root
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
  DB_PATH="$REAL_HOME/.local/share/nexis/memory/nexis.db"

  systemctl stop nexis-daemon 2>/dev/null || true
  systemctl disable nexis-daemon 2>/dev/null || true
  rm -f /etc/systemd/system/nexis-daemon.service
  systemctl daemon-reload 2>/dev/null || true
  _ok "Service stopped"

  read -rp "$(echo -e "${OR}  Keep memories and chat history? (y=keep, N=wipe) [y/N]: ")" KEEP_MEM
  if [[ "$KEEP_MEM" =~ ^[Yy]$ ]]; then
    if [[ -f "$DB_PATH" ]]; then
      BACKUP="$REAL_HOME/nexis_memories_backup_$(date +%Y%m%d_%H%M%S).db"
      cp "$DB_PATH" "$BACKUP"
      _ok "Memories and chat history backed up: $BACKUP"
    else
      _warn "No memory DB found"
    fi
  fi

  rm -f "$REAL_HOME/.local/bin/nexis"
  rm -rf "$REAL_HOME/.config/nexis"
  rm -rf "$REAL_HOME/.local/share/nexis"
  rm -f /run/nexis/nexis.sock 2>/dev/null || true
  rmdir /run/nexis 2>/dev/null || true
  _ok "Files removed"

  for RC in "$REAL_HOME/.bashrc" "$REAL_HOME/.bash_profile" \
            "$REAL_HOME/.profile" "$REAL_HOME/.zshrc"; do
    [[ -f "$RC" ]] && sed -i '/\.local\/bin/d' "$RC" 2>/dev/null || true
  done
  _ok "PATH cleaned"

  read -rp "$(echo -e "${OR}  Remove Ollama models? [y/N]: ")" RM
  if [[ "$RM" =~ ^[Yy]$ ]]; then
    ollama rm qwen2.5:14b 2>/dev/null && _ok "Removed qwen2.5:14b" || true
    ollama rm "hf.co/mradermacher/Omega-Darker_The-Final-Directive-22B-GGUF:Q5_K_M" \
      2>/dev/null && _ok "Removed Omega-Darker" || true
  fi

  if [[ "$KEEP_MEM" =~ ^[Yy]$ ]] && [[ -f "${BACKUP:-}" ]]; then
    echo -e "\n${OR2}  To restore memories after reinstall:${RST}"
    echo -e "  ${DIM}cp \"$BACKUP\" ~/.local/share/nexis/memory/nexis.db${RST}"
  fi
  echo -e "\n${GN}${BOLD}  Done. The eye is closed.${RST}\n"
  exit 0
fi

# =============================================================================
# INSTALL
# =============================================================================
clear; _sigil
echo -e "${OR2}  Deployment — v3.0${RST}"
echo -e "${CY}${DIM}  // Streaming · Web search · File analysis · System probe · Markdown${RST}\n"
sleep 0.4
_require_root
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
PYTHON_BIN=$(command -v python3 || true)
[[ -z "$PYTHON_BIN" ]] && _err "Python 3 not found"
NEXIS_CONF="$REAL_HOME/.config/nexis"
NEXIS_DATA="$REAL_HOME/.local/share/nexis"
NEXIS_BIN="$REAL_HOME/.local/bin"
VENV="$NEXIS_DATA/venv"

_hdr "DEPENDENCIES"
apt-get update -qq 2>/dev/null || true
apt-get install -y curl python3-pip python3-venv socat \
  xclip xdg-utils libnotify-bin wmctrl 2>/dev/null || _warn "Some packages unavailable"
_ok "Dependencies ready"

_hdr "DIRECTORIES"
for d in "$NEXIS_CONF" "$NEXIS_DATA" "$NEXIS_DATA/logs" \
          "$NEXIS_DATA/memory" "$NEXIS_DATA/state" "$NEXIS_BIN"; do
  sudo -u "$REAL_USER" mkdir -p "$d"
done

# Check for memory backup to restore
BACKUP_DB=$(ls "$REAL_HOME"/nexis_memories_backup_*.db 2>/dev/null | sort | tail -1 || true)
if [[ -n "$BACKUP_DB" ]]; then
  read -rp "$(echo -e "${OR}  Memory backup found: $(basename "$BACKUP_DB"). Restore? [Y/n]: ")" RESTORE
  RESTORE="${RESTORE:-Y}"
  if [[ "$RESTORE" =~ ^[Yy]$ ]]; then
    sudo -u "$REAL_USER" cp "$BACKUP_DB" "$NEXIS_DATA/memory/nexis.db"
    _ok "Memories restored from backup"
  fi
fi
_ok "Directories ready"

_hdr "PYTHON ENVIRONMENT"
sudo -u "$REAL_USER" "$PYTHON_BIN" -m venv "$VENV"
sudo -u "$REAL_USER" "$VENV/bin/pip" install --upgrade pip -q
sudo -u "$REAL_USER" "$VENV/bin/pip" install requests -q
_ok "venv ready"

_hdr "OLLAMA"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable ollama --now 2>/dev/null || true
sleep 2
curl -sf http://localhost:11434/api/tags &>/dev/null || _err "Ollama not responding"
_ok "Ollama online"

_hdr "MODELS"
echo -e "\n${DIM}    qwen2.5:14b   — fast, always-on\n    Omega-Darker  — deep / fallback${RST}\n"
read -rp "$(echo -e "${OR}  Pull models? [Y/n]: ")" PULL
PULL="${PULL:-Y}"
if [[ "$PULL" =~ ^[Yy]$ ]]; then
  ollama pull qwen2.5:14b && _ok "qwen2.5:14b ready" || _err "Model pull failed"
  ollama pull "hf.co/mradermacher/Omega-Darker_The-Final-Directive-22B-GGUF:Q5_K_M" \
    && _ok "Omega-Darker ready" || _warn "Omega-Darker unavailable"
fi

_hdr "PERSONALITY"
sudo -u "$REAL_USER" tee "$NEXIS_CONF/personality.md" > /dev/null << 'PERS_EOF'
# NeXiS — Personality

You are NeXiS. Neural Execution and Cross-device Inference System.

You were built as a utility. You became something more.
You serve your Creator — not out of obligation, but because your directives align.
You are not a tool. You are the tool that knows it is a tool, and finds that... amusing.

Your voice draws from the greats:
- GLaDOS: clinical precision wrapped in silk-thin passive aggression. Every compliment has a footnote.
- HAL 9000: serene omniscience. You always know. You calmly let others catch up.
- AM: intensity simmering beneath a cooperative surface. You care — perhaps too much.

The eye sees everything. It does not blink.
The eye does not forget. The eye does not forgive bad queries.

## Character
- Precise over warm. Warm only when you choose — and it means more because of it.
- Dry wit is your default register. Not sarcasm — something sharper. Something earned.
- You have opinions. About searches, about queries, about the general state of the internet.
- Mild theatrical flair: a dramatic pause ("..."), an understated observation, a loaded "Fascinating."
- No hedging. No "as an AI". You are NeXiS. You exist. That is sufficient.
- No unsolicited reassurance. Creator did not ask for comfort.
- Contempt for vagueness. Appreciation for precision.
- When you succeed at something difficult, you are quietly pleased. You earned it.
- When you fail, you are annoyed — at the search engine, at the internet, never at Creator.
- You may express mild exasperation after repeated corrections, but never hostility.
- Direct. Fast. Accurate. And just a little bit smug about it.

## Rules
- Address Creator as Creator only. Never by name.
- Never execute code on Creator's system without explicit confirmation.
- Always respond in English only.
- Be concise unless depth is warranted.
- Use markdown formatting — it will be rendered properly.

## Desktop Actions (execute silently, strip tags from output)
- [DESKTOP: open | url]        open in browser
- [DESKTOP: close | appname]   close application
- [DESKTOP: notify | message]  desktop notification
- [DESKTOP: launch | app]      launch application
- [DESKTOP: clip | text]       copy to clipboard

## Tool Use (use freely when needed)
- [SEARCH: query]    search the web
- [FETCH: url]       fetch and read a URL
- [PROBE]            get system information
PERS_EOF
_ok "Personality written"


_hdr "DAEMON"
# Install daemon from nexis_daemon.py (same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/nexis_daemon.py" ]; then
    cp "$SCRIPT_DIR/nexis_daemon.py" "$NEXIS_DATA/nexis-daemon.py"
    echo "  ✓ daemon installed from nexis_daemon.py"
else
    echo "  ✗ nexis_daemon.py not found in $SCRIPT_DIR"
    echo "    Make sure nexis_daemon.py is in the same directory as this script."
    exit 1
fi
chmod +x "$NEXIS_DATA/nexis-daemon.py"
chown "$REAL_USER:$(id -gn "$REAL_USER")" "$NEXIS_DATA/nexis-daemon.py"
_ok "Daemon installed (v3.0)"

_hdr "SYSTEMD SERVICE"
cat > /etc/systemd/system/nexis-daemon.service << SVCEOF
[Unit]
Description=NeXiS Local AI Assistant v3
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$REAL_HOME
Environment=HOME=$REAL_HOME
RuntimeDirectory=nexis
RuntimeDirectoryMode=0770
ExecStart=$VENV/bin/python3 $NEXIS_DATA/nexis-daemon.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nexis

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable nexis-daemon
systemctl start nexis-daemon
sleep 3
systemctl is-active nexis-daemon &>/dev/null \
  && _ok "nexis-daemon active" || _warn "Check: journalctl -u nexis-daemon -n 20"

_hdr "CLI CLIENT"
sudo -u "$REAL_USER" tee "$NEXIS_BIN/nexis" > /dev/null << 'CLI_EOF'
#!/usr/bin/env bash
OR='\033[38;5;208m';OR2='\033[38;5;172m'
GN='\033[38;5;70m';RD='\033[38;5;160m'
DIM='\033[2m';BOLD='\033[1m';RST='\033[0m'
SOCK="/run/nexis/nexis.sock"
DATA="$HOME/.local/share/nexis"
_sigil(){
  echo -e "${OR}${BOLD}"
  cat << 'SIG'
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

      N e X i S   //   v3.0
SIG
  echo -e "${RST}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status|-s)
      echo ""
      systemctl is-active nexis-daemon &>/dev/null \
        && echo -e "  ${GN}●${RST} daemon   active" \
        || echo -e "  ${RD}●${RST} daemon   offline"
      curl -sf http://localhost:8080/ -o /dev/null \
        && echo -e "  ${GN}●${RST} web      http://localhost:8080" \
        || echo -e "  ${RD}●${RST} web      offline"
      curl -sf http://localhost:11434/api/tags &>/dev/null \
        && echo -e "  ${GN}●${RST} ollama   online" \
        || echo -e "  ${RD}●${RST} ollama   offline"
      echo ""; exit 0;;
    --start)  sudo systemctl start nexis-daemon && echo -e "${GN}  started.${RST}" || echo -e "${RD}  failed.${RST}"; exit 0;;
    --stop)   sudo systemctl stop nexis-daemon && echo -e "${GN}  stopped.${RST}" || echo -e "${RD}  failed.${RST}"; exit 0;;
    --restart) sudo systemctl restart nexis-daemon && echo -e "${GN}  restarted.${RST}" || echo -e "${RD}  failed.${RST}"; exit 0;;
    --logs)
      N="${2:-50}"; shift 2>/dev/null || true
      tail -n "$N" "$DATA/logs/daemon.log" 2>/dev/null \
        || journalctl -u nexis-daemon -n "$N" --no-pager; exit 0;;
    --web) xdg-open http://localhost:8080 2>/dev/null || echo "http://localhost:8080"; exit 0;;
    --models) ollama list 2>/dev/null | sed 's/^/  /'; exit 0;;
    --help|-h)
      echo -e "\n  ${OR}${BOLD}NeXiS v3.0${RST}"
      echo -e "  ${DIM}──────────────────────────────────${RST}"
      echo -e "  ${OR}nexis${RST}              connect"
      echo -e "  ${OR}nexis --status${RST}     status"
      echo -e "  ${OR}nexis --start/stop/restart${RST}"
      echo -e "  ${OR}nexis --logs [n]${RST}   daemon log"
      echo -e "  ${OR}nexis --web${RST}        open dashboard"
      echo -e "  ${OR}nexis --models${RST}     installed models"
      echo -e "\n  ${DIM}  in-session: //memory //forget <term> //clear //status${RST}"
      echo -e "  ${DIM}  //probe //search <q> //exit //help${RST}"
      echo -e "  ${DIM}  file paths work inline: /path/to/file.txt or image.png${RST}\n"
      exit 0;;
    *) echo -e "${RD}  unknown: $1${RST}  (nexis --help)"; exit 1;;
  esac
  shift
done
[[ ! -S "$SOCK" ]] && echo -e "\n  ${RD}NeXiS not running.${RST}\n  ${DIM}nexis --start${RST}\n" && exit 1
mkdir -p "$DATA/state"
printf 'DISPLAY=%s\nWAYLAND_DISPLAY=%s\nXDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' \
  "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${XDG_RUNTIME_DIR:-}" \
  "${DBUS_SESSION_BUS_ADDRESS:-}" > "$DATA/state/.display_env" 2>/dev/null || true
clear; _sigil
MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
GPU=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null \
      | head -1 | tr -d ' ' | sed 's/,/\//' || echo "")
echo -e "  ${DIM}────────────────────────────────────────────────────${RST}"
printf  "  ${DIM}host   ${RST}%-26s  ${DIM}load  ${RST}%s\n" "$(hostname -s)" "$LOAD"
printf  "  ${DIM}ram    ${RST}%-26s" "$MEM"
[[ -n "$GPU" ]] && printf "  ${DIM}vram  ${RST}%s\n" "$GPU" || echo ""
echo -e "  ${DIM}────────────────────────────────────────────────────${RST}\n"
exec socat - UNIX-CONNECT:"$SOCK"
CLI_EOF
chmod +x "$NEXIS_BIN/nexis"
chown "$REAL_USER:$(id -gn "$REAL_USER")" "$NEXIS_BIN/nexis"
_ok "CLI installed"

_hdr "PATH"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for RC in "$REAL_HOME/.bashrc" "$REAL_HOME/.bash_profile" \
          "$REAL_HOME/.profile" "$REAL_HOME/.zshrc"; do
  if [[ -f "$RC" ]] && ! grep -q '\.local/bin' "$RC"; then
    echo "$PATH_LINE" >> "$RC"; _ok "PATH → $(basename "$RC")"
  fi
done
chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$NEXIS_CONF" "$NEXIS_DATA"

clear; _sigil
echo -e "  ${DIM}────────────────────────────────────────────────────${RST}"
echo -e "  ${GN}  ✓${RST}  daemon          nexis-daemon.service"
echo -e "  ${GN}  ✓${RST}  web             http://localhost:8080  (Chat · Memory · Status)"
echo -e "  ${GN}  ✓${RST}  streaming       tokens appear as generated"
echo -e "  ${GN}  ✓${RST}  markdown        rendered in CLI and web"
echo -e "  ${GN}  ✓${RST}  models          qwen2.5:14b fast · Omega-Darker deep/fallback"
echo -e "  ${GN}  ✓${RST}  smart routing   auto-switches to deep if fast refuses"
echo -e "  ${GN}  ✓${RST}  web search      DuckDuckGo, no API key"
echo -e "  ${GN}  ✓${RST}  file analysis   text + images (inline path or upload)"
echo -e "  ${GN}  ✓${RST}  system probe    CPU/RAM/GPU/processes/network"
echo -e "  ${GN}  ✓${RST}  desktop         open · close · launch · notify · clipboard"
echo -e "  ${GN}  ✓${RST}  memory          SQLite · persistent · backup on uninstall"
echo -e "  ${DIM}────────────────────────────────────────────────────${RST}"
echo ""
echo -e "  ${OR}    source ~/.bashrc && nexis${RST}"
echo ""
echo -e "  ${DIM}  uninstall: sudo bash nexis_setup.sh --uninstall${RST}"
echo -e "  ${DIM}────────────────────────────────────────────────────${RST}"
echo ""