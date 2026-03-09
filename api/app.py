"""SSH Key API — signed key · peer status · WebSocket log stream + force-update trigger."""
import os, hmac, hashlib, time, json, logging, secrets, asyncio, subprocess
from pathlib import Path
from fastapi import FastAPI, HTTPException, Security, WebSocket, WebSocketDisconnect, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse
import uvicorn

API_SECRET      = os.environ["API_SECRET"]
SERVER_NAME     = os.environ.get("SERVER_NAME", "server1")
PUBLIC_KEY_PATH = Path(os.environ.get("PUBLIC_KEY_PATH", "/keys/id_ed25519.pub"))
PEER_API_URLS   = os.environ.get("PEER_API_URLS", "")
LOG_LEVEL       = os.environ.get("LOG_LEVEL", "INFO")
WEBHOOK_URL     = os.environ.get("WEBHOOK_URL", "")
API_PORT        = int(os.environ.get("API_PORT", "8080"))
STATUS_FILE     = Path("/tmp/peer-status.json")
LOG_WATCH       = ["/var/log/ssh-auth/key-rotation.log", "/var/log/ssh-auth/auth-update.log",
                   "/var/log/ssh-auth/connectivity.log", "/var/log/ssh-auth/entrypoint.log"]

logging.basicConfig(level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")
log    = logging.getLogger("ssh-key-api")
app    = FastAPI(title="SSH Key API", docs_url=None, redoc_url=None, openapi_url=None)
bearer = HTTPBearer(auto_error=True)


def _expected_token() -> str:
    return hmac.new(API_SECRET.encode(), b"ssh-auth-v1", hashlib.sha256).hexdigest()

def verify_token(c: HTTPAuthorizationCredentials = Security(bearer)) -> None:
    if not hmac.compare_digest(c.credentials, _expected_token()):
        log.warning("Invalid bearer token")
        raise HTTPException(status_code=401, detail="Unauthorized")


def sign_payload(payload: dict) -> str:
    msg = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hmac.new(API_SECRET.encode(), msg, hashlib.sha256).hexdigest()


def _get_fingerprint() -> str:
    try:
        r = subprocess.run(["ssh-keygen", "-lf", str(PUBLIC_KEY_PATH)],
                           capture_output=True, text=True, timeout=5)
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
        urllib.request.urlopen(
            urllib.request.Request(WEBHOOK_URL, data=body,
                                   headers={"Content-Type": "application/json"}), timeout=5)
    except Exception as exc:
        log.warning(f"Webhook failed: {exc}")


async def _run_local_update() -> int:
    """Run update-authorized-keys.sh asynchronously; return exit code."""
    proc = await asyncio.create_subprocess_exec(
        "/scripts/update-authorized-keys.sh", env={**os.environ})
    return await proc.wait()


async def _trigger_peers() -> dict:
    """POST /trigger-update on all known peer APIs; returns {url: status}."""
    if not PEER_API_URLS:
        return {}
    import httpx
    results: dict = {}
    token = _expected_token()
    async with httpx.AsyncClient(timeout=10) as client:
        for url in PEER_API_URLS.split(","):
            url = url.strip()
            try:
                r = await client.post(f"{url}/trigger-update",
                                      headers={"Authorization": f"Bearer {token}"})
                results[url] = r.status_code
            except Exception as exc:
                results[url] = str(exc)
    return results


@app.middleware("http")
async def security_headers(request: Request, call_next):
    resp = await call_next(request)
    resp.headers.update({"X-Content-Type-Options": "nosniff",
                         "X-Frame-Options": "DENY", "Cache-Control": "no-store"})
    return resp


@app.get("/public-key")
async def get_public_key(_: None = Security(verify_token)):
    if not PUBLIC_KEY_PATH.exists():
        raise HTTPException(status_code=503, detail="Key not initialised")
    public_key = PUBLIC_KEY_PATH.read_text().strip()
    if not public_key.startswith("ssh-"):
        raise HTTPException(status_code=500, detail="Key format error")
    payload: dict = {"hostname": SERVER_NAME, "public_key": public_key,
                     "algorithm": "ed25519", "timestamp": int(time.time()),
                     "nonce": secrets.token_hex(8)}
    payload["signature"] = sign_payload({k: v for k, v in payload.items()
                                         if k != "signature"})
    log.info("Public key served to peer")
    return JSONResponse(content=payload)


@app.get("/health")
async def health():
    return JSONResponse({"status": "ok" if PUBLIC_KEY_PATH.exists() else "degraded",
                         "server": SERVER_NAME, "key_ready": PUBLIC_KEY_PATH.exists(),
                         "timestamp": int(time.time())})


@app.get("/status")
async def get_status(_: None = Security(verify_token)):
    peers: dict = {}
    if STATUS_FILE.exists():
        try:
            peers = json.loads(STATUS_FILE.read_text())
        except Exception:
            pass
    return JSONResponse({"server": SERVER_NAME, "timestamp": int(time.time()),
                         "key_ready": PUBLIC_KEY_PATH.exists(),
                         "key_fingerprint": _get_fingerprint(), "peers": peers})


@app.post("/trigger-update")
async def trigger_update(_: None = Security(verify_token)):
    """Force immediate authorized_keys refresh locally + on all peer servers."""
    rc    = await _run_local_update()
    peers = await _trigger_peers()
    log.info(f"Force-update: local_rc={rc} peers={peers}")
    _notify_webhook("force_update", f"local_rc={rc} peers={peers}")
    return JSONResponse({"status": "done", "server": SERVER_NAME,
                         "local_rc": rc, "peers": peers})


@app.websocket("/ws/logs")
async def ws_logs(ws: WebSocket):
    """
    Live log stream + control channel. Auth via ?token=<bearer>.
    Send JSON {"action":"force-update"} to trigger key refresh on all servers.
    """
    if not hmac.compare_digest(ws.query_params.get("token", ""), _expected_token()):
        await ws.close(code=4401)
        return
    await ws.accept()
    log.info("WebSocket client connected")
    positions = {p: Path(p).stat().st_size if Path(p).exists() else 0 for p in LOG_WATCH}

    async def _stream():
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

    async def _recv():
        async for raw in ws.iter_text():
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            if msg.get("action") == "force-update":
                await ws.send_text(json.dumps({"status": "triggering update on all servers..."}))
                rc    = await _run_local_update()
                peers = await _trigger_peers()
                await ws.send_text(json.dumps({"status": "done", "local_rc": rc, "peers": peers}))
                _notify_webhook("ws_force_update", f"rc={rc}")

    stream_t = asyncio.create_task(_stream())
    recv_t   = asyncio.create_task(_recv())
    try:
        await asyncio.wait([stream_t, recv_t], return_when=asyncio.FIRST_EXCEPTION)
    except WebSocketDisconnect:
        pass
    finally:
        stream_t.cancel()
        recv_t.cancel()
        log.info("WebSocket client disconnected")


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=API_PORT,
                log_level=LOG_LEVEL.lower(), access_log=True)
