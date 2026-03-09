"""
SSH Public Key API Server
Signed public key endpoint, peer status, and live log WebSocket stream.
"""
import os, hmac, hashlib, time, json, logging, secrets, asyncio, subprocess
from pathlib import Path

from fastapi import FastAPI, HTTPException, Security, WebSocket, WebSocketDisconnect, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse
import uvicorn

API_SECRET      = os.environ["API_SECRET"]
SERVER_NAME     = os.environ.get("SERVER_NAME", "server1")
PUBLIC_KEY_PATH = Path(os.environ.get("PUBLIC_KEY_PATH", "/keys/id_ed25519.pub"))
LOG_LEVEL       = os.environ.get("LOG_LEVEL", "INFO")
WEBHOOK_URL     = os.environ.get("WEBHOOK_URL", "")
API_PORT        = int(os.environ.get("API_PORT", "8080"))
STATUS_FILE     = Path("/tmp/peer-status.json")
LOG_WATCH       = [
    "/var/log/ssh-auth/key-rotation.log",
    "/var/log/ssh-auth/auth-update.log",
    "/var/log/ssh-auth/connectivity.log",
    "/var/log/ssh-auth/entrypoint.log",
]

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ssh-key-api")

app = FastAPI(title="SSH Key API", docs_url=None, redoc_url=None, openapi_url=None)
bearer = HTTPBearer(auto_error=True)


def _expected_token() -> str:
    return hmac.new(API_SECRET.encode(), b"ssh-auth-v1", hashlib.sha256).hexdigest()


def verify_token(c: HTTPAuthorizationCredentials = Security(bearer)) -> None:
    if not hmac.compare_digest(c.credentials, _expected_token()):
        log.warning("Invalid bearer token presented")
        raise HTTPException(status_code=401, detail="Unauthorized")


def sign_payload(payload: dict) -> str:
    msg = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hmac.new(API_SECRET.encode(), msg, hashlib.sha256).hexdigest()


def _get_fingerprint() -> str:
    try:
        r = subprocess.run(
            ["ssh-keygen", "-lf", str(PUBLIC_KEY_PATH)],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.split()[1] if r.returncode == 0 and r.stdout else ""
    except Exception:
        return ""


def _notify_webhook(event: str, detail: str) -> None:
    if not WEBHOOK_URL:
        return
    try:
        import urllib.request
        body = json.dumps({"server": SERVER_NAME, "event": event,
                           "detail": detail, "ts": int(time.time())}).encode()
        req = urllib.request.Request(
            WEBHOOK_URL, data=body, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:
        log.warning(f"Webhook failed: {exc}")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    resp = await call_next(request)
    resp.headers.update({
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Cache-Control": "no-store",
        "Pragma": "no-cache",
    })
    return resp


@app.get("/public-key")
async def get_public_key(_: None = Security(verify_token)):
    """Return this server's current public SSH key (HMAC-signed payload)."""
    if not PUBLIC_KEY_PATH.exists():
        raise HTTPException(status_code=503, detail="Key not initialised")
    public_key = PUBLIC_KEY_PATH.read_text().strip()
    if not public_key.startswith("ssh-"):
        raise HTTPException(status_code=500, detail="Key format error")
    payload: dict = {
        "hostname": SERVER_NAME, "public_key": public_key,
        "algorithm": "ed25519", "timestamp": int(time.time()),
        "nonce": secrets.token_hex(8),
    }
    payload["signature"] = sign_payload({k: v for k, v in payload.items()
                                         if k != "signature"})
    log.info("Public key served to authenticated peer")
    return JSONResponse(content=payload)


@app.get("/health")
async def health():
    """Unauthenticated health probe — safe to expose via Cloudflare."""
    return JSONResponse({
        "status": "ok" if PUBLIC_KEY_PATH.exists() else "degraded",
        "server": SERVER_NAME,
        "key_ready": PUBLIC_KEY_PATH.exists(),
        "timestamp": int(time.time()),
    })


@app.get("/status")
async def get_status(_: None = Security(verify_token)):
    """Peer connectivity matrix + key fingerprint (authenticated)."""
    peers: dict = {}
    if STATUS_FILE.exists():
        try:
            peers = json.loads(STATUS_FILE.read_text())
        except Exception:
            pass
    return JSONResponse({
        "server": SERVER_NAME,
        "timestamp": int(time.time()),
        "key_ready": PUBLIC_KEY_PATH.exists(),
        "key_fingerprint": _get_fingerprint(),
        "peers": peers,
    })


@app.websocket("/ws/logs")
async def ws_logs(ws: WebSocket):
    """Live log stream. Auth via ?token=<bearer-token> query param."""
    if not hmac.compare_digest(ws.query_params.get("token", ""), _expected_token()):
        await ws.close(code=4401)
        return
    await ws.accept()
    log.info("WebSocket log client connected")
    positions = {p: Path(p).stat().st_size if Path(p).exists() else 0
                 for p in LOG_WATCH}
    try:
        while True:
            for path in LOG_WATCH:
                p = Path(path)
                if not p.exists():
                    continue
                size = p.stat().st_size
                if size > positions[path]:
                    with open(path) as f:
                        f.seek(positions[path])
                        chunk = f.read()
                    positions[path] = size
                    if chunk.strip():
                        await ws.send_text(chunk)
            await asyncio.sleep(1)
    except WebSocketDisconnect:
        log.info("WebSocket log client disconnected")


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=API_PORT,
                log_level=LOG_LEVEL.lower(), access_log=True)
