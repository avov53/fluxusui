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
ETC_DIR="/etc/fluxchat"
TURN_SECRET_FILE="${ETC_DIR}/turn-secret"
TURN_PORT="3478"
TURN_MIN_PORT="49160"
TURN_MAX_PORT="49200"
TURN_REALM="fluxchat"

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
need_cmd openssl

if ! dpkg -s coturn >/dev/null 2>&1; then
  echo "Installing dependency: coturn"
  apt-get update
  apt-get install -y coturn
fi

mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$ETC_DIR"

if [ ! -s "$TURN_SECRET_FILE" ]; then
  openssl rand -base64 32 > "$TURN_SECRET_FILE"
  chmod 600 "$TURN_SECRET_FILE"
fi

TURN_SECRET="$(cat "$TURN_SECRET_FILE")"
PUBLIC_HOST="${FLUXCHAT_PUBLIC_HOST:-}"
if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST="$(curl -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
fi
if [ -z "$PUBLIC_HOST" ]; then
  echo "Could not detect public VPS IP. Set FLUXCHAT_PUBLIC_HOST and rerun."
  exit 1
fi

echo "Downloading server..."
download "${BASE_URL}/dist-server-linux/FluxChat.Server" "$SERVER_BIN"

echo "Downloading fluxus admin CLI..."
download "${BASE_URL}/dist-server-linux/fluxus" "$FLUXUS_BIN"

echo "Configuring TURN relay..."
cat > /etc/turnserver.conf <<EOF
listening-port=${TURN_PORT}
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${TURN_REALM}
server-name=${TURN_REALM}
min-port=${TURN_MIN_PORT}
max-port=${TURN_MAX_PORT}
no-multicast-peers
no-cli
simple-log
EOF

if [ -f /etc/default/coturn ]; then
  if grep -q '^#\?TURNSERVER_ENABLED=' /etc/default/coturn; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  else
    echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
  fi
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=FluxChat Relay Server
After=network-online.target coturn.service
Wants=network-online.target coturn.service

[Service]
ExecStart=${SERVER_BIN}
Restart=always
RestartSec=3
User=root
Environment="FLUXCHAT_TURN_HOST=${PUBLIC_HOST}"
Environment="FLUXCHAT_TURN_SECRET=${TURN_SECRET}"
Environment="FLUXCHAT_TURN_REALM=${TURN_REALM}"
Environment="FLUXCHAT_TURN_PORT=${TURN_PORT}"

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" || true
  ufw allow "${PORT}/udp" || true
  ufw allow "${TURN_PORT}/tcp" || true
  ufw allow "${TURN_PORT}/udp" || true
  ufw allow "${TURN_MIN_PORT}:${TURN_MAX_PORT}/udp" || true
fi

systemctl daemon-reload
systemctl enable --now coturn
systemctl restart coturn
systemctl enable --now fluxchat
systemctl restart fluxchat

echo
echo "FluxChat Relay installed or updated."
echo "Persistent data kept in: ${DATA_DIR}"
echo "TURN public host: ${PUBLIC_HOST}"
echo "TURN ports: ${TURN_PORT}/tcp+udp and ${TURN_MIN_PORT}-${TURN_MAX_PORT}/udp"
echo "Admin menu: fluxus"
echo "Service status: systemctl status fluxchat"
echo "TURN status: systemctl status coturn"
echo
echo "Create an invite code:"
echo "  fluxus"
