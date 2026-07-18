"""NPC FailGuard - configuration and constants.

Paths, network settings and the state-machine timing constants used by the
key store and proxy. All timings mirror the documented v1 behavior:
  - rate_limited: revive after ~30-60s (or the server's Retry-After)
  - exhausted:    revive after ~5h
  - dead:         safety-retry after 6h
"""

import json
import os
from pathlib import Path

CORE_DIR = Path(__file__).resolve().parent

KEYS_FILE = CORE_DIR / "keys.json"
STATE_FILE = CORE_DIR / "state.json"
PROVIDER_FILE = CORE_DIR / "provider.json"
API_TXT_FILE = CORE_DIR / "api.txt"
STATS_FILE = CORE_DIR / "stats.json"
PRICING_FILE = CORE_DIR / "pricing.json"
LOG_DIR = CORE_DIR / "logs"
LOG_FILE = LOG_DIR / "proxy.log"

HOST = os.environ.get("NPC_FAILGUARD_HOST", "127.0.0.1")
PORT = int(os.environ.get("NPC_FAILGUARD_PORT", "8787"))

# --- key state machine timings (seconds) ---
RATE_LIMIT_COOLDOWN = 30.0          # default throttle cooldown
RATE_LIMIT_COOLDOWN_MAX = 60.0      # cap when the server's Retry-After is huge
EXHAUSTED_COOLDOWN = 5 * 3600.0     # 402 -> revive after ~5h
DEAD_RETRY_AFTER = 6 * 3600.0       # dead keys get a safety retry after 6h

# --- proxy behavior ---
UPSTREAM_TIMEOUT = 600.0            # free tiers can take 60-120s+; wait it out
UPSTREAM_CONNECT_TIMEOUT = 30.0
NO_KEYS_RETRY_AFTER = 120           # Retry-After when every key is cooling down
# Cap rotations within a single request so one bad request can't burn the
# whole pool in seconds (observed 2026-07-13: ~1 key killed per 400ms).
MAX_ROTATIONS_PER_REQUEST = int(os.environ.get("NPC_FAILGUARD_MAX_ROTATIONS", "10"))

LOG_RETENTION_DAYS = 7


def load_provider() -> dict:
    """Read provider.json; returns {} if missing/unreadable."""
    try:
        with open(PROVIDER_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def base_url() -> str:
    url = load_provider().get("base_url", "")
    return url.rstrip("/")


def secure_write_json(path, data) -> None:
    """Atomic JSON write with 600 perms (chmod is a no-op on Windows ACLs)."""
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
