// Front-end build configuration for ARES.
//
// These are the ARES-related options copied verbatim from the Mundus
// autoconf.vh so that the ported front-end keeps its macro-controlled
// parameterization.  `include this from fe_pkg.sv (the test adds
// ``+incdir+include`` to the Verilator command line).

`ifndef __AUTOCONF_VH__
`define __AUTOCONF_VH__

`define CONFIG_ARES 1

// Instruction-cache backing bus.  ARES uses the AXI4-Lite master path;
// comment this out to fall back to the miniTensor uncached read handshake.
`define IO_USE_AXI 1

`define CONFIG_FE_TOURNAMENT 1
`define CONFIG_FE_PHT_WIDTH 10
`define CONFIG_FE_UBTB_WIDTH 8
`define CONFIG_FE_MBTB_WIDTH 11
`define CONFIG_FE_GHR_WIDTH 12
`define CONFIG_FE_RAS 1
`define CONFIG_FE_RAS_ENTRIES 16
`define CONFIG_FE_LOOP_PRED 1
`define CONFIG_FE_LOOP_ENTRIES 256
`define CONFIG_FE_LOOP_ITER_WIDTH 8
`define CONFIG_FE_ADDR_WIDTH 32
`define CONFIG_FE_DATA_WIDTH 32
`define CONFIG_FE_INST_WIDTH 32
`define CONFIG_FE_FETCH_WIDTH 4
`define CONFIG_FE_DECODE_WIDTH 2
`define CONFIG_FE_BODY_DEPTH 8
`define CONFIG_FE_FTQ_NUM_ENTRIES 16
`define CONFIG_FE_ICACHE_LINE_32 1
`define CONFIG_FE_ICACHE_LINE_BYTES 32
`define CONFIG_FE_ICACHE_SETS_64 1
`define CONFIG_FE_ICACHE_NR_SETS 64
`define CONFIG_FE_ICACHE_WAYS_4 1
`define CONFIG_FE_ICACHE_NR_WAYS 4

`endif
