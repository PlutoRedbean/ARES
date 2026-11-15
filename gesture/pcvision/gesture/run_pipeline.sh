#!/usr/bin/env bash
# ScreenSense gesture pipeline - one entry point for every stage.
#
#   bash pcvision/gesture/run_pipeline.sh status
#   bash pcvision/gesture/run_pipeline.sh train [extra args]
#   bash pcvision/gesture/run_pipeline.sh export [extra args]
#   bash pcvision/gesture/run_pipeline.sh eval
#   bash pcvision/gesture/run_pipeline.sh pack
#   bash pcvision/gesture/run_pipeline.sh all
#   bash pcvision/gesture/run_pipeline.sh smoke
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

DATA="$QS_GESTURE_DATA/raw"
MODEL="${MODEL:-$QS_GESTURE_RUNS/gesture.pt}"
MATS="${MATS:-$QS_GESTURE_OUT/mats}"
PACK="${PACK:-$QS_GESTURE_OUT/hw}"
PY="$QS_GESTURE_HOME/env/bin/python"
GEN="$QS_GESTURE_REPO/fpga/python_script/CnnHardwareGenerator_pds.py"

classes_file="$QS_GESTURE_DATA/classes.json"
num_classes() {
  if [ -f "$classes_file" ]; then
    "$PY" -c "import json;print(len(json.load(open('$classes_file'))['names']))"
  else
    echo "error: $classes_file missing - record gestures first" >&2
    return 1
  fi
}

need_env() {
  if [ ! -x "$PY" ]; then
    echo "error: $PY missing - run bash pcvision/gesture/setup_env.sh first" >&2
    exit 1
  fi
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  status)
    echo "workspace $QS_GESTURE_HOME"
    echo "dataset   $DATA"
    if [ -f "$classes_file" ]; then
      echo "classes   $("$PY" -c "import json;print(', '.join(json.load(open('$classes_file'))['names']))")"
    fi
    if [ -f "$DATA/labels.csv" ]; then
      echo "frames    $(( $(wc -l < "$DATA/labels.csv") - 1 ))"
    else
      echo "frames    0"
    fi
    ls -lh "$MODEL" 2>/dev/null || echo "checkpoint none"
    ls -1 "$MATS" 2>/dev/null | head -3 || true
    du -sh "$QS_GESTURE_HOME" 2>/dev/null | awk '{print "workspace  " $1}'
    ;;
  train)
    need_env
    mkdir -p "$QS_GESTURE_RUNS"
    exec "$PY" "$HERE/train_gestures.py" --data "$DATA" --out "$MODEL" "$@"
    ;;
  export)
    need_env
    k="$(num_classes)"
    exec "$PY" "$QS_GESTURE_REPO/ml/export_mat.py" --ckpt "$MODEL" --out "$MATS" \
        --classes "$k" --calib-dir "$DATA" --calib-count 8 "$@"
    ;;
  eval)
    need_env
    exec "$PY" "$HERE/evaluate.py" --ckpt "$MODEL" --data "$DATA" --mat "$MATS" --split val "$@"
    ;;
  pack)
    need_env
    k="$(num_classes)"
    [ "$k" -le 16 ] || { echo "error: $k classes > 16 hardware channels" >&2; exit 1; }
    exec "$PY" "$QS_GESTURE_REPO/ml/pack_model.py" --mat "$MATS" --gen "$GEN" \
        --out-mem "$PACK/mem_data" --out-vh "$PACK/header" "$@"
    ;;
  all)
    bash "$0" train "$@"
    bash "$0" export
    bash "$0" eval
    bash "$0" pack
    echo
    echo "done. pack -> $PACK"
    echo "manifest: bash pcvision/gesture/manifest.sh"
    ;;
  smoke)
    need_env
    exec "$PY" "$HERE/smoke_test.py" "$@"
    ;;
  doctor)
    exec bash "$HERE/doctor.sh"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    sed -n '2,12p' "$HERE/run_pipeline.sh" >&2
    exit 2
    ;;
esac
