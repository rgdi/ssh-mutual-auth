#!/usr/bin/env bash
# Fetch peer public keys via API, verify HMAC signature, update authorized_keys.
# Runs every 5 minutes via cron. Safe to run concurrently (uses atomic write).
set -euo pipefail

: "${API_SECRET:?}"
: "${PEER_API_URLS:=}"
: "${SSH_USER:=sshuser}"
: "${SERVER_NAME:=server1}"

PEER_API_SECRET="${PEER_API_SECRET:-$API_SECRET}"
AUTH_KEYS="/home/${SSH_USER}/.ssh/authorized_keys"
TMP_KEYS=$(mktemp /tmp/auth_keys.XXXXXX)
LOG=/var/log/ssh-auth/auth-update.log

exec >> "$LOG" 2>&1
trap 'rm -f "$TMP_KEYS"' EXIT

log() { echo "[$(date -u +%FT%TZ)] [update-auth-keys] $*"; }

[[ -z "$PEER_API_URLS" ]] && { log "No PEER_API_URLS set — skipping"; exit 0; }

# Derive bearer token from shared secret (mirrors api/app.py logic)
BEARER=$(echo -n "ssh-auth-v1" | \
    openssl dgst -sha256 -hmac "$PEER_API_SECRET" | awk '{print $2}')

MAX_AGE=300  # Reject responses older than 5 minutes
UPDATED=0

IFS=',' read -ra PEERS <<< "$PEER_API_URLS"
for PEER_URL in "${PEERS[@]}"; do
    PEER_URL=$(echo "$PEER_URL" | tr -d ' ')
    log "Fetching public key from ${PEER_URL}"

    RESPONSE=$(curl -sf --max-time 15 \
        -H "Authorization: Bearer ${BEARER}" \
        "${PEER_URL}/public-key") || { log "WARN: Failed to reach ${PEER_URL}"; continue; }

    # Parse fields
    PEER_HOSTNAME=$(echo "$RESPONSE" | jq -r '.hostname // empty')
    PUBLIC_KEY=$(echo    "$RESPONSE" | jq -r '.public_key // empty')
    TIMESTAMP=$(echo    "$RESPONSE" | jq -r '.timestamp // 0')
    SIGNATURE=$(echo    "$RESPONSE" | jq -r '.signature // empty')

    [[ -z "$PUBLIC_KEY" || -z "$SIGNATURE" || -z "$PEER_HOSTNAME" ]] && {
        log "ERROR: Malformed response from ${PEER_URL}"; continue; }

    # Replay-protection: reject stale responses
    NOW=$(date +%s)
    AGE=$(( NOW - TIMESTAMP ))
    if (( AGE > MAX_AGE || AGE < -60 )); then
        log "ERROR: Response timestamp out of window (age=${AGE}s) from ${PEER_HOSTNAME}"; continue
    fi

    # Verify HMAC signature (exclude 'signature' field)
    VERIFY_PAYLOAD=$(echo "$RESPONSE" | jq -c 'del(.signature)' | jq -Sc .)
    EXPECTED_SIG=$(echo -n "$VERIFY_PAYLOAD" | \
        openssl dgst -sha256 -hmac "$PEER_API_SECRET" | awk '{print $2}')

    if [[ "$SIGNATURE" != "$EXPECTED_SIG" ]]; then
        log "ERROR: Signature mismatch for ${PEER_HOSTNAME} — REJECTING KEY"
        continue
    fi

    # Validate key format
    if ! echo "$PUBLIC_KEY" | ssh-keygen -lf - >/dev/null 2>&1; then
        log "ERROR: Invalid SSH key format from ${PEER_HOSTNAME}"; continue
    fi

    echo "# peer:${PEER_HOSTNAME} updated:$(date -u +%FT%TZ)" >> "$TMP_KEYS"
    echo "$PUBLIC_KEY" >> "$TMP_KEYS"
    log "Verified and accepted key from ${PEER_HOSTNAME}"
    UPDATED=$(( UPDATED + 1 ))
done

if (( UPDATED == 0 )); then
    log "No valid peer keys retrieved — authorized_keys unchanged"
    exit 0
fi

# Log explicit revocations: keys in current file but NOT in new set
REVOKE_LOG=/var/log/ssh-auth/revocations.log
if [[ -f "$AUTH_KEYS" ]]; then
    while IFS= read -r LINE; do
        [[ "$LINE" =~ ^#  ]] && continue
        [[ -z "$LINE"     ]] && continue
        if ! grep -qF "$LINE" "$TMP_KEYS"; then
            echo "[$(date -u +%FT%TZ)] REVOKED key on ${SERVER_NAME}: ${LINE:0:60}..." >> "$REVOKE_LOG"
            log "REVOKED stale key: ${LINE:0:60}..."
        fi
    done < "$AUTH_KEYS"
fi

# Atomic replacement — sets real system SSH permissions
install -m 600 -o "$SSH_USER" -g "$SSH_USER" "$TMP_KEYS" "$AUTH_KEYS"
log "authorized_keys updated with ${UPDATED} peer key(s) at ${AUTH_KEYS}"
