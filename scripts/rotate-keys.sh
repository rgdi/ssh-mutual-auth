#!/usr/bin/env bash
# Rotate the server's SSH key pair every 24 hours.
# Called by cron; also updates authorized_keys on remote peers after rotation.
set -euo pipefail

: "${SERVER_NAME:?}"
: "${API_SECRET:?}"
: "${PEER_API_URLS:=}"
: "${PEER_API_SECRET:?}"
: "${WEBHOOK_URL:=}"

LOG=/var/log/ssh-auth/key-rotation.log
exec >> "$LOG" 2>&1

log() { echo "[$(date -u +%FT%TZ)] [rotate-keys] $*"; }

LOCK=/tmp/rotate-keys.lock
exec 9>"$LOCK"
flock -n 9 || { log "Another rotation is running — skipping"; exit 0; }

log "Starting 24-hour key rotation for ${SERVER_NAME}"

# Generate new key
/scripts/generate-keys.sh

FINGERPRINT=$(ssh-keygen -lf /keys/id_ed25519.pub | awk '{print $2}')
log "New fingerprint: ${FINGERPRINT}"

# Force peers to pull updated key immediately
if [[ -n "$PEER_API_URLS" ]]; then
    log "Triggering peer authorized_keys update..."
    /scripts/update-authorized-keys.sh
fi

# Notify via webhook if configured
if [[ -n "$WEBHOOK_URL" ]]; then
    PAYLOAD=$(jq -n \
        --arg server "$SERVER_NAME" \
        --arg fp "$FINGERPRINT" \
        --arg ts "$(date -u +%FT%TZ)" \
        '{server:$server, event:"key_rotated", fingerprint:$fp, timestamp:$ts}')
    curl -sf -X POST "$WEBHOOK_URL" \
         -H "Content-Type: application/json" \
         -d "$PAYLOAD" \
         --max-time 10 || log "Webhook notification failed (non-fatal)"
fi

log "Key rotation complete"
flock -u 9
