"""Tests for the usage/cost tracker - counting must be exact and free."""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))

import config  # noqa: E402
import usage  # noqa: E402


@pytest.fixture
def tracker(tmp_path):
    return usage.UsageTracker(stats_file=tmp_path / "stats.json")


# ---------- SSE scanner ----------

SSE = (
    b'event: message_start\n'
    b'data: {"type":"message_start","message":{"model":"claude-sonnet-5",'
    b'"usage":{"input_tokens":1200,"cache_creation_input_tokens":300,'
    b'"cache_read_input_tokens":9000,"output_tokens":1}}}\n\n'
    b'event: content_block_delta\n'
    b'data: {"type":"content_block_delta","delta":{"text":"hi"}}\n\n'
    b'event: message_delta\n'
    b'data: {"type":"message_delta","usage":{"output_tokens":57}}\n\n'
    b'event: message_stop\n'
    b'data: {"type":"message_stop"}\n\n'
)


def test_sse_scanner_reads_usage_events():
    s = usage.SSEUsageScanner()
    s.feed(SSE)
    assert s.saw_usage
    assert s.model == "claude-sonnet-5"
    assert s.input_tokens == 1200
    assert s.cache_write == 300
    assert s.cache_read == 9000
    assert s.output_tokens == 57  # cumulative from the last message_delta


def test_sse_scanner_survives_chunk_splits_mid_line():
    s = usage.SSEUsageScanner()
    for i in range(0, len(SSE), 7):  # brutal 7-byte chunking
        s.feed(SSE[i:i + 7])
    assert s.input_tokens == 1200 and s.output_tokens == 57


def test_sse_scanner_ignores_garbage():
    s = usage.SSEUsageScanner()
    s.feed(b"data: not-json\n\ndata: [DONE]\n\nrandom bytes")
    assert not s.saw_usage


# ---------- buffered body ----------

def test_record_from_body(tracker):
    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "usage": {"input_tokens": 10, "output_tokens": 5,
                  "cache_read_input_tokens": 100},
    }).encode()
    tracker.record_from_body(body)
    m = tracker.models["claude-haiku-4-5-20251001"]
    assert m["input_tokens"] == 10 and m["output_tokens"] == 5
    assert m["cache_read_tokens"] == 100 and m["requests"] == 1


def test_record_from_body_no_usage_is_noop(tracker):
    tracker.record_from_body(b'{"data":[{"id":"claude-x"}]}')  # /v1/models
    tracker.record_from_body(b"not json at all")
    assert tracker.models == {}


# ---------- pricing / cost ----------

def test_pricing_prefix_match_prefers_longest():
    pricing = {"claude-haiku": [1, 5, 1.25, 0.1],
               "claude-3-5-haiku": [0.8, 4, 1, 0.08],
               "default": [3, 15, 3.75, 0.3]}
    assert usage.rates_for("claude-3-5-haiku-20241022", pricing)[0] == 0.8
    assert usage.rates_for("claude-haiku-4-5", pricing)[0] == 1
    assert usage.rates_for("some-other-model", pricing)[0] == 3


def test_cost_math_per_million():
    rates = [3.0, 15.0, 3.75, 0.3]
    counts = {"input_tokens": 1_000_000, "output_tokens": 200_000,
              "cache_write_tokens": 0, "cache_read_tokens": 10_000_000}
    assert usage.cost_usd(counts, rates) == pytest.approx(3.0 + 3.0 + 3.0)


# ---------- budget / persistence ----------

def test_report_with_budget_and_roundtrip(tmp_path):
    t = usage.UsageTracker(stats_file=tmp_path / "stats.json")
    t.budget_usd = 50.0
    t.record("claude-sonnet-5", 1_000_000, 0, 0, 0)  # $3 at default rates
    r = t.report()
    assert r["spent_usd"] == pytest.approx(3.0)
    assert r["remaining_usd"] == pytest.approx(47.0)
    # a fresh tracker reads the same numbers back from disk
    t2 = usage.UsageTracker(stats_file=tmp_path / "stats.json")
    assert t2.budget_usd == 50.0
    assert t2.models["claude-sonnet-5"]["input_tokens"] == 1_000_000
