"""Tests for the proxy rotation flow and endpoints (httpx mocked via respx)."""

import json
import sys
from pathlib import Path

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))

import config  # noqa: E402
import key_store  # noqa: E402
import proxy  # noqa: E402

UPSTREAM = "https://mock-provider.test"


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    keys_file = tmp_path / "keys.json"
    state_file = tmp_path / "state.json"
    keys_file.write_text(json.dumps({"keys": [
        {"key": f"aero_live_test{i:02d}KEY{i:02d}", "label": f"key-{i}",
         "status": "active", "dead_reason": None, "last_used_at": None}
        for i in range(1, 4)
    ]}))
    monkeypatch.setattr(config, "KEYS_FILE", keys_file)
    monkeypatch.setattr(config, "STATE_FILE", state_file)
    monkeypatch.setattr(config, "base_url", lambda: UPSTREAM)

    proxy.store = key_store.KeyStore(keys_file=keys_file, state_file=state_file)
    proxy.client = httpx.AsyncClient()
    with TestClient(proxy.app) as tc:
        yield tc


def _msg_route():
    return respx.post(f"{UPSTREAM}/v1/messages")


@respx.mock
def test_success_passthrough(app_client):
    route = _msg_route().mock(return_value=httpx.Response(
        200, json={"content": [{"text": "ok"}]}))
    r = app_client.post("/v1/messages", json={"model": "m", "messages": []})
    assert r.status_code == 200
    sent = route.calls[0].request
    assert sent.headers["x-api-key"].endswith("KEY01")
    assert sent.headers["authorization"].startswith("Bearer ")


@respx.mock
def test_rotates_on_401_then_succeeds(app_client):
    _msg_route().mock(side_effect=[
        httpx.Response(401, json={"error": "Unauthorized - Invalid token"}),
        httpx.Response(200, json={"content": []}),
    ])
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 200
    assert proxy.store.entries[0]["status"] == key_store.DEAD
    assert proxy.store.labels[proxy.store.active_index] == "key-2"


@respx.mock
def test_busy_401_throttles_instead_of_killing(app_client):
    _msg_route().mock(side_effect=[
        httpx.Response(401, json={"error": "Free access is busy, try again"}),
        httpx.Response(200, json={"content": []}),
    ])
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 200
    assert proxy.store.entries[0]["status"] == key_store.RATE_LIMITED


@respx.mock
def test_all_keys_down_returns_503_with_retry_after(app_client):
    _msg_route().mock(return_value=httpx.Response(
        401, json={"error": "Unauthorized - Invalid token"}))
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 503
    assert r.headers["retry-after"] == str(config.NO_KEYS_RETRY_AFTER)
    assert all(e["status"] == key_store.DEAD for e in proxy.store.entries)


def test_empty_pool_says_add_keys_not_cooling_down(app_client, tmp_path):
    # fresh install: provider set but zero keys -> friendly guidance, no Retry-After
    proxy.store = key_store.KeyStore(keys_file=tmp_path / "none.json",
                                     state_file=tmp_path / "none_state.json")
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 503
    assert "add-key" in r.json()["error"]
    assert "retry-after" not in r.headers


def test_no_provider_says_run_setup(app_client, monkeypatch):
    monkeypatch.setattr(config, "base_url", lambda: "")
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 503
    assert "setup" in r.json()["error"]


@respx.mock
def test_rotation_cap_stops_pool_burn(app_client, monkeypatch, tmp_path):
    # 30-key pool, everything 402s -> cap must stop the cascade early
    keys_file = tmp_path / "many_keys.json"
    keys_file.write_text(json.dumps({"keys": [
        {"key": f"aero_live_burn{i:03d}XX{i:03d}", "label": f"key-{i}",
         "status": "active", "dead_reason": None, "last_used_at": None}
        for i in range(1, 31)
    ]}))
    proxy.store = key_store.KeyStore(keys_file=keys_file,
                                     state_file=tmp_path / "many_state.json")
    monkeypatch.setattr(config, "MAX_ROTATIONS_PER_REQUEST", 10)
    _msg_route().mock(return_value=httpx.Response(
        402, json={"error": "limit reached"}))
    r = app_client.post("/v1/messages", json={"model": "m"})
    assert r.status_code == 503
    burned = sum(1 for e in proxy.store.entries
                 if e["status"] != key_store.ACTIVE)
    assert burned == 10  # not the whole pool


@respx.mock
def test_client_error_400_passes_through_without_rotation(app_client):
    _msg_route().mock(return_value=httpx.Response(
        400, json={"error": "model not found"}))
    r = app_client.post("/v1/messages", json={"model": "bad"})
    assert r.status_code == 400
    assert proxy.store.entries[0]["status"] == key_store.ACTIVE


@respx.mock
def test_streaming_passthrough(app_client):
    sse = b'event: message_start\ndata: {"type":"message_start"}\n\n'
    _msg_route().mock(return_value=httpx.Response(
        200, content=sse, headers={"content-type": "text/event-stream"}))
    r = app_client.post("/v1/messages", json={"model": "m", "stream": True})
    assert r.status_code == 200
    assert r.content == sse


@respx.mock
def test_streaming_error_before_bytes_rotates(app_client):
    _msg_route().mock(side_effect=[
        httpx.Response(401, json={"error": "Unauthorized - Invalid token"}),
        httpx.Response(200, content=b"data: ok\n\n",
                       headers={"content-type": "text/event-stream"}),
    ])
    r = app_client.post("/v1/messages", json={"model": "m", "stream": True})
    assert r.status_code == 200
    assert proxy.store.entries[0]["status"] == key_store.DEAD


def test_status_endpoint_masks_keys(app_client):
    r = app_client.get("/_npc-failguard/status")
    assert r.status_code == 200
    body = r.text
    assert "aero_live_test" not in body
    ks = r.json()["keys"]
    assert len(ks) == 3
    assert all(len(k["key_tail"]) == 6 for k in ks)


def test_root_returns_200_not_305(app_client):
    assert app_client.get("/").status_code == 200
    assert app_client.head("/").status_code == 200


def test_reload_picks_up_new_keys(app_client, tmp_path):
    new = json.loads(Path(config.KEYS_FILE).read_text())
    new["keys"].append({"key": "aero_live_addedNEWKEY9", "label": "key-4",
                        "status": "active", "dead_reason": None,
                        "last_used_at": None})
    Path(config.KEYS_FILE).write_text(json.dumps(new))
    r = app_client.post("/_npc-failguard/reload")
    assert r.status_code == 200
    assert r.json()["keys"] == 4
