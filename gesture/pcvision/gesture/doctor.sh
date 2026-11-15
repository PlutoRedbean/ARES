#!/usr/bin/env bash
# ScreenSense gesture training - environment and camera doctor.
set +e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

ok()   { printf '  [ok]   %s\n' "$1"; }
bad()  { printf '  [MISS] %s\n' "$1"; FAIL=1; }
warn() { printf '  [warn] %s\n' "$1"; }
FAIL=0

echo "== workspace =="
ok "workspace $QS_GESTURE_HOME"
if [ -x "$QS_GESTURE_HOME/env/bin/python" ]; then
  ok "venv present"
else
  bad "venv missing (bash pcvision/gesture/setup_env.sh)"
fi
case "$QS_GESTURE_REPO" in
  /mnt/*) warn "repo on NTFS: git may report filemode noise (git config core.filemode false)" ;;
esac
touch "$QS_GESTURE_HOME/.write_test" 2>/dev/null && ok "workspace writable" && rm -f "$QS_GESTURE_HOME/.write_test" || bad "workspace not writable"

echo "== python =="
if [ -x "$QS_GESTURE_HOME/env/bin/python" ]; then
  "$QS_GESTURE_HOME/env/bin/python" -c "import sys; print('  [info]', sys.version.split()[0], sys.executable)"
  for m in numpy scipy cv2 torch; do
    "$QS_GESTURE_HOME/env/bin/python" -c "import $m" 2>/dev/null && ok "$m" || bad "$m"
  done
  "$QS_GESTURE_HOME/env/bin/python" - <<'PY'
import torch
print('  [info] torch', torch.__version__, '| cuda:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('  [info] gpu  ', torch.cuda.get_device_name(0))
PY
else
  bad "cannot test packages without the venv"
fi

echo "== camera =="
"$QS_GESTURE_HOME/env/bin/python" - <<'PY' 2>&1
import cv2, sys
cap = cv2.VideoCapture(0, cv2.CAP_V4L2)
if not cap.isOpened():
    cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print('  [MISS] cannot open camera 0')
    sys.exit(1)
cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'MJPG'))
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
for _ in range(5):
    ok, frame = cap.read()
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)); h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
fps = cap.get(cv2.CAP_PROP_FPS)
cap.release()
if not ok:
    print('  [MISS] camera opened but no frame')
    sys.exit(1)
print(f'  [ok]   camera frame {w}x{h} @ {fps:.1f} fps')
PY
[ $? -ne 0 ] && FAIL=1

echo "== display =="
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
  ok "graphical session (DISPLAY=$DISPLAY WAYLAND=$WAYLAND_DISPLAY)"
else
  bad "no DISPLAY - capture and live demo need a desktop session"
fi

echo "== data =="
if [ -f "$QS_GESTURE_DATA/raw/labels.csv" ]; then
  n=$(( $(wc -l < "$QS_GESTURE_DATA/raw/labels.csv") - 1 ))
  ok "$n labelled frames in $QS_GESTURE_DATA/raw"
else
  warn "no dataset yet (run bash pcvision/gesture/record.sh)"
fi

echo "== disk =="
df -h "$QS_GESTURE_HOME" | tail -1
echo "  workspace size: $(du -sh "$QS_GESTURE_HOME" 2>/dev/null | cut -f1)"

echo
if [ "$FAIL" -eq 0 ]; then echo "READY"; else echo "NOT READY - fix the [MISS] items above"; fi
exit $FAIL
