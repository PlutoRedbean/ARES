#!/usr/bin/env bash
# guard 本地入口：自动选 Python（Windows / WSL / Linux），web 模式起本地服务。
#
#   ./run.sh web                         # 起网页 + 烧写/IMU 接管服务，自动开浏览器
#   ./run.sh web --no-browser --port 8788
#   ./run.sh demo
#   ./run.sh text "手机 13800138000"
#   ./run.sh file examples/sample.txt --policy token
#   ./run.sh repl
#   ./run.sh report examples/sample.txt
#   ./run.sh serial -p COM3 --text "手机 13800138000"   # 上板（串口）
#
# PowerShell 里可以直接（用正斜杠，别写 .\run.sh）：
#   bash run.sh web
#   .\run.ps1 web
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

usage() {
    cat <<'EOF'
guard 本地入口：自动选 Python（Windows / WSL / Linux），web 模式起本地服务。

  ./run.sh web                         # 起网页 + 烧写/IMU 接管服务，自动开浏览器
  ./run.sh web --no-browser --port 8788
  ./run.sh demo
  ./run.sh text "手机 13800138000"
  ./run.sh file examples/sample.txt --policy token
  ./run.sh repl
  ./run.sh report examples/sample.txt
  ./run.sh serial -p COM3 --text "手机 13800138000"   # 上板（串口）

PowerShell 里可以直接（用正斜杠）：
  bash run.sh web
  .\run.ps1 web
EOF
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

# ── 宿主环境 ────────────────────────────────────────────────────────────────
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
HOST="unix"
WINPATH=0
case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            HOST="wsl"
        else
            HOST="linux"
        fi
        ;;
esac

pick_windows_python() {
    WINPATH=1
    # WSL 里优先显式用 py.exe，避免找到 Linux 的同名 py。
    if [ "$HOST" = "wsl" ] && command -v py.exe >/dev/null 2>&1 \
        && py.exe -3.11 -c "" >/dev/null 2>&1; then
        PY=(py.exe -3.11)
    elif command -v py >/dev/null 2>&1 && py -3.11 -c "" >/dev/null 2>&1; then
        PY=(py -3.11)
    elif command -v py >/dev/null 2>&1 && py -3 -c "" >/dev/null 2>&1; then
        PY=(py -3)
    elif command -v py.exe >/dev/null 2>&1 && py.exe -3.11 -c "" >/dev/null 2>&1; then
        PY=(py.exe -3.11)
    elif command -v python >/dev/null 2>&1; then
        PY=(python)
    else
        echo "[guard] 找不到 Windows Python。装 Python 3.11，或把 py.exe 放进 PATH。" >&2
        exit 1
    fi
}

pick_posix_python() {
    WINPATH=0
    if command -v python3 >/dev/null 2>&1; then
        PY=(python3)
    elif command -v python >/dev/null 2>&1; then
        PY=(python)
    else
        echo "[guard] 找不到 python3；先安装 Python 3.10+。" >&2
        exit 1
    fi
}

host_path() {
    # 只有 Windows Python（Git Bash / WSL 启动）需要 D:\...；WSL 的 python3 仍用 /mnt/...
    if [ "${WINPATH:-0}" -eq 0 ]; then
        printf '%s' "$1"
        return
    fi
    case "$HOST" in
        windows)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -w "$1"
            else
                printf '%s' "$1"
            fi
            ;;
        wsl)
            if command -v wslpath >/dev/null 2>&1; then
                wslpath -w "$1"
            else
                printf '%s' "$1"
            fi
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

MODE="${1:-}"

# ── web：guard/web + 串口/IMU 接管服务 ─────────────────────────────────────
if [ "$MODE" = "web" ]; then
    shift
    case "$HOST" in
        windows|wsl) pick_windows_python ;;
        *) pick_posix_python ;;
    esac

    args=()
    no_browser=0
    for arg in "$@"; do
        if [ "$arg" = "--no-browser" ]; then
            no_browser=1
        fi
        args+=("$arg")
    done
    if [ "$no_browser" -eq 0 ]; then
        args+=(--open-browser)
    fi

    SCRIPT="$(host_path "$HERE/tools/board_server.py")"
    echo "[guard] web: ${PY[*]} $SCRIPT ${args[*]}" >&2
    PYTHONUNBUFFERED=1 exec "${PY[@]}" "$SCRIPT" "${args[@]}"
fi

# ── serial：串口直通 tools/serial_host.py（不依赖 Verilator 构建） ─────────
if [ "$MODE" = "serial" ]; then
    shift
    case "$HOST" in
        windows|wsl) pick_windows_python ;;
        *) pick_posix_python ;;
    esac
    PYTHONUNBUFFERED=1 exec "${PY[@]}" "$(host_path "$HERE/tools/serial_host.py")" "$@"
fi

# ── 其它：guard CLI ────────────────────────────────────────────────────────
case "$HOST" in
    windows) pick_windows_python ;;
    *) pick_posix_python ;;
esac

RED="build/obj_redtop/Vredact"
DET="build/obj_detect/Vdetect"

if [ ! -x "$RED" ] || [ ! -x "$DET" ]; then
    if [ "$HOST" = "windows" ]; then
        echo "[guard] Windows 下不自动构建 Verilator harness；web / serial 不需要它。" >&2
    elif command -v make >/dev/null 2>&1; then
        echo "[guard] 首次运行，构建 Verilator 驱动（约 10s）..." >&2
        make -s redact-harness harness >/dev/null 2>&1
    fi
fi

exec "${PY[@]}" "$(host_path "$HERE/tools/guard_cli.py")" "$@"
