"""NPC FailGuard - non-interactive management CLI.

The engine behind the /npc-failguard:* key-management slash commands and the
--keys-file/--base-url flags of api-setup.sh. Pure stdlib (plus the local
config module), cross-platform, and never prints a full key - always masked
to the last 6 characters.

Usage:
  manage.py add-key <key>            add one key, hot-reload the proxy
  manage.py import-txt <path>        append every key from a txt file
  manage.py replace-txt <path>       replace the whole key set (state reset)
  manage.py remove-key <label|tail>  remove a key by label or last-6 chars
  manage.py set-base-url <url>       switch the provider base URL
  manage.py status                   free local status summary
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

import config

_NUMBERED = re.compile(r"^\d+\s+(\S+)$")


def mask(key: str) -> str:
    return f"...{key[-6:]}" if len(key) > 6 else "***"


# ---------- file helpers ----------

def parse_keys_txt(path) -> list[str]:
    """Same rules as the v1 api-setup.sh parser: skip blank lines and
    # comments, accept both `key` and `N  key` numbered formats."""
    keys: list[str] = []
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = _NUMBERED.match(line)
            keys.append(m.group(1) if m else line)
    return keys


def load_keys() -> list[dict]:
    try:
        with open(config.KEYS_FILE, "r", encoding="utf-8") as f:
            return json.load(f).get("keys", [])
    except (OSError, ValueError):
        return []


def save_keys(entries: list[dict]) -> None:
    config.secure_write_json(config.KEYS_FILE, {"keys": entries})


def new_entry(key: str, n: int) -> dict:
    return {"key": key, "label": f"key-{n}", "status": "active",
            "dead_reason": None, "last_used_at": None}


def relabel(entries: list[dict]) -> None:
    for i, e in enumerate(entries):
        e["label"] = f"key-{i + 1}"


def write_api_txt(keys: list[str]) -> None:
    """Keep core/api.txt (the default keys file) in sync with keys.json."""
    tmp = config.API_TXT_FILE.with_name(config.API_TXT_FILE.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(keys) + "\n")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, config.API_TXT_FILE)


def reset_state() -> None:
    try:
        config.STATE_FILE.unlink()
    except OSError:
        pass


def hot_reload() -> str:
    """POST /_npc-failguard/reload; falls back to a hint if daemon is down."""
    url = f"http://{config.HOST}:{config.PORT}/_npc-failguard/reload"
    try:
        with urllib.request.urlopen(
                urllib.request.Request(url, method="POST"), timeout=10) as r:
            data = json.loads(r.read())
        if data.get("ok"):
            return f"proxy reloaded ({data.get('keys')} keys, upstream {data.get('base_url')})"
        return f"proxy reload FAILED: {data.get('error')}"
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return (f"proxy not reachable ({exc}); changes saved to disk - "
                "restart the daemon to apply them")


# ---------- commands ----------

def _provider_hint() -> str | None:
    """One-line nudge when keys exist but no provider is set yet (free)."""
    if load_base_url() is None:
        return ("note: provider NOT SET yet - keys are saved but requests "
                "can't flow until you run: setup https://api.example.com")
    return None


def cmd_add_key(args) -> int:
    key = args.key.strip()
    if not key:
        print("error: empty key")
        return 1
    entries = load_keys()
    if any(e["key"] == key for e in entries):
        print(f"key {mask(key)} already exists ({next(e['label'] for e in entries if e['key'] == key)})")
        return 1
    entries.append(new_entry(key, len(entries) + 1))
    save_keys(entries)
    write_api_txt([e["key"] for e in entries])
    print(f"added {mask(key)} as key-{len(entries)} (total {len(entries)} keys)")
    print(hot_reload())
    hint = _provider_hint()
    if hint:
        print(hint)
    return 0


def cmd_import_txt(args) -> int:
    try:
        new_keys = parse_keys_txt(args.path)
    except OSError as exc:
        print(f"error: cannot read {args.path}: {exc}")
        return 1
    if not new_keys:
        print(f"error: no keys found in {args.path}")
        return 1
    entries = load_keys()
    existing = {e["key"] for e in entries}
    added = 0
    for k in new_keys:
        if k not in existing:
            entries.append(new_entry(k, len(entries) + 1))
            existing.add(k)
            added += 1
    save_keys(entries)
    write_api_txt([e["key"] for e in entries])
    skipped = len(new_keys) - added
    msg = f"imported {added} new keys from {args.path} (total {len(entries)})"
    if skipped:
        msg += f", skipped {skipped} duplicates"
    print(msg)
    print(hot_reload())
    hint = _provider_hint()
    if hint:
        print(hint)
    return 0


def cmd_replace_txt(args) -> int:
    try:
        new_keys = parse_keys_txt(args.path)
    except OSError as exc:
        print(f"error: cannot read {args.path}: {exc}")
        return 1
    if not new_keys:
        print(f"error: no keys found in {args.path}")
        return 1
    seen: set[str] = set()
    entries = []
    for k in new_keys:
        if k not in seen:
            seen.add(k)
            entries.append(new_entry(k, len(entries) + 1))
    save_keys(entries)
    write_api_txt([e["key"] for e in entries])
    reset_state()   # full replacement -> fresh state
    print(f"replaced key set with {len(entries)} keys from {args.path} (state reset)")
    print(hot_reload())
    hint = _provider_hint()
    if hint:
        print(hint)
    return 0


def load_base_url():
    try:
        with open(config.PROVIDER_FILE, "r", encoding="utf-8") as f:
            return json.load(f).get("base_url") or None
    except (OSError, ValueError):
        return None


def _setup_state_lines() -> list[str]:
    """Human status of the two setup halves - all local, zero credit."""
    url = load_base_url()
    n = len(load_keys())
    lines = [f"provider : {url}" if url else "provider : NOT SET yet",
             f"keys     : {n} loaded" if n else "keys     : none yet"]
    if url and n:
        lines.append(f"setup complete - requests will rotate through {n} key(s).")
    else:
        if not url:
            lines.append("next: set provider  ->  setup https://api.example.com")
        if not n:
            lines.append("next: add keys anytime  ->  add-key <key>  or  add-keys-txt <file.txt>")
        lines.append("(all of this is free - no provider credit is used)")
    return lines


def cmd_first_setup(args) -> int:
    """Guided bootstrap. EVERY argument is optional:
      - no args       -> show setup state + what to do next (free, never errors)
      - base URL only -> set provider now, add keys later
      - keys only     -> store keys now, set provider later
      - URL + keys    -> classic one-shot setup
    Tokens arrive in any order; a token may be a keys-file path.
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
            elif tok.lower().endswith(".txt") or os.sep in tok:
                # clearly meant as a file path - don't silently store it as a "key"
                print(f"error: keys file not found: {tok}")
                return 1
            else:
                keys.append(tok)

    # ---- nothing given: report state + guide (free, exit 0) ----
    if url is None and not keys:
        print("\n".join(_setup_state_lines()))
        return 0

    # refuse-to-clobber check FIRST so a refusal changes nothing at all
    if keys:
        existing = load_keys()
        if existing and not args.replace:
            print(f"already configured: {len(existing)} keys present. "
                  "Re-run with --replace to wipe and replace them "
                  "(or use add-key / add-keys-txt to append).")
            return 2

    if url is not None:
        config.secure_write_json(config.PROVIDER_FILE, {"base_url": url})
        print(f"provider set: {url}")

    if keys:
        seen: set[str] = set()
        entries: list[dict] = []
        for k in keys:
            if k not in seen:
                seen.add(k)
                entries.append(new_entry(k, len(entries) + 1))
        save_keys(entries)
        write_api_txt([e["key"] for e in entries])
        reset_state()
        print(f"stored {len(entries)} key(s)")

    print(hot_reload())
    print("--")
    print("\n".join(_setup_state_lines()))
    return 0


def cmd_remove_key(args) -> int:
    ident = args.ident.strip()
    entries = load_keys()
    matches = [e for e in entries
               if e["label"] == ident or e["key"].endswith(ident)]
    if not matches:
        print(f"error: no key matches '{ident}' (use a label like key-7 or the last 6 chars)")
        return 1
    if len(matches) > 1:
        print(f"error: '{ident}' matches {len(matches)} keys "
              f"({', '.join(m['label'] for m in matches)}); be more specific")
        return 1
    victim = matches[0]
    entries.remove(victim)
    relabel(entries)
    save_keys(entries)
    write_api_txt([e["key"] for e in entries])
    reset_state()   # labels shifted -> old state no longer maps cleanly
    print(f"removed {victim['label']} ({mask(victim['key'])}); {len(entries)} keys remain (relabeled)")
    print(hot_reload())
    return 0


def cmd_set_base_url(args) -> int:
    url = args.url.strip().rstrip("/")
    if not re.match(r"^https?://", url):
        print("error: base URL must start with http:// or https://")
        return 1
    config.secure_write_json(config.PROVIDER_FILE, {"base_url": url})
    print(f"base URL set to {url}")
    print(hot_reload())
    return 0


def cmd_usage(args) -> int:
    """Free: token/cost summary from the local usage endpoint (falls back to
    reading stats.json directly if the daemon is down)."""
    import usage as usage_mod
    url = f"http://{config.HOST}:{config.PORT}/_npc-failguard/usage"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError):
        data = usage_mod.UsageTracker().report()
    spent = data.get("spent_usd", 0.0)
    budget = data.get("budget_usd")
    line = f"spent ${spent:.4f}"
    if isinstance(budget, (int, float)):
        line += f" of ${budget:.2f} budget (${data.get('remaining_usd', budget - spent):.4f} left)"
    else:
        line += " (no budget set - manage.py set-budget <usd>)"
    print(line)
    for model, m in sorted(data.get("models", {}).items()):
        print(f"  {model}: {m['requests']} req, "
              f"in {m['input_tokens']:,} / out {m['output_tokens']:,} / "
              f"cache r{m['cache_read_tokens']:,} w{m['cache_write_tokens']:,} "
              f"-> ${m.get('cost_usd', 0):.4f}")
    return 0


def cmd_set_budget(args) -> int:
    import usage as usage_mod
    try:
        budget = float(args.usd)
    except ValueError:
        print("error: budget must be a number (USD), e.g. set-budget 50")
        return 1
    tracker = usage_mod.UsageTracker()
    tracker.budget_usd = budget if budget > 0 else None
    tracker.save()
    if tracker.budget_usd is None:
        print("budget cleared (pass a positive number to set one)")
    else:
        print(f"budget set to ${budget:.2f}")
    print(hot_reload())
    return 0


def cmd_reset_usage(args) -> int:
    import time as time_mod
    import usage as usage_mod
    tracker = usage_mod.UsageTracker()
    tracker.models = {}
    tracker.since = time_mod.time()
    tracker.save()
    print("usage counters reset (budget kept)")
    print(hot_reload())
    return 0


def cmd_status(args) -> int:
    url = f"http://{config.HOST}:{config.PORT}/_npc-failguard/status"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"proxy not responding on {config.HOST}:{config.PORT} ({exc})")
        print("free to fix: restart the daemon (scripts/service.sh restart "
              "or /npc-failguard:restart), then re-run status")
        return 1
    keys = data.get("keys", [])
    url = load_base_url()
    if not keys:
        print("proxy is up - no keys yet:")
        print("\n".join(_setup_state_lines()))
        return 0
    counts: dict[str, int] = {}
    current = "?"
    for k in keys:
        counts[k["status"]] = counts.get(k["status"], 0) + 1
        if k.get("active"):
            current = k["label"]
    summary = ", ".join(f"{v} {s}" for s, v in sorted(counts.items()))
    print(f"{len(keys)} keys ({summary}); current: {current}")
    if not url:
        print("provider : NOT SET yet - free to fix: "
              "setup https://api.example.com (or set-base-url <url>)")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="manage.py",
                                description="NPC FailGuard management CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("add-key", help="add one API key")
    s.add_argument("key")
    s.set_defaults(fn=cmd_add_key)

    s = sub.add_parser("import-txt", help="append keys from a txt file")
    s.add_argument("path")
    s.set_defaults(fn=cmd_import_txt)

    s = sub.add_parser("replace-txt", help="replace the whole key set from a txt file")
    s.add_argument("path")
    s.set_defaults(fn=cmd_replace_txt)

    s = sub.add_parser("first-setup",
                       help="guided setup: base URL and/or keys, all optional")
    s.add_argument("--replace", action="store_true",
                   help="allow replacing an existing key set")
    s.add_argument("tokens", nargs="*")
    s.set_defaults(fn=cmd_first_setup)

    s = sub.add_parser("remove-key", help="remove a key by label or last-6 chars")
    s.add_argument("ident")
    s.set_defaults(fn=cmd_remove_key)

    s = sub.add_parser("set-base-url", help="switch the provider base URL")
    s.add_argument("url")
    s.set_defaults(fn=cmd_set_base_url)

    s = sub.add_parser("status", help="local status summary (free)")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("usage", help="token/cost summary (free, local)")
    s.set_defaults(fn=cmd_usage)

    s = sub.add_parser("set-budget", help="set total credit budget in USD")
    s.add_argument("usd")
    s.set_defaults(fn=cmd_set_budget)

    s = sub.add_parser("reset-usage", help="zero the token/cost counters")
    s.set_defaults(fn=cmd_reset_usage)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
