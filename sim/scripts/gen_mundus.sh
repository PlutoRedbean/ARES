#!/usr/bin/env bash
#=============================================================================
# ARES - refresh the generated Mundus RTL used by the simulation
#-----------------------------------------------------------------------------
# The temporary DUT (ysyx-workbench/npc/vsrc) is partially Chisel generated:
# vsrc/build/Mundus.sv is produced by mill from npc/scsrc.  The checked in
# copy under sim/rtl/generated/ was elaborated with CONFIG_SIMULATION = true,
# which is what instantiates the DPIC modules the harness needs:
#
#   Mundus_DPIC           -> get_npc_pc / retire_event_enqueue / ebreak
#   IFU_DPIC, DCache_DPIC, LSU_DPIC, TransientRefill_DPIC, WBU_DPIC,
#   PipelineStats_DPIC    -> performance statistics hooks
#
# Without CONFIG_SIMULATION the generated design contains no DPIC instance at
# all, so there is no EBREAK callback and the simulation could never detect the
# end of a test.
#
# Usage:
#   sim/scripts/gen_mundus.sh [NPC_HOME] [OUTPUT]
#
# Defaults:
#   NPC_HOME = /home/redbean/ysyx-workbench/npc
#   OUTPUT   = <ARES>/sim/rtl/generated/Mundus.sv
#
# The npc working tree is never modified: the Chisel project is copied into
# <ARES>/sim/build/chisel first.
#=============================================================================
set -euo pipefail

SIM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARES_HOME="$(cd "${SIM_HOME}/.." && pwd)"

NPC_HOME="${1:-${NPC_HOME:-/home/redbean/ysyx-workbench/npc}}"
OUTPUT="${2:-${SIM_HOME}/rtl/generated/Mundus.sv}"
WORK="${SIM_HOME}/build/chisel"

echo "[gen_mundus] npc      : ${NPC_HOME}"
echo "[gen_mundus] output   : ${OUTPUT}"
echo "[gen_mundus] work dir : ${WORK}"

for f in build.sc mill .mill-version scsrc configs; do
  if [ ! -e "${NPC_HOME}/${f}" ]; then
    echo "[gen_mundus] error: ${NPC_HOME}/${f} not found" >&2
    exit 1
  fi
done

rm -rf "${WORK}"
mkdir -p "${WORK}"
cp -a "${NPC_HOME}/build.sc" "${NPC_HOME}/mill" "${NPC_HOME}/.mill-version" \
      "${NPC_HOME}/scsrc" "${NPC_HOME}/configs" "${WORK}/"

CONF="${WORK}/configs/build/scsrc/autoconf.scala"
if [ ! -f "${CONF}" ]; then
  echo "[gen_mundus] error: ${CONF} not found (run the npc config generator first)" >&2
  exit 1
fi
sed -i 's/val CONFIG_SIMULATION: Boolean = false/val CONFIG_SIMULATION: Boolean = true/' "${CONF}"
grep -q 'val CONFIG_SIMULATION: Boolean = true' "${CONF}" || {
  echo "[gen_mundus] error: could not enable CONFIG_SIMULATION" >&2; exit 1; }

# Keep the Verilog side configuration (include/autoconf.vh) in step with the
# Scala side.  The simulation defines CONFIG_SIMULATION on the Verilator
# command line (see sim/Makefile), so the copy stays verbatim.
if [ -f "${NPC_HOME}/configs/build/vsrc/include/autoconf.vh" ]; then
  cp "${NPC_HOME}/configs/build/vsrc/include/autoconf.vh" "${SIM_HOME}/config/autoconf.vh"
  echo "[gen_mundus] refreshed sim/config/autoconf.vh"
fi

cd "${WORK}"
./mill -i Mundus.runMain npc.Elaborate --target-dir "${WORK}/out_sv"

mkdir -p "$(dirname "${OUTPUT}")"
cp "${WORK}/out_sv/Mundus.sv" "${OUTPUT}"
echo "[gen_mundus] wrote ${OUTPUT} ($(wc -l < "${OUTPUT}") lines)"
