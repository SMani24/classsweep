#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m venv "$ROOT_DIR/.venv"
"$ROOT_DIR/.venv/bin/python" -m pip install -c "$ROOT_DIR/server/requirements.lock" -e "$ROOT_DIR/server[test]"
echo "Server installed. Start it with: python3 scripts/run_server.py"
