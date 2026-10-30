# Multi-hart pipeline SoC elaboration file list (Verilator).
# Includes the single-hart SoC/core sources and adds the coherent 2/4-hart
# blocks.  Select the hart count at the top-level parameter, e.g.
#   verilator ... --top-module pipeline_mc_soc_top -GCORES=2 -f rtl/pipeline/pipeline_mc.f
+incdir+rtl/pipeline/include
+incdir+rtl/pipeline/core/vsrc/include

-f rtl/pipeline/pipeline.f

rtl/pipeline/soc/mc/pipeline_l2.sv
rtl/pipeline/soc/mc/pipeline_core_port.sv
rtl/pipeline/soc/mc/pipeline_mmio.sv
rtl/pipeline/soc/mc/pipeline_hart.sv
rtl/pipeline/soc/mc/pipeline_mc_soc_top.sv
