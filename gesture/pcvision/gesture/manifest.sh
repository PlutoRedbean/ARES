#!/usr/bin/env bash
# ScreenSense gesture training - regenerate the install manifest.
#
# Writes $QS_GESTURE_HOME/MANIFEST.md and install_manifest.tsv: every directory
# and file this training chain created, with its size, so cleanup is auditable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

mkdir -p "$QS_GESTURE_HOME"
MD="$QS_GESTURE_HOME/MANIFEST.md"
TSV="$QS_GESTURE_HOME/install_manifest.tsv"
PY="$QS_GESTURE_HOME/env/bin/python"

stamp="$(date -Is)"
total="$(du -sh "$QS_GESTURE_HOME" 2>/dev/null | cut -f1)"

{
  echo "# Gesture training install manifest"
  echo
  echo "Generated: $stamp"
  echo
  echo "Workspace: $QS_GESTURE_HOME"
  echo "Repo (git-tracked scripts only): $QS_GESTURE_REPO"
  echo "Total workspace size: **$total**"
  echo
  echo "Everything below is outside git and can be deleted with"
  echo "pcvision/gesture/cleanup.sh --yes   (add --keep-data to keep the dataset)."
  echo
  echo "| Path | Size | Kind |"
  echo "|---|---:|---|"
  printf '| %s | %s | workspace root |\n' "$QS_GESTURE_HOME" "$total"
  for d in env cache cache/pip cache/torch cache/xdg data data/raw runs out tmp; do
    [ -e "$QS_GESTURE_HOME/$d" ] || continue
    printf '| %s | %s | %s |\n' "$QS_GESTURE_HOME/$d" "$(du -sh "$QS_GESTURE_HOME/$d" 2>/dev/null | cut -f1)" "$d"
  done
  echo
  echo "## Python packages"
  echo
  echo "~~~"
  if [ -x "$PY" ]; then
    "$PY" -m pip list --format=freeze 2>/dev/null | sed 's/==/ == /' | sort
  else
    echo "(venv missing)"
  fi
  echo "~~~"
  echo
  echo "## System packages installed by this chain"
  echo
  echo "- None. setup_env.sh only creates the venv above."
  echo "- If you later install extra apt packages (camera tools, NVIDIA CUDA), add them here by hand."
  echo
  echo "## Disk"
  echo
  echo "~~~"
  df -h "$QS_GESTURE_HOME" | tail -1
  echo "~~~"
  echo
  echo "## Dataset / model inventory"
  echo
  echo "~~~"
  if [ -f "$QS_GESTURE_DATA/raw/labels.csv" ]; then
    echo "labelled frames: $(( $(wc -l < "$QS_GESTURE_DATA/raw/labels.csv") - 1 ))"
  else
    echo "labelled frames: 0"
  fi
  find "$QS_GESTURE_RUNS" -maxdepth 2 -type f \( -name '*.pt' -o -name '*.json' \) -printf '%p  %k KiB\n' 2>/dev/null | sort | head -40
  echo "~~~"
} > "$MD"

{
  printf 'path\tsize\tcreated\n'
  printf '%s\t%s\t%s\n' "$QS_GESTURE_HOME" "$total" "$stamp"
  for d in env cache data runs out tmp; do
    [ -e "$QS_GESTURE_HOME/$d" ] || continue
    printf '%s\t%s\t%s\n' "$QS_GESTURE_HOME/$d" "$(du -sh "$QS_GESTURE_HOME/$d" 2>/dev/null | cut -f1)" "$stamp"
  done
} > "$TSV"

echo "manifest -> $MD"
echo "total    -> $total"
