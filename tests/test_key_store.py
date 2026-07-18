"""Tests for the key_store state machine - encodes the documented v1 rules."""

import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))

import config  # noqa: E402
import key_store  # noqa: E402
from key_store import ACTIVE, DEAD, EXHAUSTED, RATE_LIMITED, classify_failure  # noqa: E402


# ---------- classification ----------

def test_401_invalid_token_is_dead():
    status, reason, _ = classify_failure(401, '{"error":"Unauthorized - Invalid token"}')
    assert status == DEAD
    assert reason == "unauthorized"


def test_401_flagged_account_is_dead():
    status, reason, _ = classify_failure(
        401, '{"error":"Your account has been flagged. Add paid balance..."}')
    assert status == DEAD


def test_401_busy_body_is_throttle_not_death():
    # documented in SKILL.md: provider-wide "busy" 401 must NOT kill the key
    status, reason, cooldown = classify_failure(
        401, '{"error":"Free access is busy, try again shortly"}')
    assert status == RATE_LIMITED
    assert reason == "throttled"
    assert cooldown == config.RATE_LIMIT_COOLDOWN


def test_402_is_exhausted_with_5h_cooldown():
    status, reason, cooldown = classify_failure(
        402, '{"error":"5-hour included-usage limit reached."}')
    assert status == EXHAUSTED
    assert reason == "payment_required"
    assert cooldown == config.EXHAUSTED_COOLDOWN == 5 * 3600


def test_429_is_rate_limited():
    status, reason, cooldown = classify_failure(429, "slow down")
    assert status == RATE_LIMITED
    assert cooldown == config.RATE_LIMIT_COOLDOWN


def test_429_honors_retry_after_capped():
    _, _, cooldown = classify_failure(429, "", retry_after="45")
    assert cooldown == 45.0
    _, _, cooldown = classify_failure(429, "", retry_after="9999")
    assert cooldown == config.RATE_LIMIT_COOLDOWN_MAX


def test_transient_5xx_is_rate_limited():
    for code in (500, 502, 503, 504, 529):
        status, reason, _ = classify_failure(code, "")
        assert status == RATE_LIMITED, code
        assert reason == f"upstream_{code}"


def test_400_is_not_a_rotation_failure():
    assert classify_failure(400, '{"error":"bad model"}') is None
    assert classify_failure(404, "") is None


# ---------- store fixtures ----------

@pytest.fixture
def store(tmp_path, monkeypatch):
    keys_file = tmp_path / "keys.json"
    state_file = tmp_path / "state.json"
    keys_file.write_text(json.dumps({"keys": [
        {"key": f"aero_live_test{i:02d}KEY{i:02d}", "label": f"key-{i}",
         "status": "active", "dead_reason": None, "last_used_at": None}
        for i in range(1, 5)
    ]}))
    return key_store.KeyStore(keys_file=keys_file, state_file=state_file)


# ---------- persistence round-trip ----------

def test_state_schema_matches_v1(store):
    raw = json.loads(Path(store.state_file).read_text())
    assert set(raw.keys()) == {"active_index", "keys"}
    entry = raw["keys"][0]
    assert set(entry.keys()) == {"key", "status", "dead_reason", "last_used_at",
                                "rate_limited_until", "exhausted_until",
                                "dead_since", "request_count"}


def test_existing_state_survives_reload(store):
    store.mark_failure(1, DEAD, "unauthorized", None)
    store.mark_used(0)
    reloaded = key_store.KeyStore(keys_file=store.keys_file,
                                  state_file=store.state_file)
    assert reloaded.entries[1]["status"] == DEAD
    assert reloaded.entries[1]["dead_reason"] == "unauthorized"
    assert reloaded.entries[0]["request_count"] == 1
    assert reloaded.active_index == store.active_index


def test_live_state_json_loads():
    """The real on-disk state.json (78 keys) must load unmodified."""
    live = Path(__file__).resolve().parent.parent / "core_legacy" / "state.json"
    if not live.exists():
        pytest.skip("no live state backup")
    state = json.loads(live.read_text())
    assert "active_index" in state and "keys" in state
    entry = state["keys"][0]
    for field in ("key", "status", "dead_reason", "last_used_at",
                  "rate_limited_until", "exhausted_until", "dead_since",
                  "request_count"):
        assert field in entry


# ---------- selection / rotation ----------

def test_pick_is_sticky(store):
    assert store.pick()[1] == "key-1"
    assert store.pick()[1] == "key-1"


def test_rotation_moves_forward_and_persists(store):
    idx, label, _ = store.pick()
    store.mark_failure(idx, DEAD, "unauthorized", None)
    idx2, label2, _ = store.pick()
    assert label2 == "key-2"
    raw = json.loads(Path(store.state_file).read_text())
    assert raw["active_index"] == idx2


def test_all_dead_returns_none(store):
    for i in range(4):
        store.mark_failure(i, DEAD, "unauthorized", None)
    assert store.pick() is None


# ---------- lazy revival ----------

def test_rate_limited_revives_after_cooldown(store, monkeypatch):
    store.mark_failure(0, RATE_LIMITED, "throttled", 30.0)
    assert store.pick()[1] == "key-2"
    real_time = time.time
    monkeypatch.setattr(key_store.time, "time", lambda: real_time() + 61)
    store.active_index = 0
    idx, label, _ = store.pick()
    assert label == "key-1"
    assert store.entries[0]["status"] == ACTIVE


def test_exhausted_revives_after_5h(store, monkeypatch):
    store.mark_failure(0, EXHAUSTED, "payment_required", config.EXHAUSTED_COOLDOWN)
    assert store.entries[0]["dead_reason"].startswith("exhausted (revives at ")
    real_time = time.time
    monkeypatch.setattr(key_store.time, "time", lambda: real_time() + 5 * 3600 + 1)
    store.active_index = 0
    assert store.pick()[1] == "key-1"


def test_dead_gets_safety_retry_after_6h(store, monkeypatch):
    store.mark_failure(0, DEAD, "unauthorized", None)
    real_time = time.time
    monkeypatch.setattr(key_store.time, "time", lambda: real_time() + 6 * 3600 + 1)
    store.active_index = 0
    assert store.pick()[1] == "key-1"


# ---------- hot-reload race guard ----------

def test_mark_failure_after_pool_shrunk_reresolves_by_key(store):
    """A request captures (idx, key), then a hot-reload shrinks/reorders the
    pool before mark_* runs. The store must re-resolve by key, never IndexError."""
    idx, label, key = store.pick()
    assert idx == 0
    # reload with only the last key kept; the picked key is gone entirely
    keep = store.entries[3]["key"]
    Path(store.keys_file).write_text(json.dumps({"keys": [
        {"key": keep, "label": "key-1", "status": "active",
         "dead_reason": None, "last_used_at": None},
    ]}))
    store.load()
    # picked key no longer exists -> both mark_* calls become safe no-ops
    store.mark_failure(idx, DEAD, "unauthorized", None, key=key)
    store.mark_used(idx, key=key)
    assert len(store.entries) == 1
    assert store.entries[0]["status"] == ACTIVE  # survivor untouched


def test_mark_failure_after_reorder_hits_the_right_key(store):
    idx, label, key = store.pick()
    # reload with the pool reversed: the picked key is now at the far end
    reversed_keys = [e["key"] for e in reversed(store.entries)]
    Path(store.keys_file).write_text(json.dumps({"keys": [
        {"key": k, "label": f"key-{i+1}", "status": "active",
         "dead_reason": None, "last_used_at": None}
        for i, k in enumerate(reversed_keys)
    ]}))
    store.load()
    store.mark_failure(idx, DEAD, "unauthorized", None, key=key)
    dead = [e for e in store.entries if e["status"] == DEAD]
    assert len(dead) == 1
    assert dead[0]["key"] == key  # the right key died, not whoever sat at idx


def test_mark_failure_without_key_out_of_range_is_noop(store):
    store.mark_failure(99, DEAD, "unauthorized", None)  # no crash
    assert all(e["status"] == ACTIVE for e in store.entries)


# ---------- status report ----------

def test_status_masks_keys_to_last6(store):
    report = store.status_report()
    for k in report["keys"]:
        assert len(k["key_tail"]) == 6
        assert "aero_live" not in k["key_tail"]
    assert report["keys"][0]["active"] is True
