#!/usr/bin/env bash
set -euo pipefail

REPO="avov53/fluxusui"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

INSTALL_DIR="/opt/fluxchat"
DATA_DIR="/var/lib/fluxchat"
SERVICE_FILE="/etc/systemd/system/fluxchat.service"
SERVER_BIN="${INSTALL_DIR}/FluxChat.Server"
FLUXUS_BIN="/usr/local/bin/fluxus"
PORT="42800"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash <(curl -Ls ${BASE_URL}/install.sh)"
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Installing dependency: $1"
    apt-get update
    apt-get install -y "$1"
  fi
}

download() {
  local url="$1"
  local target="$2"
  local tmp="${target}.tmp"
  curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$url"
  chmod +x "$tmp"
  mv "$tmp" "$target"
}

echo "FluxChat Relay installer"
echo "Repository: https://github.com/${REPO}"
echo

need_cmd curl

mkdir -p "$INSTALL_DIR" "$DATA_DIR"

echo "Downloading server..."
download "${BASE_URL}/bin/FluxChat.Server" "$SERVER_BIN"

echo "Downloading fluxus admin CLI..."
download "${BASE_URL}/bin/fluxus" "$FLUXUS_BIN"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=FluxChat Relay Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${SERVER_BIN}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" || true
fi

systemctl daemon-reload
systemctl enable --now fluxchat
systemctl restart fluxchat

echo
echo "FluxChat Relay installed or updated."
echo "Persistent data kept in: ${DATA_DIR}"
echo "Admin menu: fluxus"
echo "Service status: systemctl status fluxchat"
echo
echo "Create an invite code:"
echo "  fluxus"
