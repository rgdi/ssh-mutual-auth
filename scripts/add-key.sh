#!/usr/bin/env bash
# Add a public SSH key to authorized_keys manually.
# Use this to grant access to a personal key or admin key outside of peer sync.
# Usage: docker exec ssh-mutual-auth /scripts/add-key.sh "ssh-ed25519 AAAA... comment"
#    or: docker exec -i ssh-mutual-auth /scripts/add-key.sh  (reads from stdin)
set -euo pipefail

: "${SSH_USER:=sshuser}"
AUTH_KEYS="/home/${SSH_USER}/.ssh/authorized_keys"

if [[ $# -ge 1 ]]; then
    KEY="$*"
else
    echo "Paste public key and press Enter, then Ctrl+D:"
    KEY=$(cat)
fi

[[ -z "$KEY" ]] && { echo "ERROR: no key provided"; exit 1; }

# Basic format validation
if ! echo "$KEY" | ssh-keygen -lf - >/dev/null 2>&1; then
    echo "ERROR: invalid SSH public key format"
    exit 1
fi

# Prevent duplicates
if grep -qF "$KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "Key already present in ${AUTH_KEYS}"
    exit 0
fi

echo "# manually-added:$(date -u +%FT%TZ)" >> "$AUTH_KEYS"
echo "$KEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "${SSH_USER}:${SSH_USER}" "$AUTH_KEYS"

FINGERPRINT=$(echo "$KEY" | ssh-keygen -lf - | awk '{print $2}')
echo "Added key ${FINGERPRINT} to ${AUTH_KEYS}"
echo "[$(date -u +%FT%TZ)] MANUAL-ADD ${FINGERPRINT}" >> /var/log/ssh-auth/auth-update.log
