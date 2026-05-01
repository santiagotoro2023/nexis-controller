#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RST='\033[0m'

# Read from /dev/tty so prompts work even when piped via curl | bash
ask() {
    local prompt="$1"
    local yn
    echo -en "${YELLOW}?${RST} ${prompt} [y/N] " > /dev/tty
    read -r yn < /dev/tty
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
echo "==> Stopping service..."
systemctl stop nexis-controller 2>/dev/null || true
systemctl disable nexis-controller 2>/dev/null || true

# ── Remove package ────────────────────────────────────────────────────────────
echo "==> Removing nexis-controller package..."
if dpkg -l nexis-controller &>/dev/null; then
    # Try normal purge first; fall back to force if package state is broken
    dpkg --purge nexis-controller 2>/dev/null \
        || dpkg --purge --force-remove-reinstreq nexis-controller 2>/dev/null \
        || true
fi

# Clean up any leftover files the package may not have removed
rm -rf /opt/nexis-controller
rm -f  /etc/systemd/system/nexis-controller.service
rm -f  /usr/local/bin/nexis
systemctl daemon-reload 2>/dev/null || true

echo ""

# ── Interactive: Voice / TTS models ──────────────────────────────────────────
VOICE_DIR="${HOME}/.local/share/nexis/voice"
if [[ -d "$VOICE_DIR" ]] && [[ -n "$(ls -A "$VOICE_DIR" 2>/dev/null)" ]]; then
    SIZE=$(du -sh "$VOICE_DIR" 2>/dev/null | cut -f1)
    echo -e "  Voice/TTS models: ${BOLD}${VOICE_DIR}${RST} (${SIZE})"
    ls -lh "$VOICE_DIR" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    if ask "Remove voice/TTS models?"; then
        rm -rf "$VOICE_DIR"
        echo -e "    ${GREEN}Removed.${RST}"
    else
        echo "    Kept."
    fi
    echo ""
fi

# ── Interactive: Ollama models ────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
    OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
    if [[ -n "$OLLAMA_MODELS" ]]; then
        echo "  Ollama models currently installed:"
        echo "$OLLAMA_MODELS" | sed 's/^/    /'
        echo ""
        if ask "Remove ALL Ollama models? (this affects any service using Ollama)"; then
            while IFS= read -r model; do
                [[ -z "$model" ]] && continue
                echo -n "    Removing $model ... "
                ollama rm "$model" 2>/dev/null && echo "done" || echo "failed (skipped)"
            done <<< "$OLLAMA_MODELS"
            echo -e "    ${GREEN}Done.${RST}"
        else
            echo "    Kept. Remove individually with: ollama rm <model>"
        fi
        echo ""
    fi
fi

# ── Interactive: Registered devices ──────────────────────────────────────────
DB_PATH="${HOME}/.local/share/nexis/memory/nexis.db"
if [[ -f "$DB_PATH" ]]; then
    DEV_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM devices;" 2>/dev/null || echo "0")
    if [[ "$DEV_COUNT" -gt 0 ]]; then
        echo -e "  Registered devices in database: ${BOLD}${DEV_COUNT}${RST}"
        sqlite3 "$DB_PATH" \
            "SELECT '    ' || device_id || ' (' || COALESCE(role,'no role') || ')' FROM devices LIMIT 20;" \
            2>/dev/null || true
        if ask "Remove all registered devices?"; then
            sqlite3 "$DB_PATH" "DELETE FROM devices; DELETE FROM device_commands;" 2>/dev/null || true
            echo -e "    ${GREEN}Devices cleared.${RST}"
        else
            echo "    Kept."
        fi
        echo ""
    fi
fi

# ── Interactive: Memory (facts) ───────────────────────────────────────────────
if [[ -f "$DB_PATH" ]]; then
    MEM_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "0")
    echo -e "  Stored memories: ${BOLD}${MEM_COUNT} facts${RST}"
    if ask "Remove all stored memories?"; then
        sqlite3 "$DB_PATH" "DELETE FROM memories;" 2>/dev/null || true
        echo -e "    ${GREEN}Cleared.${RST}"
    else
        echo "    Kept."
    fi
    echo ""
fi

# ── Interactive: Chat history ─────────────────────────────────────────────────
if [[ -f "$DB_PATH" ]]; then
    HIST_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chat_history;" 2>/dev/null || echo "0")
    echo -e "  Chat history: ${BOLD}${HIST_COUNT} messages${RST}"
    if ask "Remove all chat history and sessions?"; then
        sqlite3 "$DB_PATH" "DELETE FROM chat_history; DELETE FROM sessions;" 2>/dev/null || true
        echo -e "    ${GREEN}Cleared.${RST}"
    else
        echo "    Kept."
    fi
    echo ""
fi

# Remove database file if all tables are now empty
if [[ -f "$DB_PATH" ]]; then
    TOTAL=$(sqlite3 "$DB_PATH" \
        "SELECT (SELECT COUNT(*) FROM memories) + (SELECT COUNT(*) FROM chat_history) + (SELECT COUNT(*) FROM devices);" \
        2>/dev/null || echo "1")
    if [[ "$TOTAL" == "0" ]]; then
        rm -f "$DB_PATH"
        rmdir "$(dirname "$DB_PATH")" 2>/dev/null || true
    fi
fi

# ── Interactive: Config & credentials ────────────────────────────────────────
CONF_DIR="${HOME}/.config/nexis"
if [[ -d "$CONF_DIR" ]]; then
    echo -e "  Config directory: ${BOLD}${CONF_DIR}${RST}"
    echo "    Contains: TLS certificates, auth credentials, integrations, schedules"
    if ask "Remove config directory?"; then
        rm -rf "$CONF_DIR"
        echo -e "    ${GREEN}Removed.${RST}"
    else
        echo "    Kept."
    fi
    echo ""
fi

# Remove data dir if empty
DATA_DIR="${HOME}/.local/share/nexis"
if [[ -d "$DATA_DIR" ]] && [[ -z "$(find "$DATA_DIR" -mindepth 1 2>/dev/null | head -1)" ]]; then
    rm -rf "$DATA_DIR"
fi

echo -e "${GREEN}Done.${RST} NeXiS Controller has been uninstalled."
