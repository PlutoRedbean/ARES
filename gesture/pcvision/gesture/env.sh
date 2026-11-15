# shellcheck shell=bash
# ScreenSense gesture training - isolated environment variables.
# Source this before any gesture command:  . pcvision/gesture/env.sh
#
# Everything the training chain writes lives under QS_GESTURE_HOME so it can be
# removed in one go later.  Nothing is installed outside that directory except
# the git-tracked scripts themselves.

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _qs_src="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_qs_src="${(%):-%x}"'
else
  _qs_src="$0"
fi

QS_GESTURE_REPO="${QS_GESTURE_REPO:-$(cd "$(dirname "$_qs_src")/../.." 2>/dev/null && pwd)}"

# Workspace: $QS_GESTURE_HOME if set, else <repo>/../gesture-env, else the
# legacy <repo>/../../gesture-env (rule and rationale: docs/GESTURE.md §2).
if [ -z "${QS_GESTURE_HOME:-}" ]; then
  _qs_parent="$(cd "$QS_GESTURE_REPO/.." 2>/dev/null && pwd)"
  QS_GESTURE_HOME="$_qs_parent/gesture-env"
  if [ ! -d "$QS_GESTURE_HOME" ] && [ -d "$_qs_parent/../gesture-env" ]; then
    QS_GESTURE_HOME="$(cd "$_qs_parent/.." && pwd)/gesture-env"
  fi
  unset _qs_parent
fi
export QS_GESTURE_REPO QS_GESTURE_HOME

export QS_GESTURE_DATA="$QS_GESTURE_HOME/data"
export QS_GESTURE_RUNS="$QS_GESTURE_HOME/runs"
export QS_GESTURE_OUT="$QS_GESTURE_HOME/out"
export QS_GESTURE_CACHE="$QS_GESTURE_HOME/cache"

# Keep every download/build cache inside the workspace instead of ~/.cache,
# so cleanup frees the space that training actually used.
export PIP_CACHE_DIR="$QS_GESTURE_CACHE/pip"
export TORCH_HOME="$QS_GESTURE_CACHE/torch"
export TORCHINDUCTOR_CACHE_DIR="$QS_GESTURE_CACHE/torchinductor"
export TRITON_CACHE_DIR="$QS_GESTURE_CACHE/triton"
export XDG_CACHE_HOME="$QS_GESTURE_CACHE/xdg"
export MPLCONFIGDIR="$QS_GESTURE_CACHE/mpl"
export HF_HOME="$QS_GESTURE_CACHE/huggingface"
export CUDA_CACHE_PATH="$QS_GESTURE_CACHE/cuda"
export NUMBA_CACHE_DIR="$QS_GESTURE_CACHE/numba"

# The venv, when it exists.
if [ -d "$QS_GESTURE_HOME/env/bin" ]; then
  export VIRTUAL_ENV="$QS_GESTURE_HOME/env"
  export PATH="$QS_GESTURE_HOME/env/bin:$PATH"
  unset PYTHONHOME
fi

unset _qs_src
