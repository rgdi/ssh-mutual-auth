#!/usr/bin/env bash
# One-time initialisation helper — run on the host before docker compose up.
# Validates required env vars and creates .env if missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

log()  { echo "[INIT] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FAIL] $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1  || die "docker not found"
command -v openssl >/dev/null 2>&1 || die "openssl not found"

if [[ ! -f "$ENV_FILE" ]]; then
    log "Creating .env from .env.example..."
    cp "${ROOT_DIR}/.env.example" "$ENV_FILE"

    # Auto-generate strong secrets
    API_SECRET=$(openssl rand -hex 32)
    sed -i "s|API_SECRET=.*|API_SECRET=${API_SECRET}|" "$ENV_FILE"

    PEER_API_SECRET=$(openssl rand -hex 32)
    sed -i "s|PEER_API_SECRET=.*|PEER_API_SECRET=${PEER_API_SECRET}|" "$ENV_FILE"

    log ".env created with random secrets"
    log "IMPORTANT: Copy PEER_API_SECRET to peer server's .env"
fi

source "$ENV_FILE"

[[ -z "${CF_TUNNEL_TOKEN:-}" ]]  && warn "CF_TUNNEL_TOKEN not set — Cloudflare Tunnel won't start"
[[ -z "${SERVER_NAME:-}" ]]      && warn "SERVER_NAME not set — defaulting to 'server1'"
[[ -z "${PEER_API_URLS:-}" ]]    && warn "PEER_API_URLS not set — peer sync disabled"

mkdir -p "${ROOT_DIR}/logs"
chmod 750 "${ROOT_DIR}/logs"

log "Initialisation complete. Run: docker compose up -d"
log "Bearer token for this server: $(echo -n 'ssh-auth-v1' | openssl dgst -sha256 -hmac "${API_SECRET}" | awk '{print \$2}')"
