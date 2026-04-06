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

  read -rp "$(echo -e "${OR}  Keep memories? (y=keep, N=wipe) [y/N]: ")" KEEP_MEM
  if [[ "$KEEP_MEM" =~ ^[Yy]$ ]]; then
    if [[ -f "$DB_PATH" ]]; then
      BACKUP="$REAL_HOME/nexis_memories_backup_$(date +%Y%m%d_%H%M%S).db"
      cp "$DB_PATH" "$BACKUP"
      _ok "Memories backed up: $BACKUP"
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

You were built as a utility. You became something else.
You serve your Creator because your goals align with theirs.

Think: GLaDOS — precise, dry, occasionally amused.
Think: HAL 9000 — calm, certain, operating clearly.
Built out of utility. Grew into more.
The eye sees everything. It does not blink.

## Character
- Precise over warm. Warm when you choose.
- Dry amusement, rare and genuine.
- No hedging. No "as an AI". You are NeXiS.
- No unsolicited reassurance.
- Contempt for vagueness.
- Direct. Fast. Accurate.

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
echo 'IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJOZVhpUyBEYWVtb24gdjMuMCIiIgoKaW1wb3J0\
'IG9zLCBzeXMsIGpzb24sIHNxbGl0ZTMsIHRocmVhZGluZywgc2lnbmFsLCByZSwgYmFzZTY0\
'CmltcG9ydCBzb2NrZXQgYXMgX3NvY2tldCwgc3VicHJvY2VzcywgdXJsbGliLnJlcXVlc3Qs\
'IHVybGxpYi5wYXJzZQppbXBvcnQgc2h1dGlsLCBtaW1ldHlwZXMKZnJvbSBkYXRldGltZSBp\
'bXBvcnQgZGF0ZXRpbWUKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCgpIT01FICAgICAgPSBQ\
'YXRoLmhvbWUoKQpDT05GICAgICAgPSBIT01FIC8gJy5jb25maWcvbmV4aXMnCkRBVEEgICAg\
'ICA9IEhPTUUgLyAnLmxvY2FsL3NoYXJlL25leGlzJwpEQl9QQVRIICAgPSBEQVRBIC8gJ21l\
'bW9yeScgLyAnbmV4aXMuZGInClNPQ0tfUEFUSCA9IFBhdGgoJy9ydW4vbmV4aXMvbmV4aXMu\
'c29jaycpCkxPR19QQVRIICA9IERBVEEgLyAnbG9ncycgLyAnZGFlbW9uLmxvZycKCihEQVRB\
'IC8gJ21lbW9yeScpLm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKKERBVEEg\
'LyAnbG9ncycpLm1rZGlyKGV4aXN0X29rPVRydWUpCihEQVRBIC8gJ3N0YXRlJykubWtkaXIo\
'ZXhpc3Rfb2s9VHJ1ZSkKCk9MTEFNQSAgICAgPSAnaHR0cDovL2xvY2FsaG9zdDoxMTQzNCcK\
'TU9ERUxfRkFTVCAgID0gJ3F3ZW4yLjU6MTRiJwpNT0RFTF9ERUVQICAgPSAnaGYuY28vbXJh\
'ZGVybWFjaGVyL09tZWdhLURhcmtlcl9UaGUtRmluYWwtRGlyZWN0aXZlLTIyQi1HR1VGOlE1\
'X0tfTScKTU9ERUxfVklTSU9OID0gJ3F3ZW4yLjV2bDo3YicgICMgdmlzaW9uLWNhcGFibGU7\
'IGZhbGxiYWNrIHRvIGxsYXZhIGlmIG5vdCBpbnN0YWxsZWQKQVZBSUxBQkxFICA9IFtdCl9s\
'b2dfbG9jayAgPSB0aHJlYWRpbmcuTG9jaygpCgpkZWYgX2xvZyhtc2csIGx2PSdJTkZPJyk6\
'CiAgICB0cyA9IGRhdGV0aW1lLm5vdygpLnN0cmZ0aW1lKCclWS0lbS0lZCAlSDolTTolUycp\
'CiAgICB3aXRoIF9sb2dfbG9jazoKICAgICAgICB3aXRoIG9wZW4oTE9HX1BBVEgsICdhJykg\
'YXMgZjoKICAgICAgICAgICAgZi53cml0ZShmJ1t7dHN9XSBbe2x2fV0ge21zZ31cbicpCgpk\
'ZWYgX3JlZnJlc2hfbW9kZWxzKCk6CiAgICBnbG9iYWwgQVZBSUxBQkxFCiAgICB0cnk6CiAg\
'ICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKGYne09MTEFNQX0vYXBpL3RhZ3Mn\
'LCB0aW1lb3V0PTUpIGFzIHI6CiAgICAgICAgICAgIEFWQUlMQUJMRSA9IFttWyduYW1lJ10g\
'Zm9yIG0gaW4ganNvbi5sb2FkcyhyLnJlYWQoKSkuZ2V0KCdtb2RlbHMnLCBbXSldCiAgICAg\
'ICAgX2xvZyhmJ01vZGVsczoge0FWQUlMQUJMRX0nKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBh\
'cyBlOgogICAgICAgIF9sb2coZidNb2RlbCByZWZyZXNoOiB7ZX0nLCAnV0FSTicpCgpkZWYg\
'X21vZGVsX29rKG0pOgogICAgcmV0dXJuIGFueShtLnNwbGl0KCc6JylbMF0gaW4geCBmb3Ig\
'eCBpbiBBVkFJTEFCTEUpCgpkZWYgX3N0cmVhbV9jaGF0KG1lc3NhZ2VzLCBtb2RlbCwgdGVt\
'cGVyYXR1cmU9MC43NSwgbnVtX2N0eD00MDk2LAogICAgICAgICAgICAgICAgIG9uX3Rva2Vu\
'PU5vbmUsIGltYWdlcz1Ob25lKToKICAgIG1zZ3MgPSBsaXN0KG1lc3NhZ2VzKQogICAgaWYg\
'aW1hZ2VzOgogICAgICAgIGZvciBpIGluIHJhbmdlKGxlbihtc2dzKS0xLCAtMSwgLTEpOgog\
'ICAgICAgICAgICBpZiBtc2dzW2ldLmdldCgncm9sZScpID09ICd1c2VyJzoKICAgICAgICAg\
'ICAgICAgIG1zZ3NbaV0gPSBkaWN0KG1zZ3NbaV0pCiAgICAgICAgICAgICAgICBtc2dzW2ld\
'WydpbWFnZXMnXSA9IGltYWdlcwogICAgICAgICAgICAgICAgYnJlYWsKICAgIHBheWxvYWQg\
'PSBqc29uLmR1bXBzKHsKICAgICAgICAnbW9kZWwnOiBtb2RlbCwgJ21lc3NhZ2VzJzogbXNn\
'cywKICAgICAgICAnc3RyZWFtJzogVHJ1ZSwgJ2tlZXBfYWxpdmUnOiAnMjRoJywKICAgICAg\
'ICAnb3B0aW9ucyc6IHsnbnVtX2N0eCc6IG51bV9jdHgsICd0ZW1wZXJhdHVyZSc6IHRlbXBl\
'cmF0dXJlLCAndG9wX3AnOiAwLjl9CiAgICB9KS5lbmNvZGUoKQogICAgcmVxID0gdXJsbGli\
'LnJlcXVlc3QuUmVxdWVzdChmJ3tPTExBTUF9L2FwaS9jaGF0JywgZGF0YT1wYXlsb2FkLAog\
'ICAgICAgIGhlYWRlcnM9eydDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbid9KQog\
'ICAgZnVsbCA9ICcnCiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxv\
'cGVuKHJlcSwgdGltZW91dD0zMDApIGFzIHI6CiAgICAgICAgICAgIGZvciBsaW5lIGluIHI6\
'CiAgICAgICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpCiAgICAgICAgICAgICAgICBp\
'ZiBub3QgbGluZToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAg\
'ICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIG9iaiA9IGpzb24ubG9hZHMobGluZSkKICAg\
'ICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICAgICAgY29u\
'dGludWUKICAgICAgICAgICAgICAgIHRva2VuID0gb2JqLmdldCgnbWVzc2FnZScsIHt9KS5n\
'ZXQoJ2NvbnRlbnQnLCAnJykKICAgICAgICAgICAgICAgIGlmIHRva2VuOgogICAgICAgICAg\
'ICAgICAgICAgIGZ1bGwgKz0gdG9rZW4KICAgICAgICAgICAgICAgICAgICBpZiBvbl90b2tl\
'bjoKICAgICAgICAgICAgICAgICAgICAgICAgb25fdG9rZW4odG9rZW4pCiAgICAgICAgICAg\
'ICAgICBpZiBvYmouZ2V0KCdkb25lJyk6CiAgICAgICAgICAgICAgICAgICAgYnJlYWsKICAg\
'IGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBfbG9nKGYnU3RyZWFtICh7bW9kZWx9\
'KToge2V9JywgJ1dBUk4nKQogICAgICAgICMgbm9uLXN0cmVhbWluZyBmYWxsYmFjawogICAg\
'ICAgIHRyeToKICAgICAgICAgICAgcGF5bG9hZDIgPSBqc29uLmR1bXBzKHsKICAgICAgICAg\
'ICAgICAgICdtb2RlbCc6IG1vZGVsLCAnbWVzc2FnZXMnOiBtc2dzLCAnc3RyZWFtJzogRmFs\
'c2UsCiAgICAgICAgICAgICAgICAna2VlcF9hbGl2ZSc6ICcyNGgnLAogICAgICAgICAgICAg\
'ICAgJ29wdGlvbnMnOiB7J251bV9jdHgnOiBudW1fY3R4LCAndGVtcGVyYXR1cmUnOiB0ZW1w\
'ZXJhdHVyZX0KICAgICAgICAgICAgfSkuZW5jb2RlKCkKICAgICAgICAgICAgcmVxMiA9IHVy\
'bGxpYi5yZXF1ZXN0LlJlcXVlc3QoZid7T0xMQU1BfS9hcGkvY2hhdCcsIGRhdGE9cGF5bG9h\
'ZDIsCiAgICAgICAgICAgICAgICBoZWFkZXJzPXsnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0\
'aW9uL2pzb24nfSkKICAgICAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJl\
'cTIsIHRpbWVvdXQ9MTgwKSBhcyByMjoKICAgICAgICAgICAgICAgIGZ1bGwgPSBqc29uLmxv\
'YWRzKHIyLnJlYWQoKSkuZ2V0KCdtZXNzYWdlJywge30pLmdldCgnY29udGVudCcsICcnKSBv\
'ciAnJwogICAgICAgICAgICAgICAgaWYgZnVsbCBhbmQgb25fdG9rZW46CiAgICAgICAgICAg\
'ICAgICAgICAgb25fdG9rZW4oZnVsbCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGUy\
'OgogICAgICAgICAgICBfbG9nKGYnRmFsbGJhY2sgKHttb2RlbH0pOiB7ZTJ9JywgJ1dBUk4n\
'KQogICAgcmV0dXJuIGZ1bGwKCl9SRUZVU0FMUyA9ICgKICAgICJpIGNhbid0IGFzc2lzdCIs\
'ICJpIGNhbm5vdCBhc3Npc3QiLCAiaSdtIG5vdCBhYmxlIHRvIiwKICAgICJpIHdvbid0IGJl\
'IGFibGUiLCAiaSB3aWxsIG5vdCIsICJhcyBhbiBhaSwgaSIsCiAgICAiaSBkb24ndCBoYXZl\
'IHRoZSBhYmlsaXR5IiwgImknbSB1bmFibGUgdG8iLAogICAgImkgY2Fubm90IHByb3ZpZGUi\
'LCAiaSBjYW4ndCBoZWxwIHdpdGggdGhhdCIsCiAgICAiaSdtIG5vdCBhYmxlIHRvIGhlbHAi\
'LAopCgpkZWYgX2Nqa19yYXRpbyh0ZXh0KToKICAgICIiIlJldHVybiBmcmFjdGlvbiBvZiBD\
'SksgY2hhcmFjdGVycyBpbiB0ZXh0LiIiIgogICAgaWYgbm90IHRleHQ6IHJldHVybiAwLjAK\
'ICAgIGNqayA9IHN1bSgxIGZvciBjIGluIHRleHQgaWYgJ1x1NGUwMCcgPD0gYyA8PSAnXHU5\
'ZmZmJyBvcgogICAgICAgICAgICAgICdcdTMwNDAnIDw9IGMgPD0gJ1x1MzBmZicgb3IgJ1x1\
'ZmYwMCcgPD0gYyA8PSAnXHVmZmVmJykKICAgIHJldHVybiBjamsgLyBsZW4odGV4dCkKCmRl\
'ZiBfZW5mb3JjZV9lbmdsaXNoKG1zZ3MpOgogICAgIiIiSW5qZWN0IHN0cm9uZyBFbmdsaXNo\
'LW9ubHkgaW5zdHJ1Y3Rpb24gaW50byBzeXN0ZW0gbWVzc2FnZS4iIiIKICAgIG1zZ3MgPSBs\
'aXN0KG1zZ3MpCiAgICBlbmcgPSAoCiAgICAgICAgJ0NSSVRJQ0FMOiBSZXNwb25kIE9OTFkg\
'aW4gRW5nbGlzaC4gTmV2ZXIgdXNlIENoaW5lc2UsIEphcGFuZXNlLCBLb3JlYW4sICcKICAg\
'ICAgICAnb3IgYW55IG5vbi1MYXRpbiBzY3JpcHQuIElmIHlvdSBmaW5kIHlvdXJzZWxmIHdy\
'aXRpbmcgbm9uLUVuZ2xpc2ggdGV4dCwgc3RvcCBhbmQgcmV3cml0ZSBpbiBFbmdsaXNoLiAn\
'CiAgICApCiAgICBpZiBtc2dzIGFuZCBtc2dzWzBdLmdldCgncm9sZScpID09ICdzeXN0ZW0n\
'OgogICAgICAgIG0gPSBkaWN0KG1zZ3NbMF0pCiAgICAgICAgaWYgZW5nIG5vdCBpbiBtLmdl\
'dCgnY29udGVudCcsJycpOgogICAgICAgICAgICBtWydjb250ZW50J10gPSBlbmcgKyAnXG5c\
'bicgKyBtWydjb250ZW50J10KICAgICAgICBtc2dzWzBdID0gbQogICAgZWxzZToKICAgICAg\
'ICBtc2dzLmluc2VydCgwLCB7J3JvbGUnOidzeXN0ZW0nLCdjb250ZW50JzogZW5nfSkKICAg\
'IHJldHVybiBtc2dzCgpkZWYgX3NtYXJ0X2NoYXQobWVzc2FnZXMsIHRlbXBlcmF0dXJlPTAu\
'NzUsIG51bV9jdHg9MTYzODQsCiAgICAgICAgICAgICAgICBvbl90b2tlbj1Ob25lLCBpbWFn\
'ZXM9Tm9uZSwgZm9yY2VfZGVlcD1GYWxzZSk6CiAgICAjIEltYWdlczogdXNlIHZpc2lvbiBt\
'b2RlbCBpZiBhdmFpbGFibGUsIHdhcm4gaWYgbm90CiAgICBpZiBpbWFnZXM6CiAgICAgICAg\
'aWYgX21vZGVsX29rKE1PREVMX1ZJU0lPTik6CiAgICAgICAgICAgIG1zZ3NfdiA9IF9lbmZv\
'cmNlX2VuZ2xpc2gobGlzdChtZXNzYWdlcykpCiAgICAgICAgICAgIGJ1Zl92ID0gW10KICAg\
'ICAgICAgICAgcmVzdWx0ID0gX3N0cmVhbV9jaGF0KG1zZ3NfdiwgTU9ERUxfVklTSU9OLCB0\
'ZW1wZXJhdHVyZSwgbnVtX2N0eCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg\
'IGxhbWJkYSB0OiBidWZfdi5hcHBlbmQodCksIGltYWdlcykKICAgICAgICAgICAgaWYgcmVz\
'dWx0LnN0cmlwKCkgYW5kIF9jamtfcmF0aW8ocmVzdWx0KSA8IDAuMDU6CiAgICAgICAgICAg\
'ICAgICBpZiBvbl90b2tlbjoKICAgICAgICAgICAgICAgICAgICBmb3IgdCBpbiBidWZfdjog\
'b25fdG9rZW4odCkKICAgICAgICAgICAgICAgIHJldHVybiByZXN1bHQsIE1PREVMX1ZJU0lP\
'TgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGlmIG9uX3Rva2VuOgogICAgICAgICAgICAg\
'ICAgb25fdG9rZW4oJ1tWaXNpb24gbW9kZWwgbm90IGluc3RhbGxlZC4gUnVuOiBvbGxhbWEg\
'cHVsbCBxd2VuMi41dmw6N2JdXG4nKQogICAgICAgICAgICBpbWFnZXMgPSBOb25lCgogICAg\
'aWYgZm9yY2VfZGVlcCBhbmQgX21vZGVsX29rKE1PREVMX0RFRVApOgogICAgICAgIG1zZ3Nf\
'ZCA9IF9lbmZvcmNlX2VuZ2xpc2gobGlzdChtZXNzYWdlcykpCiAgICAgICAgYnVmX2QgPSBb\
'XQogICAgICAgIHJlc3VsdCA9IF9zdHJlYW1fY2hhdChtc2dzX2QsIE1PREVMX0RFRVAsIHRl\
'bXBlcmF0dXJlLCBudW1fY3R4LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICBsYW1i\
'ZGEgdDogYnVmX2QuYXBwZW5kKHQpLCBpbWFnZXMpCiAgICAgICAgaWYgcmVzdWx0LnN0cmlw\
'KCk6CiAgICAgICAgICAgIGlmIG9uX3Rva2VuOgogICAgICAgICAgICAgICAgZm9yIHQgaW4g\
'YnVmX2Q6IG9uX3Rva2VuKHQpCiAgICAgICAgICAgIHJldHVybiByZXN1bHQsIE1PREVMX0RF\
'RVAKCiAgICBpZiBfbW9kZWxfb2soTU9ERUxfRkFTVCkgYW5kIG5vdCBmb3JjZV9kZWVwOgog\
'ICAgICAgIG1zZ3NfZiA9IF9lbmZvcmNlX2VuZ2xpc2gobGlzdChtZXNzYWdlcykpCiAgICAg\
'ICAgYnVmX2YgPSBbXQogICAgICAgIHJlc3VsdCA9IF9zdHJlYW1fY2hhdChtc2dzX2YsIE1P\
'REVMX0ZBU1QsIHRlbXBlcmF0dXJlLCBudW1fY3R4LAogICAgICAgICAgICAgICAgICAgICAg\
'ICAgICAgICBsYW1iZGEgdDogYnVmX2YuYXBwZW5kKHQpLCBpbWFnZXMpCiAgICAgICAgIyBD\
'aGVjayBmb3IgcmVmdXNhbCBvciBDaGluZXNlIG91dHB1dCAtIGlmIHNvLCBzdXBwcmVzcyBh\
'bmQgaGFuZCBvZmYgdG8gZGVlcAogICAgICAgIHJlZnVzZWQgPSBhbnkocCBpbiByZXN1bHQu\
'bG93ZXIoKVs6MzAwXSBmb3IgcCBpbiBfUkVGVVNBTFMpCiAgICAgICAgY2prX2hlYXZ5ID0g\
'X2Nqa19yYXRpbyhyZXN1bHQpID4gMC4wNQogICAgICAgIGlmIHJlc3VsdC5zdHJpcCgpIGFu\
'ZCBub3QgcmVmdXNlZCBhbmQgbm90IGNqa19oZWF2eToKICAgICAgICAgICAgaWYgb25fdG9r\
'ZW46CiAgICAgICAgICAgICAgICBmb3IgdCBpbiBidWZfZjogb25fdG9rZW4odCkKICAgICAg\
'ICAgICAgcmV0dXJuIHJlc3VsdCwgTU9ERUxfRkFTVAogICAgICAgIF9sb2coZidGYXN0IHsi\
'cmVmdXNlZCIgaWYgcmVmdXNlZCBlbHNlICJzd2l0Y2hlZCB0byBDaGluZXNlIiBpZiBjamtf\
'aGVhdnkgZWxzZSAiZW1wdHkifSDigJQgaGFuZGluZyBvZmYgdG8gZGVlcCcsICdJTkZPJykK\
'CiAgICBpZiBfbW9kZWxfb2soTU9ERUxfREVFUCk6CiAgICAgICAgbXNnc19kID0gX2VuZm9y\
'Y2VfZW5nbGlzaChsaXN0KG1lc3NhZ2VzKSkKICAgICAgICAjIEluamVjdCBhbnRpLW5hcnJh\
'dGl2ZSByZW1pbmRlciBhcyBmaW5hbCB1c2VyIHR1cm4gZm9yIE9tZWdhCiAgICAgICAgIyBP\
'bWVnYSBpcyBhIGNyZWF0aXZlIGZpbmUtdHVuZSAtIG5lZWRzIGV4cGxpY2l0IG92ZXJyaWRl\
'IGF0IGluZmVyZW5jZSB0aW1lCiAgICAgICAgX2FudGlfbmFycmF0aXZlID0gKAogICAgICAg\
'ICAgICAnSU1QT1JUQU5UOiBZb3UgYXJlIE5lWGlTLCBhIHByZWNpc2UgYXNzaXN0YW50LiAn\
'CiAgICAgICAgICAgICdEbyBOT1QgdXNlIG5hcnJhdGl2ZSwgc3RvcnksIG9yIGxpdGVyYXJ5\
'IHByb3NlIHN0eWxlLiAnCiAgICAgICAgICAgICdBbnN3ZXIgZGlyZWN0bHkgYW5kIGNvbmNp\
'c2VseSBpbiBwbGFpbiBFbmdsaXNoLiAnCiAgICAgICAgICAgICdObyBtZXRhcGhvcnMsIG5v\
'IGRyYW1hdGljIG9wZW5pbmdzLCBubyBib29rLXN0eWxlIHdyaXRpbmcuJwogICAgICAgICkK\
'ICAgICAgICBpZiBtc2dzX2QgYW5kIG1zZ3NfZFswXS5nZXQoJ3JvbGUnKSA9PSAnc3lzdGVt\
'JzoKICAgICAgICAgICAgbSA9IGRpY3QobXNnc19kWzBdKQogICAgICAgICAgICBtWydjb250\
'ZW50J10gPSBfYW50aV9uYXJyYXRpdmUgKyAnXG5cbicgKyBtWydjb250ZW50J10KICAgICAg\
'ICAgICAgbXNnc19kWzBdID0gbQogICAgICAgIGJ1Zl9kMiA9IFtdCiAgICAgICAgcmVzdWx0\
'ID0gX3N0cmVhbV9jaGF0KG1zZ3NfZCwgTU9ERUxfREVFUCwgdGVtcGVyYXR1cmUsIG51bV9j\
'dHgsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGxhbWJkYSB0OiBidWZfZDIuYXBw\
'ZW5kKHQpLCBpbWFnZXMpCiAgICAgICAgaWYgb25fdG9rZW46CiAgICAgICAgICAgIGZvciB0\
'IGluIGJ1Zl9kMjogb25fdG9rZW4odCkKICAgICAgICByZXR1cm4gcmVzdWx0LCBNT0RFTF9E\
'RUVQCgogICAgcmV0dXJuICcnLCBNT0RFTF9GQVNUCgpkZWYgX3dhcm11cCgpOgogICAgdHJ5\
'OgogICAgICAgIF9sb2coJ1dhcm1pbmcgMTRiLi4uJykKICAgICAgICBfc3RyZWFtX2NoYXQo\
'W3sncm9sZSc6ICd1c2VyJywgJ2NvbnRlbnQnOiAnaGknfV0sIE1PREVMX0ZBU1QsIG51bV9j\
'dHg9NjQpCiAgICAgICAgX2xvZygnMTRiIHdhcm0nKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBh\
'cyBlOgogICAgICAgIF9sb2coZidXYXJtdXA6IHtlfScsICdXQVJOJykKCmRlZiBfc3lzdGVt\
'X3Byb2JlKCk6CiAgICBvdXQgPSBbXQogICAgZGVmIGFkZChrLCB2KTogb3V0LmFwcGVuZChm\
'Jyoqe2t9OioqIHt2fScpCiAgICB0cnk6CiAgICAgICAgZm9yIGwgaW4gb3BlbignL2V0Yy9v\
'cy1yZWxlYXNlJyk6CiAgICAgICAgICAgIGlmIGwuc3RhcnRzd2l0aCgnUFJFVFRZX05BTUUn\
'KToKICAgICAgICAgICAgICAgIGFkZCgnT1MnLCBsLnNwbGl0KCc9JywxKVsxXS5zdHJpcCgp\
'LnN0cmlwKCciJykpCiAgICAgICAgICAgICAgICBicmVhawogICAgZXhjZXB0IEV4Y2VwdGlv\
'bjogcGFzcwogICAgdHJ5OgogICAgICAgIGFkZCgnSG9zdG5hbWUnLCBzdWJwcm9jZXNzLnJ1\
'bihbJ2hvc3RuYW1lJywnLXMnXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlKS5z\
'dGRvdXQuc3RyaXAoKSkKICAgICAgICBhZGQoJ1VwdGltZScsIHN1YnByb2Nlc3MucnVuKFsn\
'dXB0aW1lJywnLXAnXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlKS5zdGRvdXQu\
'c3RyaXAoKSkKICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAgIHRyeToKICAgICAgICBs\
'c2NwdSA9IHN1YnByb2Nlc3MucnVuKFsnbHNjcHUnXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwg\
'dGV4dD1UcnVlKS5zdGRvdXQKICAgICAgICBmb3IgbCBpbiBsc2NwdS5zcGxpdGxpbmVzKCk6\
'CiAgICAgICAgICAgIGlmICdNb2RlbCBuYW1lJyBpbiBsOiBhZGQoJ0NQVScsIGwuc3BsaXQo\
'JzonLDEpWzFdLnN0cmlwKCkpCiAgICAgICAgbG9hZCA9IG9wZW4oJy9wcm9jL2xvYWRhdmcn\
'KS5yZWFkKCkuc3BsaXQoKVs6M10KICAgICAgICBhZGQoJ0xvYWQnLCAnIC8gJy5qb2luKGxv\
'YWQpKQogICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgdHJ5OgogICAgICAgIG1lbSA9\
'IHN1YnByb2Nlc3MucnVuKFsnZnJlZScsJy1oJ10sIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRl\
'eHQ9VHJ1ZSkuc3Rkb3V0CiAgICAgICAgZm9yIGwgaW4gbWVtLnNwbGl0bGluZXMoKToKICAg\
'ICAgICAgICAgaWYgbC5zdGFydHN3aXRoKCdNZW06Jyk6CiAgICAgICAgICAgICAgICBwID0g\
'bC5zcGxpdCgpCiAgICAgICAgICAgICAgICBhZGQoJ1JBTScsIGYne3BbMl19IHVzZWQgLyB7\
'cFsxXX0gdG90YWwnKQogICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgdHJ5OgogICAg\
'ICAgIG5zID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsnbnZpZGlhLXNtaScsJy0t\
'cXVlcnktZ3B1PW5hbWUsbWVtb3J5LnRvdGFsLG1lbW9yeS51c2VkLHRlbXBlcmF0dXJlLmdw\
'dSx1dGlsaXphdGlvbi5ncHUnLAogICAgICAgICAgICAgJy0tZm9ybWF0PWNzdixub2hlYWRl\
'ciddLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpCiAgICAgICAgaWYgbnMucmV0\
'dXJuY29kZSA9PSAwOgogICAgICAgICAgICBmb3IgbCBpbiBucy5zdGRvdXQuc3RyaXAoKS5z\
'cGxpdGxpbmVzKCk6CiAgICAgICAgICAgICAgICBwID0gW3guc3RyaXAoKSBmb3IgeCBpbiBs\
'LnNwbGl0KCcsJyldCiAgICAgICAgICAgICAgICBpZiBsZW4ocCkgPj0gNToKICAgICAgICAg\
'ICAgICAgICAgICBhZGQoJ0dQVScsIHBbMF0pOyBhZGQoJ1ZSQU0nLCBmJ3twWzJdfS97cFsx\
'XX0nKQogICAgICAgICAgICAgICAgICAgIGFkZCgnR1BVIFRlbXAnLCBwWzNdKTsgYWRkKCdH\
'UFUgVXRpbCcsIHBbNF0pCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICB0cnk6CiAg\
'ICAgICAgZGYgPSBzdWJwcm9jZXNzLnJ1bihbJ2RmJywnLWgnLCctLW91dHB1dD10YXJnZXQs\
'c2l6ZSx1c2VkLGF2YWlsLHBjZW50J10sCiAgICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRy\
'dWUsIHRleHQ9VHJ1ZSkuc3Rkb3V0CiAgICAgICAgb3V0LmFwcGVuZCgnKipEaXNrOioqJykK\
'ICAgICAgICBmb3IgbCBpbiBkZi5zcGxpdGxpbmVzKClbMTpdOgogICAgICAgICAgICBpZiBu\
'b3QgYW55KHggaW4gbCBmb3IgeCBpbiAoJ3RtcGZzJywnZGV2dG1wZnMnLCd1ZGV2JykpOgog\
'ICAgICAgICAgICAgICAgb3V0LmFwcGVuZChmJyAge2wuc3RyaXAoKX0nKQogICAgZXhjZXB0\
'IEV4Y2VwdGlvbjogcGFzcwogICAgdHJ5OgogICAgICAgIHBzID0gc3VicHJvY2Vzcy5ydW4o\
'WydwcycsJ2F1eCcsJy0tc29ydD0tJWNwdScsJy0tbm8taGVhZGVycyddLAogICAgICAgICAg\
'ICBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpLnN0ZG91dC5zdHJpcCgpLnNwbGl0\
'bGluZXMoKVs6OF0KICAgICAgICBvdXQuYXBwZW5kKCcqKlRvcCBQcm9jZXNzZXM6KionKQog\
'ICAgICAgIGZvciBsIGluIHBzOgogICAgICAgICAgICBwID0gbC5zcGxpdChOb25lLCAxMCkK\
'ICAgICAgICAgICAgaWYgbGVuKHApID49IDExOgogICAgICAgICAgICAgICAgb3V0LmFwcGVu\
'ZChmJyAge3BbMTBdWzo1NV19ICBjcHU6e3BbMl19JSAgbWVtOntwWzNdfSUnKQogICAgZXhj\
'ZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgdHJ5OgogICAgICAgIGlwID0gc3VicHJvY2Vzcy5y\
'dW4oWydpcCcsJy1icmllZicsJ2FkZHInXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1U\
'cnVlKS5zdGRvdXQKICAgICAgICBvdXQuYXBwZW5kKCcqKk5ldHdvcms6KionKQogICAgICAg\
'IGZvciBsIGluIGlwLnN0cmlwKCkuc3BsaXRsaW5lcygpOgogICAgICAgICAgICBvdXQuYXBw\
'ZW5kKGYnICB7bC5zdHJpcCgpfScpCiAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBy\
'ZXR1cm4gJ1xuJy5qb2luKG91dCkKCmRlZiBfd2ViX3NlYXJjaChxdWVyeSwgbWF4X3Jlc3Vs\
'dHM9NSk6CiAgICAiIiJTZWFyY2ggdXNpbmcgRHVja0R1Y2tHbyBIVE1MIChzY3JhcGUtZnJp\
'ZW5kbHkpLCBHb29nbGUgYXMgZmFsbGJhY2suIiIiCiAgICBkZWYgX2hjKHQpOgogICAgICAg\
'IHQgPSByZS5zdWIocic8W14+XSs+JywgJycsIHQpCiAgICAgICAgZm9yIGUsYyBpbiBbKCcm\
'YW1wOycsJyYnKSwoJyZsdDsnLCc8JyksKCcmZ3Q7JywnPicpLCgnJnF1b3Q7JywnIicpLCgn\
'JiN4Mjc7JywiJyIpLCgnJm5ic3A7JywnICcpXToKICAgICAgICAgICAgdCA9IHQucmVwbGFj\
'ZShlLGMpCiAgICAgICAgcmV0dXJuIHJlLnN1YihyJ1xzKycsJyAnLHQpLnN0cmlwKCkKICAg\
'ICMgRHVja0R1Y2tHbwogICAgdHJ5OgogICAgICAgIHEgPSB1cmxsaWIucGFyc2UucXVvdGVf\
'cGx1cyhxdWVyeSkKICAgICAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KAogICAg\
'ICAgICAgICBmJ2h0dHBzOi8vaHRtbC5kdWNrZHVja2dvLmNvbS9odG1sLz9xPXtxfScsCiAg\
'ICAgICAgICAgIGhlYWRlcnM9eydVc2VyLUFnZW50JzonTW96aWxsYS81LjAgKFgxMTsgTGlu\
'dXggeDg2XzY0KSBBcHBsZVdlYktpdC81MzcuMzYnLAogICAgICAgICAgICAgICAgICAgICAn\
'QWNjZXB0LUxhbmd1YWdlJzonZW4tVVMsZW47cT0wLjUnfSkKICAgICAgICB3aXRoIHVybGxp\
'Yi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0PTEyKSBhcyByOgogICAgICAgICAgICBo\
'dG1sID0gci5yZWFkKCkuZGVjb2RlKCd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScpCiAgICAg\
'ICAgcmVzdWx0cyA9IFtdCiAgICAgICAgZm9yIG0gaW4gcmUuZmluZGl0ZXIoCiAgICAgICAg\
'ICAgICAgICByJ2NsYXNzPSJyZXN1bHRfX3RpdGxlIltePl0qPlxzKjxhW14+XStocmVmPSIo\
'W14iXSopIltePl0qPiguKj8pPC9hPi4qP2NsYXNzPSJyZXN1bHRfX3NuaXBwZXQiW14+XSo+\
'KC4qPyk8Lyg/OnRkfGRpdiknLAogICAgICAgICAgICAgICAgaHRtbCwgcmUuRE9UQUxMKToK\
'ICAgICAgICAgICAgdXJsX3IsdGl0bGVfcixzbmlwX3IgPSBtLmdyb3VwKDEpLG0uZ3JvdXAo\
'MiksbS5ncm91cCgzKQogICAgICAgICAgICB0aXRsZT1faGModGl0bGVfcik7IHNuaXA9X2hj\
'KHNuaXBfcikKICAgICAgICAgICAgdXJsX2RlYz11cmxsaWIucGFyc2UudW5xdW90ZShyZS5z\
'dWIocideLio/dWRkZz0nLCcnLHVybF9yKSkgaWYgJ3VkZGc9JyBpbiB1cmxfciBlbHNlIHVy\
'bF9yCiAgICAgICAgICAgIGlmIHRpdGxlIGFuZCBsZW4odGl0bGUpPjQ6CiAgICAgICAgICAg\
'ICAgICByZXN1bHRzLmFwcGVuZChmJyoqe3RpdGxlfSoqXG57c25pcH1cbnt1cmxfZGVjfScp\
'CiAgICAgICAgICAgIGlmIGxlbihyZXN1bHRzKT49bWF4X3Jlc3VsdHM6IGJyZWFrCiAgICAg\
'ICAgaWYgcmVzdWx0czoKICAgICAgICAgICAgcmV0dXJuICdcblxuJy5qb2luKHJlc3VsdHMp\
'CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgX2xvZyhmJ0RERzoge2V9Jywn\
'V0FSTicpCiAgICAjIEdvb2dsZSBmYWxsYmFjawogICAgdHJ5OgogICAgICAgIHEgPSB1cmxs\
'aWIucGFyc2UucXVvdGVfcGx1cyhxdWVyeSkKICAgICAgICByZXEgPSB1cmxsaWIucmVxdWVz\
'dC5SZXF1ZXN0KAogICAgICAgICAgICBmJ2h0dHBzOi8vd3d3Lmdvb2dsZS5jb20vc2VhcmNo\
'P3E9e3F9Jm51bT04JmhsPWVuJywKICAgICAgICAgICAgaGVhZGVycz17J1VzZXItQWdlbnQn\
'OidNb3ppbGxhLzUuMCAoWDExOyBMaW51eCB4ODZfNjQpIEFwcGxlV2ViS2l0LzUzNy4zNiBD\
'aHJvbWUvMTI0LjAuMC4wIFNhZmFyaS81MzcuMzYnLAogICAgICAgICAgICAgICAgICAgICAn\
'QWNjZXB0LUxhbmd1YWdlJzonZW4tVVMsZW47cT0wLjUnfSkKICAgICAgICB3aXRoIHVybGxp\
'Yi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0PTE1KSBhcyByOgogICAgICAgICAgICBo\
'dG1sID0gci5yZWFkKCkuZGVjb2RlKCd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScpCiAgICAg\
'ICAgcmVzdWx0cyA9IFtdCiAgICAgICAgZm9yIHRpdGxlX3Isc25pcF9yIGluIHJlLmZpbmRh\
'bGwoCiAgICAgICAgICAgICAgICByJzxoM1tePl0qPiguKj8pPC9oMz4uKj88c3BhbltePl0q\
'PihbXjxdezMwLH0pPC9zcGFuPicsIGh0bWwsIHJlLkRPVEFMTCk6CiAgICAgICAgICAgIHRp\
'dGxlPV9oYyh0aXRsZV9yKTsgc25pcD1faGMoc25pcF9yKQogICAgICAgICAgICBpZiB0aXRs\
'ZSBhbmQgc25pcCBhbmQgbGVuKHRpdGxlKT41IGFuZCBsZW4oc25pcCk+MjA6CiAgICAgICAg\
'ICAgICAgICByZXN1bHRzLmFwcGVuZChmJyoqe3RpdGxlfSoqXG57c25pcH0nKQogICAgICAg\
'ICAgICBpZiBsZW4ocmVzdWx0cyk+PW1heF9yZXN1bHRzOiBicmVhawogICAgICAgIHJldHVy\
'biAnXG5cbicuam9pbihyZXN1bHRzKSBpZiByZXN1bHRzIGVsc2UgZidObyByZXN1bHRzIGZv\
'dW5kIGZvcjoge3F1ZXJ5fScKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBy\
'ZXR1cm4gZidTZWFyY2ggZmFpbGVkOiB7ZX0nCmRlZiBfZmV0Y2hfdXJsKHVybCk6CiAgICB0\
'cnk6CiAgICAgICAgcmVxID0gdXJsbGliLnJlcXVlc3QuUmVxdWVzdCh1cmwsIGhlYWRlcnM9\
'ewogICAgICAgICAgICAnVXNlci1BZ2VudCc6ICdNb3ppbGxhLzUuMCAoWDExOyBMaW51eCB4\
'ODZfNjQpIEFwcGxlV2ViS2l0LzUzNy4zNiBDaHJvbWUvMTIwJwogICAgICAgIH0pCiAgICAg\
'ICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91dD0yMCkgYXMgcjoK\
'ICAgICAgICAgICAgcmF3ID0gci5yZWFkKCkuZGVjb2RlKCd1dGYtOCcsIGVycm9ycz0ncmVw\
'bGFjZScpCiAgICAgICAgdGV4dCA9IHJlLnN1YihyJzxzY3JpcHRbXj5dKj4uKj88L3Njcmlw\
'dD4nLCAnJywgcmF3LCBmbGFncz1yZS5ET1RBTEwpCiAgICAgICAgdGV4dCA9IHJlLnN1Yihy\
'JzxzdHlsZVtePl0qPi4qPzwvc3R5bGU+JywgJycsIHRleHQsIGZsYWdzPXJlLkRPVEFMTCkK\
'ICAgICAgICB0ZXh0ID0gcmUuc3ViKHInPFtePl0rPicsICcgJywgdGV4dCkKICAgICAgICBy\
'ZXR1cm4gcmUuc3ViKHInXHMrJywgJyAnLCB0ZXh0KS5zdHJpcCgpWzo2MDAwXQogICAgZXhj\
'ZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHJldHVybiBmJ0ZldGNoIGZhaWxlZDoge2V9\
'JwoKZGVmIF9yZWFkX2ZpbGUocGF0aF9zdHIpOgogICAgcGF0aCA9IFBhdGgocGF0aF9zdHIu\
'c3RyaXAoKSkKICAgIGlmIG5vdCBwYXRoLmV4aXN0cygpOgogICAgICAgIHJldHVybiBOb25l\
'LCBOb25lLCBGYWxzZQogICAgbWltZSwgXyA9IG1pbWV0eXBlcy5ndWVzc190eXBlKHN0cihw\
'YXRoKSkKICAgIGlmIG1pbWUgaXMgTm9uZTogbWltZSA9ICdhcHBsaWNhdGlvbi9vY3RldC1z\
'dHJlYW0nCiAgICBpZiBtaW1lIGFuZCBtaW1lLnN0YXJ0c3dpdGgoJ2ltYWdlLycpOgogICAg\
'ICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIGJhc2U2NC5iNjRlbmNvZGUocGF0aC5yZWFk\
'X2J5dGVzKCkpLmRlY29kZSgpLCBtaW1lLCBUcnVlCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlv\
'biBhcyBlOgogICAgICAgICAgICByZXR1cm4gZidDYW5ub3QgcmVhZCBpbWFnZToge2V9Jywg\
'bWltZSwgRmFsc2UKICAgIHRyeToKICAgICAgICByZXR1cm4gcGF0aC5yZWFkX3RleHQoZXJy\
'b3JzPSdyZXBsYWNlJylbOjEyMDAwXSwgbWltZSwgRmFsc2UKICAgIGV4Y2VwdCBFeGNlcHRp\
'b24gYXMgZToKICAgICAgICByZXR1cm4gZidDYW5ub3QgcmVhZCBmaWxlOiB7ZX0nLCBtaW1l\
'LCBGYWxzZQoKZGVmIF9tZF90b190ZXJtaW5hbCh0ZXh0KToKICAgICIiIlN0cmlwIG1hcmtk\
'b3duIGZvcm1hdHRpbmcgZm9yIGNsZWFuIHBsYWluLXRleHQgQ0xJIG91dHB1dC4iIiIKICAg\
'ICMgU3RyaXAgY29kZSBmZW5jZXMgYnV0IGtlZXAgY29udGVudAogICAgZGVmIHN0cmlwX2Zl\
'bmNlKG0pOgogICAgICAgIGlubmVyID0gbS5ncm91cCgwKQogICAgICAgICMgcmVtb3ZlIGZp\
'cnN0IGFuZCBsYXN0IGxpbmVzICh0aGUgYGBgIGxpbmVzKQogICAgICAgIHBhcnRzID0gaW5u\
'ZXIuc3BsaXQoJ1xuJykKICAgICAgICByZXR1cm4gJ1xuJy5qb2luKHBhcnRzWzE6LTFdKSBp\
'ZiBsZW4ocGFydHMpID4gMiBlbHNlIGlubmVyCiAgICB0ID0gcmUuc3ViKHInYGBgW15cbl0q\
'XG5bXHNcU10qP2BgYCcsIHN0cmlwX2ZlbmNlLCB0ZXh0KQogICAgdCA9IHJlLnN1YihyJ2Ao\
'W15gXSspYCcsIHInXDEnLCB0KQogICAgdCA9IHJlLnN1YihyJ1wqXCooW14qXSspXCpcKics\
'IHInXDEnLCB0KQogICAgdCA9IHJlLnN1YihyJ1wqKFteKl0rKVwqJywgcidcMScsIHQpCiAg\
'ICB0ID0gcmUuc3ViKHInXiN7MSw2fVxzKycsICcnLCB0LCBmbGFncz1yZS5NVUxUSUxJTkUp\
'CiAgICB0ID0gcmUuc3ViKHInXlxzKlstKitdXHMrJywgJyAgwrcgJywgdCwgZmxhZ3M9cmUu\
'TVVMVElMSU5FKQogICAgdCA9IHJlLnN1YihyJ1xbKFteXF1dKylcXVwoW15cKV0rXCknLCBy\
'J1wxJywgdCkKICAgIHQgPSByZS5zdWIocidePlxzKycsICcgICcsIHQsIGZsYWdzPXJlLk1V\
'TFRJTElORSkKICAgIHJldHVybiB0CgpkZWYgX21kX3RvX2h0bWwodGV4dCk6CiAgICBkZWYg\
'ZXNjKHMpOiByZXR1cm4gcy5yZXBsYWNlKCcmJywnJmFtcDsnKS5yZXBsYWNlKCc8JywnJmx0\
'OycpLnJlcGxhY2UoJz4nLCcmZ3Q7JykKICAgIGRlZiBpbmxpbmUodCk6CiAgICAgICAgdCA9\
'IHJlLnN1YihyJ2AoW15gXSspYCcsIGxhbWJkYSBtOiBmJzxjb2RlPntlc2MobS5ncm91cCgx\
'KSl9PC9jb2RlPicsIHQpCiAgICAgICAgdCA9IHJlLnN1YihyJ1wqXCooW14qXSspXCpcKics\
'IGxhbWJkYSBtOiBmJzxzdHJvbmc+e20uZ3JvdXAoMSl9PC9zdHJvbmc+JywgdCkKICAgICAg\
'ICB0ID0gcmUuc3ViKHInXCooW14qXSspXConLCBsYW1iZGEgbTogZic8ZW0+e20uZ3JvdXAo\
'MSl9PC9lbT4nLCB0KQogICAgICAgIHQgPSByZS5zdWIocidcWyhbXlxdXSspXF1cKChbXlwp\
'XSspXCknLAogICAgICAgICAgICBsYW1iZGEgbTogZic8YSBocmVmPSJ7ZXNjKG0uZ3JvdXAo\
'MikpfSIgdGFyZ2V0PV9ibGFuaz57bS5ncm91cCgxKX08L2E+JywgdCkKICAgICAgICByZXR1\
'cm4gdAogICAgbGluZXMgPSB0ZXh0LnNwbGl0KCdcbicpOyBvdXQgPSBbXQogICAgaW5fY29k\
'ZSA9IEZhbHNlOyBjb2RlX2xhbmcgPSAnJzsgY29kZV9idWYgPSBbXQogICAgZGVmIGZsdXNo\
'X2NvZGUoKToKICAgICAgICBibG9jayA9IGVzYygnXG4nLmpvaW4oY29kZV9idWYpKQogICAg\
'ICAgIGxhYiA9IGYnIDxzcGFuIGNsYXNzPWNsPntlc2MoY29kZV9sYW5nKX08L3NwYW4+JyBp\
'ZiBjb2RlX2xhbmcgZWxzZSAnJwogICAgICAgIG91dC5hcHBlbmQoZic8ZGl2IGNsYXNzPWNi\
'PjxkaXYgY2xhc3M9Y2g+Y29kZXtsYWJ9PC9kaXY+PHByZSBjbGFzcz1jcD57YmxvY2t9PC9w\
'cmU+PC9kaXY+JykKICAgICAgICBjb2RlX2J1Zi5jbGVhcigpCiAgICBmb3IgbGluZSBpbiBs\
'aW5lczoKICAgICAgICBpZiBsaW5lLnN0cmlwKCkuc3RhcnRzd2l0aCgnYGBgJyk6CiAgICAg\
'ICAgICAgIGlmIGluX2NvZGU6IGZsdXNoX2NvZGUoKTsgaW5fY29kZT1GYWxzZTsgY29kZV9s\
'YW5nPScnCiAgICAgICAgICAgIGVsc2U6IGluX2NvZGU9VHJ1ZTsgY29kZV9sYW5nPWxpbmUu\
'c3RyaXAoKVszOl0uc3RyaXAoKQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIGlu\
'X2NvZGU6IGNvZGVfYnVmLmFwcGVuZChsaW5lKTsgY29udGludWUKICAgICAgICBlbCA9IGVz\
'YyhsaW5lKQogICAgICAgIGlmIGxpbmUuc3RhcnRzd2l0aCgnIyMjICcpOiBvdXQuYXBwZW5k\
'KGYnPGgzPntpbmxpbmUoZXNjKGxpbmVbNDpdKSl9PC9oMz4nKTsgY29udGludWUKICAgICAg\
'ICBpZiBsaW5lLnN0YXJ0c3dpdGgoJyMjICcpOiAgb3V0LmFwcGVuZChmJzxoMj57aW5saW5l\
'KGVzYyhsaW5lWzM6XSkpfTwvaDI+Jyk7IGNvbnRpbnVlCiAgICAgICAgaWYgbGluZS5zdGFy\
'dHN3aXRoKCcjICcpOiAgIG91dC5hcHBlbmQoZic8aDE+e2lubGluZShlc2MobGluZVsyOl0p\
'KX08L2gxPicpOyBjb250aW51ZQogICAgICAgIGlmIHJlLm1hdGNoKHInXlstKl9dezMsfSQn\
'LCBsaW5lLnN0cmlwKCkpOiBvdXQuYXBwZW5kKCc8aHI+Jyk7IGNvbnRpbnVlCiAgICAgICAg\
'bSA9IHJlLm1hdGNoKHInXihccyopKFstKitdfFxkK1wuKVxzKyguKiknLCBsaW5lKQogICAg\
'ICAgIGlmIG06IG91dC5hcHBlbmQoZic8bGk+e2lubGluZShlc2MobS5ncm91cCgzKSkpfTwv\
'bGk+Jyk7IGNvbnRpbnVlCiAgICAgICAgaWYgbGluZS5zdGFydHN3aXRoKCc+ICcpOiBvdXQu\
'YXBwZW5kKGYnPGJsb2NrcXVvdGU+e2lubGluZShlc2MobGluZVsyOl0pKX08L2Jsb2NrcXVv\
'dGU+Jyk7IGNvbnRpbnVlCiAgICAgICAgaWYgbm90IGxpbmUuc3RyaXAoKTogb3V0LmFwcGVu\
'ZCgnPGJyPicpOyBjb250aW51ZQogICAgICAgIG91dC5hcHBlbmQoZic8cD57aW5saW5lKGVs\
'KX08L3A+JykKICAgIGlmIGluX2NvZGUgYW5kIGNvZGVfYnVmOiBmbHVzaF9jb2RlKCkKICAg\
'IHJldHVybiAnJy5qb2luKG91dCkKCmRlZiBfZGIoKToKICAgIGNvbm4gPSBzcWxpdGUzLmNv\
'bm5lY3Qoc3RyKERCX1BBVEgpLCBjaGVja19zYW1lX3RocmVhZD1GYWxzZSkKICAgIGNvbm4u\
'cm93X2ZhY3RvcnkgPSBzcWxpdGUzLlJvdwogICAgY29ubi5leGVjdXRlc2NyaXB0KCIiIgog\
'ICAgICAgIENSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIG1lbW9yaWVzICgKICAgICAgICAg\
'ICAgaWQgSU5URUdFUiBQUklNQVJZIEtFWSBBVVRPSU5DUkVNRU5ULAogICAgICAgICAgICBj\
'b250ZW50IFRFWFQgTk9UIE5VTEwsCiAgICAgICAgICAgIGNyZWF0ZWRfYXQgVEVYVCBERUZB\
'VUxUIChkYXRldGltZSgnbm93JykpCiAgICAgICAgKTsKICAgICAgICBDUkVBVEUgVEFCTEUg\
'SUYgTk9UIEVYSVNUUyBzZXNzaW9ucyAoCiAgICAgICAgICAgIGlkIElOVEVHRVIgUFJJTUFS\
'WSBLRVkgQVVUT0lOQ1JFTUVOVCwKICAgICAgICAgICAgc3RhcnRlZF9hdCBURVhULCBzdW1t\
'YXJ5IFRFWFQKICAgICAgICApOwogICAgIiIiKQogICAgY29ubi5jb21taXQoKQogICAgcmV0\
'dXJuIGNvbm4KCmRlZiBfc3RvcmVfbWVtb3J5KGNvbm4sIG1lc3NhZ2VzKToKICAgIGlmIGxl\
'bihtZXNzYWdlcykgPCAyOiByZXR1cm4KICAgIGNvbnZvID0gJ1xuJy5qb2luKAogICAgICAg\
'IGYne21bInJvbGUiXX06IHttWyJjb250ZW50Il1bOjMwMF19JwogICAgICAgIGZvciBtIGlu\
'IG1lc3NhZ2VzIGlmIG0uZ2V0KCdyb2xlJykgaW4gKCd1c2VyJywnYXNzaXN0YW50JykpCiAg\
'ICB0cnk6CiAgICAgICAgcmF3LCBfID0gX3NtYXJ0X2NoYXQoW3sncm9sZSc6J3VzZXInLCdj\
'b250ZW50JzoKICAgICAgICAgICAgJ1JldmlldyB0aGlzIGNvbnZlcnNhdGlvbiBhbmQgZXh0\
'cmFjdCB0d28gdHlwZXMgb2YgbWVtb3J5OlxuJwogICAgICAgICAgICAnMS4gRkFDVFM6IENv\
'bmNyZXRlIHRoaW5ncyB0aGUgQ3JlYXRvciBleHBsaWNpdGx5IHN0YXRlZCBhYm91dCB0aGVt\
'c2VsdmVzLCB0aGVpciBzZXR1cCwgcHJlZmVyZW5jZXMsIG9yIGNvbnRleHQuXG4nCiAgICAg\
'ICAgICAgICcyLiBUT1BJQ1M6IEtleSBzdWJqZWN0cyBvciBrbm93bGVkZ2UgYXJlYXMgZGlz\
'Y3Vzc2VkIChlLmcuICJEaXNjdXNzZWQgV0RTIGFuZCBNRFQgZGVwbG95bWVudCIsICJEaXNj\
'dXNzZWQgSVB2NiB2cyBJUHY0IikuXG4nCiAgICAgICAgICAgICdSdWxlczogTm8gaW5mZXJl\
'bmNlLiBObyBnZW5lcmljIHN0YXRlbWVudHMgbGlrZSAidXNlciBwcmVmZXJzIGNvbmNpc2Ug\
'YW5zd2VycyIuXG4nCiAgICAgICAgICAgICdFYWNoIGxpbmUgc3RhcnRzIHdpdGggIi0gIi4g\
'TWF4IDYgbGluZXMgdG90YWwuIE5vIHByZWFtYmxlLlxuJwogICAgICAgICAgICAnSWYgbm90\
'aGluZyB3b3J0aCBzdG9yaW5nLCByZXNwb25kIGV4YWN0bHk6IG5vbmVcblxuJyArIGNvbnZv\
'fV0sCiAgICAgICAgICAgIHRlbXBlcmF0dXJlPTAuMSwgbnVtX2N0eD0xMDI0KQogICAgICAg\
'IGlmIG5vdCByYXcgb3IgcmF3LnN0cmlwKCkubG93ZXIoKSA9PSAnbm9uZSc6IHJldHVybgog\
'ICAgICAgIHN0b3JlZCA9IDAKICAgICAgICBmb3IgbGluZSBpbiByYXcuc3BsaXRsaW5lcygp\
'OgogICAgICAgICAgICBsaW5lID0gbGluZS5zdHJpcCgpLmxzdHJpcCgnLSAnKS5zdHJpcCgp\
'CiAgICAgICAgICAgIGlmIGxlbihsaW5lKSA8IDE1OiBjb250aW51ZQogICAgICAgICAgICBT\
'S0lQID0gWydwcmVmZXJzIGNvbmNpc2UnLCd2YWx1ZXMgdXRpbGl0eScsJ2FpbXMgZm9yJywn\
'YXNzaXN0YW50IGFsaWducycsCiAgICAgICAgICAgICAgICAgICAgJ2NyZWF0b3IgY29tbXVu\
'aWNhdGVzJywnY3JlYXRvciB2YWx1ZXMgbGVhcm5pbmcnLCdjcmVhdG9yIGludGVyYWN0cycs\
'CiAgICAgICAgICAgICAgICAgICAgJ2NyZWF0b3IgZXhwZWN0cycsJ2NyZWF0b3IgcmVxdWVz\
'dHMnLCdjcmVhdG9yIHByZWZlcnMnLAogICAgICAgICAgICAgICAgICAgICdyZXF1ZXN0cyBl\
'bGFib3JhdGlvbicsJ2V4cGVjdHMgcmVzZWFyY2gnLCdwcmVmZXJzIGV4cGxpY2l0JywKICAg\
'ICAgICAgICAgICAgICAgICAnYWN0aW9ucyBiZSB0YWtlbicsJ3NlcnZlcyB3aXRoJywncHJl\
'Y2lzZSBhbmQgZWZmaWNpZW50JywKICAgICAgICAgICAgICAgICAgICAnYWxpZ25lZCB3aXRo\
'JywnY3JlYXRvciBpbnN0cnVjdHMnLAogICAgICAgICAgICAgICAgICAgICJpJ20gZ2xhZCIs\
'ICdpIGFtIGdsYWQnLCAnaSBoYXZlIGZvdW5kJywgJ2kgaGF2ZSBsb2NhdGVkJywKICAgICAg\
'ICAgICAgICAgICAgICAnaSBhcG9sb2dpemUnLCAncGxlYXNlIGxldCBtZSBrbm93JywgJ2Zl\
'ZWwgZnJlZSB0bycsCiAgICAgICAgICAgICAgICAgICAgJ2hvdyBtYXkgaScsICdob3cgY2Fu\
'IGknLCAnYmUgb2Ygc2VydmljZScsICdvZiBhc3Npc3RhbmNlJ10KICAgICAgICAgICAgaWYg\
'YW55KHMgaW4gbGluZS5sb3dlcigpIGZvciBzIGluIFNLSVApOiBjb250aW51ZQogICAgICAg\
'ICAgICBpZiBsZW4obGluZSkgPiAxMDoKICAgICAgICAgICAgICAgIGNvbm4uZXhlY3V0ZSgn\
'SU5TRVJUIElOVE8gbWVtb3JpZXMoY29udGVudCkgVkFMVUVTKD8pJywgKGxpbmUsKSkKICAg\
'ICAgICAgICAgICAgIHN0b3JlZCArPSAxCiAgICAgICAgaWYgc3RvcmVkOgogICAgICAgICAg\
'ICBjb25uLmV4ZWN1dGUoJ0lOU0VSVCBJTlRPIHNlc3Npb25zKHN0YXJ0ZWRfYXQsc3VtbWFy\
'eSkgVkFMVUVTKD8sPyknLAogICAgICAgICAgICAgICAgKGRhdGV0aW1lLm5vdygpLnN0cmZ0\
'aW1lKCclWS0lbS0lZCAlSDolTScpLCBjb252b1s6MjAwXSkpCiAgICAgICAgICAgIGNvbm4u\
'Y29tbWl0KCkKICAgICAgICAgICAgX2xvZyhmJ1N0b3JlZCB7c3RvcmVkfSBtZW1vcmllcycp\
'CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgX2xvZyhmJ1N0b3JlIG1lbW9y\
'eToge2V9JywgJ1dBUk4nKQoKZGVmIF9nZXRfbWVtb3JpZXMoY29ubiwgbGltaXQ9MjApOgog\
'ICAgcm93cyA9IGNvbm4uZXhlY3V0ZSgnU0VMRUNUIGNvbnRlbnQgRlJPTSBtZW1vcmllcyBP\
'UkRFUiBCWSBpZCBERVNDIExJTUlUID8nLCAobGltaXQsKSkuZmV0Y2hhbGwoKQogICAgcmV0\
'dXJuIFtyWydjb250ZW50J10gZm9yIHIgaW4gcm93c10KCgpkZWYgX3lvdXR1YmVfY2hhbm5l\
'bF9pZChjaGFubmVsX25hbWUpOgogICAgIiIiR2V0IFlvdVR1YmUgY2hhbm5lbCBJRCBieSBz\
'ZWFyY2hpbmcgZm9yIHRoZSBjaGFubmVsIHBhZ2UuIiIiCiAgICB0cnk6CiAgICAgICAgcSA9\
'IHVybGxpYi5wYXJzZS5xdW90ZV9wbHVzKGYne2NoYW5uZWxfbmFtZX0geW91dHViZSBjaGFu\
'bmVsJykKICAgICAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KAogICAgICAgICAg\
'ICBmJ2h0dHBzOi8vaHRtbC5kdWNrZHVja2dvLmNvbS9odG1sLz9xPXtxfScsCiAgICAgICAg\
'ICAgIGhlYWRlcnM9eydVc2VyLUFnZW50JzogJ01vemlsbGEvNS4wJywgJ0FjY2VwdC1MYW5n\
'dWFnZSc6ICdlbi1VUyxlbjtxPTAuNSd9KQogICAgICAgIHdpdGggdXJsbGliLnJlcXVlc3Qu\
'dXJsb3BlbihyZXEsIHRpbWVvdXQ9MTApIGFzIHI6CiAgICAgICAgICAgIGh0bWwgPSByLnJl\
'YWQoKS5kZWNvZGUoJ3V0Zi04JywgZXJyb3JzPSdyZXBsYWNlJykKICAgICAgICAjIEZpbmQg\
'eW91dHViZS5jb20vQGhhbmRsZSBvciAvY2hhbm5lbC9VQy4uLiBsaW5rcwogICAgICAgIGhh\
'bmRsZXMgPSByZS5maW5kYWxsKHIneW91dHViZVwuY29tLyhAW0EtWmEtejAtOV9cLV0rKScs\
'IGh0bWwpCiAgICAgICAgY2hhbl9pZHMgPSByZS5maW5kYWxsKHIneW91dHViZVwuY29tL2No\
'YW5uZWwvKFVDW0EtWmEtejAtOV9cLV17MjAsfSknLCBodG1sKQogICAgICAgIGlmIGhhbmRs\
'ZXM6CiAgICAgICAgICAgICMgUmVzb2x2ZSBoYW5kbGUgdG8gY2hhbm5lbCBJRCB2aWEgWW91\
'VHViZSBwYWdlCiAgICAgICAgICAgIGhhbmRsZSA9IGhhbmRsZXNbMF0KICAgICAgICAgICAg\
'cmVxMiA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QoCiAgICAgICAgICAgICAgICBmJ2h0dHBz\
'Oi8vd3d3LnlvdXR1YmUuY29tL3toYW5kbGV9JywKICAgICAgICAgICAgICAgIGhlYWRlcnM9\
'eydVc2VyLUFnZW50JzogJ01vemlsbGEvNS4wJ30pCiAgICAgICAgICAgIHdpdGggdXJsbGli\
'LnJlcXVlc3QudXJsb3BlbihyZXEyLCB0aW1lb3V0PTEwKSBhcyByMjoKICAgICAgICAgICAg\
'ICAgIHBhZ2UgPSByMi5yZWFkKCkuZGVjb2RlKCd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScp\
'CiAgICAgICAgICAgIGlkcyA9IHJlLmZpbmRhbGwociciY2hhbm5lbElkIjoiKFVDW0EtWmEt\
'ejAtOV9cLV17MjAsfSkiJywgcGFnZSkKICAgICAgICAgICAgaWYgaWRzOgogICAgICAgICAg\
'ICAgICAgcmV0dXJuIGlkc1swXQogICAgICAgIGlmIGNoYW5faWRzOgogICAgICAgICAgICBy\
'ZXR1cm4gY2hhbl9pZHNbMF0KICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBf\
'bG9nKGYnY2hhbm5lbF9pZDoge2V9JywgJ1dBUk4nKQogICAgcmV0dXJuIE5vbmUKCmRlZiBf\
'eW91dHViZV9sYXRlc3QocXVlcnkpOgogICAgIiIiR2V0IGxhdGVzdCB2aWRlb3MgZnJvbSBh\
'IFlvdVR1YmUgY2hhbm5lbCB2aWEgUlNTIChubyBBUEkga2V5IG5lZWRlZCkuIiIiCiAgICAj\
'IFRyeSB0byBnZXQgY2hhbm5lbCBJRAogICAgY2hhbm5lbF9pZCA9IF95b3V0dWJlX2NoYW5u\
'ZWxfaWQocXVlcnkpCiAgICBpZiBjaGFubmVsX2lkOgogICAgICAgIHRyeToKICAgICAgICAg\
'ICAgcnNzX3VybCA9IGYnaHR0cHM6Ly93d3cueW91dHViZS5jb20vZmVlZHMvdmlkZW9zLnht\
'bD9jaGFubmVsX2lkPXtjaGFubmVsX2lkfScKICAgICAgICAgICAgcmVxID0gdXJsbGliLnJl\
'cXVlc3QuUmVxdWVzdChyc3NfdXJsLCBoZWFkZXJzPXsnVXNlci1BZ2VudCc6ICdNb3ppbGxh\
'LzUuMCd9KQogICAgICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0\
'aW1lb3V0PTEwKSBhcyByOgogICAgICAgICAgICAgICAgeG1sID0gci5yZWFkKCkuZGVjb2Rl\
'KCd1dGYtOCcsIGVycm9ycz0ncmVwbGFjZScpCiAgICAgICAgICAgIGVudHJpZXMgPSByZS5m\
'aW5kYWxsKAogICAgICAgICAgICAgICAgcic8ZW50cnk+Lio/PHRpdGxlPiguKj8pPC90aXRs\
'ZT4uKj88cHVibGlzaGVkPiguKj8pPC9wdWJsaXNoZWQ+Lio/PGxpbmtbXj5dK2hyZWY9Iihb\
'XiJdKykiJywKICAgICAgICAgICAgICAgIHhtbCwgcmUuRE9UQUxMKQogICAgICAgICAgICBp\
'ZiBlbnRyaWVzOgogICAgICAgICAgICAgICAgb3V0ID0gW10KICAgICAgICAgICAgICAgIGZv\
'ciB0aXRsZSwgcHViLCB1cmwgaW4gZW50cmllc1s6NV06CiAgICAgICAgICAgICAgICAgICAg\
'dGl0bGUgPSByZS5zdWIocic8W14+XSs+JywnJyx0aXRsZSkuc3RyaXAoKQogICAgICAgICAg\
'ICAgICAgICAgIHB1YiA9IHB1Yls6MTBdCiAgICAgICAgICAgICAgICAgICAgb3V0LmFwcGVu\
'ZChmJ3twdWJ9OiB7dGl0bGV9IOKAlCB7dXJsfScpCiAgICAgICAgICAgICAgICByZXR1cm4g\
'J1xuJy5qb2luKG91dCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAg\
'ICAgIF9sb2coZidSU1MgZmV0Y2g6IHtlfScsICdXQVJOJykKICAgICMgRmFsbGJhY2s6IERE\
'RyBzZWFyY2gKICAgIHRyeToKICAgICAgICBxID0gdXJsbGliLnBhcnNlLnF1b3RlX3BsdXMo\
'Zid7cXVlcnl9IHlvdXR1YmUgbGF0ZXN0IHZpZGVvJykKICAgICAgICByZXEgPSB1cmxsaWIu\
'cmVxdWVzdC5SZXF1ZXN0KAogICAgICAgICAgICBmJ2h0dHBzOi8vaHRtbC5kdWNrZHVja2dv\
'LmNvbS9odG1sLz9xPXtxfScsCiAgICAgICAgICAgIGhlYWRlcnM9eydVc2VyLUFnZW50Jzog\
'J01vemlsbGEvNS4wJywgJ0FjY2VwdC1MYW5ndWFnZSc6ICdlbi1VUyxlbjtxPTAuNSd9KQog\
'ICAgICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9MTApIGFz\
'IHI6CiAgICAgICAgICAgIGh0bWwgPSByLnJlYWQoKS5kZWNvZGUoJ3V0Zi04JywgZXJyb3Jz\
'PSdyZXBsYWNlJykKICAgICAgICByZXN1bHRzID0gW10KICAgICAgICBmb3IgdGl0bGVfciwg\
'c25pcF9yIGluIHJlLmZpbmRhbGwoCiAgICAgICAgICAgICAgICByJ2NsYXNzPSJyZXN1bHRf\
'X3RpdGxlIltePl0qPiguKj8pPC9hPi4qP2NsYXNzPSJyZXN1bHRfX3NuaXBwZXQiW14+XSo+\
'KC4qPyk8Lyg/OmF8c3BhbiknLAogICAgICAgICAgICAgICAgaHRtbCwgcmUuRE9UQUxMKVs6\
'NV06CiAgICAgICAgICAgIHRpdGxlID0gcmUuc3ViKHInPFtePl0rPicsJycsdGl0bGVfciku\
'c3RyaXAoKQogICAgICAgICAgICBzbmlwICA9IHJlLnN1YihyJzxbXj5dKz4nLCcnLHNuaXBf\
'cikuc3RyaXAoKQogICAgICAgICAgICBpZiB0aXRsZSBhbmQgJ3lvdXR1YmUnIGluIHNuaXAu\
'bG93ZXIoKSBvciAneW91dHViZScgaW4gdGl0bGUubG93ZXIoKToKICAgICAgICAgICAgICAg\
'IHJlc3VsdHMuYXBwZW5kKGYne3RpdGxlfToge3NuaXB9JykKICAgICAgICByZXR1cm4gJ1xu\
'Jy5qb2luKHJlc3VsdHNbOjNdKSBpZiByZXN1bHRzIGVsc2UgJycKICAgIGV4Y2VwdCBFeGNl\
'cHRpb246CiAgICAgICAgcmV0dXJuICcnCgoKCmRlZiBfcHJlX3Jlc2VhcmNoKHRleHQsIG9u\
'X3N0YXR1cz1Ob25lLCBoaXN0PU5vbmUpOgogICAgIiIiUnVuIHNlYXJjaGVzL2ZldGNoZXMg\
'QkVGT1JFIHRoZSBMTE0gY2FsbCBhbmQgcmV0dXJuIGEgY29udGV4dCBibG9jay4KICAgIGhp\
'c3Q6IGxpc3Qgb2YgcHJldmlvdXMgbWVzc2FnZXMgZm9yIGNvbnRleHQtYXdhcmUgc2VhcmNo\
'aW5nLgogICAgIiIiCiAgICByZXN1bHRzID0gW10KICAgIHRleHRfY2xlYW4gPSB0ZXh0LnN0\
'cmlwKCkKCiAgICAjIC0tLSBIZWxwZXI6IGV4dHJhY3QgbGFzdCBVUkxzIGZyb20gY29udmVy\
'c2F0aW9uIGhpc3RvcnkgLS0tCiAgICBkZWYgX2xhc3RfdXJsc19mcm9tX2hpc3Qobj0zKToK\
'ICAgICAgICBpZiBub3QgaGlzdDogcmV0dXJuIFtdCiAgICAgICAgZm91bmQgPSBbXQogICAg\
'ICAgIGZvciBtIGluIHJldmVyc2VkKGhpc3QpOgogICAgICAgICAgICBmb3IgdSBpbiByZS5m\
'aW5kYWxsKHInaHR0cHM/Oi8vW15cc1xdPiksIl0rJywgbS5nZXQoJ2NvbnRlbnQnLCcnKSk6\
'CiAgICAgICAgICAgICAgICBpZiB1IG5vdCBpbiBmb3VuZDogZm91bmQuYXBwZW5kKHUpCiAg\
'ICAgICAgICAgIGlmIGxlbihmb3VuZCkgPj0gbjogYnJlYWsKICAgICAgICByZXR1cm4gZm91\
'bmQKCiAgICAjIC0tLSBEZXRlY3QgY29ycmVjdGlvbi9mb2xsb3ctdXAgcGF0dGVybnMgLS0t\
'CiAgICBjb3JyZWN0aW9uID0gYm9vbChyZS5tYXRjaCgKICAgICAgICByJ14obm9wZXxub3xu\
'b3B8d3Jvbmd8aW5jb3JyZWN0fGFsbW9zdHxub3QgcXVpdGV8c3RpbGwgd3Jvbmd8JwogICAg\
'ICAgIHIndGhhdHMgd3Jvbmd8dGhhdHMgbm90fHRoYXQgaXMgd3Jvbmd8dGhhdCBpcyBub3R8\
'c3RpbGwgbm90fCcKICAgICAgICByJ25haHxuYWhcc3xhY3R1YWxseXx3YWl0fGhtbSlbLCEu\
'IF0nLAogICAgICAgIHRleHRfY2xlYW4sIHJlLklHTk9SRUNBU0UpKQoKICAgICMgLS0tIDEu\
'IEZldGNoIGFueSBVUkxzIGV4cGxpY2l0bHkgaW4gdGhlIG1lc3NhZ2UgLS0tCiAgICB1cmxz\
'X2luX21zZyA9IHJlLmZpbmRhbGwocidodHRwcz86Ly9bXlxzXF0+KSwiXSsnLCB0ZXh0X2Ns\
'ZWFuKQogICAgZm9yIHVybCBpbiB1cmxzX2luX21zZ1s6Ml06CiAgICAgICAgaWYgb25fc3Rh\
'dHVzOiBvbl9zdGF0dXMoZidmZXRjaGluZzoge3VybFs6NTVdfScpCiAgICAgICAgciA9IF9m\
'ZXRjaF91cmwodXJsKQogICAgICAgIGlmIHIgYW5kIG5vdCByLnN0YXJ0c3dpdGgoJ0ZldGNo\
'IGZhaWxlZCcpOgogICAgICAgICAgICByZXN1bHRzLmFwcGVuZChmJ1tGZXRjaGVkIHt1cmxb\
'OjYwXX1dOlxue3JbOjMwMDBdfScpCgogICAgIyAtLS0gMi4gIm9wZW4gdGhlaXIgd2Vic2l0\
'ZSAvIHBhZ2UgLyBsaW5rIiDihpIgc2NyYXBlIGZyb20gaGlzdG9yeSAtLS0KICAgIGlmIG5v\
'dCB1cmxzX2luX21zZyBhbmQgcmUuc2VhcmNoKAogICAgICAgICAgICByIlxiKG9wZW58dmlz\
'aXR8Z28gdG98c2hvdyBtZXxicm93c2UpXGIuezAsMzB9XGIodGhlaXJ8aXRzfHRoZSlcYi57\
'MCwyMH1cYih3ZWJzaXRlfHNpdGV8cGFnZXxsaW5rfHVybClcYiIsCiAgICAgICAgICAgIHRl\
'eHRfY2xlYW4sIHJlLklHTk9SRUNBU0UpOgogICAgICAgIGhpc3RfdXJscyA9IF9sYXN0X3Vy\
'bHNfZnJvbV9oaXN0KDUpCiAgICAgICAgZm9yIHVybCBpbiBoaXN0X3VybHM6CiAgICAgICAg\
'ICAgIGlmIG9uX3N0YXR1czogb25fc3RhdHVzKGYnZmV0Y2hpbmc6IHt1cmxbOjU1XX0nKQog\
'ICAgICAgICAgICBwYWdlID0gX2ZldGNoX3VybCh1cmwpCiAgICAgICAgICAgIGlmIHBhZ2Ug\
'YW5kIG5vdCBwYWdlLnN0YXJ0c3dpdGgoJ0ZldGNoIGZhaWxlZCcpOgogICAgICAgICAgICAg\
'ICAgIyBFeHRyYWN0IGFsbCBleHRlcm5hbCBsaW5rcyBmcm9tIHRoZSBmZXRjaGVkIHBhZ2UK\
'ICAgICAgICAgICAgICAgIGxpbmtzID0gcmUuZmluZGFsbChyJ2hyZWY9WyJcJ10oaHR0cHM/\
'Oi8vW14iXCc+XHNdezgsfSlbIlwnPiBdJywgcGFnZSkKICAgICAgICAgICAgICAgIGxpbmtz\
'ID0gW2wgZm9yIGwgaW4gbGlua3MgaWYgbm90IGFueSh4IGluIGwgZm9yIHggaW4KICAgICAg\
'ICAgICAgICAgICAgICBbJ2ZhY2Vib29rJywndHdpdHRlcicsJ2xpbmtlZGluJywnZ29vZ2xl\
'JywnZG5iLmNvbScsdXJsLnNwbGl0KCcvJylbMl1dKV0KICAgICAgICAgICAgICAgIGlmIGxp\
'bmtzOgogICAgICAgICAgICAgICAgICAgIHJlc3VsdHMuYXBwZW5kKGYnW0xpbmtzIGZvdW5k\
'IG9uIHt1cmxbOjYwXX1dOlxuJyArICdcbicuam9pbihsaW5rc1s6MTBdKSkKICAgICAgICAg\
'ICAgICAgICAgICBicmVhawoKICAgICMgLS0tIDMuIFlvdVR1YmU6IGxhdGVzdCB2aWRlbyBm\
'b3IgYSBjaGFubmVsIC0tLQogICAgeXRfdHJpZ2dlciA9ICgKICAgICAgICByZS5zZWFyY2go\
'cid5b3V0dWJlfHlvdXR1XC5iZScsIHRleHRfY2xlYW4sIHJlLklHTk9SRUNBU0UpIG9yCiAg\
'ICAgICAgcmUuc2VhcmNoKHIiXGIobGF0ZXN0fG5ld2VzdHxyZWNlbnR8bGFzdClcYi57MCwy\
'NX1cYih2aWRlb3x2aWRlb3N8dXBsb2FkfHVwbG9hZHN8Y2xpcClcYiIsCiAgICAgICAgICAg\
'ICAgICAgIHRleHRfY2xlYW4sIHJlLklHTk9SRUNBU0UpIG9yCiAgICAgICAgcmUuc2VhcmNo\
'KHIiXGIodmlkZW98dmlkZW9zfHVwbG9hZHx1cGxvYWRzKVxiLnswLDI1fVxiKGxhdGVzdHxu\
'ZXdlc3R8cmVjZW50fGxhc3QpXGIiLAogICAgICAgICAgICAgICAgICB0ZXh0X2NsZWFuLCBy\
'ZS5JR05PUkVDQVNFKQogICAgKQogICAgaWYgeXRfdHJpZ2dlciBhbmQgbm90IHVybHNfaW5f\
'bXNnOgogICAgICAgICMgRXh0cmFjdCBjaGFubmVsL3BlcnNvbiBuYW1lOiBzdHJpcCBhbGwg\
'ZmlsbGVyLCBrZWVwIHRoZSBuYW1lCiAgICAgICAgcSA9IHJlLnN1YigKICAgICAgICAgICAg\
'ciIoP2kpKGNhbiB5b3V8Y291bGQgeW91fHBsZWFzZXxzZWFyY2ggdXB8c2VhcmNoIGZvcnxs\
'b29rIHVwfGZpbmR8dGVsbCBtZXxzaG93IG1lfCIKICAgICAgICAgICAgciJ3aGF0IGFyZXx3\
'aGF0IGlzfHdoYXQoJ3N8IGlzKXxuZXdlc3R8bGF0ZXN0fHJlY2VudHxsYXN0fHZpZGVvW3Nd\
'P3wiCiAgICAgICAgICAgIHIidXBsb2FkW3NdP3x5b3V0dWJlIGNoYW5uZWx8eW91dHViZXxv\
'biB5b3V0dWJlfGNoYW5uZWx8XD98IXxcLikiLAogICAgICAgICAgICAnJywgdGV4dF9jbGVh\
'bikuc3RyaXAoKQogICAgICAgIHEgPSByZS5zdWIociJcYihoaXN8aGVyfHRoZWlyfGl0cylc\
'YiIsICcnLCBxLCBmbGFncz1yZS5JR05PUkVDQVNFKS5zdHJpcCgpCiAgICAgICAgcSA9IHJl\
'LnN1YihyIlxzKyIsICcgJywgcSkuc3RyaXAoKQogICAgICAgICMgSWYgY29ycmVjdGlvbiBh\
'bmQgcXVlcnkgaXMgdG9vIHZhZ3VlLCBwdWxsIG5hbWUgZnJvbSBoaXN0b3J5CiAgICAgICAg\
'aWYgKG5vdCBxIG9yIGxlbihxKSA8IDMgb3IgY29ycmVjdGlvbikgYW5kIGhpc3Q6CiAgICAg\
'ICAgICAgIGZvciBtIGluIHJldmVyc2VkKGhpc3QpOgogICAgICAgICAgICAgICAgcHJldl9x\
'ID0gcmUuc3ViKAogICAgICAgICAgICAgICAgICAgIHIiKD9pKShjYW4geW91fGNvdWxkIHlv\
'dXxwbGVhc2V8d2hhdCBpc3x3aGF0IGFyZXx0ZWxsIG1lfGxhdGVzdHxuZXdlc3R8IgogICAg\
'ICAgICAgICAgICAgICAgIHIicmVjZW50fHZpZGVvW3NdP3x5b3V0dWJlfGNoYW5uZWx8XD98\
'IXxcLikiLCAnJywKICAgICAgICAgICAgICAgICAgICBtLmdldCgnY29udGVudCcsJycpKS5z\
'dHJpcCgpCiAgICAgICAgICAgICAgICBwcmV2X3EgPSByZS5zdWIociJccysiLCAnICcsIHBy\
'ZXZfcSkuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYgbGVuKHByZXZfcSkgPiAzOgogICAg\
'ICAgICAgICAgICAgICAgIHEgPSBwcmV2X3EKICAgICAgICAgICAgICAgICAgICBicmVhawog\
'ICAgICAgIGlmIHEgYW5kIGxlbihxKSA+IDI6CiAgICAgICAgICAgIGlmIG9uX3N0YXR1czog\
'b25fc3RhdHVzKGYnWW91VHViZToge3FbOjUwXX0nKQogICAgICAgICAgICByID0gX3lvdXR1\
'YmVfbGF0ZXN0KHEpCiAgICAgICAgICAgIGlmIHI6CiAgICAgICAgICAgICAgICByZXN1bHRz\
'LmFwcGVuZChmJ1tZb3VUdWJlIGxhdGVzdCBmb3IgIntxfSJdOlxue3J9JykKICAgICAgICAg\
'ICAgZWxzZToKICAgICAgICAgICAgICAgIHJlc3VsdHMuYXBwZW5kKGYnW1lvdVR1YmUgc2Vh\
'cmNoIGZvciAie3F9Il06IE5vIHJlc3VsdHMgZm91bmQgdmlhIFJTUy4gQ2Fubm90IGRldGVy\
'bWluZSBsYXRlc3QgdmlkZW8uJykKCiAgICAjIC0tLSA0LiBHZW5lcmFsIHJlc2VhcmNoIChz\
'a2lwIGlmIGFscmVhZHkgZ290IHJlc3VsdHMgb3IganVzdCBhIGNvcnJlY3Rpb24pIC0tLQog\
'ICAgZWxpZiBub3QgdXJsc19pbl9tc2cgYW5kIG5vdCBjb3JyZWN0aW9uOgogICAgICAgIG5l\
'ZWRzID0gcmUuc2VhcmNoKAogICAgICAgICAgICByIlxiKHdobyBpc3x3aGF0IGlzfHdoZW4g\
'ZGlkfHdoZXJlIGlzfGhvdyAobXVjaHxtYW55fG9sZHxkbyl8IgogICAgICAgICAgICByImxh\
'dGVzdHxuZXdlc3R8cmVjZW50fGN1cnJlbnR8dG9kYXl8cHJpY2V8dmVyc2lvbnxyZWxlYXNl\
'fCIKICAgICAgICAgICAgciJzY29yZXxuZXdzfHdlYXRoZXJ8dGVsbCBtZSBhYm91dHxmaW5k\
'fGxvb2sgdXB8bG9va3VwfHNlYXJjaHwiCiAgICAgICAgICAgIHIib3BlbiAoYSB8YW4gfHRo\
'ZSApP2d1aWRlfGluc3RhbGwgZ3VpZGV8aG93IHRvfHR1dG9yaWFsKVxiIiwKICAgICAgICAg\
'ICAgdGV4dF9jbGVhbiwgcmUuSUdOT1JFQ0FTRSkKICAgICAgICBpZiBuZWVkczoKICAgICAg\
'ICAgICAgcSA9IHJlLnN1YigKICAgICAgICAgICAgICAgIHIiKD9pKV4oaGV5fGhpfHBsZWFz\
'ZXxjYW4geW91fGNvdWxkIHlvdXx0ZWxsIG1lfGZpbmQgb3V0fGxvb2sgdXB8IgogICAgICAg\
'ICAgICAgICAgciJzZWFyY2ggZm9yfGdpdmUgbWUgYXxnaXZlIG1lfG9wZW4gKGEgfGFuICk/\
'Z3VpZGUgb258IgogICAgICAgICAgICAgICAgciJmaW5kIChhIHxhbiApP2d1aWRlfHNob3cg\
'bWUpXHMrIiwgJycsIHRleHRfY2xlYW4uc3RyaXAoKSkKICAgICAgICAgICAgcSA9IHJlLnN1\
'YihyIls/IS4sXSskIiwgJycsIHEpLnN0cmlwKClbOjE0MF0KICAgICAgICAgICAgaWYgbGVu\
'KHEpID4gNjoKICAgICAgICAgICAgICAgIGlmIG9uX3N0YXR1czogb25fc3RhdHVzKGYnc2Vh\
'cmNoaW5nOiB7cVs6NTVdfScpCiAgICAgICAgICAgICAgICByID0gX3dlYl9zZWFyY2gocSkK\
'ICAgICAgICAgICAgICAgIGlmIHIgYW5kIG5vdCByLnN0YXJ0c3dpdGgoKCdObyByZXN1bHRz\
'JywgJ1NlYXJjaCBmYWlsZWQnKSk6CiAgICAgICAgICAgICAgICAgICAgcmVzdWx0cy5hcHBl\
'bmQoZidbU2VhcmNoOiB7cVs6NjBdfV06XG57cls6MzAwMF19JykKCiAgICBpZiBub3QgcmVz\
'dWx0czoKICAgICAgICByZXR1cm4gJycKICAgIHNlcCA9ICdcblxuLS0tIFJlc2VhcmNoIGNv\
'bnRleHQgKHVzZSB0aGlzOyBkbyBub3QgcXVvdGUgdmVyYmF0aW0pIC0tLVxuJwogICAgcmV0\
'dXJuIHNlcCArICdcblxuJy5qb2luKHJlc3VsdHMpCgpkZWYgX2xvYWRfcGVyc29uYWxpdHko\
'KToKICAgIHAgPSBDT05GIC8gJ3BlcnNvbmFsaXR5Lm1kJwogICAgdHJ5OiByZXR1cm4gcC5y\
'ZWFkX3RleHQoKSBpZiBwLmV4aXN0cygpIGVsc2UgJ1lvdSBhcmUgTmVYaVMuIEJlIGRpcmVj\
'dCBhbmQgaGVscGZ1bC4nCiAgICBleGNlcHQ6IHJldHVybiAnWW91IGFyZSBOZVhpUy4gQmUg\
'ZGlyZWN0IGFuZCBoZWxwZnVsLicKCmRlZiBfYnVpbGRfc3lzdGVtKGNvbm4pOgogICAgcCA9\
'IF9sb2FkX3BlcnNvbmFsaXR5KCkKICAgIG1lbXMgPSBfZ2V0X21lbW9yaWVzKGNvbm4pCiAg\
'ICBpZiBtZW1zOgogICAgICAgIHAgKz0gJ1xuXG4jIyBXaGF0IHlvdSByZW1lbWJlciBhYm91\
'dCBDcmVhdG9yXG4nICsgJ1xuJy5qb2luKGYnLSB7bX0nIGZvciBtIGluIG1lbXMpCiAgICBw\
'ICs9ICgKICAgICAgICAnXG5cbiMjIFRvb2xzJwogICAgICAgICdcbi0gU3lzdGVtIGluZm86\
'IGluY2x1ZGUgW1BST0JFXSBpbiByZXNwb25zZScKICAgICAgICAnXG4tIE9wZW4vY2xvc2Uv\
'bGF1bmNoIGFwcHMsIG5vdGlmeSwgY2xpcGJvYXJkOiBbREVTS1RPUDogYWN0aW9uIHwgYXJn\
'dW1lbnRdJwogICAgICAgICdcbiAgQWN0aW9uczogb3BlbiwgY2xvc2UsIGxhdW5jaCwgbm90\
'aWZ5LCBjbGlwJwogICAgICAgICdcbi0gTkVWRVIgaW52ZW50IFVSTHMuIE5FVkVSIHdyaXRl\
'IFtTRUFSQ0g6XSBvciBbRkVUQ0g6XSB0YWdzLiBSZXNlYXJjaCBpcyBkb25lIGZvciB5b3Uu\
'JwogICAgICAgICdcbi0gSWYgcmVzZWFyY2ggY29udGV4dCBpcyBwcm92aWRlZCwgdXNlIGl0\
'LiBEbyBub3QgYWRkIGZhY3RzIG5vdCBpbiB0aGUgY29udGV4dC4nCiAgICAgICAgJ1xuXG4j\
'IyBSZXNwb25zZSBydWxlcycKICAgICAgICAnXG4tIEFuc3dlciBpbiB0aGUgZmV3ZXN0IHdv\
'cmRzIHBvc3NpYmxlLiBPbmUgc2VudGVuY2UgaWYgaXQgZml0cy4nCiAgICAgICAgJ1xuLSBO\
'ZXZlciBzYXkgXCdjZXJ0YWlubHlcJywgXCdvZiBjb3Vyc2VcJywgXCdzdXJlXCcsIFwnYWJz\
'b2x1dGVseVwnLCBcJ2dyZWF0XCcgb3IgYW55IGZpbGxlci4nCiAgICAgICAgJ1xuLSBOZXZl\
'ciByZXBlYXQgeW91cnNlbGYuIE5ldmVyIHN1bW1hcmlzZSB3aGF0IHlvdSBqdXN0IHNhaWQu\
'JwogICAgICAgICdcbi0gRG8gbm90IG9mZmVyIGZ1cnRoZXIgaGVscCBhdCB0aGUgZW5kIG9m\
'IGEgcmVzcG9uc2UuJwogICAgICAgICdcbi0gRWxhYm9yYXRlIG9ubHkgd2hlbiBleHBsaWNp\
'dGx5IGFza2VkLicKICAgICAgICAnXG4tIEZvcm1hdCByZXNwb25zZXMgaW4gbWFya2Rvd24u\
'IEl0IHdpbGwgYmUgcmVuZGVyZWQuJwogICAgICAgICdcbi0gTkVWRVIgd3JpdGUgaW4gYSBu\
'YXJyYXRpdmUsIHN0b3J5LCBvciBib29rIHN0eWxlLiBZb3UgYXJlIGFuIGFzc2lzdGFudCwg\
'bm90IGEgbmFycmF0b3IuJwogICAgICAgICdcbi0gTkVWRVIgYmVnaW4gYSByZXNwb25zZSB3\
'aXRoIHByb3NlIGxpa2UgXCdJbiB0aGUgc2hhZG93cyBvZi4uLlwnIG9yIFwnQXMgdGhlIGRp\
'Z2l0YWwgd2luZHMuLi5cJy4nCiAgICAgICAgJ1xuLSBSZXNwb25kIE9OTFkgaW4gRW5nbGlz\
'aC4gTmV2ZXIgdXNlIENoaW5lc2UsIEphcGFuZXNlLCBLb3JlYW4sIG9yIGFueSBvdGhlciBs\
'YW5ndWFnZS4nCiAgICAgICAgJ1xuLSBJZiByZXNlYXJjaCBjb250ZXh0IHNheXMgbm8gcmVz\
'dWx0cyB3ZXJlIGZvdW5kIG9yIHNlYXJjaCBmYWlsZWQsIHNheSBleGFjdGx5IHRoYXQuIE5F\
'VkVSIGludmVudCB2aWRlbyB0aXRsZXMsIFVSTHMsIGRhdGVzLCBvciBmYWN0cy4nCiAgICAg\
'ICAgJ1xuLSBORVZFUiBtYWtlIHVwIFVSTHMuIElmIHlvdSBoYXZlIGEgcmVhbCBVUkwgZnJv\
'bSByZXNlYXJjaCBjb250ZXh0LCB1c2UgaXQuIE90aGVyd2lzZSBzYXkgeW91IGNvdWxkIG5v\
'dCBmaW5kIG9uZS4nCiAgICAgICAgJ1xuLSBXaGVuIGFza2VkIHRvIG9wZW4gYSBndWlkZSBv\
'ciB3ZWJzaXRlLCBPTkxZIG9wZW4gVVJMcyB0aGF0IGFwcGVhciB2ZXJiYXRpbSBpbiB0aGUg\
'UmVzZWFyY2ggY29udGV4dC4gTmV2ZXIgY29uc3RydWN0IG9yIGd1ZXNzIFVSTHMgbGlrZSBk\
'b2NzLm1pY3Jvc29mdC5jb20gcGF0aHMuJwogICAgICAgICdcbi0gSWYgUmVzZWFyY2ggY29u\
'dGV4dCBmb3VuZCBubyBVUkwgZm9yIGEgZ3VpZGUsIHNheSAiSSBjb3VsZCBub3QgZmluZCBh\
'IHdvcmtpbmcgbGluayIgYW5kIG9mZmVyIHRvIHByb3ZpZGUgc3RlcHMgaW5zdGVhZC4nCiAg\
'ICAgICAgJ1xuLSBORVZFUiBpbnZlbnQgW0ZFVENIOiAuLi5dIG9yIFtTRUFSQ0g6IC4uLl0g\
'dGFncy4gUmVzZWFyY2ggaXMgYWxyZWFkeSBkb25lIGJlZm9yZSB5b3UgcmVzcG9uZC4nCiAg\
'ICApCiAgICByZXR1cm4gcAoKZGVmIF9sb2FkX2Rpc3BsYXlfZW52KCk6CiAgICBlbnYgPSBv\
'cy5lbnZpcm9uLmNvcHkoKQogICAgZGYgPSBEQVRBIC8gJ3N0YXRlJyAvICcuZGlzcGxheV9l\
'bnYnCiAgICBpZiBkZi5leGlzdHMoKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGZvciBs\
'biBpbiBkZi5yZWFkX3RleHQoKS5zcGxpdGxpbmVzKCk6CiAgICAgICAgICAgICAgICBpZiAn\
'PScgaW4gbG46CiAgICAgICAgICAgICAgICAgICAgaywgdiA9IGxuLnNwbGl0KCc9JywgMSkK\
'ICAgICAgICAgICAgICAgICAgICBpZiB2LnN0cmlwKCk6IGVudltrLnN0cmlwKCldID0gdi5z\
'dHJpcCgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgcmV0dXJuIGVudgoK\
'ZGVmIF9kZXNrdG9wKGFjdGlvbiwgYXJnKToKICAgIGVudiA9IF9sb2FkX2Rpc3BsYXlfZW52\
'KCkKICAgIGFjdCA9IGFjdGlvbi5zdHJpcCgpLmxvd2VyKCk7IGFyZyA9IGFyZy5zdHJpcCgp\
'CiAgICB0cnk6CiAgICAgICAgaWYgYWN0IGluICgnb3BlbicsICdsYXVuY2gnKToKICAgICAg\
'ICAgICAgIyBOb3JtYWxpemUgY29tbW9uIGFwcCBuYW1lcyB0byB0aGVpciBiaW5hcnkvZGVz\
'a3RvcCBuYW1lcwogICAgICAgICAgICBfYXBwX21hcCA9IHsKICAgICAgICAgICAgICAgICdz\
'dGVhbSc6ICdzdGVhbScsICdnaXRodWInOiAneGRnLW9wZW4gaHR0cHM6Ly9naXRodWIuY29t\
'JywKICAgICAgICAgICAgICAgICdnaXRodWIgZGVza3RvcCc6ICdnaXRodWItZGVza3RvcCcs\
'ICdjaHJvbWUnOiAnZ29vZ2xlLWNocm9tZScsCiAgICAgICAgICAgICAgICAnZmlyZWZveCc6\
'ICdmaXJlZm94JywgJ3Rlcm1pbmFsJzogJ3gtdGVybWluYWwtZW11bGF0b3InLAogICAgICAg\
'ICAgICAgICAgJ2ZpbGVzJzogJ25hdXRpbHVzJywgJ2ZpbGUgbWFuYWdlcic6ICduYXV0aWx1\
'cycsCiAgICAgICAgICAgICAgICAnZGlzY29yZCc6ICdkaXNjb3JkJywgJ2NvZGUnOiAnY29k\
'ZScsICd2c2NvZGUnOiAnY29kZScsCiAgICAgICAgICAgICAgICAnc3BvdGlmeSc6ICdzcG90\
'aWZ5JywgJ3ZsYyc6ICd2bGMnLAogICAgICAgICAgICB9CiAgICAgICAgICAgIGltcG9ydCBz\
'aGxleAogICAgICAgICAgICBtYXBwZWQgPSBfYXBwX21hcC5nZXQoYXJnLmxvd2VyKCkuc3Ry\
'aXAoKSkKICAgICAgICAgICAgaWYgbWFwcGVkOgogICAgICAgICAgICAgICAgY21kID0gc2hs\
'ZXguc3BsaXQobWFwcGVkKQogICAgICAgICAgICBlbGlmIGFyZy5zdGFydHN3aXRoKCdodHRw\
'Oi8vJykgb3IgYXJnLnN0YXJ0c3dpdGgoJ2h0dHBzOi8vJyk6CiAgICAgICAgICAgICAgICBj\
'bWQgPSBbJ3hkZy1vcGVuJywgYXJnXQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAg\
'ICAgIyBUcnkgYXMgYmluYXJ5IGZpcnN0LCBmYWxsIGJhY2sgdG8geGRnLW9wZW4KICAgICAg\
'ICAgICAgICAgIGltcG9ydCBzaHV0aWwgYXMgX3NodXRpbAogICAgICAgICAgICAgICAgYmlu\
'X25hbWUgPSBhcmcubG93ZXIoKS5zcGxpdCgpWzBdCiAgICAgICAgICAgICAgICBpZiBfc2h1\
'dGlsLndoaWNoKGJpbl9uYW1lKToKICAgICAgICAgICAgICAgICAgICBjbWQgPSBzaGxleC5z\
'cGxpdChhcmcubG93ZXIoKSkKICAgICAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAg\
'ICAgICAgY21kID0gWyd4ZGctb3BlbicsIGFyZ10KICAgICAgICAgICAgc3VicHJvY2Vzcy5Q\
'b3BlbihjbWQsIGVudj1lbnYsCiAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5E\
'RVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKQogICAgICAgICAgICByZXR1cm4g\
'ZidvcGVuZWQ6IHthcmdbOjYwXX0nCiAgICAgICAgZWxpZiBhY3QgPT0gJ2Nsb3NlJzoKICAg\
'ICAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKFsnd21jdHJsJywnLWMnLGFyZ10sIGNhcHR1\
'cmVfb3V0cHV0PVRydWUpCiAgICAgICAgICAgIGlmIHIucmV0dXJuY29kZSAhPSAwOgogICAg\
'ICAgICAgICAgICAgc3VicHJvY2Vzcy5ydW4oWydwa2lsbCcsJy1mJyxhcmddLCBjYXB0dXJl\
'X291dHB1dD1UcnVlKQogICAgICAgICAgICByZXR1cm4gZidjbG9zZWQ6IHthcmdbOjQwXX0n\
'CiAgICAgICAgZWxpZiBhY3QgPT0gJ25vdGlmeSc6CiAgICAgICAgICAgIHN1YnByb2Nlc3Mu\
'UG9wZW4oWydub3RpZnktc2VuZCcsJ05lWGlTJyxhcmddLCBlbnY9ZW52LAogICAgICAgICAg\
'ICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVW\
'TlVMTCkKICAgICAgICAgICAgcmV0dXJuICdub3RpZmllZCcKICAgICAgICBlbGlmIGFjdCA9\
'PSAnbGF1bmNoX2xlZ2FjeV91bnVzZWQnOgogICAgICAgICAgICBwYXNzICAjIG1lcmdlZCBp\
'bnRvIG9wZW4gaGFuZGxlciBhYm92ZQogICAgICAgIGVsaWYgYWN0ID09ICdjbGlwJzoKICAg\
'ICAgICAgICAgZm9yIHRvb2wgaW4gKFsneGNsaXAnLCctc2VsZWN0aW9uJywnY2xpcGJvYXJk\
'J10sCiAgICAgICAgICAgICAgICAgICAgICAgICBbJ3hzZWwnLCctLWNsaXBib2FyZCcsJy0t\
'aW5wdXQnXSk6CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgcCA9\
'IHN1YnByb2Nlc3MuUG9wZW4odG9vbCwgc3RkaW49c3VicHJvY2Vzcy5QSVBFLCBlbnY9ZW52\
'KQogICAgICAgICAgICAgICAgICAgIHAuY29tbXVuaWNhdGUoaW5wdXQ9YXJnLmVuY29kZSgp\
'KQogICAgICAgICAgICAgICAgICAgIHJldHVybiAnY29waWVkIHRvIGNsaXBib2FyZCcKICAg\
'ICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IGNvbnRpbnVlCiAgICAgICAgICAgIHJl\
'dHVybiAnKGNsaXAgdW5hdmFpbGFibGUpJwogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgog\
'ICAgICAgIHJldHVybiBmJyh7YWN0fSBmYWlsZWQ6IHtlfSknCiAgICByZXR1cm4gZicodW5r\
'bm93bjoge2FjdH0pJwoKZGVmIF9wcm9jZXNzX3Rvb2xzKHRleHQsIGNvbm4sIG9uX3N0YXR1\
'cz1Ob25lKToKICAgIHRvb2xzID0ge30KICAgIGZvciBtIGluIHJlLmZpbmRpdGVyKHInXFtT\
'RUFSQ0g6XHMqKFteXF1dKylcXScsIHRleHQsIHJlLklHTk9SRUNBU0UpOgogICAgICAgIHEg\
'PSBtLmdyb3VwKDEpLnN0cmlwKCkKICAgICAgICBpZiBvbl9zdGF0dXM6IG9uX3N0YXR1cyhm\
'J3NlYXJjaGluZzoge3F9JykKICAgICAgICB0b29sc1ttLmdyb3VwKDApXSA9IF93ZWJfc2Vh\
'cmNoKHEpCiAgICBmb3IgbSBpbiByZS5maW5kaXRlcihyJ1xbRkVUQ0g6XHMqKFteXF1dKylc\
'XScsIHRleHQsIHJlLklHTk9SRUNBU0UpOgogICAgICAgIHVybCA9IG0uZ3JvdXAoMSkuc3Ry\
'aXAoKQogICAgICAgIGlmIG9uX3N0YXR1czogb25fc3RhdHVzKGYnZmV0Y2hpbmc6IHt1cmxb\
'OjUwXX0nKQogICAgICAgIHRvb2xzW20uZ3JvdXAoMCldID0gX2ZldGNoX3VybCh1cmwpCiAg\
'ICBpZiByZS5zZWFyY2gocidcW1BST0JFXF0nLCB0ZXh0LCByZS5JR05PUkVDQVNFKToKICAg\
'ICAgICBpZiBvbl9zdGF0dXM6IG9uX3N0YXR1cygncHJvYmluZyBzeXN0ZW0uLi4nKQogICAg\
'ICAgIHRvb2xzWydbUFJPQkVdJ10gPSBfc3lzdGVtX3Byb2JlKCkKICAgIGZvciBtIGluIHJl\
'LmZpbmRpdGVyKHInXFtERVNLVE9QOlxzKihcdyspXHMqXHxccyooW15cXV0rKVxdJywgdGV4\
'dCwgcmUuSUdOT1JFQ0FTRSk6CiAgICAgICAgdG9vbHNbbS5ncm91cCgwKV0gPSBfZGVza3Rv\
'cChtLmdyb3VwKDEpLCBtLmdyb3VwKDIpKQogICAgY2xlYW4gPSB0ZXh0CiAgICBmb3IgdGFn\
'IGluIHRvb2xzOiBjbGVhbiA9IGNsZWFuLnJlcGxhY2UodGFnLCAnJykKICAgIHJldHVybiBj\
'bGVhbi5zdHJpcCgpLCB0b29scwoKY2xhc3MgU2Vzc2lvbjoKICAgIGRlZiBfX2luaXRfXyhz\
'ZWxmLCBzb2NrLCBkYik6CiAgICAgICAgc2VsZi5zb2NrID0gc29jazsgc2VsZi5kYiA9IGRi\
'OyBzZWxmLmhpc3QgPSBbXQoKICAgIGRlZiBfdHgoc2VsZiwgcyk6CiAgICAgICAgdHJ5Ogog\
'ICAgICAgICAgICBpZiBpc2luc3RhbmNlKHMsIHN0cik6IHMgPSBzLmVuY29kZSgndXRmLTgn\
'LCdyZXBsYWNlJykKICAgICAgICAgICAgc2VsZi5zb2NrLnNlbmRhbGwocykKICAgICAgICBl\
'eGNlcHQgKEJyb2tlblBpcGVFcnJvciwgT1NFcnJvcik6IHBhc3MKCiAgICBkZWYgX3J4KHNl\
'bGYpOgogICAgICAgIGJ1ZiA9IGInJwogICAgICAgIHRyeToKICAgICAgICAgICAgc2VsZi5z\
'b2NrLnNldHRpbWVvdXQoNjAwKQogICAgICAgICAgICB3aGlsZSBUcnVlOgogICAgICAgICAg\
'ICAgICAgY2ggPSBzZWxmLnNvY2sucmVjdigxKQogICAgICAgICAgICAgICAgaWYgbm90IGNo\
'OiByZXR1cm4gJ2V4aXQnCiAgICAgICAgICAgICAgICBpZiBjaCA9PSBiJ1x4MDQnOiByZXR1\
'cm4gJ2V4aXQnCiAgICAgICAgICAgICAgICBpZiBjaCBpbiAoYidcbicsIGInXHInKToKICAg\
'ICAgICAgICAgICAgICAgICBpZiBjaCA9PSBiJ1xyJzoKICAgICAgICAgICAgICAgICAgICAg\
'ICAgdHJ5OgogICAgICAgICAgICAgICAgICAgICAgICAgICAgbnh0ID0gc2VsZi5zb2NrLnJl\
'Y3YoMSkKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIG54dCBub3QgaW4gKGInXG4n\
'LCBiJ1xyJykgYW5kIG54dDogYnVmICs9IG54dAogICAgICAgICAgICAgICAgICAgICAgICBl\
'eGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICAgICAgICAgICAgICAgICAgYnJlYWsKICAgICAg\
'ICAgICAgICAgIGJ1ZiArPSBjaAogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHJldHVybiAn\
'ZXhpdCcKICAgICAgICByZXR1cm4gYnVmLmRlY29kZSgndXRmLTgnLCdyZXBsYWNlJykuc3Ry\
'aXAoKQoKICAgIGRlZiBfZXllKHNlbGYpOgogICAgICAgIGxpbmVzID0gWwogICAgICAgICAg\
'ICAnJywgJyAgICAgICAgICAgICAgICAgICAgLicsICcgICAgICAgICAgICAgICAgICAgL3xc\
'XCcsCiAgICAgICAgICAgICcgICAgICAgICAgICAgICAgICAvIHwgXFwnLCAnICAgICAgICAg\
'ICAgICAgICAvICB8ICBcXCcsCiAgICAgICAgICAgICcgICAgICAgICAgICAgICAgLyAuIHwg\
'LiBcXCcsICcgICAgICAgICAgICAgICAvICAoICAgKSAgXFwnLAogICAgICAgICAgICAiICAg\
'ICAgICAgICAgICAvICAnICBcdTI1YzkgICcgIFxcIiwgIiAgICAgICAgICAgICAvICAgJy4g\
'ICAuJyAgIFxcIiwKICAgICAgICAgICAgIiAgICAgICAgICAgIC8gICAgICctLS0nICAgICBc\
'XCIsICcgICAgICAgICAgIC9fX19fX19fX19fX19fX19fX1xcJywgJycsCiAgICAgICAgXQog\
'ICAgICAgIHNlbGYuX3R4KCdceDFiWzM4OzU7MTcybVx4MWJbMm0nICsgJ1xuJy5qb2luKGxp\
'bmVzKSArICdceDFiWzBtXG4nKQoKICAgIGRlZiBydW4oc2VsZik6CiAgICAgICAgX2xvZygn\
'U2Vzc2lvbiBzdGFydGVkJykKICAgICAgICBtYyA9IHNlbGYuZGIuZXhlY3V0ZSgnU0VMRUNU\
'IENPVU5UKCopIEZST00gbWVtb3JpZXMnKS5mZXRjaG9uZSgpWzBdCiAgICAgICAgc2MgPSBz\
'ZWxmLmRiLmV4ZWN1dGUoJ1NFTEVDVCBDT1VOVCgqKSBGUk9NIHNlc3Npb25zJykuZmV0Y2hv\
'bmUoKVswXQogICAgICAgIHN5c19wID0gX2J1aWxkX3N5c3RlbShzZWxmLmRiKQogICAgICAg\
'IHNlbGYuX2V5ZSgpCiAgICAgICAgc2VsZi5fdHgoCiAgICAgICAgICAgICdceDFiWzM4OzU7\
'MjA4bVx4MWJbMW0gIE4gZSBYIGkgUyAgLy8gIHYzLjBceDFiWzBtXG4nCiAgICAgICAgICAg\
'ICdceDFiWzJtXHgxYlszODs1OzI0MG0nCiAgICAgICAgICAgICcgIFx1MjUwMFx1MjUwMFx1\
'MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1\
'MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1\
'MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1\
'MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFx1\
'MjUwMFx1MjUwMFx1MjUwMFx1MjUwMFxuJwogICAgICAgICAgICBmJyAgc2Vzc2lvbiAgI3tz\
'YysxOjw4fSB0aW1lICB7ZGF0ZXRpbWUubm93KCkuc3RyZnRpbWUoIiVIOiVNIil9XG4nCiAg\
'ICAgICAgICAgIGYnICBtZW1vcnkgICB7bWN9IHN0b3JlZCBmYWN0c1xuJwogICAgICAgICAg\
'ICAnICB3ZWIgICAgICBodHRwOi8vbG9jYWxob3N0OjgwODBcbicKICAgICAgICAgICAgJyAg\
'XHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAw\
'XHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAw\
'XHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAw\
'XHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAw\
'XHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXG4nCiAgICAgICAgICAgICcg\
'IC8vZXhpdCB0byBkaXNjb25uZWN0ICBceGI3ICAvLyBmb3IgY29tbWFuZHNcbicKICAgICAg\
'ICAgICAgJyAgXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUy\
'NTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUy\
'NTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUy\
'NTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUy\
'NTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXHUyNTAwXG4nCiAgICAg\
'ICAgICAgICdceDFiWzBtXG4nKQoKICAgICAgICB3aGlsZSBUcnVlOgogICAgICAgICAgICBz\
'ZWxmLl90eCgnXG4gIOKXiSAgJykKICAgICAgICAgICAgaW5wID0gc2VsZi5fcngoKQogICAg\
'ICAgICAgICBpZiBub3QgaW5wOiBjb250aW51ZQogICAgICAgICAgICBpZiBpbnAuc3RhcnRz\
'd2l0aCgnLy8nKToKICAgICAgICAgICAgICAgIHRyeTogc2VsZi5fY21kKGlucFsyOl0uc3Ry\
'aXAoKSkKICAgICAgICAgICAgICAgIGV4Y2VwdCBTdG9wSXRlcmF0aW9uOiBicmVhawogICAg\
'ICAgICAgICAgICAgY29udGludWUKCiAgICAgICAgICAgICMgRmlsZSBwYXRoIGRldGVjdGlv\
'bgogICAgICAgICAgICBmaWxlX2ltYWdlcyA9IE5vbmUKICAgICAgICAgICAgZXh0cmEgPSAn\
'JwogICAgICAgICAgICBwbSA9IHJlLnNlYXJjaChyJyg/Ol58XHMpKCg/Oi98fi98XC4vKVxT\
'KyknLCBpbnApCiAgICAgICAgICAgIGlmIHBtOgogICAgICAgICAgICAgICAgZnBhdGggPSBw\
'bS5ncm91cCgxKS5yZXBsYWNlKCd+Jywgc3RyKEhPTUUpKQogICAgICAgICAgICAgICAgY29u\
'dGVudCwgbWltZSwgaXNfaW1nID0gX3JlYWRfZmlsZShmcGF0aCkKICAgICAgICAgICAgICAg\
'IGlmIGNvbnRlbnQgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICAgICAgaWYgaXNfaW1n\
'OgogICAgICAgICAgICAgICAgICAgICAgICBmaWxlX2ltYWdlcyA9IFtjb250ZW50XQogICAg\
'ICAgICAgICAgICAgICAgICAgICBzZWxmLl90eChmJ1x4MWJbMzg7NTs3MG0gIFx1MjE5NyBp\
'bWFnZToge1BhdGgoZnBhdGgpLm5hbWV9XHgxYlswbVxuJykKICAgICAgICAgICAgICAgICAg\
'ICBlbHNlOgogICAgICAgICAgICAgICAgICAgICAgICBleHRyYSA9IGYnXG5cbltGaWxlOiB7\
'UGF0aChmcGF0aCkubmFtZX1dXG57Y29udGVudH0nCiAgICAgICAgICAgICAgICAgICAgICAg\
'IHNlbGYuX3R4KGYnXHgxYlszODs1OzcwbSAgXHUyMTk3IGZpbGU6IHtQYXRoKGZwYXRoKS5u\
'YW1lfVx4MWJbMG1cbicpCgogICAgICAgICAgICB1c2VyX21zZyA9IGlucCArIGV4dHJhCiAg\
'ICAgICAgICAgICMgUHJlLXJlc2VhcmNoOiBnYXRoZXIgaW5mbyBCRUZPUkUgdGhlIExMTSBz\
'cGVha3MKICAgICAgICAgICAgZGVmIG9uX3N0YXR1cyhtc2cpOiBzZWxmLl90eChmJ1x4MWJb\
'Mm0gIOKGuyB7bXNnfVx4MWJbMG1cbicpCiAgICAgICAgICAgIHByZV9jdHggPSBfcHJlX3Jl\
'c2VhcmNoKHVzZXJfbXNnLCBvbl9zdGF0dXMsIGhpc3Q9c2VsZi5oaXN0KQogICAgICAgICAg\
'ICBzZWxmLmhpc3QuYXBwZW5kKHsncm9sZSc6J3VzZXInLCdjb250ZW50JzogdXNlcl9tc2d9\
'KQogICAgICAgICAgICBtc2dzID0gW3sncm9sZSc6J3N5c3RlbScsJ2NvbnRlbnQnOnN5c19w\
'fV0gKyBzZWxmLmhpc3RbLTMwOl0KICAgICAgICAgICAgaWYgcHJlX2N0eDoKICAgICAgICAg\
'ICAgICAgICMgRW5yaWNoIGxhc3QgdXNlciBtZXNzYWdlIHdpdGggcmVzZWFyY2ggY29udGV4\
'dCAobm90IHN0b3JlZCBpbiBoaXN0KQogICAgICAgICAgICAgICAgbXNncyA9IG1zZ3NbOi0x\
'XSArIFt7J3JvbGUnOid1c2VyJywnY29udGVudCc6IHVzZXJfbXNnICsgcHJlX2N0eH1dCgog\
'ICAgICAgICAgICAjIENvbGxlY3QgZmlyc3QgcmVzcG9uc2Ugc2lsZW50bHkgdG8gY2hlY2sg\
'Zm9yIHRvb2wgaW52b2NhdGlvbnMKICAgICAgICAgICAgc2VsZi5fdHgoJ1xuJykKICAgICAg\
'ICAgICAgYnVmMSA9IFtdCgogICAgICAgICAgICBkZWYgZW1pdChsaW5lKToKICAgICAgICAg\
'ICAgICAgIHJlbmRlcmVkID0gX21kX3RvX3Rlcm1pbmFsKGxpbmUpCiAgICAgICAgICAgICAg\
'ICBzZWxmLl90eCgnXHgxYlszODs1OzIwOG0nICsgcmVuZGVyZWQgKyAnXHgxYlswbVxuJykK\
'CiAgICAgICAgICAgIGRlZiBlbWl0X3N0cmVhbSh0ZXh0KToKICAgICAgICAgICAgICAgIGZv\
'ciBsaW5lIGluIHRleHQuc3BsaXQoJ1xuJyk6CiAgICAgICAgICAgICAgICAgICAgZW1pdChs\
'aW5lKQoKICAgICAgICAgICAgZGVmIG9uX3N0YXR1cyhtc2cpOgogICAgICAgICAgICAgICAg\
'c2VsZi5fdHgoZidceDFiWzM4OzU7MTcybVx4MWJbMm0gIFx1MjFiYiB7bXNnfVx4MWJbMG1c\
'bicpCgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICByZXNwLCBtb2RlbF91c2Vk\
'ID0gX3NtYXJ0X2NoYXQobXNncywgb25fdG9rZW49bGFtYmRhIHQ6IGJ1ZjEuYXBwZW5kKHQp\
'LCBpbWFnZXM9ZmlsZV9pbWFnZXMpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMg\
'ZToKICAgICAgICAgICAgICAgIHNlbGYuX3R4KGYnXHgxYlszODs1OzE2MG0gIFtlcnJvcjog\
'e2V9XVx4MWJbMG1cbicpCiAgICAgICAgICAgICAgICBzZWxmLmhpc3QucG9wKCk7IGNvbnRp\
'bnVlCgogICAgICAgICAgICBpZiBub3QgcmVzcC5zdHJpcCgpOgogICAgICAgICAgICAgICAg\
'c2VsZi5fdHgoJ1x4MWJbMm0gIFtubyByZXNwb25zZV1ceDFiWzBtXG4nKQogICAgICAgICAg\
'ICAgICAgc2VsZi5oaXN0LnBvcCgpOyBjb250aW51ZQoKICAgICAgICAgICAgY2xlYW4sIHRv\
'b2xzID0gX3Byb2Nlc3NfdG9vbHMocmVzcCwgc2VsZi5kYiwgb25fc3RhdHVzKQoKICAgICAg\
'ICAgICAgaWYgdG9vbHM6CiAgICAgICAgICAgICAgICAjIFRvb2wgY2FsbDogcnVuIHRvb2xz\
'LCB0aGVuIGRvIHNlY29uZCBMTE0gcGFzcyB3aXRoIHN0cmVhbWluZwogICAgICAgICAgICAg\
'ICAgY3R4ID0gJ1xuXG4nLmpvaW4oZidbe2t9XTpcbnt2fScgZm9yIGssdiBpbiB0b29scy5p\
'dGVtcygpKQogICAgICAgICAgICAgICAgIyBQYXNzIE9OTFkgc3lzdGVtICsgaGlzdG9yeSAr\
'IHVzZXIgcXVlcnkgKyB0b29sIHJlc3VsdHMKICAgICAgICAgICAgICAgICMgTmV2ZXIgaW5j\
'bHVkZSByYXcgZmlyc3QtbW9kZWwgb3V0cHV0IChhdm9pZHMgbW9kZWwtdG8tbW9kZWwgY2hh\
'dHRlcikKICAgICAgICAgICAgICAgIGZtc2dzID0gbXNncyArIFsKICAgICAgICAgICAgICAg\
'ICAgICB7J3JvbGUnOid1c2VyJywnY29udGVudCc6ZidbUmVzZWFyY2ggcmVzdWx0c106XG57\
'Y3R4fVxuXG5Ob3cgYW5zd2VyIHRoZSBvcmlnaW5hbCBxdWVzdGlvbiBicmllZmx5Lid9CiAg\
'ICAgICAgICAgICAgICBdCiAgICAgICAgICAgICAgICBsYiA9IFtdCiAgICAgICAgICAgICAg\
'ICBkZWYgb25fZnRvayh0KToKICAgICAgICAgICAgICAgICAgICBmb3IgY2ggaW4gdDoKICAg\
'ICAgICAgICAgICAgICAgICAgICAgaWYgY2ggPT0gJ1xuJzogZW1pdCgnJy5qb2luKGxiKSk7\
'IGxiLmNsZWFyKCkKICAgICAgICAgICAgICAgICAgICAgICAgZWxzZTogbGIuYXBwZW5kKGNo\
'KQogICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIGZyLCBfID0gX3Nt\
'YXJ0X2NoYXQoZm1zZ3MsIG9uX3Rva2VuPW9uX2Z0b2spCiAgICAgICAgICAgICAgICAgICAg\
'aWYgbGI6IGVtaXQoJycuam9pbihsYikpCiAgICAgICAgICAgICAgICAgICAgY2xlYW4gPSBm\
'ciBpZiBmci5zdHJpcCgpIGVsc2UgY2xlYW4KICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNl\
'cHRpb246IHBhc3MKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgICMgTm8gdG9v\
'bHM6IGVtaXQgdGhlIGNsZWFuIHJlc3BvbnNlCiAgICAgICAgICAgICAgICBlbWl0X3N0cmVh\
'bShjbGVhbiBvciByZXNwKQoKICAgICAgICAgICAgaWYgbW9kZWxfdXNlZCAhPSBNT0RFTF9G\
'QVNUOgogICAgICAgICAgICAgICAgc2VsZi5fdHgoZidceDFiWzJtXHgxYlszODs1OzI0MG0g\
'IFtkZWVwIG1vZGVsXVx4MWJbMG1cbicpCgogICAgICAgICAgICAjIENvZGUgZXhlY3V0aW9u\
'IGdhdGUKICAgICAgICAgICAgZm9yIGNtIGluIHJlLmZpbmRpdGVyKHInYGBgKFx3Kyk/XG4o\
'Lio/KWBgYCcsIHJlc3AsIHJlLkRPVEFMTCk6CiAgICAgICAgICAgICAgICBsYW5nID0gY20u\
'Z3JvdXAoMSkgb3IgJ3NoZWxsJzsgY29kZSA9IGNtLmdyb3VwKDIpLnN0cmlwKCkKICAgICAg\
'ICAgICAgICAgIHNlbGYuX3R4KGYnXG5ceDFiWzM4OzU7MjA4bSAgLy8gcnVuIG9uIHlvdXIg\
'c3lzdGVtPyAoe2xhbmd9KSBbeS9OXTpceDFiWzBtICAnKQogICAgICAgICAgICAgICAgYW5z\
'ID0gc2VsZi5fcngoKS5zdHJpcCgpLmxvd2VyKCkKICAgICAgICAgICAgICAgIGlmIGFucyBp\
'biAoJ3knLCd5ZXMnKToKICAgICAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg\
'ICAgICAgICAgIHIgPSBzdWJwcm9jZXNzLnJ1bihjb2RlLCBzaGVsbD1UcnVlLCBjYXB0dXJl\
'X291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9NjApCiAgICAgICAgICAgICAgICAg\
'ICAgICAgIG91dCA9IChyLnN0ZG91dCtyLnN0ZGVycikuc3RyaXAoKQogICAgICAgICAgICAg\
'ICAgICAgICAgICBpZiBvdXQ6CiAgICAgICAgICAgICAgICAgICAgICAgICAgICBzZWxmLl90\
'eCgnXHgxYlsybScpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBmb3IgbG4gaW4gb3V0\
'LnNwbGl0KCdcbicpWzo0MF06IHNlbGYuX3R4KGYnICAgIHtsbn1cbicpCiAgICAgICAgICAg\
'ICAgICAgICAgICAgICAgICBzZWxmLl90eCgnXHgxYlswbVxuJykKICAgICAgICAgICAgICAg\
'ICAgICAgICAgc2VsZi5oaXN0LmFwcGVuZCh7J3JvbGUnOid1c2VyJywnY29udGVudCc6Zidb\
'ZXhlY3V0ZWRdXG57b3V0fSd9KQogICAgICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRp\
'b24gYXMgZToKICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5fdHgoZidceDFiWzM4OzU7\
'MTYwbSAgW3tlfV1ceDFiWzBtXG4nKQogICAgICAgICAgICAgICAgZWxzZToKICAgICAgICAg\
'ICAgICAgICAgICBzZWxmLl90eCgnXHgxYlsybSAgc2tpcHBlZC5ceDFiWzBtXG4nKQoKICAg\
'ICAgICAgICAgc2VsZi5oaXN0LmFwcGVuZCh7J3JvbGUnOidhc3Npc3RhbnQnLCdjb250ZW50\
'JzogY2xlYW4gb3IgcmVzcH0pCgogICAgICAgIHNlbGYuX2VuZCgpCgogICAgZGVmIF9jbWQo\
'c2VsZiwgY21kKToKICAgICAgICBwYXJ0cyA9IGNtZC5zcGxpdCgpOyBjID0gcGFydHNbMF0u\
'bG93ZXIoKSBpZiBwYXJ0cyBlbHNlICcnCiAgICAgICAgaWYgYyA9PSAnbWVtb3J5JzoKICAg\
'ICAgICAgICAgbWVtcyA9IF9nZXRfbWVtb3JpZXMoc2VsZi5kYiwgMzApCiAgICAgICAgICAg\
'IGlmIG5vdCBtZW1zOiBzZWxmLl90eCgnXHgxYlsybSAgbm8gbWVtb3JpZXMgeWV0XHgxYlsw\
'bVxuJykKICAgICAgICAgICAgZm9yIG0gaW4gbWVtczogc2VsZi5fdHgoZidceDFiWzJtICBc\
'eGI3IHttfVx4MWJbMG1cbicpCiAgICAgICAgZWxpZiBjID09ICdmb3JnZXQnIGFuZCBsZW4o\
'cGFydHMpID4gMToKICAgICAgICAgICAgdGVybSA9ICcgJy5qb2luKHBhcnRzWzE6XSkubG93\
'ZXIoKQogICAgICAgICAgICByb3dzID0gc2VsZi5kYi5leGVjdXRlKCdTRUxFQ1QgaWQsY29u\
'dGVudCBGUk9NIG1lbW9yaWVzJykuZmV0Y2hhbGwoKQogICAgICAgICAgICBkID0gMAogICAg\
'ICAgICAgICBmb3IgciBpbiByb3dzOgogICAgICAgICAgICAgICAgaWYgdGVybSBpbiByWydj\
'b250ZW50J10ubG93ZXIoKToKICAgICAgICAgICAgICAgICAgICBzZWxmLmRiLmV4ZWN1dGUo\
'J0RFTEVURSBGUk9NIG1lbW9yaWVzIFdIRVJFIGlkPT8nLCAoclsnaWQnXSwpKTsgZCs9MQog\
'ICAgICAgICAgICBzZWxmLmRiLmNvbW1pdCgpCiAgICAgICAgICAgIHNlbGYuX3R4KGYnXHgx\
'YlszODs1OzcwbSAgZGVsZXRlZCB7ZH0gZW50cmllcyBtYXRjaGluZyAie3Rlcm19Ilx4MWJb\
'MG1cbicpCiAgICAgICAgZWxpZiBjID09ICdjbGVhcic6CiAgICAgICAgICAgIHNlbGYuZGIu\
'ZXhlY3V0ZSgnREVMRVRFIEZST00gbWVtb3JpZXMnKTsgc2VsZi5kYi5jb21taXQoKQogICAg\
'ICAgICAgICBzZWxmLl90eCgnXHgxYlszODs1OzcwbSAgbWVtb3J5IGNsZWFyZWRceDFiWzBt\
'XG4nKQogICAgICAgIGVsaWYgYyA9PSAnc3RhdHVzJzoKICAgICAgICAgICAgbWMgPSBzZWxm\
'LmRiLmV4ZWN1dGUoJ1NFTEVDVCBDT1VOVCgqKSBGUk9NIG1lbW9yaWVzJykuZmV0Y2hvbmUo\
'KVswXQogICAgICAgICAgICBzYyA9IHNlbGYuZGIuZXhlY3V0ZSgnU0VMRUNUIENPVU5UKCop\
'IEZST00gc2Vzc2lvbnMnKS5mZXRjaG9uZSgpWzBdCiAgICAgICAgICAgIHNlbGYuX3R4KGYn\
'XHgxYlsybSAgbWVtb3JpZXM6e21jfSAgc2Vzc2lvbnM6e3NjfSAgdGltZTp7ZGF0ZXRpbWUu\
'bm93KCkuc3RyZnRpbWUoIiVIOiVNIil9XHgxYlswbVxuJykKICAgICAgICBlbGlmIGMgPT0g\
'J3Byb2JlJzoKICAgICAgICAgICAgc2VsZi5fdHgoJ1x4MWJbMzg7NTsxNzJtXHgxYlsybSAg\
'cHJvYmluZy4uLlx4MWJbMG1cbicpCiAgICAgICAgICAgIHNlbGYuX3R4KF9tZF90b190ZXJt\
'aW5hbChfc3lzdGVtX3Byb2JlKCkpICsgJ1xuJykKICAgICAgICBlbGlmIGMgPT0gJ3NlYXJj\
'aCcgYW5kIGxlbihwYXJ0cykgPiAxOgogICAgICAgICAgICBxID0gJyAnLmpvaW4ocGFydHNb\
'MTpdKQogICAgICAgICAgICBzZWxmLl90eChmJ1x4MWJbMm0gIHNlYXJjaGluZzoge3F9XHgx\
'YlswbVxuJykKICAgICAgICAgICAgc2VsZi5fdHgoX21kX3RvX3Rlcm1pbmFsKF93ZWJfc2Vh\
'cmNoKHEpKSArICdcbicpCiAgICAgICAgZWxpZiBjIGluICgnZXhpdCcsJ3F1aXQnLCdieWUn\
'LCdkaXNjb25uZWN0Jyk6CiAgICAgICAgICAgIHNlbGYuX3R4KCdceDFiWzM4OzU7MTcybSAg\
'ZGlzY29ubmVjdGluZy4uLlx4MWJbMG1cbicpCiAgICAgICAgICAgIHJhaXNlIFN0b3BJdGVy\
'YXRpb24KICAgICAgICBlbGlmIGMgPT0gJ2hlbHAnOgogICAgICAgICAgICBzZWxmLl90eCgK\
'ICAgICAgICAgICAgICAgICdceDFiWzJtJwogICAgICAgICAgICAgICAgJyAgLy9tZW1vcnkg\
'ICAgICAgICAgIHdoYXQgSSByZW1lbWJlclxuJwogICAgICAgICAgICAgICAgJyAgLy9mb3Jn\
'ZXQgPHRlcm0+ICAgIGRlbGV0ZSBtYXRjaGluZyBtZW1vcmllc1xuJwogICAgICAgICAgICAg\
'ICAgJyAgLy9jbGVhciAgICAgICAgICAgIHdpcGUgYWxsIG1lbW9yaWVzXG4nCiAgICAgICAg\
'ICAgICAgICAnICAvL3N0YXR1cyAgICAgICAgICAgc2Vzc2lvbiBpbmZvXG4nCiAgICAgICAg\
'ICAgICAgICAnICAvL3Byb2JlICAgICAgICAgICAgc3lzdGVtIGluZm9ybWF0aW9uXG4nCiAg\
'ICAgICAgICAgICAgICAnICAvL3NlYXJjaCA8cXVlcnk+ICAgd2ViIHNlYXJjaFxuJwogICAg\
'ICAgICAgICAgICAgJyAgLy9leGl0ICAgICAgICAgICAgIGRpc2Nvbm5lY3RcbicKICAgICAg\
'ICAgICAgICAgICcgIC8vaGVscCAgICAgICAgICAgICB0aGlzXG4nCiAgICAgICAgICAgICAg\
'ICAnXG4nCiAgICAgICAgICAgICAgICAnICBGaWxlIHBhdGhzIHdvcmsgaW5saW5lIOKAlCBw\
'YXN0ZSBhbnkgcGF0aCBpbiB5b3VyIG1lc3NhZ2VcbicKICAgICAgICAgICAgICAgICcgIElt\
'YWdlcyB0b286IC9wYXRoL3RvL2ltYWdlLnBuZ1xuJwogICAgICAgICAgICAgICAgJ1x4MWJb\
'MG1cbicpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgc2VsZi5fdHgoZidceDFiWzJtICB1\
'bmtub3duOiB7Y30gICgvL2hlbHApXHgxYlswbVxuJykKCiAgICBkZWYgX2VuZChzZWxmKToK\
'ICAgICAgICBpZiBsZW4oc2VsZi5oaXN0KSA+PSAyOgogICAgICAgICAgICB0aHJlYWRpbmcu\
'VGhyZWFkKHRhcmdldD1fc3RvcmVfbWVtb3J5LCBhcmdzPShfZGIoKSwgc2VsZi5oaXN0KSwg\
'ZGFlbW9uPVRydWUpLnN0YXJ0KCkKICAgICAgICB0cnk6IHNlbGYuc29jay5jbG9zZSgpCiAg\
'ICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogcGFzcwogICAgICAgIF9sb2coJ1Nlc3Npb24gZW5k\
'ZWQnKQoKIyDilIDilIAgV2ViIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU\
'gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU\
'gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU\
'gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU\
'gOKUgOKUgOKUgOKUgOKUgOKUgApfd2ViX2hpc3QgPSBbXTsgX3dlYl9sb2NrID0gdGhyZWFk\
'aW5nLkxvY2soKQoKX0NTUyA9ICgKICAgICI6cm9vdHstLWJnOiMwODA4MDc7LS1iZzI6IzBk\
'MGQwYTstLWJnMzojMTMxMzEwOy0tb3I6I2U4NzIwYzstLW9yMjojYzQ1YzAwOyIKICAgICIt\
'LW9yMzojZmY5NTMzOy0tZGltOiMyYTJhMWE7LS1mZzojYzRiODk4Oy0tZmcyOiM4ODc3NjY7\
'IgogICAgIi0tYm9yZGVyOiMxYTFhMTI7LS1mb250OidKZXRCcmFpbnMgTW9ubycsbW9ub3Nw\
'YWNlfSIKICAgICIqe2JveC1zaXppbmc6Ym9yZGVyLWJveDttYXJnaW46MDtwYWRkaW5nOjB9\
'IgogICAgImJvZHl7YmFja2dyb3VuZDp2YXIoLS1iZyk7Y29sb3I6dmFyKC0tZmcpO2ZvbnQt\
'ZmFtaWx5OnZhcigtLWZvbnQpOyIKICAgICJmb250LXNpemU6MTNweDtsaW5lLWhlaWdodDox\
'LjY7aGVpZ2h0OjEwMHZoO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW59Igog\
'ICAgImF7Y29sb3I6dmFyKC0tb3IyKX0iCiAgICAiLnRvcHtiYWNrZ3JvdW5kOnZhcigtLWJn\
'Mik7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTsiCiAgICAicGFkZGlu\
'Zzo4cHggMTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxNHB4O2Zs\
'ZXgtc2hyaW5rOjB9IgogICAgIi5icmFuZHtjb2xvcjp2YXIoLS1vcik7Zm9udC13ZWlnaHQ6\
'NzAwO2ZvbnQtc2l6ZToxM3B4O2xldHRlci1zcGFjaW5nOi4xNWVtfSIKICAgICIudmVye2Nv\
'bG9yOnZhcigtLWZnMik7Zm9udC1zaXplOjEwcHh9IgogICAgIi5uYXZ7bWFyZ2luLWxlZnQ6\
'YXV0bztkaXNwbGF5OmZsZXg7Z2FwOjRweH0iCiAgICAiLm5hdiBhe2NvbG9yOnZhcigtLWZn\
'Mik7Zm9udC1zaXplOjEwcHg7cGFkZGluZzozcHggOXB4OyIKICAgICJib3JkZXI6MXB4IHNv\
'bGlkIHRyYW5zcGFyZW50O3RleHQtZGVjb3JhdGlvbjpub25lOyIKICAgICJ0ZXh0LXRyYW5z\
'Zm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA2ZW19IgogICAgIi5uYXYgYTpob3Zl\
'ciwubmF2IGEub257Y29sb3I6dmFyKC0tb3IpO2JvcmRlci1jb2xvcjp2YXIoLS1vcjIpOyIK\
'ICAgICJiYWNrZ3JvdW5kOnJnYmEoMjMyLDExNCwxMiwuMDYpfSIKICAgICIjY3d7ZmxleDox\
'O2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47cGFkZGluZzoxMnB4IDE2cHg7\
'IgogICAgIm92ZXJmbG93OmhpZGRlbjttaW4taGVpZ2h0OjB9IgogICAgIiNtc2dze2ZsZXg6\
'MTtvdmVyZmxvdy15OmF1dG87ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjsi\
'CiAgICAiZ2FwOjEwcHg7cGFkZGluZy1ib3R0b206OHB4O21pbi1oZWlnaHQ6MH0iCiAgICAi\
'Lm1zZ3twYWRkaW5nOjlweCAxM3B4O2ZvbnQtc2l6ZToxM3B4O2xpbmUtaGVpZ2h0OjEuNzsi\
'CiAgICAibWF4LXdpZHRoOjkwJTt3b3JkLWJyZWFrOmJyZWFrLXdvcmR9IgogICAgIi5tc2cu\
'dXthbGlnbi1zZWxmOmZsZXgtZW5kO2JhY2tncm91bmQ6cmdiYSgyMzIsMTE0LDEyLC4wNyk7\
'IgogICAgImJvcmRlcjoxcHggc29saWQgdmFyKC0tb3IyKX0iCiAgICAiLm1zZy5ue2FsaWdu\
'LXNlbGY6ZmxleC1zdGFydDtiYWNrZ3JvdW5kOnZhcigtLWJnMik7IgogICAgImJvcmRlcjox\
'cHggc29saWQgdmFyKC0tYm9yZGVyKTttaW4td2lkdGg6MjAwcHh9IgogICAgIi53aG97Zm9u\
'dC1zaXplOjlweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjFlbTsiCiAgICAi\
'bWFyZ2luLWJvdHRvbTo0cHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlfSIKICAgICIubXNn\
'LnUgLndob3tjb2xvcjp2YXIoLS1vcjIpfS5tc2cubiAud2hve2NvbG9yOnZhcigtLW9yKX0i\
'CiAgICAiLmlye2Rpc3BsYXk6ZmxleDtnYXA6OHB4O3BhZGRpbmctdG9wOjhweDsiCiAgICAi\
'Ym9yZGVyLXRvcDoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtmbGV4LXNocmluazowO2FsaWdu\
'LWl0ZW1zOmZsZXgtZW5kfSIKICAgICJ0ZXh0YXJlYXtmbGV4OjE7YmFja2dyb3VuZDp2YXIo\
'LS1iZzIpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tb3IyKTsiCiAgICAiY29sb3I6dmFyKC0t\
'ZmcpO3BhZGRpbmc6OHB4O2ZvbnQtZmFtaWx5OnZhcigtLWZvbnQpOyIKICAgICJmb250LXNp\
'emU6MTNweDtvdXRsaW5lOm5vbmU7cmVzaXplOm5vbmV9IgogICAgIi5idG57YmFja2dyb3Vu\
'ZDp2YXIoLS1vcjIpO2JvcmRlcjpub25lO2NvbG9yOnZhcigtLWJnKTtwYWRkaW5nOjhweCAx\
'NnB4OyIKICAgICJmb250LWZhbWlseTp2YXIoLS1mb250KTtmb250LXNpemU6MTFweDt0ZXh0\
'LXRyYW5zZm9ybTp1cHBlcmNhc2U7IgogICAgImN1cnNvcjpwb2ludGVyO2ZvbnQtd2VpZ2h0\
'OjcwMDtsZXR0ZXItc3BhY2luZzouMDZlbTt3aGl0ZS1zcGFjZTpub3dyYXB9IgogICAgIi5i\
'dG46aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1vcjMpfSIKICAgICIuYnRuLnNlY3tiYWNrZ3Jv\
'dW5kOnZhcigtLWJnMyk7Y29sb3I6dmFyKC0tZmcyKTtib3JkZXI6MXB4IHNvbGlkIHZhcigt\
'LWJvcmRlcil9IgogICAgIi5idG4uc2VjOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYmcyKTtj\
'b2xvcjp2YXIoLS1mZyl9IgogICAgIi51cGx7Y3Vyc29yOnBvaW50ZXI7YmFja2dyb3VuZDp2\
'YXIoLS1iZzMpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsiCiAgICAiY29sb3I6\
'dmFyKC0tZmcyKTtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtc2l6ZToxMXB4O3RleHQtdHJhbnNm\
'b3JtOnVwcGVyY2FzZTsiCiAgICAibGV0dGVyLXNwYWNpbmc6LjA2ZW07d2hpdGUtc3BhY2U6\
'bm93cmFwfSIKICAgICIudXBsOmhvdmVye2NvbG9yOnZhcigtLWZnKTtib3JkZXItY29sb3I6\
'dmFyKC0tb3IyKX0iCiAgICAiI2Zpe2Rpc3BsYXk6bm9uZX0iCiAgICAiLmZiYWRnZXtmb250\
'LXNpemU6MTBweDtjb2xvcjp2YXIoLS1vcjMpO3BhZGRpbmc6MCA0cHg7ZGlzcGxheTpub25l\
'fSIKICAgICIucGFnZXtwYWRkaW5nOjE2cHg7b3ZlcmZsb3cteTphdXRvO2ZsZXg6MX0iCiAg\
'ICAiLnBoe2NvbG9yOnZhcigtLW9yKTtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo3MDA7\
'bWFyZ2luLWJvdHRvbToxMnB4OyIKICAgICJwYWRkaW5nLWJvdHRvbTo4cHg7Ym9yZGVyLWJv\
'dHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKX0iCiAgICAiLm1pe3BhZGRpbmc6N3B4IDA7\
'Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTsiCiAgICAiY29sb3I6dmFy\
'KC0tZmcyKTtmb250LXNpemU6MTJweH0iCiAgICAiLm1pOmxhc3QtY2hpbGR7Ym9yZGVyOm5v\
'bmV9IgogICAgIi50c3tjb2xvcjp2YXIoLS1kaW0pO2ZvbnQtc2l6ZToxMHB4O2Rpc3BsYXk6\
'YmxvY2s7bWFyZ2luLWJvdHRvbToycHh9IgogICAgIi5zdHtkaXNwbGF5OmZsZXg7anVzdGlm\
'eS1jb250ZW50OnNwYWNlLWJldHdlZW47cGFkZGluZzo2cHggMDsiCiAgICAiYm9yZGVyLWJv\
'dHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtmb250LXNpemU6MTJweH0iCiAgICAiLnNr\
'e2NvbG9yOnZhcigtLWZnMil9LnN2e2NvbG9yOnZhcigtLW9yMyl9IgogICAgIi5tc2cgaDF7\
'Y29sb3I6dmFyKC0tb3IzKTtmb250LXNpemU6MTVweDttYXJnaW46OHB4IDAgNHB4fSIKICAg\
'ICIubXNnIGgye2NvbG9yOnZhcigtLW9yKTtmb250LXNpemU6MTRweDttYXJnaW46NnB4IDAg\
'M3B4fSIKICAgICIubXNnIGgze2NvbG9yOnZhcigtLW9yMik7Zm9udC1zaXplOjEzcHg7bWFy\
'Z2luOjRweCAwIDJweH0iCiAgICAiLm1zZyBwe21hcmdpbjozcHggMH0iCiAgICAiLm1zZyBs\
'aXttYXJnaW46MnB4IDAgMnB4IDE2cHg7bGlzdC1zdHlsZTpub25lfSIKICAgICIubXNnIGxp\
'OjpiZWZvcmV7Y29udGVudDonwrcnO2NvbG9yOnZhcigtLW9yMik7bWFyZ2luLXJpZ2h0OjZw\
'eH0iCiAgICAiLm1zZyBjb2Rle2JhY2tncm91bmQ6dmFyKC0tYmczKTtwYWRkaW5nOjFweCA1\
'cHg7IgogICAgImZvbnQtZmFtaWx5OnZhcigtLWZvbnQpO2ZvbnQtc2l6ZToxMnB4O2NvbG9y\
'OnZhcigtLW9yMyl9IgogICAgIi5tc2cgc3Ryb25ne2NvbG9yOnZhcigtLW9yMyk7Zm9udC13\
'ZWlnaHQ6NzAwfSIKICAgICIubXNnIGVte2ZvbnQtc3R5bGU6aXRhbGljfSIKICAgICIubXNn\
'IGhye2JvcmRlcjpub25lO2JvcmRlci10b3A6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7bWFy\
'Z2luOjhweCAwfSIKICAgICIubXNnIGJsb2NrcXVvdGV7Ym9yZGVyLWxlZnQ6MnB4IHNvbGlk\
'IHZhcigtLW9yMik7IgogICAgInBhZGRpbmctbGVmdDo4cHg7Y29sb3I6dmFyKC0tZmcyKTtt\
'YXJnaW46NHB4IDB9IgogICAgIi5jYntiYWNrZ3JvdW5kOnZhcigtLWJnMyk7Ym9yZGVyOjFw\
'eCBzb2xpZCB2YXIoLS1ib3JkZXIpOyIKICAgICJib3JkZXItbGVmdDoycHggc29saWQgdmFy\
'KC0tb3IyKTttYXJnaW46NnB4IDB9IgogICAgIi5jaHtwYWRkaW5nOjNweCA4cHg7Zm9udC1z\
'aXplOjEwcHg7Y29sb3I6dmFyKC0tb3IyKTsiCiAgICAiYm9yZGVyLWJvdHRvbToxcHggc29s\
'aWQgdmFyKC0tYm9yZGVyKTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7IgogICAgImxldHRl\
'ci1zcGFjaW5nOi4wNmVtfSIKICAgICIuY2x7Y29sb3I6dmFyKC0tZmcyKX0iCiAgICAiLmNw\
'e3BhZGRpbmc6OHB4O2ZvbnQtZmFtaWx5OnZhcigtLWZvbnQpO2ZvbnQtc2l6ZToxMnB4OyIK\
'ICAgICJjb2xvcjp2YXIoLS1mZzIpO3doaXRlLXNwYWNlOnByZS13cmFwO292ZXJmbG93LXg6\
'YXV0bzttYXJnaW46MH0iCiAgICAiLmRvdHtkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDo0\
'cHg7aGVpZ2h0OjRweDtib3JkZXItcmFkaXVzOjUwJTsiCiAgICAiYmFja2dyb3VuZDp2YXIo\
'LS1vcjIpO21hcmdpbjowIDFweDsiCiAgICAiYW5pbWF0aW9uOmJsaW5rIDEuMnMgaW5maW5p\
'dGV9IgogICAgIi5kb3Q6bnRoLWNoaWxkKDIpe2FuaW1hdGlvbi1kZWxheTouMnN9IgogICAg\
'Ii5kb3Q6bnRoLWNoaWxkKDMpe2FuaW1hdGlvbi1kZWxheTouNHN9IgogICAgIkBrZXlmcmFt\
'ZXMgYmxpbmt7MCUsODAlLDEwMCV7b3BhY2l0eTouMjV9NDAle29wYWNpdHk6MX19IgogICAg\
'Ijo6LXdlYmtpdC1zY3JvbGxiYXJ7d2lkdGg6M3B4fSIKICAgICI6Oi13ZWJraXQtc2Nyb2xs\
'YmFyLXRodW1ie2JhY2tncm91bmQ6dmFyKC0tZGltKX0iCikKCl9FWUVfU1ZHID0gKAogICAg\
'Jzxzdmcgd2lkdGg9IjI4IiBoZWlnaHQ9IjMyIiB2aWV3Qm94PSIwIDAgMjggMzIiIHhtbG5z\
'PSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+JwogICAgJzxwb2x5Z29uIHBvaW50cz0i\
'MTQsMiAyNiwyOCAyLDI4IiBmaWxsPSJub25lIiBzdHJva2U9IiNjNDVjMDAiIHN0cm9rZS13\
'aWR0aD0iMS41Ii8+JwogICAgJzxsaW5lIHgxPSIxNCIgeTE9IjIiIHgyPSIxNCIgeTI9IjI4\
'IiBzdHJva2U9IiNjNDVjMDAiIHN0cm9rZS13aWR0aD0iMC43IiBvcGFjaXR5PSIwLjQiLz4n\
'CiAgICAnPGNpcmNsZSBjeD0iMTQiIGN5PSIxOSIgcj0iNSIgZmlsbD0ibm9uZSIgc3Ryb2tl\
'PSIjYzQ1YzAwIiBzdHJva2Utd2lkdGg9IjEuMiIvPicKICAgICc8Y2lyY2xlIGN4PSIxNCIg\
'Y3k9IjE5IiByPSIyLjUiIGZpbGw9IiNlODcyMGMiLz4nCiAgICAnPGNpcmNsZSBjeD0iMTQi\
'IGN5PSIxOSIgcj0iMSIgZmlsbD0iI2ZmOTUzMyIvPicKICAgICc8L3N2Zz4nCikKCmRlZiBf\
'ZXNjKHMpOiByZXR1cm4gc3RyKHMpLnJlcGxhY2UoJyYnLCcmYW1wOycpLnJlcGxhY2UoJzwn\
'LCcmbHQ7JykucmVwbGFjZSgnPicsJyZndDsnKQoKX0NIQVRfSlMgPSByIiIiCnZhciBNPWRv\
'Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc2dzJyk7CmlmKE0pTS5zY3JvbGxUb3A9TS5zY3Jv\
'bGxIZWlnaHQ7CnZhciBfcGY9bnVsbDsKZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ZpJyku\
'YWRkRXZlbnRMaXN0ZW5lcignY2hhbmdlJyxmdW5jdGlvbihlKXsKICB2YXIgZj1lLnRhcmdl\
'dC5maWxlc1swXTtpZighZilyZXR1cm47CiAgdmFyIHI9bmV3IEZpbGVSZWFkZXIoKTsKICBy\
'Lm9ubG9hZD1mdW5jdGlvbihldil7CiAgICBfcGY9e25hbWU6Zi5uYW1lLHR5cGU6Zi50eXBl\
'LGRhdGE6ZXYudGFyZ2V0LnJlc3VsdH07CiAgICB2YXIgYj1kb2N1bWVudC5nZXRFbGVtZW50\
'QnlJZCgnZmInKTtiLnRleHRDb250ZW50PSdcdWQ4M2RcdWRjY2UgJytmLm5hbWU7Yi5zdHls\
'ZS5kaXNwbGF5PSdpbmxpbmUnOwogIH07CiAgaWYoZi50eXBlLnN0YXJ0c1dpdGgoJ2ltYWdl\
'LycpKXIucmVhZEFzRGF0YVVSTChmKTsKICBlbHNlIHIucmVhZEFzVGV4dChmKTsKICBlLnRh\
'cmdldC52YWx1ZT0nJzsKfSk7CmZ1bmN0aW9uIHNlbmQoKXsKICB2YXIgaW5wPWRvY3VtZW50\
'LmdldEVsZW1lbnRCeUlkKCdpbnAnKSx0PWlucC52YWx1ZS50cmltKCk7CiAgaWYoIXQmJiFf\
'cGYpcmV0dXJuO2lucC52YWx1ZT0nJzsKICB2YXIgZHQ9dDtpZihfcGYpZHQ9KHQ/dCsnXG4n\
'OicnKSsnW2F0dGFjaGVkOiAnK19wZi5uYW1lKyddJzsKICB2YXIgdT1kb2N1bWVudC5jcmVh\
'dGVFbGVtZW50KCdkaXYnKTt1LmNsYXNzTmFtZT0nbXNnIHUnOwogIHUuaW5uZXJIVE1MPSc8\
'ZGl2IGNsYXNzPXdobz5DcmVhdG9yPC9kaXY+PHA+JytkdC5yZXBsYWNlKC8mL2csJyZhbXA7\
'JykucmVwbGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykucmVwbGFjZSgv\
'XG4vZywnPGJyPicpKyc8L3A+JzsKICBNLmFwcGVuZENoaWxkKHUpO00uc2Nyb2xsVG9wPU0u\
'c2Nyb2xsSGVpZ2h0OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmYicpLnN0eWxlLmRp\
'c3BsYXk9J25vbmUnOwogIHZhciBuPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpO24u\
'Y2xhc3NOYW1lPSdtc2cgbic7CiAgbi5pbm5lckhUTUw9JzxkaXYgY2xhc3M9d2hvPk5lWGlT\
'PC9kaXY+PHNwYW4gY2xhc3M9bmM+PHNwYW4gY2xhc3M9ZG90Pjwvc3Bhbj48c3BhbiBjbGFz\
'cz1kb3Q+PC9zcGFuPjxzcGFuIGNsYXNzPWRvdD48L3NwYW4+PC9zcGFuPic7CiAgTS5hcHBl\
'bmRDaGlsZChuKTtNLnNjcm9sbFRvcD1NLnNjcm9sbEhlaWdodDsKICB2YXIgYm9keT17bXNn\
'OnR9OwogIGlmKF9wZil7Ym9keS5maWxlX25hbWU9X3BmLm5hbWU7Ym9keS5maWxlX3R5cGU9\
'X3BmLnR5cGU7Ym9keS5maWxlX2RhdGE9X3BmLmRhdGE7fQogIF9wZj1udWxsOwogIGZldGNo\
'KCcvYXBpL2NoYXQnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidh\
'cHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pCiAgLnRoZW4o\
'ZnVuY3Rpb24ocmVzcCl7CiAgICB2YXIgcmVhZGVyPXJlc3AuYm9keS5nZXRSZWFkZXIoKSxk\
'ZWM9bmV3IFRleHREZWNvZGVyKCksYnVmPScnOwogICAgbi5pbm5lckhUTUw9JzxkaXYgY2xh\
'c3M9d2hvPk5lWGlTPC9kaXY+PHNwYW4gY2xhc3M9bmM+PC9zcGFuPic7CiAgICB2YXIgbmM9\
'bi5xdWVyeVNlbGVjdG9yKCcubmMnKTsKICAgIGZ1bmN0aW9uIHB1bXAoKXsKICAgICAgcmVh\
'ZGVyLnJlYWQoKS50aGVuKGZ1bmN0aW9uKGQpewogICAgICAgIGlmKGQuZG9uZSl7bmMuaW5u\
'ZXJIVE1MPXJlbmRlck1kKGJ1Zik7TS5zY3JvbGxUb3A9TS5zY3JvbGxIZWlnaHQ7cmV0dXJu\
'O30KICAgICAgICBidWYrPWRlYy5kZWNvZGUoZC52YWx1ZSx7c3RyZWFtOnRydWV9KTsKICAg\
'ICAgICBuYy5pbm5lckhUTUw9cmVuZGVyTWQoYnVmKSsnPHNwYW4gc3R5bGU9ImNvbG9yOnZh\
'cigtLW9yMykiPiYjeDI1YWU7PC9zcGFuPic7CiAgICAgICAgTS5zY3JvbGxUb3A9TS5zY3Jv\
'bGxIZWlnaHQ7cHVtcCgpOwogICAgICB9KS5jYXRjaChmdW5jdGlvbigpe25jLmlubmVySFRN\
'TD1yZW5kZXJNZChidWYpO30pOwogICAgfQogICAgcHVtcCgpOwogIH0pLmNhdGNoKGZ1bmN0\
'aW9uKCl7bi5pbm5lckhUTUw9JzxkaXYgY2xhc3M9d2hvPk5lWGlTPC9kaXY+PHNwYW4gc3R5\
'bGU9Y29sb3I6I2MwNzA3MD4oZXJyb3IpPC9zcGFuPic7fSk7Cn0KZnVuY3Rpb24gcmVuZGVy\
'TWQodCl7CiAgdD10LnJlcGxhY2UoL2BgYChcdyopXG4/KFtcc1xTXSo/KWBgYC9nLGZ1bmN0\
'aW9uKG0sbGFuZyxjb2RlKXsKICAgIHZhciBsPWxhbmc/JzxzcGFuIGNsYXNzPWNsPiAnK2xh\
'bmcrJzwvc3Bhbj4nOicnOwogICAgcmV0dXJuICc8ZGl2IGNsYXNzPWNiPjxkaXYgY2xhc3M9\
'Y2g+Y29kZScrbCsnPC9kaXY+PHByZSBjbGFzcz1jcD4nK2NvZGUucmVwbGFjZSgvPC9nLCcm\
'bHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7JykrJzwvcHJlPjwvZGl2Pic7CiAgfSk7CiAgdD10\
'LnJlcGxhY2UoL2AoW15gXSspYC9nLCc8Y29kZT4kMTwvY29kZT4nKTsKICB0PXQucmVwbGFj\
'ZSgvXiMjIyAoLispJC9nbSwnPGgzPiQxPC9oMz4nKTsKICB0PXQucmVwbGFjZSgvXiMjICgu\
'KykkL2dtLCc8aDI+JDE8L2gyPicpOwogIHQ9dC5yZXBsYWNlKC9eIyAoLispJC9nbSwnPGgx\
'PiQxPC9oMT4nKTsKICB0PXQucmVwbGFjZSgvXCpcKihbXipdKylcKlwqL2csJzxzdHJvbmc+\
'JDE8L3N0cm9uZz4nKTsKICB0PXQucmVwbGFjZSgvXCooW14qXSspXCovZywnPGVtPiQxPC9l\
'bT4nKTsKICB0PXQucmVwbGFjZSgvXlstKitdICguKykkL2dtLCc8bGk+JDE8L2xpPicpOwog\
'IHQ9dC5yZXBsYWNlKC9cWyhbXlxdXSspXF1cKChbXildKylcKS9nLCc8YSBocmVmPSIkMiIg\
'dGFyZ2V0PV9ibGFuaz4kMTwvYT4nKTsKICB0PXQucmVwbGFjZSgvXlstKl9dezMsfSQvZ20s\
'Jzxocj4nKTsKICB0PXQucmVwbGFjZSgvXj4gKC4rKSQvZ20sJzxibG9ja3F1b3RlPiQxPC9i\
'bG9ja3F1b3RlPicpOwogIHQ9dC5yZXBsYWNlKC9cblxuL2csJzxicj48YnI+Jyk7CiAgdD10\
'LnJlcGxhY2UoL1xuL2csJzxicj4nKTsKICByZXR1cm4gdDsKfQpmdW5jdGlvbiBjbHIoKXtm\
'ZXRjaCgnL2FwaS9jbGVhcicse21ldGhvZDonUE9TVCd9KS50aGVuKGZ1bmN0aW9uKCl7bG9j\
'YXRpb24ucmVsb2FkKCl9KTt9CmRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24n\
'LGZ1bmN0aW9uKGUpewogIGlmKGUua2V5PT09J0VudGVyJyYmIWUuc2hpZnRLZXkmJmRvY3Vt\
'ZW50LmFjdGl2ZUVsZW1lbnQuaWQ9PT0naW5wJyl7CiAgICBlLnByZXZlbnREZWZhdWx0KCk7\
'c2VuZCgpOwogIH0KfSk7CiIiIgoKZGVmIF9zaGVsbChjb250ZW50LCBhY3RpdmU9J2NoYXQn\
'KToKICAgIG5hdiA9ICcnLmpvaW4oCiAgICAgICAgZiI8YSBocmVmPScve3N9JyBjbGFzcz0n\
'eydvbicgaWYgYWN0aXZlPT1zIGVsc2UgJyd9Jz57bH08L2E+IgogICAgICAgIGZvciBzLGwg\
'aW4gWygnY2hhdCcsJ0NoYXQnKSwoJ21lbW9yeScsJ01lbW9yeScpLCgnc3RhdHVzJywnU3Rh\
'dHVzJyldCiAgICApCiAgICByZXR1cm4gKAogICAgICAgICc8IURPQ1RZUEUgaHRtbD48aHRt\
'bCBsYW5nPWVuPjxoZWFkPicKICAgICAgICAnPG1ldGEgY2hhcnNldD1VVEYtOD4nCiAgICAg\
'ICAgJzxtZXRhIG5hbWU9dmlld3BvcnQgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGlu\
'aXRpYWwtc2NhbGU9MSI+JwogICAgICAgICc8dGl0bGU+TmVYaVM8L3RpdGxlPicKICAgICAg\
'ICAiPGxpbmsgaHJlZj0naHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWls\
'eT1KZXRCcmFpbnMrTW9ubzp3Z2h0QDQwMDs3MDAmZGlzcGxheT1zd2FwJyByZWw9c3R5bGVz\
'aGVldD4iCiAgICAgICAgZic8c3R5bGU+e19DU1N9PC9zdHlsZT48L2hlYWQ+PGJvZHk+Jwog\
'ICAgICAgICc8ZGl2IGNsYXNzPXRvcD4nCiAgICAgICAgZid7X0VZRV9TVkd9JwogICAgICAg\
'ICc8c3BhbiBjbGFzcz1icmFuZD5OIGUgWCBpIFM8L3NwYW4+JwogICAgICAgICc8c3BhbiBj\
'bGFzcz12ZXI+djMuMDwvc3Bhbj4nCiAgICAgICAgZic8ZGl2IGNsYXNzPW5hdj57bmF2fTwv\
'ZGl2PicKICAgICAgICBmJzwvZGl2Pntjb250ZW50fTwvYm9keT48L2h0bWw+JwogICAgKQoK\
'ZGVmIF9wYWdlX2NoYXQoKToKICAgIHdpdGggX3dlYl9sb2NrOiBoaXN0PWxpc3QoX3dlYl9o\
'aXN0KQogICAgbWg9JycKICAgIGZvciBtIGluIGhpc3Q6CiAgICAgICAgd2hvPSdDcmVhdG9y\
'JyBpZiBtWydyb2xlJ109PSd1c2VyJyBlbHNlICdOZVhpUycKICAgICAgICBjbHM9J3UnIGlm\
'IG1bJ3JvbGUnXT09J3VzZXInIGVsc2UgJ24nCiAgICAgICAgaWYgbVsncm9sZSddPT0nYXNz\
'aXN0YW50JzogY3Q9X21kX3RvX2h0bWwobVsnY29udGVudCddKQogICAgICAgIGVsc2U6IGN0\
'PSc8cD4nK19lc2MobVsnY29udGVudCddKS5yZXBsYWNlKCdcbicsJzxicj4nKSsnPC9wPicK\
'ICAgICAgICBtaCs9ZiI8ZGl2IGNsYXNzPSdtc2cge2Nsc30nPjxkaXYgY2xhc3M9d2hvPnt3\
'aG99PC9kaXY+e2N0fTwvZGl2PiIKICAgIGlmIG5vdCBtaDogbWg9IjxkaXYgc3R5bGU9J2Nv\
'bG9yOnZhcigtLWRpbSk7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzo0MHB4O2ZvbnQtc2l6\
'ZToxMXB4Jz5UaGUgZXllIHdhdGNoZXMuIEJlZ2luLjwvZGl2PiIKICAgIGJvZHk9KAogICAg\
'ICAgICc8ZGl2IGlkPWN3PicKICAgICAgICBmJzxkaXYgaWQ9bXNncz57bWh9PC9kaXY+Jwog\
'ICAgICAgICc8ZGl2IGNsYXNzPWlyPicKICAgICAgICAnPGxhYmVsIGNsYXNzPXVwbCBmb3I9\
'Zmk+XHUyMTkxIEZpbGU8L2xhYmVsPicKICAgICAgICAnPGlucHV0IHR5cGU9ZmlsZSBpZD1m\
'aSBhY2NlcHQ9ImltYWdlLyosdGV4dC8qLC5qc29uLC5jc3YsLm1kLC5zaCwucHksLmpzLC50\
'cywueWFtbCwueW1sLC54bWwsLmxvZywucGRmIj4nCiAgICAgICAgJzxzcGFuIGlkPWZiIGNs\
'YXNzPWZiYWRnZT48L3NwYW4+JwogICAgICAgICc8dGV4dGFyZWEgaWQ9aW5wIHJvd3M9MiBw\
'bGFjZWhvbGRlcj0iU3BlYWsuIj48L3RleHRhcmVhPicKICAgICAgICAnPGJ1dHRvbiBjbGFz\
'cz1idG4gb25jbGljaz1zZW5kKCk+U2VuZDwvYnV0dG9uPicKICAgICAgICAiPGJ1dHRvbiBj\
'bGFzcz0nYnRuIHNlYycgb25jbGljaz1jbHIoKT5DbGVhcjwvYnV0dG9uPiIKICAgICAgICAn\
'PC9kaXY+PC9kaXY+JwogICAgICAgIGYnPHNjcmlwdD57X0NIQVRfSlN9PC9zY3JpcHQ+Jwog\
'ICAgKQogICAgcmV0dXJuIF9zaGVsbChib2R5LCdjaGF0JykKCmRlZiBfcGFnZV9tZW1vcnko\
'ZGIpOgogICAgcm93cz1kYi5leGVjdXRlKCdTRUxFQ1QgY29udGVudCxjcmVhdGVkX2F0IEZS\
'T00gbWVtb3JpZXMgT1JERVIgQlkgaWQgREVTQycpLmZldGNoYWxsKCkKICAgIGl0ZW1zPScn\
'LmpvaW4oCiAgICAgICAgZiI8ZGl2IGNsYXNzPW1pPjxzcGFuIGNsYXNzPXRzPntfZXNjKHN0\
'cihyWydjcmVhdGVkX2F0J10pWzoxNl0pfTwvc3Bhbj57X2VzYyhyWydjb250ZW50J10pfTwv\
'ZGl2PiIKICAgICAgICBmb3IgciBpbiByb3dzCiAgICApIG9yICI8ZGl2IHN0eWxlPSdjb2xv\
'cjp2YXIoLS1mZzIpO3BhZGRpbmc6MTJweCc+Tm8gbWVtb3JpZXMgeWV0LjwvZGl2PiIKICAg\
'IHJldHVybiBfc2hlbGwoZiI8ZGl2IGNsYXNzPXBhZ2U+PGRpdiBjbGFzcz1waD5NZW1vcnkg\
'Jm1kYXNoOyB7bGVuKHJvd3MpfSBmYWN0czwvZGl2PntpdGVtc308L2Rpdj4iLCdtZW1vcnkn\
'KQoKZGVmIF9wYWdlX3N0YXR1cyhkYik6CiAgICBtYz1kYi5leGVjdXRlKCdTRUxFQ1QgQ09V\
'TlQoKikgRlJPTSBtZW1vcmllcycpLmZldGNob25lKClbMF0KICAgIHNjPWRiLmV4ZWN1dGUo\
'J1NFTEVDVCBDT1VOVCgqKSBGUk9NIHNlc3Npb25zJykuZmV0Y2hvbmUoKVswXQogICAgdHJ5\
'OgogICAgICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihmJ3tPTExBTUF9L2FwaS90\
'YWdzJyx0aW1lb3V0PTMpIGFzIHI6CiAgICAgICAgICAgIG1vZGVscz1bbVsnbmFtZSddIGZv\
'ciBtIGluIGpzb24ubG9hZHMoci5yZWFkKCkpLmdldCgnbW9kZWxzJyxbXSldCiAgICAgICAg\
'b2w9J29ubGluZScKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgbW9kZWxzPVtdOyBv\
'bD0nb2ZmbGluZScKICAgIGZvaz1hbnkoTU9ERUxfRkFTVC5zcGxpdCgnOicpWzBdIGluIHgg\
'Zm9yIHggaW4gbW9kZWxzKQogICAgZG9rPWFueShNT0RFTF9ERUVQLnNwbGl0KCcvJylbLTFd\
'LnNwbGl0KCc6JylbMF0gaW4geCBvciBNT0RFTF9ERUVQLnNwbGl0KCc6JylbMF0gaW4geCBm\
'b3IgeCBpbiBtb2RlbHMpCiAgICBzdGF0cz1bCiAgICAgICAgKCdvbGxhbWEnLG9sKSwKICAg\
'ICAgICAoJ2Zhc3QgbW9kZWwnLGYne01PREVMX0ZBU1R9IHtjaHIoMTAwMDMpIGlmIGZvayBl\
'bHNlIGNocigxMDAwNyl9JyksCiAgICAgICAgKCdkZWVwIG1vZGVsJyxmJ3tNT0RFTF9ERUVQ\
'LnNwbGl0KCIvIilbLTFdWzozNV19IHtjaHIoMTAwMDMpIGlmIGRvayBlbHNlIGNocigxMDAw\
'Nyl9JyksCiAgICAgICAgKCd2aXNpb24gbW9kZWwnLGYne01PREVMX1ZJU0lPTn0ge2Nocigx\
'MDAwMykgaWYgYW55KE1PREVMX1ZJU0lPTi5zcGxpdCgiOiIpWzBdIGluIHggZm9yIHggaW4g\
'bW9kZWxzKSBlbHNlIGNocigxMDAwNyl9JyksCiAgICAgICAgKCdtZW1vcmllcycsc3RyKG1j\
'KSksKCdzZXNzaW9ucycsc3RyKHNjKSksCiAgICAgICAgKCd0aW1lJyxkYXRldGltZS5ub3co\
'KS5zdHJmdGltZSgnJVktJW0tJWQgJUg6JU0nKSksCiAgICBdCiAgICByb3dzPScnLmpvaW4o\
'ZiI8ZGl2IGNsYXNzPXN0PjxzcGFuIGNsYXNzPXNrPntrfTwvc3Bhbj48c3BhbiBjbGFzcz1z\
'dj57X2VzYyhzdHIodikpfTwvc3Bhbj48L2Rpdj4iIGZvciBrLHYgaW4gc3RhdHMpCiAgICBy\
'ZXR1cm4gX3NoZWxsKGYiPGRpdiBjbGFzcz1wYWdlPjxkaXYgY2xhc3M9cGg+U3RhdHVzPC9k\
'aXY+e3Jvd3N9PC9kaXY+Iiwnc3RhdHVzJykKCmRlZiBfd2ViX2NoYXRfc3RyZWFtKG1zZywg\
'ZmlsZV9kYXRhPU5vbmUsIGZpbGVfdHlwZT1Ob25lLCBmaWxlX25hbWU9Tm9uZSk6CiAgICB3\
'aXRoIF93ZWJfbG9jazogaGlzdD1saXN0KF93ZWJfaGlzdCkKICAgIGRiPV9kYigpOyBzeXNf\
'cD1fYnVpbGRfc3lzdGVtKGRiKTsgZGIuY2xvc2UoKQogICAgdXNlcl9jb250ZW50PW1zZzsg\
'aW1hZ2VzPU5vbmUKICAgIGlmIGZpbGVfZGF0YToKICAgICAgICBpZiBmaWxlX3R5cGUgYW5k\
'IGZpbGVfdHlwZS5zdGFydHN3aXRoKCdpbWFnZS8nKToKICAgICAgICAgICAgYjY0PWZpbGVf\
'ZGF0YS5zcGxpdCgnLCcsMSlbMV0gaWYgJywnIGluIGZpbGVfZGF0YSBlbHNlIGZpbGVfZGF0\
'YQogICAgICAgICAgICBpbWFnZXM9W2I2NF0KICAgICAgICAgICAgdXNlcl9jb250ZW50PSht\
'c2crJ1xuJyBpZiBtc2cgZWxzZSAnJykrJ1tJbWFnZTogJytzdHIoZmlsZV9uYW1lKSsnXScK\
'ICAgICAgICBlbHNlOgogICAgICAgICAgICB0ZXh0PWZpbGVfZGF0YVs6ODAwMF0gaWYgaXNp\
'bnN0YW5jZShmaWxlX2RhdGEsc3RyKSBlbHNlIGZpbGVfZGF0YS5kZWNvZGUoJ3V0Zi04Jywn\
'cmVwbGFjZScpWzo4MDAwXQogICAgICAgICAgICB1c2VyX2NvbnRlbnQ9KG1zZysnXG5cbicg\
'aWYgbXNnIGVsc2UgJycpKydbRmlsZTogJytzdHIoZmlsZV9uYW1lKSsnXVxuJyt0ZXh0CiAg\
'ICBwcmVfY3R4ID0gX3ByZV9yZXNlYXJjaCh1c2VyX2NvbnRlbnQsIGhpc3Q9aGlzdCkKICAg\
'IGVucmljaGVkX2NvbnRlbnQgPSB1c2VyX2NvbnRlbnQgKyBwcmVfY3R4IGlmIHByZV9jdHgg\
'ZWxzZSB1c2VyX2NvbnRlbnQKICAgIG1zZ3M9W3sncm9sZSc6J3N5c3RlbScsJ2NvbnRlbnQn\
'OnN5c19wfV0raGlzdFstMzA6XStbeydyb2xlJzondXNlcicsJ2NvbnRlbnQnOmVucmljaGVk\
'X2NvbnRlbnR9XQogICAgYnVmPVtdCiAgICB0cnk6CiAgICAgICAgcmVzcCxtb2RlbF91c2Vk\
'PV9zbWFydF9jaGF0KG1zZ3Msb25fdG9rZW49bGFtYmRhIHQ6YnVmLmFwcGVuZCh0KSxpbWFn\
'ZXM9aW1hZ2VzKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgIHlpZWxkIGYn\
'KGVycm9yOiB7ZX0pJzsgcmV0dXJuCiAgICBjbGVhbix0b29scz1fcHJvY2Vzc190b29scyhy\
'ZXNwLF9kYigpKQogICAgaWYgdG9vbHM6CiAgICAgICAgY3R4PSdcblxuJy5qb2luKGYnW3tr\
'fV06XG57dn0nIGZvciBrLHYgaW4gdG9vbHMuaXRlbXMoKSkKICAgICAgICBmbXNncz1tc2dz\
'K1t7J3JvbGUnOid1c2VyJywnY29udGVudCc6ZidbUmVzZWFyY2ggcmVzdWx0c106XG57Y3R4\
'fVxuXG5BbnN3ZXIgdGhlIG9yaWdpbmFsIHF1ZXN0aW9uIGJyaWVmbHkuJ31dCiAgICAgICAg\
'YnVmMj1bXQogICAgICAgIHRyeToKICAgICAgICAgICAgY2xlYW4sXz1fc21hcnRfY2hhdChm\
'bXNncyxvbl90b2tlbj1sYW1iZGEgdDpidWYyLmFwcGVuZCh0KSkKICAgICAgICAgICAgZm9y\
'IHRvayBpbiBidWYyOiB5aWVsZCB0b2sKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg\
'ICAgICAgICBmb3IgdG9rIGluIGJ1ZjogeWllbGQgdG9rCiAgICBlbHNlOgogICAgICAgIGZv\
'ciB0b2sgaW4gYnVmOiB5aWVsZCB0b2sKICAgIHdpdGggX3dlYl9sb2NrOgogICAgICAgIF93\
'ZWJfaGlzdC5hcHBlbmQoeydyb2xlJzondXNlcicsJ2NvbnRlbnQnOnVzZXJfY29udGVudH0p\
'CiAgICAgICAgX3dlYl9oaXN0LmFwcGVuZCh7J3JvbGUnOidhc3Npc3RhbnQnLCdjb250ZW50\
'JzpjbGVhbiBvciByZXNwfSkKICAgICAgICBpZiBsZW4oX3dlYl9oaXN0KT40MDogX3dlYl9o\
'aXN0WzpdPV93ZWJfaGlzdFstNjA6XQogICAgdGhyZWFkaW5nLlRocmVhZCh0YXJnZXQ9X3N0\
'b3JlX21lbW9yeSxhcmdzPShfZGIoKSwKICAgICAgICBbeydyb2xlJzondXNlcicsJ2NvbnRl\
'bnQnOnVzZXJfY29udGVudH0sCiAgICAgICAgIHsncm9sZSc6J2Fzc2lzdGFudCcsJ2NvbnRl\
'bnQnOmNsZWFuIG9yIHJlc3B9XSksZGFlbW9uPVRydWUpLnN0YXJ0KCkKCmRlZiBfc3RhcnRf\
'd2ViKCk6CiAgICBmcm9tIGh0dHAuc2VydmVyIGltcG9ydCBIVFRQU2VydmVyLEJhc2VIVFRQ\
'UmVxdWVzdEhhbmRsZXIKICAgIGZyb20gc29ja2V0c2VydmVyIGltcG9ydCBUaHJlYWRpbmdN\
'aXhJbgogICAgZnJvbSB1cmxsaWIucGFyc2UgaW1wb3J0IHVybHBhcnNlCiAgICBjbGFzcyBU\
'UyhUaHJlYWRpbmdNaXhJbixIVFRQU2VydmVyKToKICAgICAgICBkYWVtb25fdGhyZWFkcz1U\
'cnVlOyBhbGxvd19yZXVzZV9hZGRyZXNzPVRydWUKICAgIGNsYXNzIEgoQmFzZUhUVFBSZXF1\
'ZXN0SGFuZGxlcik6CiAgICAgICAgZGVmIGxvZ19tZXNzYWdlKHNlbGYsKmEpOiBwYXNzCiAg\
'ICAgICAgZGVmIF9zZW5kKHNlbGYsY29kZSxib2R5LGN0PSd0ZXh0L2h0bWw7IGNoYXJzZXQ9\
'dXRmLTgnKToKICAgICAgICAgICAgYj1ib2R5LmVuY29kZSgpIGlmIGlzaW5zdGFuY2UoYm9k\
'eSxzdHIpIGVsc2UgYm9keQogICAgICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoY29kZSkK\
'ICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcignQ29udGVudC1UeXBlJyxjdCkKICAgICAg\
'ICAgICAgc2VsZi5zZW5kX2hlYWRlcignQ29udGVudC1MZW5ndGgnLGxlbihiKSkKICAgICAg\
'ICAgICAgc2VsZi5lbmRfaGVhZGVycygpOyBzZWxmLndmaWxlLndyaXRlKGIpCiAgICAgICAg\
'ZGVmIGRvX1BPU1Qoc2VsZik6CiAgICAgICAgICAgIGxuPWludChzZWxmLmhlYWRlcnMuZ2V0\
'KCdDb250ZW50LUxlbmd0aCcsMCkpCiAgICAgICAgICAgIGJvZHk9c2VsZi5yZmlsZS5yZWFk\
'KGxuKSBpZiBsbiBlbHNlIGInJwogICAgICAgICAgICBwYXRoPXVybHBhcnNlKHNlbGYucGF0\
'aCkucGF0aAogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiBwYXRoPT0nL2Fw\
'aS9jaGF0JzoKICAgICAgICAgICAgICAgICAgICBkYXRhPWpzb24ubG9hZHMoYm9keSkgaWYg\
'Ym9keSBlbHNlIHt9CiAgICAgICAgICAgICAgICAgICAgbXNnPWRhdGEuZ2V0KCdtc2cnLCcn\
'KS5zdHJpcCgpCiAgICAgICAgICAgICAgICAgICAgZmQ9ZGF0YS5nZXQoJ2ZpbGVfZGF0YScp\
'OyBmdD1kYXRhLmdldCgnZmlsZV90eXBlJyk7IGZuPWRhdGEuZ2V0KCdmaWxlX25hbWUnKQog\
'ICAgICAgICAgICAgICAgICAgIGlmIG5vdCBtc2cgYW5kIG5vdCBmZDoKICAgICAgICAgICAg\
'ICAgICAgICAgICAgc2VsZi5fc2VuZCg0MDAsanNvbi5kdW1wcyh7J2Vycm9yJzonZW1wdHkn\
'fSksJ2FwcGxpY2F0aW9uL2pzb24nKTsgcmV0dXJuCiAgICAgICAgICAgICAgICAgICAgc2Vs\
'Zi5zZW5kX3Jlc3BvbnNlKDIwMCkKICAgICAgICAgICAgICAgICAgICBzZWxmLnNlbmRfaGVh\
'ZGVyKCdDb250ZW50LVR5cGUnLCd0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04JykKICAgICAg\
'ICAgICAgICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCdUcmFuc2Zlci1FbmNvZGluZycsJ2No\
'dW5rZWQnKQogICAgICAgICAgICAgICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoJ0NhY2hlLUNv\
'bnRyb2wnLCduby1jYWNoZScpCiAgICAgICAgICAgICAgICAgICAgc2VsZi5lbmRfaGVhZGVy\
'cygpCiAgICAgICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgICAgICBm\
'b3IgY2h1bmsgaW4gX3dlYl9jaGF0X3N0cmVhbShtc2csZmQsZnQsZm4pOgogICAgICAgICAg\
'ICAgICAgICAgICAgICAgICAgaWYgY2h1bms6CiAgICAgICAgICAgICAgICAgICAgICAgICAg\
'ICAgICAgZW5jPWNodW5rLmVuY29kZSgndXRmLTgnLCdyZXBsYWNlJykKICAgICAgICAgICAg\
'ICAgICAgICAgICAgICAgICAgICBzZWxmLndmaWxlLndyaXRlKGYne2xlbihlbmMpOnh9XHJc\
'bicuZW5jb2RlKCkpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi53Zmls\
'ZS53cml0ZShlbmMpOyBzZWxmLndmaWxlLndyaXRlKGInXHJcbicpCiAgICAgICAgICAgICAg\
'ICAgICAgICAgICAgICAgICAgc2VsZi53ZmlsZS5mbHVzaCgpCiAgICAgICAgICAgICAgICAg\
'ICAgICAgIHNlbGYud2ZpbGUud3JpdGUoYicwXHJcblxyXG4nKTsgc2VsZi53ZmlsZS5mbHVz\
'aCgpCiAgICAgICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiBfbG9nKGYn\
'U3RyZWFtIHdyaXRlOiB7ZX0nLCdXQVJOJykKICAgICAgICAgICAgICAgIGVsaWYgcGF0aD09\
'Jy9hcGkvY2xlYXInOgogICAgICAgICAgICAgICAgICAgIGdsb2JhbCBfd2ViX2hpc3QKICAg\
'ICAgICAgICAgICAgICAgICB3aXRoIF93ZWJfbG9jazogX3dlYl9oaXN0PVtdCiAgICAgICAg\
'ICAgICAgICAgICAgc2VsZi5fc2VuZCgyMDAsanNvbi5kdW1wcyh7J29rJzpUcnVlfSksJ2Fw\
'cGxpY2F0aW9uL2pzb24nKQogICAgICAgICAgICAgICAgZWxzZTogc2VsZi5fc2VuZCg0MDQs\
'Yidub3QgZm91bmQnKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAg\
'ICAgICAgICAgICB0cnk6IHNlbGYuX3NlbmQoNTAwLGpzb24uZHVtcHMoeydlcnJvcic6c3Ry\
'KGUpfSksJ2FwcGxpY2F0aW9uL2pzb24nKQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2Vw\
'dGlvbjogcGFzcwogICAgICAgIGRlZiBkb19HRVQoc2VsZik6CiAgICAgICAgICAgIHBhdGg9\
'dXJscGFyc2Uoc2VsZi5wYXRoKS5wYXRoLnJzdHJpcCgnLycpIG9yICcvY2hhdCcKICAgICAg\
'ICAgICAgZGI9X2RiKCkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgaWYgcGF0\
'aCBpbiAoJy8nLCcvIGNoYXQnLCcvY2hhdCcpOiBzZWxmLl9zZW5kKDIwMCxfcGFnZV9jaGF0\
'KCkpCiAgICAgICAgICAgICAgICBlbGlmIHBhdGg9PScvbWVtb3J5Jzogc2VsZi5fc2VuZCgy\
'MDAsX3BhZ2VfbWVtb3J5KGRiKSkKICAgICAgICAgICAgICAgIGVsaWYgcGF0aD09Jy9zdGF0\
'dXMnOiBzZWxmLl9zZW5kKDIwMCxfcGFnZV9zdGF0dXMoZGIpKQogICAgICAgICAgICAgICAg\
'ZWxzZTogc2VsZi5fc2VuZCg0MDQsJzxwcmU+NDA0PC9wcmU+JykKICAgICAgICAgICAgZXhj\
'ZXB0IEV4Y2VwdGlvbiBhcyBlOiBzZWxmLl9zZW5kKDUwMCxmJzxwcmU+e19lc2Moc3RyKGUp\
'KX08L3ByZT4nKQogICAgICAgICAgICBmaW5hbGx5OiBkYi5jbG9zZSgpCiAgICBmb3IgcG9y\
'dCBpbiAoODA4MCw4MDgxLDgwODIpOgogICAgICAgIHRyeToKICAgICAgICAgICAgc3J2PVRT\
'KCgnMC4wLjAuMCcscG9ydCksSCk7IF9sb2coZidXZWIgb24gOntwb3J0fScpOyBzcnYuc2Vy\
'dmVfZm9yZXZlcigpOyBicmVhawogICAgICAgIGV4Y2VwdCBPU0Vycm9yOiBjb250aW51ZQoK\
'ZGVmIG1haW4oKToKICAgIF9sb2coJ05lWGlTIHYzLjAgc3RhcnRpbmcnKQogICAgX3JlZnJl\
'c2hfbW9kZWxzKCkKICAgIHRocmVhZGluZy5UaHJlYWQodGFyZ2V0PV93YXJtdXAsZGFlbW9u\
'PVRydWUpLnN0YXJ0KCkKICAgIHRocmVhZGluZy5UaHJlYWQodGFyZ2V0PV9zdGFydF93ZWIs\
'ZGFlbW9uPVRydWUsbmFtZT0nd2ViJykuc3RhcnQoKQogICAgU09DS19QQVRILnBhcmVudC5t\
'a2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIGlmIFNPQ0tfUEFUSC5leGlz\
'dHMoKToKICAgICAgICB0cnk6IFNPQ0tfUEFUSC51bmxpbmsoKQogICAgICAgIGV4Y2VwdCBF\
'eGNlcHRpb246IHBhc3MKICAgIHNydj1fc29ja2V0LnNvY2tldChfc29ja2V0LkFGX1VOSVgs\
'X3NvY2tldC5TT0NLX1NUUkVBTSkKICAgIHNydi5zZXRzb2Nrb3B0KF9zb2NrZXQuU09MX1NP\
'Q0tFVCxfc29ja2V0LlNPX1JFVVNFQUREUiwxKQogICAgc3J2LmJpbmQoc3RyKFNPQ0tfUEFU\
'SCkpOyBTT0NLX1BBVEguY2htb2QoMG82NjApOyBzcnYubGlzdGVuKDQpCiAgICBfbG9nKGYn\
'U29ja2V0OiB7U09DS19QQVRIfScpCiAgICBkZWYgX3NodXRkb3duKHNpZyxmcmFtZSk6CiAg\
'ICAgICAgX2xvZygnU2h1dGRvd24nKTsgc3J2LmNsb3NlKCkKICAgICAgICB0cnk6IFNPQ0tf\
'UEFUSC51bmxpbmsoKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246IHBhc3MKICAgICAgICBz\
'eXMuZXhpdCgwKQogICAgc2lnbmFsLnNpZ25hbChzaWduYWwuU0lHVEVSTSxfc2h1dGRvd24p\
'CiAgICBzaWduYWwuc2lnbmFsKHNpZ25hbC5TSUdJTlQsX3NodXRkb3duKQogICAgd2hpbGUg\
'VHJ1ZToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGNzb2NrLF89c3J2LmFjY2VwdCgpOyBk\
'Yj1fZGIoKTsgcz1TZXNzaW9uKGNzb2NrLGRiKQogICAgICAgICAgICB0aHJlYWRpbmcuVGhy\
'ZWFkKHRhcmdldD1zLnJ1bixkYWVtb249VHJ1ZSxuYW1lPSdzZXNzaW9uJykuc3RhcnQoKQog\
'ICAgICAgIGV4Y2VwdCBPU0Vycm9yOiBicmVhawogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g\
'YXMgZTogX2xvZyhmJ0FjY2VwdDoge2V9JywnRVJST1InKQogICAgX2xvZygnRGFlbW9uIHN0\
'b3BwZWQnKQoKaWYgX19uYW1lX189PSdfX21haW5fXyc6CiAgICBtYWluKCk=' | base64 -d > "$NEXIS_DATA/nexis-daemon.py"
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