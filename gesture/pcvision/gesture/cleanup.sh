#!/usr/bin/env bash
# ScreenSense gesture training - remove the isolated environment.
#
#   bash pcvision/gesture/cleanup.sh              # dry run: show what would go
#   bash pcvision/gesture/cleanup.sh --yes        # remove everything
#   bash pcvision/gesture/cleanup.sh --yes --keep-data   # keep data/ runs/ out/
#
# Only $QS_GESTURE_HOME is ever touched.  The git repo is never modified.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

YES=0
KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    -h|--help) sed -n '2,10p' "$HERE/cleanup.sh"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

WS="$QS_GESTURE_HOME"
if [ -z "$WS" ] || [ "$WS" = "/" ] || [ "$WS" = "$QS_GESTURE_REPO" ]; then
  echo "refusing to remove suspicious path: $WS" >&2
  exit 1
fi
case "$WS" in
  "$QS_GESTURE_REPO"/*) echo "refusing to remove a path inside the repo: $WS" >&2; exit 1 ;;
esac
if [ ! -f "$WS/install_manifest.tsv" ] && [ ! -d "$WS/env" ]; then
  echo "no gesture workspace at $WS (nothing to do)" >&2
  exit 1
fi

echo "workspace: $WS"
echo
for d in env cache data runs out tmp; do
  [ -e "$WS/$d" ] || continue
  printf '  %-10s %s\n' "$d" "$(du -sh "$WS/$d" 2>/dev/null | cut -f1)"
done
echo
echo "total: $(du -sh "$WS" 2>/dev/null | cut -f1)"
echo "disk before: $(df -h "$WS" | tail -1 | awk '{print $4" free"}')"

if [ "$YES" -ne 1 ]; then
  echo
  echo "dry run - nothing removed. Re-run with --yes to delete."
  exit 0
fi

if [ "$KEEP_DATA" -eq 1 ]; then
  echo "--keep-data: removing env/cache/tmp only"
  for d in env cache tmp; do rm -rf "$WS/$d"; done
  rm -f "$WS/install_manifest.tsv"
else
  echo "removing $WS ..."
  rm -rf --one-file-system "$WS"
fi

echo "disk after: $(df -h /home | tail -1 | awk '{print $4" free"}')"
echo "done. The repo still contains the scripts (git branch feat/gesture-pipeline)."
