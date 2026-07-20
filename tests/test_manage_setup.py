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


def test_partial_setups_now_succeed(capsys):
    # keys only -> stored, provider guidance shown
    assert manage.main(["first-setup", "k-only-key"]) == 0
    assert len(manage.load_keys()) == 1
    out = capsys.readouterr().out
    assert "next: set provider" in out
    # url only -> provider set, keys guidance shown (keys kept from above)
    assert manage.main(["first-setup", "https://p.example.com"]) == 0
    assert config.load_provider()["base_url"] == "https://p.example.com"
    out = capsys.readouterr().out
    assert "setup complete" in out


def test_no_args_shows_state_not_error(capsys):
    assert manage.main(["first-setup"]) == 0
    out = capsys.readouterr().out
    assert "provider : NOT SET yet" in out
    assert "keys     : none yet" in out
    assert "error" not in out.lower()


def test_url_only_refusal_leaves_keys_untouched():
    assert manage.main(["first-setup", "https://a.example.com", "k-1"]) == 0
    # keys given again without --replace -> refused, provider NOT switched
    assert manage.main(["first-setup", "https://c.example.com", "k-9"]) == 2
    assert config.load_provider()["base_url"] == "https://a.example.com"
    keys = manage.load_keys()
    assert len(keys) == 1 and keys[0]["key"] == "k-1"


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


def test_add_key_without_provider_hints_setup(capsys):
    assert manage.main(["add-key", "k-lonely-key"]) == 0
    out = capsys.readouterr().out
    assert "provider NOT SET yet" in out
    # once the provider exists, the hint disappears
    assert manage.main(["set-base-url", "https://p.example.com"]) == 0
    capsys.readouterr()
    assert manage.main(["add-key", "k-second-key"]) == 0
    assert "provider NOT SET yet" not in capsys.readouterr().out
