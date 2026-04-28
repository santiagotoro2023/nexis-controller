#!/usr/bin/env bash
set -euo pipefail

REPO="santiagotoro2023/nexis-controller"
INSTALL_DIR="/opt/nexis-controller"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo bash install.sh)" >&2
  exit 1
fi

echo "==> Fetching latest release..."
API="https://api.github.com/repos/${REPO}/releases/latest"
DEB_URL=$(curl -fsSL "$API" | python3 -c "
import sys, json
assets = json.load(sys.stdin)['assets']
deb = next(a['browser_download_url'] for a in assets if a['name'].endswith('.deb'))
print(deb)
")

TMP=$(mktemp -d)
DEB="${TMP}/nexis-controller.deb"

echo "==> Downloading ${DEB_URL##*/}..."
curl -fsSL -o "$DEB" "$DEB_URL"

echo "==> Installing..."
dpkg -i "$DEB"

rm -rf "$TMP"

echo ""
echo "Done. Access the web UI at https://$(hostname -I | awk '{print $1}'):8443"
