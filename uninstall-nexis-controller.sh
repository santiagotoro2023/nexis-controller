#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RST='\033[0m'

ask() {
    local prompt="$1" default="${2:-n}"
    local yn
    read -r -p "$(echo -e "${YELLOW}?${RST} ${prompt} [y/N] ")" yn
    [[ "${yn,,}" == "y" ]]
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root (sudo bash uninstall-nexis-controller.sh)${RST}" >&2
    exit 1
fi

echo -e "${BOLD}NeXiS Controller — Uninstaller${RST}"
echo "────────────────────────────────────────"
echo ""
echo "This will remove the nexis-controller service, package, and binary."
echo "You will be asked separately about data you may want to keep."
echo ""

# ── Stop & disable service ────────────────────────────────────────────────────
echo -e "==> Stopping service..."
systemctl stop nexis-controller 2>/dev/null || true
systemctl disable nexis-controller 2>/dev/null || true

# ── Remove package ────────────────────────────────────────────────────────────
echo -e "==> Removing nexis-controller package..."
if dpkg -l nexis-controller &>/dev/null; then
    dpkg --purge nexis-controller || true
else
    echo "    Package not found via dpkg — cleaning manually."
    rm -rf /opt/nexis-controller
    rm -f  /etc/systemd/system/nexis-controller.service
    rm -f  /usr/local/bin/nexis
    systemctl daemon-reload 2>/dev/null || true
fi

# ── Interactive: Voice / TTS models ──────────────────────────────────────────
VOICE_DIR="${HOME}/.local/share/nexis/voice"
if [[ -d "$VOICE_DIR" ]] && [[ -n "$(ls -A "$VOICE_DIR" 2>/dev/null)" ]]; then
    echo ""
    echo -e "  Voice/TTS models found at: ${BOLD}${VOICE_DIR}${RST}"
    ls -lh "$VOICE_DIR" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    if ask "Remove voice/TTS models?"; then
        rm -rf "$VOICE_DIR"
        echo -e "    ${GREEN}Removed.${RST}"
    else
        echo "    Kept."
    fi
fi

# ── Interactive: Ollama models ────────────────────────────────────────────────
echo ""
if command -v ollama &>/dev/null; then
    OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
    if [[ -n "$OLLAMA_MODELS" ]]; then
        echo -e "  Ollama models currently installed:"
        echo "$OLLAMA_MODELS" | sed 's/^/    /'
        echo ""
        if ask "Remove ALL Ollama models?"; then
            while IFS= read -r model; do
                [[ -z "$model" ]] && continue
                echo -n "    Removing $model ... "
                ollama rm "$model" 2>/dev/null && echo "done" || echo "failed"
            done <<< "$OLLAMA_MODELS"
        else
            echo "  Skipping — you can remove individual models with: ollama rm <model>"
        fi
    else
        echo "  No Ollama models found."
    fi
else
    echo "  Ollama not installed — skipping model removal."
fi

# ── Interactive: Memory (facts database) ─────────────────────────────────────
DB_PATH="${HOME}/.local/share/nexis/memory/nexis.db"
if [[ -f "$DB_PATH" ]]; then
    MEM_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "?")
    echo ""
    echo -e "  Memory database: ${BOLD}${DB_PATH}${RST} (${MEM_COUNT} stored facts)"
    if ask "Remove all stored memories?"; then
        sqlite3 "$DB_PATH" "DELETE FROM memories;" 2>/dev/null || true
        echo -e "    ${GREEN}Memories cleared.${RST}"
    else
        echo "    Kept."
    fi
fi

# ── Interactive: Chat history ─────────────────────────────────────────────────
if [[ -f "$DB_PATH" ]]; then
    HIST_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chat_history;" 2>/dev/null || echo "?")
    echo ""
    echo -e "  Chat history: ${BOLD}${DB_PATH}${RST} (${HIST_COUNT} messages)"
    if ask "Remove all chat history?"; then
        sqlite3 "$DB_PATH" "DELETE FROM chat_history; DELETE FROM sessions;" 2>/dev/null || true
        echo -e "    ${GREEN}Chat history cleared.${RST}"
    else
        echo "    Kept."
    fi
fi

# ── Interactive: Config & credentials ────────────────────────────────────────
CONF_DIR="${HOME}/.config/nexis"
DATA_DIR="${HOME}/.local/share/nexis"
if [[ -d "$CONF_DIR" ]]; then
    echo ""
    echo -e "  Config directory: ${BOLD}${CONF_DIR}${RST}"
    echo "    Contains: TLS certificates, auth credentials, integrations, schedules"
    if ask "Remove config directory (credentials, TLS certs, schedules)?"; then
        rm -rf "$CONF_DIR"
        echo -e "    ${GREEN}Removed.${RST}"
    else
        echo "    Kept."
    fi
fi

# Remove data dir if now empty
if [[ -d "$DATA_DIR" ]] && [[ -z "$(find "$DATA_DIR" -mindepth 1 2>/dev/null | head -1)" ]]; then
    rm -rf "$DATA_DIR"
fi

echo ""
echo -e "${GREEN}Done.${RST} NeXiS Controller has been uninstalled."
