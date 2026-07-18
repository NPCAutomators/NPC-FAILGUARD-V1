"""NPC FailGuard - token/cost usage tracking.

Counts only what the proxy already carries: every Anthropic-compatible
response includes a `usage` block (input/output/cache tokens) - in the JSON
body for buffered responses, and in the `message_start`/`message_delta` SSE
events for streaming ones. Parsing those is free: no extra upstream
requests, no extra tokens spent.

Dollar figures come from core/pricing.json (USD per million tokens, matched
by model-id prefix). Edit it to mirror your provider's billing; the token
counts themselves are exact regardless.

The provider's total remaining balance cannot be read (no balance API on
most Anthropic-compatible providers), so "remaining" is computed against a
user-set budget: manage.py set-budget <usd>.
"""

import json
import logging
import time

import config

log = logging.getLogger("npc-failguard")

# USD per million tokens: [input, output, cache_write, cache_read]
_DEFAULT_PRICING = {
    "claude-fable": [15.0, 75.0, 18.75, 1.5],
    "claude-opus": [15.0, 75.0, 18.75, 1.5],
    "claude-sonnet": [3.0, 15.0, 3.75, 0.3],
    "claude-haiku": [1.0, 5.0, 1.25, 0.1],
    "claude-3-5-haiku": [0.8, 4.0, 1.0, 0.08],
    "default": [3.0, 15.0, 3.75, 0.3],
}

_MODEL_FIELDS = ("input_tokens", "output_tokens",
                 "cache_write_tokens", "cache_read_tokens", "requests")


def load_pricing() -> dict:
    """Read pricing.json, creating it with defaults on first use so the
    user has a file to edit."""
    try:
        with open(config.PRICING_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and data:
            return data
    except (OSError, ValueError):
        pass
    try:
        config.secure_write_json(config.PRICING_FILE, _DEFAULT_PRICING)
    except OSError:
        pass
    return dict(_DEFAULT_PRICING)


def rates_for(model: str, pricing: dict) -> list:
    """Longest prefix match on the model id, else the 'default' row."""
    best = None
    for prefix in pricing:
        if prefix != "default" and model.startswith(prefix):
            if best is None or len(prefix) > len(best):
                best = prefix
    row = pricing.get(best or "default") or _DEFAULT_PRICING["default"]
    return list(row) + [0.0] * (4 - len(row))


def cost_usd(counts: dict, rates: list) -> float:
    return (counts.get("input_tokens", 0) * rates[0]
            + counts.get("output_tokens", 0) * rates[1]
            + counts.get("cache_write_tokens", 0) * rates[2]
            + counts.get("cache_read_tokens", 0) * rates[3]) / 1_000_000.0


class UsageTracker:
    """Persistent per-model token counters + optional budget (stats.json)."""

    def __init__(self, stats_file=None):
        self.stats_file = stats_file or config.STATS_FILE
        self.budget_usd = None
        self.since = time.time()
        self.models: dict[str, dict] = {}
        self.load()

    def load(self) -> None:
        try:
            with open(self.stats_file, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
        self.budget_usd = data.get("budget_usd")
        self.since = data.get("since") or time.time()
        self.models = {}
        for model, counts in (data.get("models") or {}).items():
            if isinstance(counts, dict):
                self.models[model] = {f: int(counts.get(f) or 0)
                                      for f in _MODEL_FIELDS}
        if not data:
            self.save()

    def save(self) -> None:
        config.secure_write_json(self.stats_file, {
            "budget_usd": self.budget_usd,
            "since": self.since,
            "models": self.models,
        })

    def record(self, model: str | None, input_tokens: int, output_tokens: int,
               cache_write: int = 0, cache_read: int = 0) -> None:
        m = self.models.setdefault(model or "unknown",
                                   {f: 0 for f in _MODEL_FIELDS})
        m["input_tokens"] += int(input_tokens or 0)
        m["output_tokens"] += int(output_tokens or 0)
        m["cache_write_tokens"] += int(cache_write or 0)
        m["cache_read_tokens"] += int(cache_read or 0)
        m["requests"] += 1
        self.save()

    def record_from_body(self, body: bytes) -> None:
        """Buffered response: usage block sits in the JSON body. Silently a
        no-op for non-JSON or usage-less payloads (e.g. GET /v1/models)."""
        try:
            data = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            return
        if not isinstance(data, dict):
            return
        u = data.get("usage")
        if not isinstance(u, dict):
            return
        self.record(data.get("model"),
                    u.get("input_tokens") or 0,
                    u.get("output_tokens") or 0,
                    u.get("cache_creation_input_tokens") or 0,
                    u.get("cache_read_input_tokens") or 0)

    def report(self) -> dict:
        pricing = load_pricing()
        models = {}
        spent = 0.0
        for model, counts in self.models.items():
            c = cost_usd(counts, rates_for(model, pricing))
            spent += c
            models[model] = dict(counts, cost_usd=round(c, 6))
        out = {
            "since": self.since,
            "budget_usd": self.budget_usd,
            "spent_usd": round(spent, 6),
            "models": models,
        }
        if isinstance(self.budget_usd, (int, float)):
            out["remaining_usd"] = round(self.budget_usd - spent, 6)
        return out


class SSEUsageScanner:
    """Incremental scanner for a streaming (SSE) response.

    feed() every chunk as it passes through; the pass-through bytes are
    never modified. message_start carries the model + input/cache token
    counts; message_delta carries the cumulative output_tokens.
    """

    _MAX_BUF = 1 << 20  # guard against a pathological line with no newline

    def __init__(self):
        self.model: str | None = None
        self.input_tokens = 0
        self.output_tokens = 0
        self.cache_write = 0
        self.cache_read = 0
        self.saw_usage = False
        self._buf = b""

    def feed(self, chunk: bytes) -> None:
        self._buf += chunk
        while b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            self._scan_line(line.strip())
        if len(self._buf) > self._MAX_BUF:
            self._buf = self._buf[-4096:]

    def _scan_line(self, line: bytes) -> None:
        if not line.startswith(b"data:"):
            return
        payload = line[5:].strip()
        if not payload or payload == b"[DONE]":
            return
        try:
            evt = json.loads(payload)
        except ValueError:
            return
        etype = evt.get("type")
        if etype == "message_start":
            msg = evt.get("message") or {}
            self.model = msg.get("model") or self.model
            u = msg.get("usage") or {}
            if u:
                self.saw_usage = True
                self.input_tokens = int(u.get("input_tokens") or 0)
                self.cache_write = int(u.get("cache_creation_input_tokens") or 0)
                self.cache_read = int(u.get("cache_read_input_tokens") or 0)
        elif etype == "message_delta":
            u = evt.get("usage") or {}
            if "output_tokens" in u:
                self.saw_usage = True
                self.output_tokens = int(u.get("output_tokens") or 0)
            if u.get("input_tokens"):
                self.input_tokens = int(u["input_tokens"])

    def record_into(self, tracker: UsageTracker) -> None:
        if self.saw_usage:
            tracker.record(self.model, self.input_tokens, self.output_tokens,
                           self.cache_write, self.cache_read)
