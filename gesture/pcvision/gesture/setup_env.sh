#!/usr/bin/env bash
# ScreenSense gesture training - create the isolated Python environment.
#
#   bash pcvision/gesture/setup_env.sh            # CUDA build (default)
#   bash pcvision/gesture/setup_env.sh --cpu      # CPU-only build
#
# Everything is installed under $QS_GESTURE_HOME (default:
# <repo>/../gesture-env, falling back to <repo>/../../gesture-env).
# Nothing touches the system Python or ~/.cache.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

MODE=cuda
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --cpu) MODE=cpu ;;
    --cuda) MODE=cuda ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,10p' "$HERE/setup_env.sh"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "== ScreenSense gesture env =="
echo "workspace : $QS_GESTURE_HOME"
echo "repo      : $QS_GESTURE_REPO"
echo "mode      : $MODE"
echo

mkdir -p "$QS_GESTURE_HOME"/{env,cache,data/raw,runs,out,tmp}
cd "$QS_GESTURE_HOME"

if [ "$FORCE" -eq 1 ]; then
  echo "--force: rebuilding the venv from scratch"
  rm -rf "$QS_GESTURE_HOME/env"
fi

if [ ! -x "$QS_GESTURE_HOME/env/bin/python" ]; then
  echo "== creating venv =="
  python3 -m venv "$QS_GESTURE_HOME/env"
fi

PY="$QS_GESTURE_HOME/env/bin/python"
$PY -m pip install --upgrade pip

echo
echo "== installing torch ($MODE) =="
if [ "$MODE" = cuda ]; then
  TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu124}"
else
  TORCH_INDEX="https://download.pytorch.org/whl/cpu"
fi
$PY -m pip install --index-url "$TORCH_INDEX" torch

echo
echo "== installing training deps =="
$PY -m pip install -r "$HERE/requirements.txt"

echo
echo "== verify =="
$PY - <<'PY'
import sys
import numpy, scipy, cv2, torch
print("python    ", sys.version.split()[0])
print("numpy     ", numpy.__version__)
print("scipy     ", scipy.__version__)
print("opencv    ", cv2.__version__)
print("torch     ", torch.__version__)
print("cuda avail", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu       ", torch.cuda.get_device_name(0))
    print("gpu mem   ", round(torch.cuda.get_device_properties(0).total_memory / 2**30, 1), "GiB")
PY

echo
echo "== recording install manifest =="
bash "$HERE/manifest.sh" >/dev/null

echo
echo "env ready.  Activate with:"
echo "  source $HERE/env.sh"
echo "next:"
echo "  bash $HERE/doctor.sh"
