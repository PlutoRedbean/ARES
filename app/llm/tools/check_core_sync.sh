#!/usr/bin/env bash
# Check that both applications carry the same core and miniTensor, and that
# rtl/core still matches the ARES checkout apart from the documented reset-entry
# change in Mundus_PC.v.
#
#   tools/check_core_sync.sh [/path/to/ARES]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$(cd "$ROOT/.." && pwd)"
ARES=${1:-/home/ccy/Documents/qs/ARES}
fail=0

echo "== llm vs gesture: rtl/ (the gesture camera front end is app-specific) =="
if diff -r --exclude=cam --exclude=board_gesture.v "$APP/llm/rtl" "$APP/gesture/rtl"; then
  echo "   identical"
else
  fail=1
fi

echo "== rtl/core vs ARES =="
missing=0
for f in Mundus.sv myCPU.v RegisterFile.v BimodalRas.v ReturnAddressStack.v \
         Divider.v Multplier.v div.v mult.v \
         DCacheData_BRAM.v DCacheTag_BRAM.v DCacheLru_BRAM.v icache/pipeline_icache.v; do
  a="$ARES/rtl/pipeline/core/vsrc/build/$f"
  [ -f "$a" ] || a="$ARES/rtl/pipeline/core/vsrc/Mundus/$f"
  [ -f "$a" ] || a="$ARES/rtl/pipeline/soc/ip/$f"
  [ -f "$a" ] || a="$ARES/rtl/pipeline/core/vsrc/icache/$(basename "$f")"
  if [ ! -f "$a" ]; then
    echo "   MISSING source $f"; missing=1; continue
  fi
  if ! cmp -s "$a" "$APP/llm/rtl/core/$f"; then
    echo "   DIFF $f"; fail=1
  fi
done
[ "$missing" -eq 0 ] || fail=1

# Mundus_PC.v: only the entry constant differs (plus its comment).
norm_pc() { grep -v '^[[:space:]]*//' "$1" \
  | sed "s/32'h80000000/PC_BASE_X/; s/32'h00000000/PC_BASE_X/; s/__VERILATOR__/ENTRY_MACRO/; s/CORE_ENTRY/ENTRY_MACRO/"; }
if ! diff <(norm_pc "$ARES/rtl/pipeline/core/vsrc/Mundus/Mundus_PC.v") \
           <(norm_pc "$APP/llm/rtl/core/Mundus_PC.v") >/dev/null; then
  echo "   Mundus_PC.v differs beyond the entry constant"; fail=1
else
  echo "   Mundus_PC.v: entry constant only"
fi

echo "== miniTensor: shared by both applications =="
echo "   rtl/minitensor/ (4x4 INT8 array, 128-bit UB, vector unit, epilogue, DMA)"

if [ "$fail" -eq 0 ]; then echo "core sync: OK"; else echo "core sync: FAILED"; fi
exit "$fail"
