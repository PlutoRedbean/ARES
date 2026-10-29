+incdir+rtl/pipeline/include
+incdir+rtl/pipeline/core/vsrc/include

# ---------------------------------------------------------------------------
# Pango PDS synthesis file list (Verilog-2001 flow)
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

# Memory wrappers that are inferred RAM in both flows
rtl/pipeline/soc/ip/mult.v
rtl/pipeline/soc/ip/div.v
rtl/pipeline/soc/ip/DCacheData_BRAM.v
rtl/pipeline/soc/ip/DCacheTag_BRAM.v

# jyd SoC
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
rtl/pipeline/board/pipeline_board_top.v
