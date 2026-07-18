"""NPC FailGuard - key store and rotation state machine.

Faithfully replicates the v1 behavior:

  active       -> usable
  rate_limited -> 429 / transient 5xx / provider "busy" throttle; auto-revives
                  after ~30-60s or the server's Retry-After
  exhausted    -> 402 payment_required; auto-revives after ~5h
  dead         -> genuinely invalid token (401); safety-retry after 6h

Selection is sticky: the same key keeps serving until it fails, then the
store rotates forward to the next available key (active_index persisted in
state.json). Revival is lazy - cooldown timestamps are checked whenever a
key is considered, and revive transitions are logged so self-healing is
observable in the proxy log.

File formats are byte-compatible with v1:
  keys.json:  {"keys": [{key, label, status, dead_reason, last_used_at}]}
  state.json: {"active_index": N, "keys": [{key, status, dead_reason,
               last_used_at, rate_limited_until, exhausted_until,
               dead_since, request_count}]}
"""

import asyncio
import json
import logging
import time

import config

log = logging.getLogger("npc-failguard")

# statuses
ACTIVE = "active"
RATE_LIMITED = "rate_limited"
EXHAUSTED = "exhausted"
DEAD = "dead"

# markers in upstream bodies that mean "provider is busy", not "key is bad"
_BUSY_MARKERS = ("busy", "overloaded", "try again", "at capacity")


def classify_failure(status_code: int, body: str, retry_after: str | None = None):
    """Map an upstream failure to (new_status, reason, cooldown_seconds).

    Returns None if the response is not a key-rotation failure (e.g. a 400
    validation error that should be passed straight back to the client).
    """
    body_l = (body or "").lower()

    if status_code == 401:
        # Body-based classification: a provider-wide "busy" 401 is a
        # throttle, not a dead key.
        if any(m in body_l for m in _BUSY_MARKERS):
            return RATE_LIMITED, "throttled", _throttle_cooldown(retry_after)
        return DEAD, "unauthorized", None
    if status_code == 403:
        return DEAD, "forbidden", None
    if status_code == 402:
        return EXHAUSTED, "payment_required", config.EXHAUSTED_COOLDOWN
    if status_code == 429:
        return RATE_LIMITED, "throttled", _throttle_cooldown(retry_after)
    if status_code in (500, 502, 503, 504, 529):
        # transient upstream trouble - cool the key briefly and move on
        return RATE_LIMITED, f"upstream_{status_code}", _throttle_cooldown(retry_after)
    return None


def _throttle_cooldown(retry_after: str | None) -> float:
    if retry_after:
        try:
            return min(float(retry_after), config.RATE_LIMIT_COOLDOWN_MAX)
        except ValueError:
            pass
    return config.RATE_LIMIT_COOLDOWN


def _new_state_entry(key: str) -> dict:
    return {
        "key": key,
        "status": ACTIVE,
        "dead_reason": None,
        "last_used_at": None,
        "rate_limited_until": None,
        "exhausted_until": None,
        "dead_since": None,
        "request_count": 0,
    }


class KeyStore:
    def __init__(self, keys_file=None, state_file=None):
        self.keys_file = keys_file or config.KEYS_FILE
        self.state_file = state_file or config.STATE_FILE
        self.lock = asyncio.Lock()
        self.labels: list[str] = []
        self.entries: list[dict] = []   # state.json "keys" list, same order
        self.active_index = 0
        self.load()

    # ---------- persistence ----------

    def load(self) -> None:
        """(Re)load keys.json and merge any existing state.json on top.

        A missing/empty keys.json is normal on a fresh install (keys arrive
        later via setup + /reload) - start with zero keys instead of crashing.
        """
        try:
            with open(self.keys_file, "r", encoding="utf-8") as f:
                key_defs = json.load(f).get("keys", [])
        except (OSError, ValueError):
            log.warning("no keys.json yet (%s) - starting with 0 keys; "
                        "run setup to add keys", self.keys_file)
            key_defs = []

        self.labels = [d.get("label", f"key-{i+1}") for i, d in enumerate(key_defs)]
        self.entries = [_new_state_entry(d["key"]) for d in key_defs]
        self.active_index = 0

        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                state = json.load(f)
        except (OSError, ValueError):
            state = None

        if state:
            by_key = {e.get("key"): e for e in state.get("keys", [])}
            for entry in self.entries:
                old = by_key.get(entry["key"])
                if old:
                    for field in ("status", "dead_reason", "last_used_at",
                                  "rate_limited_until", "exhausted_until",
                                  "dead_since", "request_count"):
                        if field in old:
                            entry[field] = old[field]
            idx = state.get("active_index", 0)
            if isinstance(idx, int) and 0 <= idx < len(self.entries):
                self.active_index = idx

        self.save()

    def save(self) -> None:
        config.secure_write_json(self.state_file, {
            "active_index": self.active_index,
            "keys": self.entries,
        })

    # ---------- state machine ----------

    def _maybe_revive(self, i: int, now: float) -> None:
        e = self.entries[i]
        if e["status"] == RATE_LIMITED and e["rate_limited_until"] and now >= e["rate_limited_until"]:
            self._revive(i, "rate_limit cooldown expired")
        elif e["status"] == EXHAUSTED and e["exhausted_until"] and now >= e["exhausted_until"]:
            self._revive(i, "exhausted cooldown expired")
        elif e["status"] == DEAD and e["dead_since"] and now - e["dead_since"] >= config.DEAD_RETRY_AFTER:
            self._revive(i, "dead safety-retry window reached")

    def _revive(self, i: int, why: str) -> None:
        e = self.entries[i]
        old = e["status"]
        e["status"] = ACTIVE
        e["dead_reason"] = None
        e["rate_limited_until"] = None
        e["exhausted_until"] = None
        e["dead_since"] = None
        log.info("revive key=%s %s->active (%s)", self.labels[i], old, why)

    def pick(self) -> tuple[int, str, str] | None:
        """Return (index, label, key) of the key to use, or None if all are
        cooling down. Sticky: prefers the current active_index."""
        now = time.time()
        n = len(self.entries)
        if n == 0:
            return None
        for offset in range(n):
            i = (self.active_index + offset) % n
            self._maybe_revive(i, now)
            if self.entries[i]["status"] == ACTIVE:
                if i != self.active_index:
                    self.active_index = i
                    self.save()
                return i, self.labels[i], self.entries[i]["key"]
        return None

    def _locate(self, i: int, key: str | None) -> int | None:
        """Re-resolve an index captured before an await: a hot-reload may have
        shrunk or reordered the pool while the request was in flight. With no
        key given, only bounds-check; with a key, verify it and fall back to a
        lookup. None -> the key is gone, caller should skip the update."""
        if key is None:
            return i if 0 <= i < len(self.entries) else None
        if 0 <= i < len(self.entries) and self.entries[i]["key"] == key:
            return i
        for j, e in enumerate(self.entries):
            if e["key"] == key:
                return j
        return None

    def mark_used(self, i: int, key: str | None = None) -> None:
        idx = self._locate(i, key)
        if idx is None:
            log.warning("mark_used skipped: key no longer in pool (reloaded mid-request)")
            return
        e = self.entries[idx]
        e["last_used_at"] = time.time()
        e["request_count"] = int(e.get("request_count") or 0) + 1
        self.save()

    def mark_failure(self, i: int, new_status: str, reason: str,
                     cooldown: float | None, key: str | None = None) -> None:
        idx = self._locate(i, key)
        if idx is None:
            log.warning("mark_failure skipped: key no longer in pool (reloaded mid-request)")
            return
        now = time.time()
        e = self.entries[idx]
        e["last_used_at"] = now
        e["request_count"] = int(e.get("request_count") or 0) + 1
        e["status"] = new_status
        if new_status == RATE_LIMITED:
            e["rate_limited_until"] = now + (cooldown or config.RATE_LIMIT_COOLDOWN)
            e["dead_reason"] = reason
        elif new_status == EXHAUSTED:
            until = now + (cooldown or config.EXHAUSTED_COOLDOWN)
            e["exhausted_until"] = until
            e["dead_reason"] = f"exhausted (revives at {int(until)})"
        elif new_status == DEAD:
            e["dead_since"] = now
            e["dead_reason"] = reason
        self.save()

    # ---------- reporting ----------

    def counts(self) -> dict:
        now = time.time()
        for i in range(len(self.entries)):
            self._maybe_revive(i, now)
        c = {ACTIVE: 0, RATE_LIMITED: 0, EXHAUSTED: 0, DEAD: 0}
        for e in self.entries:
            c[e["status"]] = c.get(e["status"], 0) + 1
        return c

    def status_report(self) -> dict:
        """Shape matches the v1 /_npc-failguard/status payload."""
        now = time.time()
        keys = []
        for i, e in enumerate(self.entries):
            self._maybe_revive(i, now)
            keys.append({
                "label": self.labels[i],
                "key_tail": e["key"][-6:],
                "status": e["status"],
                "dead_reason": e["dead_reason"],
                "request_count": e["request_count"],
                "last_used_at": e["last_used_at"],
                "rate_limited_until": e["rate_limited_until"],
                "exhausted_until": e["exhausted_until"],
                "dead_since": e["dead_since"],
                "active": i == self.active_index,
            })
        return {"keys": keys}
