`ifndef __COMMON_PARA_VH__
`define __COMMON_PARA_VH__

`include "autoconf.vh"

// Define `TAPE_OUT_SIM for tape-out modules' name
// **only used in ysyxSoC** so no rename required
// Simply comment out the macro
// `define TAPE_OUT_SIM

// Define `__VERILATOR__ to run ysyxSoC
// `__VERILATOR__ is defined in npc/Makefile

// Define DPIC to disable DPIC
`ifdef CONFIG_SIMULATION
  `ifdef __VERILATOR__
    `define DPIC
  `endif
`endif

`endif
