# SSH Mutual Authentication — Docker + Cloudflare Tunnel

Private, zero-open-port mutual SSH trust between servers.
Keys rotate every **24 hours**. No port is exposed to the internet.

## Architecture

```
Server A                          Server B
─────────────────                 ─────────────────
sshd (internal)  ←── CF Tunnel ──→ sshd (internal)
Key API :8080    ←── CF Tunnel ──→ Key API :8080
rotate-keys.sh (cron 00:00 UTC)
update-authorized-keys.sh (cron */5)
```

Keys are exchanged **only** through Cloudflare Tunnel (HTTPS).
Each response is signed with HMAC-SHA256. Stale responses (>5 min) are rejected.

## Quick Start

### Prerequisites
- Docker + Docker Compose
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) installed locally
- A Cloudflare account with Zero Trust enabled

### 1 — Create Cloudflare Tunnels (one per server)

```bash
cloudflared tunnel login
cloudflared tunnel create server1-ssh-auth
# Copy the tunnel token shown — used as CF_TUNNEL_TOKEN
```

In Cloudflare Zero Trust dashboard, add DNS routes:
- `ssh.server1.example.com` → SSH service
- `keyapi.server1.example.com` → Key API

### 2 — Configure each server

```bash
git clone https://github.com/YOUR_USER/ssh-mutual-auth
cd ssh-mutual-auth
bash scripts/init-server.sh   # creates .env with random secrets
```

Edit `.env`:
```
SERVER_NAME=server1
CF_TUNNEL_TOKEN=<paste tunnel token>
PEER_API_URLS=https://keyapi.server2.example.com
PEER_API_SECRET=<same value on ALL servers>
```

### 3 — Start

```bash
docker compose up -d
docker compose logs -f
```

### 4 — Test

```bash
# Check API health (no auth required)
curl https://keyapi.server1.example.com/health

# Get bearer token
BEARER=$(echo -n 'ssh-auth-v1' | openssl dgst -sha256 -hmac "$API_SECRET" | awk '{print $2}')

# Fetch public key (signed response)
curl -H "Authorization: Bearer $BEARER" https://keyapi.server1.example.com/public-key | jq .

# SSH via Cloudflare Tunnel (install cloudflared on client)
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.server1.example.com" sshuser@ssh.server1.example.com
```

## Security Properties

| Property | Implementation |
|---|---|
| No open ports | All traffic via Cloudflare Tunnel |
| Key authenticity | HMAC-SHA256 per-response signature |
| Replay protection | Timestamp window ±5 min + nonce |
| Ciphers | ChaCha20-Poly1305, AES-256-GCM only |
| Key type | Ed25519 only |
| Key rotation | Automatic every 24h (cron) |
| Auth method | Public key only, passwords disabled |
| Root login | Disabled |

## File Reference

| File | Purpose |
|---|---|
| `Dockerfile` | Container image |
| `docker-compose.yml` | Service definition |
| `api/app.py` | Public key API (FastAPI) |
| `scripts/entrypoint.sh` | Container startup |
| `scripts/generate-keys.sh` | Ed25519 key generation |
| `scripts/rotate-keys.sh` | 24h rotation cron |
| `scripts/update-authorized-keys.sh` | Peer key sync cron |
| `config/sshd_config` | Hardened SSH config |
| `config/cloudflared/config.yml.template` | Tunnel template |

## Detailed Usage and Troubleshooting

### Troubleshooting Authentication
- **Invalid Bearer Token:** Ensure both servers use identical `API_SECRET` and `PEER_API_SECRET`.
- **Key Mismatches:** You can trigger an immediate manual update of public keys by accessing the WebSocket API or by directly running `update-authorized-keys.sh` on the container.
- **Connection Latency:** Connectivity results are periodically stored to `/tmp/peer-status.json` via `check-connectivity.sh`. You can poll the `/status` API endpoint.

### Checking Logs

To check specific logs for rotation or authentication:
```bash
docker exec ssh-mutual-auth tail -f /var/log/ssh-auth/key-rotation.log
docker exec ssh-mutual-auth tail -f /var/log/ssh-auth/auth-update.log
```
