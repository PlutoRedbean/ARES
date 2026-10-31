+incdir+rtl/pipeline/include
+incdir+rtl/pipeline/core/vsrc/include

# ---------------------------------------------------------------------------
# Pango PDS synthesis file list (SystemVerilog accepted by PDS)
#
# The SoC wrappers stay Verilog-2001 style; the reused CoreMark accelerator
# engines are SystemVerilog and are compiled with the PDS SystemVerilog
# standard (the flow passes -verilog_standard {SystemVerilog}).
#
# Differences from pipeline.f (Verilator simulation):
#   * no DPI memory models (BRAM.v / StoreBuffer_DPIC / DPIC core hooks)
#   * pango/pipeline_bram.v provides the synthesizable BRAM module
#   * pango/pipeline_cdc.v replaces the Xilinx XPM CDC macros
#   * board/pipeline_pll.v instantiates GTP_GPLL; simulation uses
#     board/pipeline_pll_sim.v instead
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
rtl/pipeline/core/vsrc/icache/pipeline_icache.v

# Memory wrappers that are inferred RAM in both flows
rtl/pipeline/soc/ip/mult.v
rtl/pipeline/soc/ip/div.v
rtl/pipeline/soc/ip/DCacheData_BRAM.v
rtl/pipeline/soc/ip/DCacheTag_BRAM.v

# CoreMark accelerator engines + MMIO wrapper
rtl/accel/mtx9_engine.sv
rtl/accel/state9_engine.sv
rtl/pipeline/soc/jyd/pipeline_accel.sv

# jyd SoC
rtl/pipeline/soc/jyd/student_top.sv
rtl/pipeline/soc/jyd/irom_bmem32.sv
rtl/pipeline/soc/jyd/pipeline_irom_passthrough.v
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
rtl/pipeline/board/pipeline_board_top.v

# ---------------------------------------------------------------------------
# Multi-hart coherent SoC (M4).  pipeline_mc_soc_top is not instantiated by the
# single-hart pipeline_board_top; the files are listed so a future Pango board
# wrapper can use the same synthesis file list.  The downstream 128-bit L2
# memory port is left for that wrapper (shared DRAM/BRAM).
# ---------------------------------------------------------------------------
rtl/pipeline/soc/mc/pipeline_l2.sv
rtl/pipeline/soc/mc/pipeline_core_port.sv
rtl/pipeline/soc/mc/pipeline_mmio.sv
rtl/pipeline/soc/mc/pipeline_hart.sv
rtl/pipeline/soc/mc/pipeline_mc_soc_top.sv

# Non-coherent multi-hart AMP profile (replicated IROM + shared mailbox)
rtl/pipeline/soc/mc/pipeline_coremark_mbox.sv
rtl/pipeline/soc/amp/pipeline_amp_icache.sv
rtl/pipeline/soc/amp/pipeline_irom_arbiter.sv
rtl/pipeline/soc/amp/pipeline_amp_top.sv
# Legacy module name kept as a thin wrapper over pipeline_amp_top.
rtl/pipeline/soc/mc/pipeline_coremark_amp_top.sv
