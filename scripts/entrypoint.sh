#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_NAME:?SERVER_NAME is required}"
: "${API_SECRET:?API_SECRET is required}"
: "${CF_TUNNEL_TOKEN:=}"   # optional — cloudflared already installed on host
: "${SSH_USER:=sshuser}"
: "${SSH_USER_SHELL:=/bin/bash}"
: "${PEER_SSH_HOSTS:=}"

LOG=/var/log/ssh-auth/entrypoint.log
mkdir -p "$(dirname "$LOG")" /var/log/ssh-auth
exec > >(tee -a "$LOG") 2>&1

echo "[$(date -u +%FT%TZ)] Starting ssh-mutual-auth on ${SERVER_NAME}"

# Create SSH user if absent and grant full sudo
if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -s "$SSH_USER_SHELL" -G sudo "$SSH_USER"
    mkdir -p "/home/${SSH_USER}/.ssh"
    chmod 700 "/home/${SSH_USER}/.ssh"
    chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
fi
# Idempotent: ensure sudo entry even if user pre-existed
echo "${SSH_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SSH_USER}"
chmod 0440 "/etc/sudoers.d/${SSH_USER}"
echo "[$(date -u +%FT%TZ)] sudo granted to ${SSH_USER} (NOPASSWD:ALL)"

# Regenerate host keys if missing
ssh-keygen -A

# Generate server identity key if absent
if [[ ! -f /keys/id_ed25519 ]]; then
    echo "[$(date -u +%FT%TZ)] No server key found — generating..."
    /scripts/generate-keys.sh
fi

# Ensure authorized_keys exists with correct ownership (real system SSH)
touch "/home/${SSH_USER}/.ssh/authorized_keys"
chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"
chown "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh/authorized_keys"
echo "[$(date -u +%FT%TZ)] SSH user ${SSH_USER} home: /home/${SSH_USER}/.ssh/"

# Write PEER_SSH_HOSTS into cron environment (cron strips env vars)
printf 'PEER_SSH_HOSTS=%s\n*/5 * * * * root /scripts/check-connectivity.sh >> /var/log/ssh-auth/connectivity.log 2>&1\n' \
    "$PEER_SSH_HOSTS" >> /etc/cron.d/ssh-rotation

# Start cron for scheduled tasks
cron

# Start SSH daemon
/usr/sbin/sshd -e

# Start Cloudflare Tunnel (cloudflared pre-installed on host, available via PATH or bind-mount)
CF_PID=""
if [[ -n "${CF_TUNNEL_TOKEN}" ]]; then
    cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
    CF_PID=$!
    echo "[$(date -u +%FT%TZ)] cloudflared started PID=${CF_PID}"
else
    echo "[$(date -u +%FT%TZ)] CF_TUNNEL_TOKEN not set — run cloudflared on the host"
fi

# Start API server
/app/venv/bin/python /app/app.py &
API_PID=$!

echo "[$(date -u +%FT%TZ)] All services started. cf=${CF_PID:-host} api=${API_PID}"

# Wait; restart API if it dies
while true; do
    if ! kill -0 "$API_PID" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] API died — restarting"
        /app/venv/bin/python /app/app.py &
        API_PID=$!
    fi
    sleep 15
done
