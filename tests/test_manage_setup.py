"""first-setup: token parsing, refuse-then-replace, file expansion."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))

import config  # noqa: E402
import manage  # noqa: E402


@pytest.fixture(autouse=True)
def sandbox(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "KEYS_FILE", tmp_path / "keys.json")
    monkeypatch.setattr(config, "STATE_FILE", tmp_path / "state.json")
    monkeypatch.setattr(config, "PROVIDER_FILE", tmp_path / "provider.json")
    monkeypatch.setattr(config, "API_TXT_FILE", tmp_path / "api.txt")
    monkeypatch.setattr(manage, "hot_reload", lambda: "(reload skipped in test)")
    return tmp_path


def test_url_and_inline_keys_any_order(capsys):
    assert manage.main(["first-setup", "k-aaa111", "https://p.example.com", "k-bbb222,k-ccc333"]) == 0
    assert len(manage.load_keys()) == 3
    assert config.load_provider()["base_url"] == "https://p.example.com"
    out = capsys.readouterr().out
    assert "k-aaa111" not in out          # keys never printed in full


def test_keys_file_token_is_expanded(sandbox):
    kf = sandbox / "my.txt"
    kf.write_text("k-one\n# comment\nk-two\n")
    assert manage.main(["first-setup", str(kf), "https://p.example.com"]) == 0
    assert len(manage.load_keys()) == 2


def test_missing_url_or_keys_errors():
    assert manage.main(["first-setup", "k-only-key"]) == 1
    assert manage.main(["first-setup", "https://p.example.com"]) == 1


def test_refuses_overwrite_then_replace_works():
    assert manage.main(["first-setup", "https://a.example.com", "k-1"]) == 0
    assert manage.main(["first-setup", "https://b.example.com", "k-2"]) == 2
    assert config.load_provider()["base_url"] == "https://a.example.com"
    assert manage.main(["first-setup", "--replace", "https://b.example.com", "k-2"]) == 0
    keys = manage.load_keys()
    assert len(keys) == 1 and keys[0]["key"] == "k-2"


def test_duplicate_keys_deduped():
    assert manage.main(["first-setup", "https://p.example.com", "k-x,k-x", "k-x"]) == 0
    assert len(manage.load_keys()) == 1
