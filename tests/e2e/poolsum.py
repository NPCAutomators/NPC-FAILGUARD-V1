"""Print a one-line key-pool summary from the local status endpoint."""
import json
import urllib.request

d = json.load(urllib.request.urlopen(
    "http://127.0.0.1:8787/_npc-failguard/status", timeout=5))
ks = d.get("keys", [])
c: dict = {}
cur = "?"
for k in ks:
    c[k["status"]] = c.get(k["status"], 0) + 1
    if k.get("active"):
        cur = k["label"]
print(len(ks), "keys:", " ".join(f"{s}={n}" for s, n in sorted(c.items())),
      "current=" + cur)
