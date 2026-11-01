+incdir+rtl/pipeline/include
+incdir+rtl/pipeline/core/vsrc/include

# ---------------------------------------------------------------------------
# Pango PDS synthesis file list for the 2-hart AMP full-accelerated CoreMark
# board top (pipeline_amp_board_top).
#
# This list intentionally excludes the shared-L2 coherent SoC files: the AMP
# profile has private per-hart DRAM and a shared read-only IROM, so the L2 is
# not instantiated.  Keeping the L2 files out also avoids PDS parsing the
# still-SystemVerilog enum state machines in pipeline_l2/pipeline_mmio.
#
# Run PDS from the repository root so the $readmemh defaults resolve:
#   build/pipeline/irom.hex, build/pipeline/dram.hex
# ---------------------------------------------------------------------------

# Generated core (Verilog-2001 style; do not hand-edit)
rtl/pipeline/core/vsrc/build/Mundus.sv
rtl/pipeline/core/vsrc/Mundus/myCPU.v
rtl/pipeline/core/vsrc/Mundus/RegisterFile.v
rtl/pipeline/core/vsrc/Mundus/Bimodal.v
rtl/pipeline/core/vsrc/Mundus/BimodalRas.v
rtl/pipeline/core/vsrc/Mundus/ReturnAddressStack.v
rtl/pipeline/core/vsrc/Mundus/Mundus_PC.v
rtl/pipeline/core/vsrc/Mundus/Multplier.v
rtl/pipeline/core/vsrc/Mundus/Divider.v
rtl/pipeline/core/vsrc/modules/Adder.v
rtl/pipeline/core/vsrc/modules/Comparator.v
rtl/pipeline/core/vsrc/modules/Encode24.v
rtl/pipeline/core/vsrc/modules/MuxKey.v
rtl/pipeline/core/vsrc/modules/MuxKeyInternal.v
rtl/pipeline/core/vsrc/modules/MuxKeyWithDefault.v
rtl/pipeline/core/vsrc/modules/Reg.v
rtl/pipeline/core/vsrc/modules/RegWithReset.v
rtl/pipeline/core/vsrc/modules/Segment.v
rtl/pipeline/core/vsrc/modules/Shifter.v

# Memory wrappers that are inferred RAM in both flows
rtl/pipeline/soc/ip/mult.v
rtl/pipeline/soc/ip/div.v
rtl/pipeline/soc/ip/DCacheData_BRAM.v
rtl/pipeline/soc/ip/DCacheTag_BRAM.v

# CoreMark accelerator engines + MMIO wrapper (PDS-compatible Verilog-2001 subset)
rtl/accel/mtx9_engine.sv
rtl/accel/state9_engine.sv
rtl/pipeline/soc/jyd/pipeline_accel.sv

# jyd SoC / per-hart private memory and MMIO
rtl/pipeline/soc/jyd/student_top.sv
rtl/pipeline/soc/jyd/irom_bmem32.sv
rtl/pipeline/soc/jyd/perip_bridge.sv
rtl/pipeline/soc/jyd/bram_driver.sv
rtl/pipeline/soc/jyd/counter.v
rtl/pipeline/soc/jyd/uart.sv
rtl/pipeline/soc/jyd/display_seg.sv
rtl/pipeline/soc/jyd/seg7.sv

# Pango-portable platform layer
rtl/pipeline/soc/pango/pipeline_cdc.v
rtl/pipeline/soc/pango/pipeline_bram.v
rtl/pipeline/board/pipeline_pll.v
rtl/pipeline/board/pipeline_clk_reset.v

# 2-hart AMP top + shared IROM/mailbox + per-hart instruction caches
rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv
rtl/pipeline/soc/amp/pipeline_amp_icache.sv
rtl/pipeline/soc/amp/pipeline_irom_arbiter.sv
rtl/pipeline/soc/amp/pipeline_amp_top.sv

# Board top (PLL/reset/UART/LED)
rtl/pipeline/board/pipeline_amp_board_top.v
