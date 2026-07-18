"""Shipped one-command install URLs must be concrete (no placeholders)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

RAW_CURL = (
    "curl -fsSL https://raw.githubusercontent.com/NPCAutomators/NPC-FAILGUARD-V1/main/bootstrap.sh | bash"
)
ARCHIVE = (
    "https://github.com/NPCAutomators/NPC-FAILGUARD-V1/archive/refs/heads/main.tar.gz"
)


def test_root_bootstrap_is_curl_entrypoint():
    text = (ROOT / "bootstrap.sh").read_text(encoding="utf-8")
    assert "REPLACE-ME" not in text
    assert "GITHUB_REPO=" in text
    assert "NPCAutomators/NPC-FAILGUARD-V1" in text
    assert "archive/refs/heads/" in text
    assert "install.sh" in text
    assert "--no-keys" in text


def test_scripts_bootstrap_delegates_to_root():
    text = (ROOT / "scripts" / "bootstrap.sh").read_text(encoding="utf-8")
    assert "bootstrap.sh" in text
    assert "REPLACE-ME" not in text


def test_readme_documents_root_curl_install():
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    assert "<YOUR-HOST-URL>" not in text
    assert RAW_CURL in text
    assert "scripts/bootstrap.sh | bash" not in text  # prefer shorter root path
