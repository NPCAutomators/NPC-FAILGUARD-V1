# PLAN v2.2 — One-command install + first-setup from inside Claude Code

> **Executor instructions (READ FIRST).** You are implementing a fully pre-designed
> feature. Do the tasks IN ORDER (T1 → T8). Every task gives you the exact file,
> the exact content or exact edit anchor, and a VERIFY command with its expected
> output. After each task run the VERIFY; if it fails or an edit anchor is not
> found verbatim, **STOP and report — do not improvise or "fix" the plan.**
> All design decisions are already made. You never need to make one.

---

## Goal

A user on any PC (with or without Claude Code) runs ONE command:

```
curl -fsSL <HOST_URL>/bootstrap.sh | bash
```

That installs NPC FailGuard + Claude Code (if missing), configures everything
**except API keys/provider**. The user then opens `claude` and types:

```
/npc-failguard:setup https://provider.example.com key1 key2 key3
```

…and everything works from that moment. This works even with zero working keys
beforehand, because the slash command's `` !`bash` `` block executes client-side
BEFORE Claude Code calls the model — by the time the model call happens, the
proxy already has keys and forwards it successfully.

## Ground rules (guardrails — apply to every task)

1. **Never print, log, or commit a full API key.** Always mask with the existing
   `mask()` helper (last 6 chars). Files containing keys are written with the
   existing `config.secure_write_json` / `write_api_txt` helpers (chmod 600).
2. **Do NOT touch** `core/key_store.py`, `core/proxy.py`, `core/usage.py`,
   `core/config.py`, `core/main.py`. This feature needs none of them.
3. **Never restart the live daemon.** All key/provider changes go through
   `manage.py`'s `hot_reload()` (already exists).
4. **Do not run `git commit` or `git push`.** (Repo history contains leaked keys;
   cleanup is a separate task owned by the user.)
5. All JSON merges into `~/.claude/settings.json` and `~/.claude.json` must be
   **read-modify-write of only the named keys** — never rebuild these files from
   scratch, never drop unknown keys. Both merges must be **idempotent** (running
   twice produces "no changes").
6. Paths contain a space (`/home/npc/Desktop/NPC FailGuard`) — always quote.
7. Python venv for tests: `./core/.venv/bin/python` (run from repo root).

## Existing facts you rely on (verified 2026-07-18 on the dev machine)

- `manage.py` already has: `mask`, `parse_keys_txt`, `load_keys`, `save_keys`,
  `new_entry`, `write_api_txt`, `reset_state`, `hot_reload`, and commands
  add-key / import-txt / replace-txt / remove-key / set-base-url / status /
  usage / set-budget / reset-usage. Dispatch = argparse subparsers with
  `set_defaults(fn=...)`.
- `install.sh` parses args in a `for arg in "$@"` loop (`--no-claude` exists) and
  ends with a "step 8" block that interactively offers `api-setup.sh`.
- `scripts/setup-claude-code.sh` installs Claude Code if missing and merges
  `env` + `statusLine` into `~/.claude/settings.json` via an inline python3
  heredoc.
- Plugin registration schema **proven working** in `~/.claude/settings.json`:
  ```json
  "enabledPlugins": {"npc-failguard@npc-failguard-local": true},
  "extraKnownMarketplaces": {"npc-failguard-local": {"source": {"source": "directory", "path": "<REPO_DIR>"}}}
  ```
- Onboarding state lives in `~/.claude.json` (NOT settings.json):
  `hasCompletedOnboarding` (bool) and `customApiKeyResponses`
  (`{"approved": [...], "rejected": [...]}` — entries are the **last 20 chars**
  of the key). Our dummy key `npc-failguard-proxy-ignores-this` →
  last-20 = `d-proxy-ignores-this`.
  **Known bug being fixed by T4:** on the dev machine that suffix sits in
  `rejected` (the user once answered "No" to the API-key prompt). It works there
  only because the proxy ignores client auth — on a fresh PC a "No" means the
  login page and a dead end. T4 must both APPROVE the suffix and REMOVE it from
  `rejected`.

---

## T1 — `manage.py first-setup` (one-shot keys + provider, no model needed)

**File:** `core/manage.py` (additive edits only).

### T1a. Add the command function

Find this exact anchor line:

```python
def cmd_remove_key(args) -> int:
```

Insert **above** it (with one blank line separating from the previous function):

```python
def cmd_first_setup(args) -> int:
    """One-shot bootstrap: parse a mixed token list into base URL + keys
    (tokens may arrive in any order; a token may also be a keys-file path).
    Refuses to clobber an existing key set unless --replace is given."""
    url = None
    keys: list[str] = []
    for raw in args.tokens:
        for tok in re.split(r"[,\s]+", raw.strip()):
            if not tok:
                continue
            if re.match(r"^https?://", tok):
                if url is None:
                    url = tok.rstrip("/")
                continue
            if os.path.isfile(tok):
                try:
                    keys.extend(parse_keys_txt(tok))
                except OSError as exc:
                    print(f"error: cannot read keys file {tok}: {exc}")
                    return 1
            else:
                keys.append(tok)
    if url is None:
        print("error: no base URL found - include one token starting with "
              "http:// or https:// (e.g. https://api.example.com)")
        return 1
    if not keys:
        print("error: no API keys found - pass keys (space/comma separated) "
              "and/or a path to a keys .txt file")
        return 1
    existing = load_keys()
    if existing and not args.replace:
        print(f"already configured: {len(existing)} keys present. "
              "Re-run with --replace to wipe and replace them "
              "(or use add-key / add-keys-txt to append).")
        return 2
    seen: set[str] = set()
    entries: list[dict] = []
    for k in keys:
        if k not in seen:
            seen.add(k)
            entries.append(new_entry(k, len(entries) + 1))
    config.secure_write_json(config.PROVIDER_FILE, {"base_url": url})
    save_keys(entries)
    write_api_txt([e["key"] for e in entries])
    reset_state()
    print(f"first-setup done: {len(entries)} keys, base URL {url}")
    print(hot_reload())
    return 0


```

### T1b. Register the subparser

Find this exact anchor block:

```python
    s = sub.add_parser("replace-txt", help="replace the whole key set from a txt file")
    s.add_argument("path")
    s.set_defaults(fn=cmd_replace_txt)
```

Insert **directly after** it:

```python
    s = sub.add_parser("first-setup",
                       help="one-shot: base URL + keys (any order, file or inline)")
    s.add_argument("--replace", action="store_true",
                   help="allow replacing an existing key set")
    s.add_argument("tokens", nargs="+")
    s.set_defaults(fn=cmd_first_setup)
```

### VERIFY T1

```bash
cd "/home/npc/Desktop/NPC FailGuard" && ./core/.venv/bin/python -m py_compile core/manage.py && \
./core/.venv/bin/python core/manage.py first-setup 2>&1 | head -2
```

Expected: no compile error; argparse usage error mentioning `tokens` (exit ≠ 0 is fine here).
Then a behavioral check that must NOT touch real files — run with a temp HOME-style env:

```bash
cd "/home/npc/Desktop/NPC FailGuard" && ./core/.venv/bin/python - <<'EOF'
import sys, tempfile, pathlib
sys.path.insert(0, "core")
import config, manage
tmp = pathlib.Path(tempfile.mkdtemp())
config.KEYS_FILE = tmp/"keys.json"; config.STATE_FILE = tmp/"state.json"
config.PROVIDER_FILE = tmp/"provider.json"; config.API_TXT_FILE = tmp/"api.txt"
rc = manage.main(["first-setup", "https://x.example.com", "aaa111,bbb222", "ccc333"])
assert rc == 0, rc
assert len(manage.load_keys()) == 3
rc = manage.main(["first-setup", "https://y.example.com", "ddd444"])
assert rc == 2, "must refuse without --replace"
rc = manage.main(["first-setup", "--replace", "https://y.example.com", "ddd444"])
assert rc == 0 and len(manage.load_keys()) == 1
print("T1 OK")
EOF
```

Expected output ends with `T1 OK`.

---

## T2 — Rewrite `commands/setup.md` (first-setup from inside Claude)

**File:** `commands/setup.md` — REPLACE the entire file with exactly:

```markdown
---
description: First-time setup or provider switch — give API keys + provider base URL in one shot, entirely from inside Claude Code. Works even before any key is configured.
argument-hint: <base-url> <key1 key2 ... | /path/to/keys.txt>
allowed-tools: Bash(bash:*)
---
## NPC FailGuard setup

The command below already ran BEFORE this request reached the model — that is
what makes first-time setup possible even with zero working keys: keys + URL
land in the proxy first, then this very reply travels through it.

!`bash -c 'PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/bin/python"; [ -x "$PY" ] || PY="${CLAUDE_PLUGIN_ROOT}/core/.venv/Scripts/python.exe"; "$PY" "${CLAUDE_PLUGIN_ROOT}/core/manage.py" first-setup "$@"' _ $ARGUMENTS`

Interpret the output above:

- **"first-setup done: N keys, base URL …"** → tell the user setup is complete
  and working (this very reply already went through the proxy). Suggest
  `/npc-failguard:status` (free) and `/npc-failguard:set-budget <usd>`.
- **"already configured: N keys present"** → keys already exist. Ask the user to
  confirm they want to REPLACE everything (old keys + state wiped). Only after an
  explicit yes, re-run:
  `bash -c '…manage.py first-setup --replace <their args>'` (same pattern as above).
  If they only want to add keys, point them to `/npc-failguard:add-key` /
  `/npc-failguard:add-keys-txt`.
- **"error: no base URL found"** → ask for the provider base URL
  (must start with http:// or https://) and re-run with all arguments.
- **"error: no API keys found"** → ask for keys (pasted directly, space or comma
  separated, or a path to a .txt file) and re-run with all arguments.
- **"proxy not reachable"** after a done-line → keys are saved; the daemon is not
  running. Run `/npc-failguard:restart`, then `/npc-failguard:status`.

Rules: never echo a full API key back to the user (they appear masked as
`...last6` in the output — keep it that way). Keys may arrive in any order,
mixed with the URL; `manage.py` sorts that out — do not pre-parse arguments.
```

### VERIFY T2

```bash
cd "/home/npc/Desktop/NPC FailGuard" && head -5 commands/setup.md | grep -c "First-time setup"
```

Expected: `1`.

---

## T3 — `install.sh --no-keys` (deterministic bootstrap mode)

**File:** `install.sh`. Two exact edits.

### T3a. Find:

```bash
SKIP_CLAUDE=0
for arg in "$@"; do
    case "$arg" in
        --no-claude) SKIP_CLAUDE=1 ;;
    esac
done
```

Replace with:

```bash
SKIP_CLAUDE=0
SKIP_KEYS=0
for arg in "$@"; do
    case "$arg" in
        --no-claude) SKIP_CLAUDE=1 ;;
        --no-keys)   SKIP_KEYS=1 ;;
    esac
done
```

### T3b. Find:

```bash
# ---- 8. Offer to auto-run api-setup.sh ----
if [ -x "$SCRIPT_DIR/api-setup.sh" ] && [ -t 0 ]; then
```

Replace with:

```bash
# ---- 8. Offer to auto-run api-setup.sh ----
if [ "$SKIP_KEYS" -eq 1 ]; then
    echo "  Keys/provider NOT configured yet (--no-keys)."
    echo "  Next: open a NEW terminal, run 'claude', then type:"
    echo "     /npc-failguard:setup <base-url> <key1 key2 ...>"
elif [ -x "$SCRIPT_DIR/api-setup.sh" ] && [ -t 0 ]; then
```

### VERIFY T3

```bash
cd "/home/npc/Desktop/NPC FailGuard" && bash -n install.sh && grep -c 'no-keys' install.sh
```

Expected: no syntax error; count ≥ 2.

---

## T4 + T5 — Zero-touch onboarding + plugin auto-register

**File:** `scripts/setup-claude-code.sh`. One edit: the python3 heredoc currently
receives 3 argv (`SETTINGS PORT STATUSLINE_SH`). Extend to 5 and add two merge
steps. Make these exact changes:

### T4a. Find:

```bash
STATUSLINE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
```

Replace with:

```bash
STATUSLINE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_JSON="$HOME/.claude.json"
```

### T4b. Find:

```bash
    python3 - "$SETTINGS" "$PORT" "$STATUSLINE_SH" <<'PYEOF'
import json, os, sys

path, port, statusline = sys.argv[1], sys.argv[2], sys.argv[3]
```

Replace with:

```bash
    python3 - "$SETTINGS" "$PORT" "$STATUSLINE_SH" "$PLUGIN_DIR" "$CLAUDE_JSON" <<'PYEOF'
import json, os, sys

path, port, statusline, plugin_dir, claude_json = sys.argv[1:6]
```

### T4c. Find (end of the heredoc, before `PYEOF`):

```python
if changed:
    print(f"[✓] settings.json updated ({', '.join(changed)})")
else:
    print("[✓] settings.json already configured (no changes)")
PYEOF
```

Replace with:

```python
# ---- plugin auto-register (same proven schema the /plugin UI writes) ----
mkts = data.setdefault("extraKnownMarketplaces", {})
want_mkt = {"source": {"source": "directory", "path": plugin_dir}}
if mkts.get("npc-failguard-local") != want_mkt:
    mkts["npc-failguard-local"] = want_mkt
    changed["plugin-marketplace"] = plugin_dir
plugins = data.setdefault("enabledPlugins", {})
if plugins.get("npc-failguard@npc-failguard-local") is not True:
    plugins["npc-failguard@npc-failguard-local"] = True
    changed["plugin-enabled"] = "npc-failguard"

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)

if changed:
    print(f"[✓] settings.json updated ({', '.join(changed)})")
else:
    print("[✓] settings.json already configured (no changes)")

# ---- zero-touch onboarding: ~/.claude.json ----
# Skips the first-run wizard AND pre-approves our dummy API key so the
# "Detected a custom API key ... use it? (y/n)" prompt never appears.
# A past "No" is also healed: the suffix is removed from `rejected`.
cj = {}
if os.path.exists(claude_json):
    try:
        with open(claude_json) as f:
            cj = json.load(f)
    except ValueError:
        print(f"[!] {claude_json} is invalid JSON - left untouched "
              "(onboarding prompts may appear once).")
        cj = None
if cj is not None:
    suffix = "npc-failguard-proxy-ignores-this"[-20:]
    cj_changed = False
    if cj.get("hasCompletedOnboarding") is not True:
        cj["hasCompletedOnboarding"] = True
        cj_changed = True
    ckr = cj.setdefault("customApiKeyResponses", {})
    approved = ckr.setdefault("approved", [])
    rejected = ckr.setdefault("rejected", [])
    if suffix not in approved:
        approved.append(suffix)
        cj_changed = True
    if suffix in rejected:
        ckr["rejected"] = [s for s in rejected if s != suffix]
        cj_changed = True
    if cj_changed:
        tmp = claude_json + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cj, f, indent=2)
        os.replace(tmp, claude_json)
        print("[✓] ~/.claude.json: onboarding skipped + proxy key pre-approved")
    else:
        print("[✓] ~/.claude.json already configured (no changes)")
PYEOF
```

> Note for the executor: T4c REPLACES the old final-write block — the
> `tmp = path + ".tmp"` write that used to sit there is included again above
> (after the plugin merge) so nothing is lost. The heredoc must still end with
> a line containing only `PYEOF`, and there must be exactly one such write of
> `path` in the final file.

### VERIFY T4+T5

```bash
cd "/home/npc/Desktop/NPC FailGuard" && bash -n scripts/setup-claude-code.sh && bash scripts/setup-claude-code.sh && \
python3 -c "
import json, os
s = json.load(open(os.path.expanduser('~/.claude/settings.json')))
assert s['enabledPlugins']['npc-failguard@npc-failguard-local'] is True
assert s['extraKnownMarketplaces']['npc-failguard-local']['source']['path'].endswith('NPC FailGuard')
assert s['env']['ANTHROPIC_BASE_URL'].startswith('http://127.0.0.1')
c = json.load(open(os.path.expanduser('~/.claude.json')))
assert c['hasCompletedOnboarding'] is True
assert 'd-proxy-ignores-this' in c['customApiKeyResponses']['approved']
assert 'd-proxy-ignores-this' not in c['customApiKeyResponses']['rejected']
print('T4+T5 OK')
"
```

Expected: ends with `T4+T5 OK`. Run the script a SECOND time — it must print
"no changes" lines (idempotency).

---

## T6 — `scripts/bootstrap.sh` (the curl target)

**File:** `scripts/bootstrap.sh` — CREATE with exactly this content, then
`chmod +x` it:

```bash
#!/usr/bin/env bash
# NPC FailGuard one-command installer (the curl target).
#   curl -fsSL <HOST_URL>/bootstrap.sh | bash
# Downloads the app, installs everything (incl. Claude Code if missing),
# and defers keys/provider to a single in-Claude command.
set -euo pipefail

# ==== EDIT BEFORE HOSTING ===================================================
TARBALL_URL="${NPC_FAILGUARD_TARBALL:-https://REPLACE-ME.example.com/npc-failguard.tar.gz}"
# ============================================================================
INSTALL_DIR="$HOME/.npc-failguard/app"
KEEP_FILES="keys.json state.json provider.json api.txt stats.json pricing.json"

echo "==> NPC FailGuard bootstrap"
case "$TARBALL_URL" in *REPLACE-ME*) 
    echo "[!] This bootstrap script has no download URL configured."; exit 1;; esac
for dep in curl tar python3; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "[!] Missing dependency: $dep - install it and re-run."; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> Downloading..."
curl -fsSL "$TARBALL_URL" -o "$TMP/app.tar.gz"
mkdir -p "$TMP/x"
tar -xzf "$TMP/app.tar.gz" -C "$TMP/x"
SRC="$(find "$TMP/x" -maxdepth 2 -name install.sh -printf '%h\n' | head -1)"
[ -n "$SRC" ] || { echo "[!] install.sh not found inside the archive."; exit 1; }

if [ -d "$INSTALL_DIR" ]; then
    echo "==> Existing install found - upgrading (keys/state preserved)"
    for f in $KEEP_FILES; do
        [ -f "$INSTALL_DIR/core/$f" ] && cp -p "$INSTALL_DIR/core/$f" "$TMP/x/" || true
    done
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$(dirname "$INSTALL_DIR")"
mv "$SRC" "$INSTALL_DIR"
for f in $KEEP_FILES; do
    [ -f "$TMP/x/$f" ] && mv "$TMP/x/$f" "$INSTALL_DIR/core/$f" || true
done

echo "==> Running installer..."
bash "$INSTALL_DIR/install.sh" --no-keys < /dev/null

echo ""
echo "==================================================================="
echo "  Bootstrap complete."
echo "  1. Open a NEW terminal and run:  claude"
echo "  2. Inside Claude, type:"
echo "     /npc-failguard:setup <base-url> <key1 key2 ... or /path/keys.txt>"
echo "==================================================================="
```

Notes baked into this design (do not change):
- `< /dev/null` on install.sh keeps every interactive prompt off even when the
  user runs bootstrap in a TTY.
- Upgrade path preserves the 6 runtime files listed in `KEEP_FILES`.
- The tarball URL is a placeholder — the user will host either a GitHub release
  tarball (`https://github.com/<u>/<r>/archive/refs/heads/main.tar.gz`, repo
  must be public) or a tarball on their website. `NPC_FAILGUARD_TARBALL` env
  overrides it for testing.

### VERIFY T6

```bash
cd "/home/npc/Desktop/NPC FailGuard" && chmod +x scripts/bootstrap.sh && bash -n scripts/bootstrap.sh && \
bash scripts/bootstrap.sh 2>&1 | head -3
```

Expected: syntax OK; run prints the "no download URL configured" error and
exits 1 (that is the CORRECT result on this machine — do not "fix" it).
Full end-to-end: `tar -czf /tmp/nf.tar.gz -C "/home/npc/Desktop" "NPC FailGuard" && NPC_FAILGUARD_TARBALL="file:///tmp/nf.tar.gz" bash scripts/bootstrap.sh`
— only run this full test if the user asks; it installs a second copy under
`~/.npc-failguard` (harmless, removable with `rm -rf ~/.npc-failguard`), but
note `curl` handles `file://` URLs, and the installer will re-point
settings.json's marketplace path at the new copy — afterwards re-run
`bash "/home/npc/Desktop/NPC FailGuard/scripts/setup-claude-code.sh"` to point it back.

---

## T7 — Tests

**File:** `tests/test_manage_setup.py` — CREATE:

```python
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
```

### VERIFY T7

```bash
cd "/home/npc/Desktop/NPC FailGuard" && ./core/.venv/bin/python -m pytest tests/ -q 2>&1 | tail -1
```

Expected: `45 passed` (40 existing + 5 new). Any failure → STOP and report.

---

## T8 — Docs + version

1. **`README.md`** — directly under the `## Install on Linux` heading, add:

   ```markdown
   ### One-command install (recommended)

   ```bash
   curl -fsSL <YOUR-HOST-URL>/bootstrap.sh | bash
   ```

   Installs everything — the proxy daemon, and Claude Code itself if missing —
   with no prompts. Then open a new terminal, run `claude`, and type:

   ```
   /npc-failguard:setup <base-url> <key1 key2 ... or /path/to/keys.txt>
   ```

   That single in-Claude command adds your keys + provider and everything is
   live from that reply onward — no terminal setup, no restart. (Replace
   `<YOUR-HOST-URL>` with where you host `scripts/bootstrap.sh`, and set
   `TARBALL_URL` inside it.)
   ```

2. **`README.md`** commands table — replace the `/npc-failguard:setup` row's
   description with: `First-time setup / switch provider — base URL + keys in one shot, works before any key exists` and its cost with `free`.
3. **`skills/manage/SKILL.md`** quick-ops table — update the
   `/npc-failguard:setup` row the same way (it currently says it runs
   api-setup.sh with a credit-using health check; the new command is free and
   uses `manage.py first-setup`).
4. **`.claude-plugin/plugin.json`** — `"version": "2.1.0"` → `"2.2.0"`.
5. **`README.md` Files table** (root section) — add row:
   `| scripts/bootstrap.sh | One-command curl installer (host this + a tarball) |`

### VERIFY T8

```bash
cd "/home/npc/Desktop/NPC FailGuard" && grep -c "One-command install" README.md && grep '"version"' .claude-plugin/plugin.json
```

Expected: count ≥ 1 and version `2.2.0`.

---

## Final acceptance checklist (run all, report results as a table)

```bash
cd "/home/npc/Desktop/NPC FailGuard"
./core/.venv/bin/python -m pytest tests/ -q | tail -1        # 45 passed
bash -n install.sh scripts/bootstrap.sh scripts/setup-claude-code.sh
./core/.venv/bin/python -m py_compile core/manage.py
./core/.venv/bin/python core/manage.py status | head -2      # daemon untouched, keys intact
curl -s -m 2 http://127.0.0.1:8787/_npc-failguard/status >/dev/null && echo LIVE-OK
grep -c 'first-setup' commands/setup.md                      # >= 1
```

Everything green → done. Report: what changed per task, verify outputs, and
anything you had to STOP on.

## Out of scope (do NOT do)

- Windows bootstrap (`bootstrap.ps1`) and Windows statusline — separate task.
- git history key cleanup, commits, pushes.
- set-budget race fix, budget alerts, daily spend buckets (see backlog in the
  session plan file).
- Hosting: the user uploads `bootstrap.sh` + tarball and fills `TARBALL_URL`.
