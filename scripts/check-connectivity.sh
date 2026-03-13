#!/usr/bin/env bash
# Test SSH connectivity to peer servers via Cloudflare Tunnel ProxyCommand.
# Writes JSON results to /tmp/peer-status.json consumed by API /status endpoint.
# Env: PEER_SSH_HOSTS  comma-separated  user@hostname  (hostname = CF tunnel hostname)
# Example: root@ukssh.rgodim.org,ubuntu@ukssh2.rgodim.org
set -euo pipefail

: "${PEER_SSH_HOSTS:=}"
STATUS_FILE=/tmp/peer-status.json
LOG=/var/log/ssh-auth/connectivity.log
SSH_KEY=/keys/id_ed25519

exec >> "$LOG" 2>&1
log() { echo "[$(date -u +%FT%TZ)] [connectivity] $*"; }

[[ -z "$PEER_SSH_HOSTS" ]] && { log "No PEER_SSH_HOSTS configured — skipping"; exit 0; }
[[ ! -f "$SSH_KEY" ]]      && { log "SSH key not found — skipping"; exit 0; }

RESULTS=()
IFS=',' read -ra ENTRIES <<< "$PEER_SSH_HOSTS"

for ENTRY in "${ENTRIES[@]}"; do
    ENTRY=$(echo "$ENTRY" | tr -d ' ')
    [[ -z "$ENTRY" ]] && continue

    USER=$(echo "$ENTRY" | cut -d@ -f1)
    HOST=$(echo "$ENTRY" | cut -d@ -f2)
    TS=$(date -u +%FT%TZ)
    START_MS=$(date +%s%3N)
    STATUS="unreachable"
    LATENCY=0

    log "Testing ${USER}@${HOST} via cloudflared ProxyCommand..."

    if timeout 25 ssh \
        -o "ProxyCommand=cloudflared access ssh --hostname ${HOST}" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "ConnectTimeout=15" \
        -o "BatchMode=yes" \
        -o "LogLevel=ERROR" \
        -i "${SSH_KEY}" \
        "${USER}@${HOST}" "echo SSH_CONNECTIVITY_OK" 2>/dev/null \
        | grep -q "SSH_CONNECTIVITY_OK"; then
        LATENCY=$(( $(date +%s%3N) - START_MS ))
        STATUS="ok"
        log "OK ${HOST} latency=${LATENCY}ms"
    else
        log "UNREACHABLE ${HOST}"
    fi

    RESULTS+=("${HOST}|${USER}|${STATUS}|${LATENCY}|${TS}")
done

if (( ${#RESULTS[@]} == 0 )); then
    log "No valid results to report — skipping status file update"
    exit 0
fi

# Build JSON atomically via Python (avoids bash quoting edge cases)
TMP=$(mktemp /tmp/peer-status.XXXXXX)

python3 -c "
import sys, json
out = {}
for entry in sys.argv[1:]:
    parts = entry.split('|', 4)
    if len(parts) != 5:
        continue
    host, user, status, latency, ts = parts
    out[host] = {
        'user': user, 'host': host, 'status': status,
        'latency_ms': int(latency) if status == 'ok' else None,
        'last_check': ts,
    }
print(json.dumps(out, indent=2))
" ${RESULTS[@]+"${RESULTS[@]}"} > "$TMP"

mv "$TMP" "$STATUS_FILE"
chmod 644 "$STATUS_FILE"
log "Status file updated: ${STATUS_FILE}"
