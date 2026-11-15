#!/usr/bin/env bash
# ScreenSense gesture training platform - single entry point.
#
#   bash pcvision/gesture/gesture.sh <command> [args]
#
# Everything else under pcvision/gesture/ is an internal implementation detail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh"

usage() {
  cat <<'EOF'
ScreenSense gesture platform

  setup [--cpu|--cuda|--force]   create the isolated venv + deps
  doctor                         environment / camera check
  app [--port N]                 web workbench (record/train/eval/monitor)
  record [--rounds N] [--manual] collect gestures (guided by default)
  train [--epochs N] [...]       train from data/raw
  eval [--thresh T]              export .mat + float/bit-exact evaluation
  all                            train -> export -> eval -> pack
  monitor                        CLI real-time monitor
  demo                           print the local demo URL
  status                         dataset / model / workspace summary
  manifest                       refresh install manifest
  clean [--yes] [--keep-data]    remove the isolated workspace
  smoke                          synthetic end-to-end self-test
  help                           this text

Typical first run:
  bash pcvision/gesture/gesture.sh setup
  bash pcvision/gesture/gesture.sh doctor
  bash pcvision/gesture/gesture.sh app
  # browser: http://127.0.0.1:8765  (demo: /demo)
EOF
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift || true

case "$cmd" in
  setup)    exec bash "$HERE/setup_env.sh" "$@" ;;
  doctor)   exec bash "$HERE/doctor.sh" ;;
  app)      exec bash "$HERE/app.sh" "$@" ;;
  record)   exec bash "$HERE/record.sh" "$@" ;;
  train)    exec bash "$HERE/run_pipeline.sh" train "$@" ;;
  export)   exec bash "$HERE/run_pipeline.sh" export "$@" ;;
  eval)     exec bash "$HERE/run_pipeline.sh" eval "$@" ;;
  all)      exec bash "$HERE/run_pipeline.sh" all "$@" ;;
  pack)     exec bash "$HERE/run_pipeline.sh" pack "$@" ;;
  smoke)    exec bash "$HERE/run_pipeline.sh" smoke "$@" ;;
  status)   exec bash "$HERE/run_pipeline.sh" status ;;
  monitor)  exec bash "$HERE/monitor.sh" "$@" ;;
  manifest) exec bash "$HERE/manifest.sh" ;;
  clean)    exec bash "$HERE/cleanup.sh" "$@" ;;
  demo)     echo "workbench: http://127.0.0.1:8765"; echo "demo page: http://127.0.0.1:8765/demo" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
