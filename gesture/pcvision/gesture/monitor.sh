#!/usr/bin/env bash
# Real-time gesture monitor (PyTorch, webcam).
#
#   bash pcvision/gesture/monitor.sh                 # uses runs/gesture.pt
#   bash pcvision/gesture/monitor.sh <checkpoint.pt> [live_demo args]
#
# Keys: q quit, p pause, r reset action state, s save a screenshot.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

CKPT="${1:-$QS_GESTURE_RUNS/gesture.pt}"
[ $# -gt 0 ] && shift || true

if [ ! -x "$QS_GESTURE_HOME/env/bin/python" ]; then
  echo "environment missing - run: bash pcvision/gesture/setup_env.sh" >&2
  exit 1
fi
if [ ! -f "$CKPT" ]; then
  echo "no checkpoint at $CKPT" >&2
  echo "record first:  bash pcvision/gesture/record.sh" >&2
  echo "then train:   bash pcvision/gesture/run_pipeline.sh all" >&2
  exit 1
fi
exec "$QS_GESTURE_HOME/env/bin/python" "$HERE/live_demo.py" --ckpt "$CKPT" "$@"
