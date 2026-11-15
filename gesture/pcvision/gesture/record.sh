#!/usr/bin/env bash
# Record a gesture dataset from the webcam.
#
#   bash pcvision/gesture/record.sh                     # guided, 1 round
#   bash pcvision/gesture/record.sh --rounds 4           # 4 rounds = 4 sessions
#   bash pcvision/gesture/record.sh --manual             # freeform Space-to-save
#
# One "round" records every class once (Space starts each class).  Each round
# is a separate session, which is what makes the train/val split honest.
# Any further flags go to capture_gestures.py (--names, --seconds, --camera...).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"
PY="$QS_GESTURE_HOME/env/bin/python"

ROUNDS=1
if [ "${1:-}" = "--rounds" ]; then
  ROUNDS="${2:?--rounds needs a number}"
  shift 2
fi

if [ "${1:-}" = "--manual" ]; then
  shift
  exec "$PY" "$HERE/capture_gestures.py" "$@"
fi

for i in $(seq 1 "$ROUNDS"); do
  echo "== recording round $i/$ROUNDS (new session) =="
  "$PY" "$HERE/capture_gestures.py" --guided "$@" || break
done
echo
echo "done. next:"
echo "  bash pcvision/gesture/run_pipeline.sh all"
