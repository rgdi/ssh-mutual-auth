#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_NAME:?SERVER_NAME is required}"
: "${API_SECRET:?API_SECRET is required}"
: "${CF_TUNNEL_TOKEN:?CF_TUNNEL_TOKEN is required}"
: "${SSH_USER:=sshuser}"
: "${SSH_USER_SHELL:=/bin/bash}"

LOG=/var/log/ssh-auth/entrypoint.log
mkdir -p "$(dirname "$LOG")" /var/log/ssh-auth
exec > >(tee -a "$LOG") 2>&1

echo "[$(date -u +%FT%TZ)] Starting ssh-mutual-auth on ${SERVER_NAME}"

# Create SSH user if absent
if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -s "$SSH_USER_SHELL" "$SSH_USER"
    mkdir -p "/home/${SSH_USER}/.ssh"
    chmod 700 "/home/${SSH_USER}/.ssh"
    chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
fi

# Regenerate host keys if missing
ssh-keygen -A

# Generate server identity key if absent
if [[ ! -f /keys/id_ed25519 ]]; then
    echo "[$(date -u +%FT%TZ)] No server key found — generating..."
    /scripts/generate-keys.sh
fi

# Start cron for scheduled tasks
cron

# Start SSH daemon
/usr/sbin/sshd -e

# Start Cloudflare Tunnel (exposes API + SSH via tunnel only)
cloudflared tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" &
CF_PID=$!

# Start API server
/app/venv/bin/python /app/app.py &
API_PID=$!

echo "[$(date -u +%FT%TZ)] All services started. PID cf=${CF_PID} api=${API_PID}"

# Wait; restart API if it dies
while true; do
    if ! kill -0 "$API_PID" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] API died — restarting"
        /app/venv/bin/python /app/app.py &
        API_PID=$!
    fi
    sleep 15
done
