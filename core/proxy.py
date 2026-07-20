"""NPC FailGuard - the rotating proxy itself.

FastAPI app that forwards Anthropic-compatible API requests to the provider
in provider.json, injecting keys from the key store and rotating on
failures. Supports SSE streaming pass-through, exposes a local status
endpoint (keys masked to their last 6 chars) and a reload endpoint so key
management never has to interrupt in-flight traffic with a restart.
"""

import json
import logging
import time
from logging.handlers import TimedRotatingFileHandler

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

import config
import key_store
import usage

log = logging.getLogger("npc-failguard")

# request headers we never forward upstream (the proxy sets its own)
_STRIP_REQUEST_HEADERS = {
    "host", "content-length", "connection", "x-api-key", "authorization",
    "accept-encoding",
}
# response headers that would corrupt the re-encoded body
_STRIP_RESPONSE_HEADERS = {
    "content-length", "content-encoding", "transfer-encoding", "connection",
}


def setup_logging() -> None:
    config.LOG_DIR.mkdir(exist_ok=True)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")
    root = logging.getLogger("npc-failguard")
    root.setLevel(logging.INFO)
    if not root.handlers:
        fh = TimedRotatingFileHandler(
            config.LOG_FILE, when="midnight",
            backupCount=config.LOG_RETENTION_DAYS, encoding="utf-8")
        fh.setFormatter(fmt)
        root.addHandler(fh)
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        root.addHandler(sh)


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
store: key_store.KeyStore | None = None
client: httpx.AsyncClient | None = None
tracker: usage.UsageTracker | None = None


@app.on_event("startup")
async def _startup() -> None:
    global store, client, tracker
    setup_logging()
    store = key_store.KeyStore()
    tracker = usage.UsageTracker()
    client = httpx.AsyncClient(
        timeout=httpx.Timeout(config.UPSTREAM_TIMEOUT,
                              connect=config.UPSTREAM_CONNECT_TIMEOUT),
        follow_redirects=True,
    )
    log.info("proxy started, upstream=%s, %d keys loaded",
             config.base_url(), len(store.entries))


@app.on_event("shutdown")
async def _shutdown() -> None:
    if client:
        await client.aclose()


# ---------- local management endpoints ----------

@app.get("/_npc-failguard/status")
async def status() -> JSONResponse:
    async with store.lock:
        report = store.status_report()
        store.save()
    return JSONResponse(report)


@app.post("/_npc-failguard/reload")
async def reload_config() -> JSONResponse:
    """Re-read keys.json / provider.json without restarting the daemon."""
    async with store.lock:
        try:
            store.load()
            tracker.load()
        except (OSError, ValueError) as exc:
            log.error("reload failed: %s", exc)
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)
    log.info("reload ok, upstream=%s, %d keys loaded",
             config.base_url(), len(store.entries))
    return JSONResponse({"ok": True, "keys": len(store.entries),
                         "base_url": config.base_url()})


@app.get("/_npc-failguard/usage")
async def usage_stats() -> JSONResponse:
    """Token/cost counters (local only, free - reads what already passed
    through the proxy, never asks upstream anything)."""
    async with store.lock:
        report = tracker.report()
        report["keys"] = store.counts()
    return JSONResponse(report)


@app.get("/")
@app.head("/")
async def root() -> JSONResponse:
    return JSONResponse({"service": "npc-failguard", "ok": True})


# ---------- the forwarder ----------

def _upstream_headers(request: Request, key: str) -> dict:
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in _STRIP_REQUEST_HEADERS}
    headers["x-api-key"] = key
    headers["authorization"] = f"Bearer {key}"
    return headers


def _client_response_headers(upstream: httpx.Response) -> dict:
    return {k: v for k, v in upstream.headers.items()
            if k.lower() not in _STRIP_RESPONSE_HEADERS}


def _is_stream(body: bytes) -> bool:
    try:
        return bool(json.loads(body).get("stream"))
    except (ValueError, AttributeError):
        return False


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def forward(request: Request, path: str) -> Response:
    upstream_base = config.base_url()
    if not upstream_base:
        return JSONResponse(
            {"error": "npc-failguard: no provider set yet - run "
                      "/npc-failguard:setup <base-url> (free, no credit)"},
            status_code=503)

    body = await request.body()
    wants_stream = _is_stream(body)
    url = f"{upstream_base}/{path}"
    if request.url.query:
        url += f"?{request.url.query}"

    rotations = 0
    while True:
        async with store.lock:
            picked = store.pick()
        if picked is None:
            async with store.lock:
                empty_pool = len(store.entries) == 0
            if empty_pool:
                log.error("request rejected: no keys configured yet")
                return JSONResponse(
                    {"error": "npc-failguard: no API keys added yet - run "
                              "/npc-failguard:add-key <key> or "
                              "/npc-failguard:add-keys-txt <file> (free, no credit)"},
                    status_code=503)
            log.error("no active keys available (retry_after=%d)", config.NO_KEYS_RETRY_AFTER)
            return JSONResponse(
                {"error": "npc-failguard: no active keys available, all cooling down"},
                status_code=503,
                headers={"Retry-After": str(config.NO_KEYS_RETRY_AFTER)})

        idx, label, key = picked
        headers = _upstream_headers(request, key)
        started = time.monotonic()

        try:
            if wants_stream:
                result = await _forward_streaming(request, url, headers, body,
                                                  idx, label, key, path, started)
            else:
                result = await _forward_buffered(request, url, headers, body,
                                                 idx, label, key, path, started, wants_stream)
        except httpx.HTTPError as exc:
            log.error("upstream request error key=%s err=%s", label, exc)
            async with store.lock:
                store.mark_failure(idx, key_store.RATE_LIMITED, "request_error",
                                   config.RATE_LIMIT_COOLDOWN, key=key)
            result = None

        if result is not None:
            return result

        rotations += 1
        if rotations >= config.MAX_ROTATIONS_PER_REQUEST:
            log.error("rotation cap reached (%d) for %s %s",
                      rotations, request.method, f"/{path}")
            return JSONResponse(
                {"error": "npc-failguard: upstream rejecting keys, rotation cap reached"},
                status_code=503,
                headers={"Retry-After": str(config.NO_KEYS_RETRY_AFTER)})


async def _handle_failure(idx: int, label: str, key: str, status_code: int,
                          body_text: str, retry_after: str | None,
                          latency_ms: int) -> bool:
    """Classify an upstream failure. True -> rotate to next key."""
    verdict = key_store.classify_failure(status_code, body_text, retry_after)
    if verdict is None:
        return False
    new_status, reason, cooldown = verdict
    log.warning("rotate key=%s status=%d reason=%s latency=%dms body=%s",
                label, status_code, reason, latency_ms, body_text[:500])
    async with store.lock:
        store.mark_failure(idx, new_status, reason, cooldown, key=key)
    return True


async def _forward_buffered(request: Request, url: str, headers: dict,
                            body: bytes, idx: int, label: str, key: str, path: str,
                            started: float, wants_stream: bool) -> Response | None:
    upstream = await client.request(request.method, url,
                                    headers=headers, content=body)
    latency_ms = int((time.monotonic() - started) * 1000)

    if upstream.status_code >= 400:
        rotate = await _handle_failure(idx, label, key, upstream.status_code,
                                       upstream.text, upstream.headers.get("retry-after"),
                                       latency_ms)
        if rotate:
            return None

    log.info("ok key=%s method=%s path=/%s status=%d latency=%dms stream=%s",
             label, request.method, path, upstream.status_code, latency_ms,
             wants_stream)
    async with store.lock:
        store.mark_used(idx, key=key)
        if upstream.status_code < 400:
            tracker.record_from_body(upstream.content)
    return Response(content=upstream.content,
                    status_code=upstream.status_code,
                    headers=_client_response_headers(upstream))


async def _forward_streaming(request: Request, url: str, headers: dict,
                             body: bytes, idx: int, label: str, key: str, path: str,
                             started: float) -> Response | None:
    req = client.build_request(request.method, url, headers=headers, content=body)
    upstream = await client.send(req, stream=True)
    latency_ms = int((time.monotonic() - started) * 1000)

    if upstream.status_code >= 400:
        # error before any bytes streamed -> classify and maybe rotate
        error_body = (await upstream.aread()).decode("utf-8", "replace")
        await upstream.aclose()
        rotate = await _handle_failure(idx, label, key, upstream.status_code,
                                       error_body, upstream.headers.get("retry-after"),
                                       latency_ms)
        if rotate:
            return None
        log.info("ok key=%s method=%s path=/%s status=%d latency=%dms stream=True",
                 label, request.method, path, upstream.status_code, latency_ms)
        async with store.lock:
            store.mark_used(idx, key=key)
        return Response(content=error_body,
                        status_code=upstream.status_code,
                        headers=_client_response_headers(upstream))

    log.info("ok key=%s method=%s path=/%s status=%d latency=%dms stream=True",
             label, request.method, path, upstream.status_code, latency_ms)
    async with store.lock:
        store.mark_used(idx, key=key)

    scanner = usage.SSEUsageScanner()

    async def _iterate():
        try:
            async for chunk in upstream.aiter_bytes():
                scanner.feed(chunk)   # passive tap; bytes pass through untouched
                yield chunk
        finally:
            await upstream.aclose()
            async with store.lock:
                scanner.record_into(tracker)

    return StreamingResponse(_iterate(),
                             status_code=upstream.status_code,
                             headers=_client_response_headers(upstream))
