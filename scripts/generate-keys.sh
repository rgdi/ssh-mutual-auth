#!/usr/bin/env bash
# Generate a fresh ed25519 key pair for this server.
# Private key: /keys/id_ed25519 (mode 600, root only)
# Public key:  /keys/id_ed25519.pub (mode 644)
set -euo pipefail

KEY_DIR=/keys
PRIV="${KEY_DIR}/id_ed25519"
PUB="${PRIV}.pub"
BACKUP_DIR="${KEY_DIR}/backup"

log() { echo "[$(date -u +%FT%TZ)] [generate-keys] $*"; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$KEY_DIR" "$BACKUP_DIR"

# Back up existing key atomically
if [[ -f "$PRIV" ]]; then
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    mv "$PRIV"     "${BACKUP_DIR}/id_ed25519.${TS}"
    mv "$PUB"      "${BACKUP_DIR}/id_ed25519.pub.${TS}" 2>/dev/null || true
    log "Old key archived as ${TS}"
fi

# Generate new ed25519 key pair (no passphrase — container manages access)
ssh-keygen -t ed25519 -C "ssh-mutual@${SERVER_NAME:-$(hostname)}" \
           -f "$PRIV" -N "" -q

chmod 600 "$PRIV"
chmod 644 "$PUB"
chown root:root "$PRIV" "$PUB"

# Purge backups older than 7 days
find "$BACKUP_DIR" -type f -mtime +7 -delete 2>/dev/null || true

PUB_FINGERPRINT=$(ssh-keygen -lf "$PUB" | awk '{print $2}')
log "New key generated. Fingerprint: ${PUB_FINGERPRINT}"
echo "GENERATED:$(date -u +%FT%TZ):${PUB_FINGERPRINT}" >> "${KEY_DIR}/key-history.log"
