"""
SSH Public Key API Server
Serves the server's public key with HMAC-SHA256 signature verification.
All responses are signed; clients MUST verify signatures before trusting.
"""
import os
import hmac
import hashlib
import time
import json
import logging
import secrets
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Security, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse
import uvicorn

API_SECRET = os.environ["API_SECRET"]
SERVER_NAME = os.environ.get("SERVER_NAME", "server1")
PUBLIC_KEY_PATH = Path(os.environ.get("PUBLIC_KEY_PATH", "/keys/id_ed25519.pub"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
WEBHOOK_URL = os.environ.get("WEBHOOK_URL", "")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("ssh-key-api")

app = FastAPI(title="SSH Key API", docs_url=None, redoc_url=None, openapi_url=None)
bearer = HTTPBearer(auto_error=True)


def _expected_token() -> str:
    return hmac.new(
        API_SECRET.encode("utf-8"),
        b"ssh-auth-v1",
        hashlib.sha256,
    ).hexdigest()


def verify_token(
    creds: HTTPAuthorizationCredentials = Security(bearer),
) -> None:
    if not hmac.compare_digest(creds.credentials, _expected_token()):
        log.warning("Invalid bearer token presented")
        raise HTTPException(status_code=401, detail="Unauthorized")


def sign_payload(payload: dict) -> str:
    """HMAC-SHA256 signature over JSON-serialised payload (keys sorted)."""
    msg = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hmac.new(API_SECRET.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _notify_webhook(event: str, detail: str) -> None:
    if not WEBHOOK_URL:
        return
    try:
        import urllib.request
        body = json.dumps({"server": SERVER_NAME, "event": event, "detail": detail,
                           "ts": int(time.time())}).encode()
        req = urllib.request.Request(WEBHOOK_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:
        log.warning(f"Webhook delivery failed: {exc}")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    return response


@app.get("/public-key")
async def get_public_key(_: None = Security(verify_token)):
    """Return this server's current public SSH key (signed payload)."""
    if not PUBLIC_KEY_PATH.exists():
        log.error("Public key file missing — server not initialised")
        raise HTTPException(status_code=503, detail="Key not initialised")

    public_key = PUBLIC_KEY_PATH.read_text().strip()
    if not public_key.startswith("ssh-"):
        log.error("Public key file contains unexpected data")
        raise HTTPException(status_code=500, detail="Key format error")

    payload: dict = {
        "hostname": SERVER_NAME,
        "public_key": public_key,
        "algorithm": "ed25519",
        "timestamp": int(time.time()),
        "nonce": secrets.token_hex(8),
    }
    payload["signature"] = sign_payload({k: v for k, v in payload.items()
                                         if k != "signature"})
    log.info("Public key served to authenticated peer")
    return JSONResponse(content=payload)


@app.get("/health")
async def health():
    return JSONResponse({
        "status": "ok" if PUBLIC_KEY_PATH.exists() else "degraded",
        "server": SERVER_NAME,
        "key_ready": PUBLIC_KEY_PATH.exists(),
        "timestamp": int(time.time()),
    })


if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=8080,
        log_level=LOG_LEVEL.lower(),
        access_log=True,
    )
