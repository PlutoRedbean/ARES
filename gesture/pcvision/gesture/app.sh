#!/usr/bin/env bash
# Start the local gesture workbench (camera + record + train + eval + monitor).
#
#   bash pcvision/gesture/app.sh
#   bash pcvision/gesture/app.sh --port 8765 --camera 0
#
# Open the printed URL in a browser. Ctrl+C in this terminal stops it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

if [ ! -x "$QS_GESTURE_HOME/env/bin/python" ]; then
  echo "environment missing - run: bash pcvision/gesture/setup_env.sh" >&2
  exit 1
fi
exec "$QS_GESTURE_HOME/env/bin/python" "$HERE/webapp.py" "$@"
