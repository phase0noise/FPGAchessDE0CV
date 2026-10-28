#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compatibility entry point. No pip install or systemd unit is required to run.
exec "${PYTHON:-python3}" "$ROOT/run.py" "$@"
