#!/usr/bin/env python3
"""Merge NPC FailGuard config into Claude Code's settings (cross-platform).

Used by install.ps1 (Windows) - mirrors the python block embedded in
scripts/setup-claude-code.sh (Linux). Merges, never clobbers:
  settings.json : proxy env keys, statusLine (only if absent or ours),
                  plugin marketplace + enable
  ~/.claude.json: skip onboarding wizard, pre-approve the dummy proxy key
All output is plain ASCII (Windows consoles often run a legacy codepage).
"""
import argparse
import json
import os


def load(path):
    """Return (data, was_broken)."""
    if not os.path.exists(path):
        return {}, False
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), False
    except ValueError:
        return None, True


def save(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", required=True)
    ap.add_argument("--claude-json", required=True)
    ap.add_argument("--port", default="8787")
    ap.add_argument("--statusline-cmd", default=None,
                    help='full statusLine command, e.g. powershell -File "...statusline.ps1"')
    ap.add_argument("--statusline-ps1", default=None,
                    help="path to statusline.ps1; the command is built here "
                         "(avoids PS 5.1 quote-mangling of paths with spaces)")
    ap.add_argument("--plugin-dir", required=True)
    a = ap.parse_args()

    sl_cmd = a.statusline_cmd
    if not sl_cmd and a.statusline_ps1:
        sl_cmd = ('powershell -NoProfile -ExecutionPolicy Bypass -File "%s"'
                  % a.statusline_ps1)
    if not sl_cmd:
        ap.error("need --statusline-cmd or --statusline-ps1")

    # ---- settings.json ----
    data, broken = load(a.settings)
    if broken:
        os.replace(a.settings, a.settings + ".broken")
        print("[!] Existing settings.json was invalid JSON; moved to settings.json.broken")
        data = {}

    env = data.setdefault("env", {})
    wanted = {
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{a.port}",
        "ANTHROPIC_API_KEY": "npc-failguard-proxy-ignores-this",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }
    changed = {k for k, v in wanted.items() if env.get(k) != v}
    env.update(wanted)

    # statusLine: only set if the user has none yet or the existing one is ours
    sl = data.get("statusLine")
    if not sl or "npc-failguard" in json.dumps(sl) or "statusline" in json.dumps(sl):
        new_sl = {"type": "command", "command": sl_cmd, "padding": 0}
        if sl != new_sl:
            data["statusLine"] = new_sl
            changed.add("statusLine")
    else:
        print("[!] Existing custom statusLine found - left untouched.")

    mkts = data.setdefault("extraKnownMarketplaces", {})
    want_mkt = {"source": {"source": "directory", "path": a.plugin_dir}}
    if mkts.get("npc-failguard-local") != want_mkt:
        mkts["npc-failguard-local"] = want_mkt
        changed.add("plugin-marketplace")
    plugins = data.setdefault("enabledPlugins", {})
    if plugins.get("npc-failguard@npc-failguard-local") is not True:
        plugins["npc-failguard@npc-failguard-local"] = True
        changed.add("plugin-enabled")

    save(a.settings, data)
    if changed:
        print(f"[OK] settings.json updated ({', '.join(sorted(changed))})")
    else:
        print("[OK] settings.json already configured (no changes)")

    # ---- ~/.claude.json : zero-touch onboarding ----
    cj, broken = load(a.claude_json)
    if broken:
        print("[!] ~/.claude.json is invalid JSON - left untouched "
              "(onboarding prompts may appear once).")
        return
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
        save(a.claude_json, cj)
        print("[OK] ~/.claude.json: onboarding skipped + proxy key pre-approved")
    else:
        print("[OK] ~/.claude.json already configured (no changes)")


if __name__ == "__main__":
    main()
