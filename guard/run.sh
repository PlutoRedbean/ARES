#!/usr/bin/env bash
# guard 本地入口：自动构建（首次）后转到 tools/guard_cli.py
#
#   ./run.sh demo
#   ./run.sh text "手机 13800138000"
#   ./run.sh file examples/sample.txt --policy token
#   ./run.sh repl
#   ./run.sh report examples/sample.txt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RED="build/obj_redtop/Vredact"
DET="build/obj_detect/Vdetect"

if [ ! -x "$RED" ] || [ ! -x "$DET" ]; then
    echo "[guard] 首次运行，构建 Verilator 驱动（约 10s）..." >&2
    make -s redact-harness harness >/dev/null
fi

exec python3 tools/guard_cli.py "$@"
