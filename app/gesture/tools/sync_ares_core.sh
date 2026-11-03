#!/usr/bin/env bash
# Re-copy the ARES core RTL into this project's rtl/core and re-apply the one
# application-side change (the reset entry point in Mundus_PC.v).
#
#   tools/sync_ares_core.sh /home/ccy/Documents/qs/ARES
set -euo pipefail
ARES=${1:?usage: sync_ares_core.sh <ARES root>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="$ROOT/rtl/core"

mkdir -p "$DST/icache" "$DST/include"
cp "$ARES/rtl/pipeline/core/vsrc/build/Mundus.sv"            "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/myCPU.v             "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/Mundus_PC.v         "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/RegisterFile.v      "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/BimodalRas.v        "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/ReturnAddressStack.v "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/Divider.v           "$DST/"
cp "$ARES"/rtl/pipeline/core/vsrc/Mundus/Multplier.v         "$DST/"
cp "$ARES"/rtl/pipeline/soc/ip/div.v "$ARES"/rtl/pipeline/soc/ip/mult.v "$DST/"
cp "$ARES"/rtl/pipeline/soc/ip/DCacheData_BRAM.v            "$DST/"
cp "$ARES"/rtl/pipeline/soc/ip/DCacheTag_BRAM.v             "$DST/"
cp "$ARES"/rtl/pipeline/soc/ip/DCacheLru_BRAM.v             "$DST/"
cp "$ARES/rtl/pipeline/core/vsrc/icache/pipeline_icache.v"  "$DST/icache/"
cp "$ARES"/rtl/pipeline/core/vsrc/include/*.vh              "$DST/include/"
cp "$ARES/rtl/pipeline/include/autoconf.vh"                 "$DST/include/"
cp "$ARES/rtl/pipeline/include/pipeline_autoconf.vh"        "$DST/include/"

# Application entry point: ROM trampoline / UART loader live at 0x0.
python3 - "$DST/Mundus_PC.v" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace("localparam PC_BASE = 32'h80000000;",
              "localparam PC_BASE = 32'h00000000;")
open(p, 'w', encoding='utf-8').write(s)
PY
echo "synced $DST from $ARES"
