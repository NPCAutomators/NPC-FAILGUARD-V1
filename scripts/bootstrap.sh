#!/usr/bin/env bash
# Back-compat wrapper — preferred curl target is repo-root bootstrap.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/bootstrap.sh" "$@"
