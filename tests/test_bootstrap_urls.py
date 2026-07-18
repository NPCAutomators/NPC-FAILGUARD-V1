"""Shipped one-command install URLs must be concrete (no placeholders)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_bootstrap_default_tarball_is_github_archive():
    text = (ROOT / "scripts" / "bootstrap.sh").read_text(encoding="utf-8")
    assert "REPLACE-ME" not in text
    assert (
        "https://github.com/NPC-AUTOMATORS/NPC-FAILGUARD/archive/refs/heads/main.tar.gz"
        in text
    )
    # Default is overridable for offline / pre-push tests.
    assert "NPC_FAILGUARD_TARBALL" in text


def test_readme_documents_concrete_curl_install():
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    assert "<YOUR-HOST-URL>" not in text
    assert (
        "curl -fsSL https://raw.githubusercontent.com/NPC-AUTOMATORS/NPC-FAILGUARD/main/scripts/bootstrap.sh | bash"
        in text
    )
