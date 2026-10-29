/**
 * ARES pipeline SoC configuration.
 *
 * Merged from:
 *   - npc 5-stage-pipeline core (BPU/cache/MDU parameters)
 *   - npc jyd SoC (IROM geometry, 32 KiB)
 *
 * Do not edit generated npc autoconf.vh; this file is the ARES pipeline view.
 */
`ifndef __PIPELINE_AUTOCONF_VH__
`define __PIPELINE_AUTOCONF_VH__

/* Simulation / core clock */
/* CONFIG_SIMULATION intentionally not defined: ARES does not use the npc
 * difftest/DPIC hooks.  The standalone DPI memory/console hooks still
 * compile under __VERILATOR__. */
`define CONFIG_CORE_FREQ "100.00"
`define CORE_FREQ 100.000
`define CORE_ENTRY 32'h8000_0000
`define CONFIG_NPC_ENTRY 'h80000000
`define CONFIG_SOC_ENTRY 'h80000000

/* Branch prediction (5-stage-pipeline core) */
`define CONFIG_BP_BIMODAL 1
`define CONFIG_BRANCH_PREDICT 1
`define CONFIG_BRANCH_BTB_WIDTH 4
`define CONFIG_BRANCH_BIMODAL_BITS 2
`define CONFIG_BRANCH_RAS 1
`define CONFIG_BRANCH_RAS_WIDTH 3
`define CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE 0
`define CONFIG_FRONTEND_QUEUE 1
`define CONFIG_FRONTEND_QUEUE_DEPTH 8

/* D-Cache / store buffer */
`define CONFIG_DCACHE_SIZE_8KB 1
`define CONFIG_DCACHE_SIZE_KB 8
`define CONFIG_STORE_BUFFER_DEPTH_4 1
`define CONFIG_STORE_BUFFER_DEPTH 4

/* MDU latency */
`define CONFIG_MUL_LATENCY 4
`define CONFIG_DIV_LATENCY 35

/* JYD IROM: 32 KiB.  CONFIG_IROM_ADDR_WIDTH is the 64-bit-pair index width
 * used by the original jyd SoC.  IROM_BMEM32 uses one extra address bit for
 * 32-bit words (8192 entries). */
`define CONFIG_IROM_SIZE_32KB 1
`define CONFIG_IROM_SIZE_KB 32
`define CONFIG_IROM_SIZE_BYTES 32768
`define CONFIG_IROM_DEPTH 4096
`define CONFIG_IROM_ADDR_WIDTH 12
`define CONFIG_IROM_READ_LATENCY 1

`endif
