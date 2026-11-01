#=============================================================================
# ARES - FPGA single-issue pipeline SoC
#-----------------------------------------------------------------------------
# Builds and verifies the Pango-targeted pipeline SoC:
#
#   pipeline_board_top   single hart   rtl/pipeline/board/pipeline_board_top.v
#   pipeline_amp_top     2/4-hart AMP  rtl/pipeline/soc/amp/pipeline_amp_top.v
#
# Software images come from the accelerated CoreMark flow
# (scripts/build_coremark_crc.py) and are split into the two Pango memories by
# scripts/pipeline_image.py.  The PDS project is
# fpga/pango/pipeline/flow_pipeline.tcl.
#
#   make pipeline-core-gen          regenerate Mundus.sv from the Chisel sources
#   make pipeline-lint              Verilator lint of the SoC
#   make pipeline-smoke             8-instruction smoke test
#   make pipeline-isa-images        build the ISA test binaries (no simulator)
#   make pipeline-isa               ISA regression (36 cpu-tests)
#   make pipeline-div-test          divider unit test (Icarus)
#   make pipeline-coremark          baseline CoreMark
#   make pipeline-coremark-{crc,matrix,state,full}
#   make pipeline-coremark-mt       2/4-hart MULTITHREAD CoreMark
#   make pipeline-coremark-full-mt  accelerated 2-hart CoreMark
#   make pipeline-console           Pango-only CDC/UART/mailbox test
#   make pipeline-pango-lint        board top + behavioural PLL
#   make pipeline-image             ELF -> build/pipeline/{irom,dram}.hex
#
# See rtl/pipeline/README.md for the core/SoC and
# fpga/pango/pipeline/README.md for the PDS run.
#=============================================================================
ARES_HOME := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

#-----------------------------------------------------------------------------
# CoreMark software images.  The EEMBC tree in tests/benchmarks/coremark is
# vendored; scripts/build_coremark_crc.py stages a copy, adds the accelerated
# TUs and calls scripts/build_coremark_image.py (AbstractMachine + riscv gcc).
#-----------------------------------------------------------------------------
COREMARK_OUT          ?= $(ARES_HOME)/build/coremark
COREMARK_IMAGE_FLAGS  ?=
COREMARK_IMAGE_CMD     = python3 "$(ARES_HOME)/scripts/build_coremark_image.py" --out "$(COREMARK_OUT)" $(COREMARK_IMAGE_FLAGS)

coremark-image:
	@$(COREMARK_IMAGE_CMD)

# CRC-only variant (custom-0 CRC8 instruction; EEMBC sources untouched).
coremark-crc-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --out "$(ARES_HOME)/build/coremark_crc" --jobs 4 \
	    $(PIPELINE_COREMARK_IMAGE_FLAGS)

# CRC + software array-shadow core_bench_list variant.
coremark-array-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --array-list \
	    --out "$(ARES_HOME)/build/coremark_array" --jobs 4

# CRC + 9-PE INT16 matrix engine variant.
coremark-matrix-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --matrix-engine \
	    --out "$(ARES_HOME)/build/coremark_matrix" --jobs 4 \
	    $(PIPELINE_COREMARK_IMAGE_FLAGS)

# CRC + array-shadow list + 9-PE matrix engine variant.
coremark-matrix-array-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --matrix-engine --array-list \
	    --out "$(ARES_HOME)/build/coremark_matrix_array" --jobs 4

# CRC + state-machine token scanner variant.
coremark-state-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --state-engine \
	    --out "$(ARES_HOME)/build/coremark_state" --jobs 4 \
	    $(PIPELINE_COREMARK_IMAGE_FLAGS)

# CRC + array-shadow list + matrix engine + state scanner.
coremark-full-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --state-engine \
	    --matrix-engine --array-list --out "$(ARES_HOME)/build/coremark_full" --jobs 4 \
	    $(PIPELINE_COREMARK_IMAGE_FLAGS)

# Image-chain tests (ELF32 -> bin -> Pango readmemh), no RTL.
test-coremark-image:
	@python3 "$(ARES_HOME)/scripts/test_coremark_image.py"

# Host-side equivalence over the full 100x2 core_bench_list call sequence.
test-coremark-array:
	@python3 "$(ARES_HOME)/scripts/test_coremark_array.py"

test-images:
	@python3 "$(ARES_HOME)/scripts/test_split_image.py"

#-----------------------------------------------------------------------------
# Accelerator engines (standalone lint + unit tests)
#-----------------------------------------------------------------------------
ACCEL_LINT_FLAGS := --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION

lint-mtx9:
	@echo "[lint] mtx9_engine"
	@verilator $(ACCEL_LINT_FLAGS) --top-module mtx9_engine rtl/accel/mtx9_engine.sv

unit-mtx9:
	@mkdir -p $(ARES_HOME)/build/unit/tb_mtx9_engine
	@CCACHE_DISABLE=1 verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
	    -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -DCONFIG_SIMULATION \
	    --top-module tb_mtx9_engine \
	    --Mdir $(ARES_HOME)/build/unit/tb_mtx9_engine \
	    -o $(ARES_HOME)/build/unit/tb_mtx9_engine/tb_mtx9_engine \
	    rtl/accel/mtx9_engine.sv rtl/accel/test/unit/tb_mtx9_engine.sv
	@$(ARES_HOME)/build/unit/tb_mtx9_engine/tb_mtx9_engine

lint-state9:
	@echo "[lint] state9_engine"
	@verilator $(ACCEL_LINT_FLAGS) --top-module state9_engine rtl/accel/state9_engine.sv

unit-state9:
	@mkdir -p $(ARES_HOME)/build/unit/tb_state9_engine
	@CCACHE_DISABLE=1 verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
	    -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-IMPLICIT -Wno-UNSIGNED \
	    -DCONFIG_SIMULATION \
	    --top-module tb_state9_engine \
	    --Mdir $(ARES_HOME)/build/unit/tb_state9_engine \
	    -o $(ARES_HOME)/build/unit/tb_state9_engine/tb_state9_engine \
	    rtl/accel/state9_engine.sv rtl/accel/test/unit/tb_state9_engine.sv
	@$(ARES_HOME)/build/unit/tb_state9_engine/tb_state9_engine

#-----------------------------------------------------------------------------
# Pipeline SoC (Verilator + Pango)
#-----------------------------------------------------------------------------
.PHONY: coremark-image coremark-crc-image coremark-array-image coremark-matrix-image \
        coremark-matrix-array-image coremark-state-image coremark-full-image \
        test-coremark-image test-coremark-array test-images \
        lint-mtx9 lint-state9 unit-mtx9 unit-state9 clean \
        pipeline-core-gen pipeline-lint pipeline-div-test pipeline-smoke pipeline-isa-images pipeline-isa-sim pipeline-isa pipeline-coremark pipeline-coremark-nocache pipeline-coremark-serial pipeline-coremark-crc pipeline-coremark-matrix pipeline-coremark-state pipeline-coremark-full pipeline-coremark-images pipeline-coremark-mc pipeline-coremark-mt pipeline-coremark-mt-test pipeline-coremark-full-mt pipeline-coremark-mt-image pipeline-coremark-full-mt-image coremark-full-mc-image pipeline-image pipeline-board-image pipeline-amp-image pipeline-amp-image-mt pipeline-pango-lint pipeline-amp-pango-lint pipeline-amp-board-sim pipeline-console pipeline-mc-images pipeline-mc-lint pipeline-mc-run pipeline-mc-test
# Accelerated image locations (built by the existing ARES CoreMark scripts).
PIPELINE_COREMARK_CRC_BIN    ?= $(ARES_HOME)/build/coremark_crc/coremark.bin
PIPELINE_COREMARK_MATRIX_BIN ?= $(ARES_HOME)/build/coremark_matrix/coremark.bin
PIPELINE_COREMARK_STATE_BIN  ?= $(ARES_HOME)/build/coremark_state/coremark.bin
PIPELINE_COREMARK_FULL_BIN   ?= $(ARES_HOME)/build/coremark_full/coremark.bin
PIPELINE_COREMARK_FULL_MC_OUT ?= $(ARES_HOME)/build/coremark_full_mc
PIPELINE_COREMARK_FULL_MC_BIN ?= $(PIPELINE_COREMARK_FULL_MC_OUT)/coremark.bin
PIPELINE_MC_LDSCRIPT          ?= $(ARES_HOME)/tests/abstract-machine/scripts/ares-linker-mc.ld
PIPELINE_IMAGE_ELF           ?= $(ARES_HOME)/build/coremark/coremark-riscv32-ares.elf
PIPELINE_IMAGE_OUT           ?= $(ARES_HOME)/build/pipeline
PIPELINE_AMP_ELF             ?= $(PIPELINE_COREMARK_FULL_MC_OUT)/coremark-riscv32-ares.elf
PIPELINE_AMP_IMAGE_OUT       ?= $(ARES_HOME)/build/pipeline
PIPELINE_BOARD_ELF          ?= $(PIPELINE_AMP_ELF)
PIPELINE_AMP_BOARD_IROM      ?= $(PIPELINE_AMP_IMAGE_OUT)/irom.hex
PIPELINE_AMP_BOARD_DRAM      ?= $(PIPELINE_AMP_IMAGE_OUT)/dram.hex
PIPELINE_AMP_BOARD_MAX_NS    ?= 200000000
# Applied by pipeline-coremark-images so the accelerated images fit the
# pipeline's 32 KiB IROM.  Normal coremark-*-image targets keep the default
# (empty) flags for the OoO flow.
PIPELINE_COREMARK_IMAGE_FLAGS ?=

# 2/4-hart standard CoreMark MULTITHREAD images.  CORES is the build-time
# switch and MULTITHREAD/ITERATIONS are compile-time macros, so each core
# count needs its own image directory.  The canonical total is 10,000
# iterations (2 -> 2x5000, 4 -> 4x2500); the Verilator target builds a
# reduced profile because a full 10,000-iteration run is hours long.
CORES                       ?= 2
COREMARK_MT_TOTAL_ITERATIONS ?= 10000
PIPELINE_MT_OUT             ?= $(ARES_HOME)/build/coremark_mt$(CORES)
PIPELINE_MT_BIN             ?= $(PIPELINE_MT_OUT)/coremark.bin
PIPELINE_FULL_MT_OUT        ?= $(ARES_HOME)/build/coremark_full_mt$(CORES)
PIPELINE_MT_SIM_TOTAL       ?= 200
PIPELINE_MT_MAX_CYCLES      ?= 400000000

# Board image profile: which program build/pipeline/*.hex holds, i.e. what the
# board-level simulation loads and what the PDS bitstream initializes the
# BRAMs from.  Both profiles go through the same splitter
# (scripts/pipeline_image.py --replicate-dram-words 8192), so the simulated
# image is the on-board image; only the software differs.
#   amp  per-hart full-accelerated CoreMark (hart 0 prints its own report)
#   mt   MULTITHREAD aggregate report over CORES harts (200 iterations in
#        simulation, COREMARK_MT_TOTAL_ITERATIONS for the bitstream build)
PIPELINE_BOARD_PROFILE      ?= amp
ifeq ($(PIPELINE_BOARD_PROFILE),amp)
PIPELINE_BOARD_IMAGE_TARGET := pipeline-amp-image
PIPELINE_BOARD_IMAGE_ARGS   :=
else ifeq ($(PIPELINE_BOARD_PROFILE),mt)
PIPELINE_BOARD_IMAGE_TARGET := pipeline-amp-image-mt
PIPELINE_BOARD_IMAGE_ARGS   := COREMARK_MT_TOTAL_ITERATIONS=$(PIPELINE_MT_SIM_TOTAL)
else
$(error PIPELINE_BOARD_PROFILE must be 'amp' or 'mt', got '$(PIPELINE_BOARD_PROFILE)')
endif

# Multi-hart pipeline SoC (M4).  CORES is the build-time option; the same RTL
# elaborates as 2 or 4 harts.  Images are built by tests/pipeline-mc.
PIPELINE_MC_CORES ?= 2
PIPELINE_MC_IMAGE ?= $(ARES_HOME)/build/pipeline_mc/mc_linear$(PIPELINE_MC_CORES).bin

pipeline-core-gen:
	@cd $(ARES_HOME)/rtl/pipeline/gen && \
	  MILL_WORKSPACE_ROOT=$$(pwd) ./mill -i Mundus.runMain npc.Elaborate \
	      --target-dir ../core/vsrc/build

pipeline-lint:
	@cd $(ARES_HOME) && verilator --lint-only --language 1800-2017 -D__VERILATOR__ -Wall -Wno-fatal \
	    --top-module student_top -f rtl/pipeline/pipeline.f

# Unit test for the divider behind Mundus/EXU/DIV (rtl/pipeline/soc/ip/div.v):
# directed boundaries, random pairs against a reference model, result
# latency/hold checks and the dropped-request case at LATENCY=35 and 17.
# Icarus only, ~2 s.
pipeline-div-test:
	@mkdir -p $(ARES_HOME)/build/div_test
	@cd $(ARES_HOME) && iverilog -g2012 \
	    -I rtl/pipeline/include -I rtl/pipeline/core/vsrc/include \
	    -o build/div_test/tb_div rtl/pipeline/soc/ip/div.v rtl/pipeline/test/tb_div.sv
	@cd $(ARES_HOME) && vvp build/div_test/tb_div

pipeline-smoke:
	@mkdir -p $(ARES_HOME)/build/pipeline_smoke
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_smoke -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/test/tb_pipeline_smoke.sv $(ARES_HOME)/rtl/pipeline/test/sim_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_smoke -o $(ARES_HOME)/build/pipeline_smoke/pipeline_smoke
	@$(ARES_HOME)/build/pipeline_smoke/pipeline_smoke

pipeline-isa-sim:
	@mkdir -p $(ARES_HOME)/build/pipeline_isa
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_isa -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/test/tb_pipeline_isa.sv $(ARES_HOME)/rtl/pipeline/test/sim_isa_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_isa -o $(ARES_HOME)/build/pipeline_isa/pipeline_isa

# Rebuild the ISA test binaries (ELF + bin) without any simulator.  The
# pipeline-isa harness below consumes tests/cpu-tests/build/*-riscv32-ares.bin.
pipeline-isa-images:
	@$(MAKE) -C $(ARES_HOME)/tests/cpu-tests ARCH=riscv32-ares images

pipeline-isa: pipeline-isa-sim
	@set -e; pass=0; fail=0; \
	for bin in $(ARES_HOME)/tests/cpu-tests/build/*-riscv32-ares.bin; do \
	    name=$$(basename $$bin -riscv32-ares.bin); \
	    if $(ARES_HOME)/build/pipeline_isa/pipeline_isa $$bin 2000000 \
	        > $(ARES_HOME)/build/pipeline_isa/$$name.log 2>&1; then \
	        printf '[%14s] PASS\n' $$name; pass=$$((pass+1)); \
	    else \
	        printf '[%14s] FAIL\n' $$name; tail -3 $(ARES_HOME)/build/pipeline_isa/$$name.log; fail=$$((fail+1)); \
	    fi; \
	done; \
	echo "ISA pass=$$pass fail=$$fail"; test $$fail -eq 0

pipeline-coremark: pipeline-isa-sim
	@test -f $(ARES_HOME)/build/coremark/coremark.bin || \
	  { echo "error: build/coremark/coremark.bin missing; run 'make coremark-image'"; exit 1; }
	@$(ARES_HOME)/build/pipeline_isa/pipeline_isa \
	    $(ARES_HOME)/build/coremark/coremark.bin 200000000

# Same CoreMark image with the instruction cache bypassed (USE_ICACHE=0).
# Kept in a separate Mdir because the Verilator parameter changes elaboration.
pipeline-coremark-nocache:
	@test -f $(ARES_HOME)/build/coremark/coremark.bin || \
	  { echo "error: build/coremark/coremark.bin missing; run 'make coremark-image'"; exit 1; }
	@mkdir -p $(ARES_HOME)/build/pipeline_isa_nocache
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_isa -GUSE_ICACHE=0 -f rtl/pipeline/pipeline.f \
	    $(ARES_HOME)/rtl/pipeline/test/tb_pipeline_isa.sv $(ARES_HOME)/rtl/pipeline/test/sim_isa_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_isa_nocache \
	    -o $(ARES_HOME)/build/pipeline_isa_nocache/pipeline_isa
	@$(ARES_HOME)/build/pipeline_isa_nocache/pipeline_isa \
	    $(ARES_HOME)/build/coremark/coremark.bin 200000000

# Same image with the serialised 2-cycle cache hit path (ICACHE_PIPE_HITS=0).
pipeline-coremark-serial:
	@test -f $(ARES_HOME)/build/coremark/coremark.bin || \
	  { echo "error: build/coremark/coremark.bin missing; run 'make coremark-image'"; exit 1; }
	@mkdir -p $(ARES_HOME)/build/pipeline_isa_serial
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_isa -GICACHE_PIPE_HITS=0 -f rtl/pipeline/pipeline.f \
	    $(ARES_HOME)/rtl/pipeline/test/tb_pipeline_isa.sv $(ARES_HOME)/rtl/pipeline/test/sim_isa_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_isa_serial \
	    -o $(ARES_HOME)/build/pipeline_isa_serial/pipeline_isa
	@$(ARES_HOME)/build/pipeline_isa_serial/pipeline_isa \
	    $(ARES_HOME)/build/coremark/coremark.bin 200000000

# M4 accelerated images.  The same software build flow as the OoO core is
# reused; the pipeline SoC adds the custom-0 CRC8 instruction and the
# 0xA000_1000 / 0xA000_2000 MMIO engines.
pipeline-coremark-crc: pipeline-isa-sim
	@test -f $(PIPELINE_COREMARK_CRC_BIN) || \
	  { echo "error: $(PIPELINE_COREMARK_CRC_BIN) missing; run 'make pipeline-coremark-images'"; exit 1; }
	@$(ARES_HOME)/build/pipeline_isa/pipeline_isa \
	    $(PIPELINE_COREMARK_CRC_BIN) 200000000

pipeline-coremark-matrix: pipeline-isa-sim
	@test -f $(PIPELINE_COREMARK_MATRIX_BIN) || \
	  { echo "error: $(PIPELINE_COREMARK_MATRIX_BIN) missing; run 'make pipeline-coremark-images'"; exit 1; }
	@$(ARES_HOME)/build/pipeline_isa/pipeline_isa \
	    $(PIPELINE_COREMARK_MATRIX_BIN) 200000000

pipeline-coremark-state: pipeline-isa-sim
	@test -f $(PIPELINE_COREMARK_STATE_BIN) || \
	  { echo "error: $(PIPELINE_COREMARK_STATE_BIN) missing; run 'make pipeline-coremark-images'"; exit 1; }
	@$(ARES_HOME)/build/pipeline_isa/pipeline_isa \
	    $(PIPELINE_COREMARK_STATE_BIN) 200000000

pipeline-coremark-full: pipeline-isa-sim
	@test -f $(PIPELINE_COREMARK_FULL_BIN) || \
	  { echo "error: $(PIPELINE_COREMARK_FULL_BIN) missing; run 'make pipeline-coremark-images'"; exit 1; }
	@$(ARES_HOME)/build/pipeline_isa/pipeline_isa \
	    $(PIPELINE_COREMARK_FULL_BIN) 200000000

pipeline-coremark-images:
	@$(MAKE) PIPELINE_COREMARK_IMAGE_FLAGS=--small-code \
	    coremark-crc-image coremark-matrix-image coremark-state-image coremark-full-image

# Full accelerated CoreMark image linked for per-hart AMP data regions.
# The image is still MULTITHREAD=1: each hart runs its own CoreMark instance;
# DATA_STRIDE provides the private 32 KiB data/rodata/bss/stack window.
coremark-full-mc-image:
	@python3 $(ARES_HOME)/scripts/build_coremark_crc.py \
	    --array-list --matrix-engine --state-engine --small-code \
	    --ldscript $(PIPELINE_MC_LDSCRIPT) \
	    --out $(PIPELINE_COREMARK_FULL_MC_OUT)

# Standard CoreMark MULTITHREAD image: one aggregate report over CORES harts,
# each context running COREMARK_MT_TOTAL_ITERATIONS/CORES iterations.  The
# image is linked with the per-hart 32 KiB AMP window and never shared
# between 2- and 4-hart builds.
pipeline-coremark-mt-image:
	@case "$(CORES)" in 2|4) ;; *) echo "error: CORES must be 2 or 4 (got '$(CORES)')"; exit 1;; esac
	@python3 $(ARES_HOME)/scripts/build_coremark_image.py \
	    --mt-pipe --cores $(CORES) \
	    --total-iterations $(COREMARK_MT_TOTAL_ITERATIONS) \
	    --ldscript $(PIPELINE_MC_LDSCRIPT) --jobs 4 \
	    --out $(PIPELINE_MT_OUT)

# Full-accelerated variant of the pipeline MULTITHREAD image (same
# semantics, CRC8 + matrix + state engines, per-hart private windows).
# --small-code shrinks the cold fallback TUs so the 2/4-hart aggregate image
# fits the 32 KiB IROM; the accelerated hot path keeps -O3.
pipeline-coremark-full-mt-image:
	@case "$(CORES)" in 2|4) ;; *) echo "error: CORES must be 2 or 4 (got '$(CORES)')"; exit 1;; esac
	@python3 $(ARES_HOME)/scripts/build_coremark_crc.py \
	    --array-list --matrix-engine --state-engine --small-code \
	    --ldscript $(PIPELINE_MC_LDSCRIPT) \
	    --mt-pipe --cores $(CORES) \
	    --total-iterations $(COREMARK_MT_TOTAL_ITERATIONS) --jobs 4 \
	    --out $(PIPELINE_FULL_MT_OUT)

# Two-hart full-accelerated CoreMark on the private-memory AMP profile:
# each hart instantiates a student_top with its own perip_bridge DRAM, UART,
# and matrix/state engines, plus a private I$/passthrough for instruction
# fetch.  With USE_ICACHE=1 (default) the I$s share one 32 KiB IROM bank
# through the refill arbiter.  DATA_OFFSET moves each hart's 32 KiB data
# window; the TB checks per-hart EBREAK/a0 and the per-hart UART reports
# provide CRC/score detail.
# The full-accelerated image has ~30 KiB of text, so it needs the 32 KiB
# (512-line) I$ to avoid capacity misses; the MT target keeps 16 KiB.
pipeline-coremark-mc: coremark-full-mc-image
	@mkdir -p $(ARES_HOME)/build/pipeline_coremark_mc$(CORES)
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_coremark_amp -GCORES=$(CORES) -GICACHE_LINES=512 \
	    -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/test/tb_pipeline_coremark_amp.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_coremark_amp_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_coremark_mc$(CORES) \
	    -o $(ARES_HOME)/build/pipeline_coremark_mc$(CORES)/pipeline_coremark_mc
	@$(ARES_HOME)/build/pipeline_coremark_mc$(CORES)/pipeline_coremark_mc \
	    $(PIPELINE_COREMARK_FULL_MC_BIN) 200000000 $(CORES)

# Split one board ELF into the two Pango memories.  Every board profile goes
# through here, so the layout/replication policy lives in
# scripts/pipeline_image.py only.  The 32 KiB data region is replicated at
# every 32 KiB boundary so each hart's private BRAM sees its copy at
# DATA_OFFSET = hart * 0x8000.
PIPELINE_BOARD_REPLICATE_WORDS ?= 8192
pipeline-board-image:
	@python3 $(ARES_HOME)/scripts/pipeline_image.py \
	    --elf  $(PIPELINE_BOARD_ELF) \
	    --irom $(PIPELINE_AMP_IMAGE_OUT)/irom.hex \
	    --dram $(PIPELINE_AMP_IMAGE_OUT)/dram.hex \
	    --json $(PIPELINE_AMP_IMAGE_OUT)/image.json \
	    --replicate-dram-words $(PIPELINE_BOARD_REPLICATE_WORDS)

# AMP profile: each hart runs its own full-accelerated CoreMark (ITERATIONS=100,
# MULTITHREAD=1) and prints its own report.
pipeline-amp-image: coremark-full-mc-image
	@$(MAKE) pipeline-board-image PIPELINE_BOARD_ELF=$(PIPELINE_AMP_ELF)

# MULTITHREAD profile: one aggregate report over CORES harts (mt2 / mt4).
# The canonical bitstream image uses COREMARK_MT_TOTAL_ITERATIONS (10000);
# pipeline-amp-board-sim overrides it with PIPELINE_MT_SIM_TOTAL so the
# Verilator run finishes in minutes.
pipeline-amp-image-mt:
	@test "$(CORES)" = "2" || \
	  { echo "error: pipeline_amp_board_top instantiates CORES=2; a 4-hart"; \
	    echo "       board top is needed before an mt4 image can run on it"; exit 1; }
	@$(MAKE) pipeline-coremark-full-mt-image
	@$(MAKE) pipeline-board-image \
	    PIPELINE_BOARD_ELF=$(PIPELINE_FULL_MT_OUT)/coremark-riscv32-ares.elf

# 2/4-hart standard CoreMark MULTITHREAD on the private-memory AMP top.
# The Verilator profile uses PIPELINE_MT_SIM_TOTAL total iterations (200 by
# default: 2x100 or 4x50) so the run finishes in minutes.  The canonical
# 10,000-iteration report image is the default of 'pipeline-coremark-mt-image';
# run it in simulation with
#   make pipeline-coremark-mt CORES=2 PIPELINE_MT_SIM_TOTAL=10000
# (hours of Verilator time) if a full-size score is required.
pipeline-coremark-mt:
	@$(MAKE) pipeline-coremark-mt-image COREMARK_MT_TOTAL_ITERATIONS=$(PIPELINE_MT_SIM_TOTAL)
	@mkdir -p $(ARES_HOME)/build/pipeline_coremark_mt$(CORES)
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_coremark_amp -GCORES=$(CORES) \
	    -f rtl/pipeline/pipeline.f \
	    $(ARES_HOME)/rtl/pipeline/test/tb_pipeline_coremark_amp.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_coremark_amp_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_coremark_mt$(CORES) \
	    -o $(ARES_HOME)/build/pipeline_coremark_mt$(CORES)/pipeline_coremark_mt
	@$(ARES_HOME)/build/pipeline_coremark_mt$(CORES)/pipeline_coremark_mt \
	    $(PIPELINE_MT_BIN) $(PIPELINE_MT_MAX_CYCLES) $(CORES)

pipeline-coremark-mt-test:
	@$(MAKE) pipeline-coremark-mt CORES=2
	@$(MAKE) pipeline-coremark-mt CORES=4

# Full-accelerated standard MULTITHREAD CoreMark (one aggregate report).
# The accelerated image is ~31 KiB of text, so the simulation uses the 32 KiB
# (512-line) instruction cache; PIPELINE_MT_SIM_TOTAL keeps the run short.
pipeline-coremark-full-mt:
	@$(MAKE) pipeline-coremark-full-mt-image COREMARK_MT_TOTAL_ITERATIONS=$(PIPELINE_MT_SIM_TOTAL)
	@mkdir -p $(ARES_HOME)/build/pipeline_coremark_full_mt$(CORES)
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_coremark_amp -GCORES=$(CORES) -GICACHE_LINES=512 \
	    -f rtl/pipeline/pipeline.f \
	    $(ARES_HOME)/rtl/pipeline/test/tb_pipeline_coremark_amp.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_coremark_amp_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_coremark_full_mt$(CORES) \
	    -o $(ARES_HOME)/build/pipeline_coremark_full_mt$(CORES)/pipeline_coremark_full_mt
	@$(ARES_HOME)/build/pipeline_coremark_full_mt$(CORES)/pipeline_coremark_full_mt \
	    $(PIPELINE_FULL_MT_OUT)/coremark.bin $(PIPELINE_MT_MAX_CYCLES) $(CORES)

# Split the ARES ELF image into the two local Pango memories:
#   build/pipeline/irom.hex  8192 x 32-bit  (0x8000_0000)
#   build/pipeline/dram.hex 65536 x 32-bit  (0x8010_0000)
pipeline-image:
	@test -f $(PIPELINE_IMAGE_ELF) || \
	  { echo "error: $(PIPELINE_IMAGE_ELF) missing; build the chosen CoreMark image first"; exit 1; }
	@python3 $(ARES_HOME)/scripts/pipeline_image.py \
	    --elf   $(PIPELINE_IMAGE_ELF) \
	    --irom  $(PIPELINE_IMAGE_OUT)/irom.hex \
	    --dram  $(PIPELINE_IMAGE_OUT)/dram.hex \
	    --json  $(PIPELINE_IMAGE_OUT)/image.json

# Directed test of the Pango-only path: generic CDC, real UART toggle
# handshake, LED/SEG mailbox and the inferred IROM/DRAM.  Compiles with
# -U__VERILATOR__ so perip_bridge/counter take their synthesis branches.
pipeline-console:
	@mkdir -p $(ARES_HOME)/build/pipeline_console
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --timing --language 1800-2017 -U__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_console -Irtl/pipeline/include -Irtl/pipeline/core/vsrc/include \
	    rtl/pipeline/soc/pango/pipeline_cdc.v \
	    rtl/pipeline/soc/pango/pipeline_bram.v \
	    rtl/accel/mtx9_engine.sv \
	    rtl/accel/state9_engine.sv \
	    rtl/pipeline/soc/jyd/pipeline_accel.sv \
	    rtl/pipeline/soc/jyd/perip_bridge.sv \
	    rtl/pipeline/soc/jyd/irom_bmem32.sv \
	    rtl/pipeline/soc/jyd/bram_driver.sv \
	    rtl/pipeline/soc/jyd/counter.v \
	    rtl/pipeline/soc/jyd/uart.sv \
	    rtl/pipeline/soc/jyd/display_seg.sv \
	    rtl/pipeline/soc/jyd/seg7.sv \
	    rtl/pipeline/test/tb_pipeline_console.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_console_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_console -o $(ARES_HOME)/build/pipeline_console/pipeline_console
	@$(ARES_HOME)/build/pipeline_console/pipeline_console

# Elaborate the Pango board layer (PLL + clock/reset + UART + SoC) with the
# behavioural PLL model.  This is the local check for the board top; the PDS
# synthesis/implementation run happens on the Pango tool host.
pipeline-pango-lint:
	@cd $(ARES_HOME) && verilator --lint-only --language 1800-2017 -D__VERILATOR__ -Wall -Wno-fatal \
	    --top-module pipeline_board_top -Irtl/pipeline/include -Irtl/pipeline/core/vsrc/include \
	    -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/board/pipeline_pll_sim.v \
	    rtl/pipeline/board/pipeline_clk_reset.v \
	    rtl/pipeline/board/pipeline_board_top.v

# Elaborate the 2-hart AMP full-CoreMark board top with the behavioural PLL.
pipeline-amp-pango-lint:
	@cd $(ARES_HOME) && verilator --lint-only --timing --language 1800-2017 -D__VERILATOR__ -Wall -Wno-fatal \
	    --top-module pipeline_amp_board_top -Irtl/pipeline/include -Irtl/pipeline/core/vsrc/include \
	    -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/board/pipeline_pll_sim.v \
	    rtl/pipeline/board/pipeline_clk_reset.v \
	    rtl/pipeline/board/pipeline_amp_board_top.v

# Full board-level simulation: 27 MHz input -> PLL/reset -> pipeline_amp_top
# -> physical UART TX.  The TB decodes 115200 8N1 and stops after CoreMark
# prints PASS.  The loader reads the same build/pipeline/*.hex files the PDS
# flow initializes the BRAMs from, so the simulated image is the on-board
# image (regenerate them with pipeline-amp-image; no separate sim image).
pipeline-amp-board-sim:
	@$(MAKE) $(PIPELINE_BOARD_IMAGE_TARGET) $(PIPELINE_BOARD_IMAGE_ARGS)
	@mkdir -p $(ARES_HOME)/build/pipeline_amp_board_sim
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --timing --language 1800-2017 -D__VERILATOR__ -DARES_SIM_REAL_UART -Wno-fatal \
	    --top-module tb_pipeline_amp_board -Irtl/pipeline/include -Irtl/pipeline/core/vsrc/include \
	    -f rtl/pipeline/pipeline.f \
	    rtl/pipeline/board/pipeline_pll_sim.v \
	    rtl/pipeline/board/pipeline_clk_reset.v \
	    rtl/pipeline/board/pipeline_amp_board_top.v \
	    rtl/pipeline/test/tb_pipeline_amp_board.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_amp_board_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_amp_board_sim \
	    -o $(ARES_HOME)/build/pipeline_amp_board_sim/pipeline_amp_board_sim
	@$(ARES_HOME)/build/pipeline_amp_board_sim/pipeline_amp_board_sim \
	    $(PIPELINE_AMP_BOARD_IROM) $(PIPELINE_AMP_BOARD_DRAM) \
	    $(PIPELINE_AMP_BOARD_MAX_NS)

# Build the 2/4-hart coherence test images (branch-free linear program).
pipeline-mc-images:
	@$(MAKE) -C $(ARES_HOME)/tests/pipeline-mc all

# Lint the multi-hart top in both supported configurations.
pipeline-mc-lint:
	@for cores in 2 4; do \
	  cd $(ARES_HOME) && verilator --lint-only --language 1800-2017 -D__VERILATOR__ -Wall -Wno-fatal \
	      --top-module pipeline_mc_soc_top -GCORES=$$cores \
	      -f rtl/pipeline/pipeline_mc.f || exit 1; \
	done

# Build/run one configuration: make pipeline-mc-run PIPELINE_MC_CORES=2|4
pipeline-mc-run:
	@test -f $(PIPELINE_MC_IMAGE) || \
	  { echo "error: $(PIPELINE_MC_IMAGE) missing; run 'make pipeline-mc-images'"; exit 1; }
	@mkdir -p $(ARES_HOME)/build/pipeline_mc_run$(PIPELINE_MC_CORES)
	@cd $(ARES_HOME) && CCACHE_DISABLE=1 verilator --cc --exe --build --language 1800-2017 -D__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_mc -GCORES=$(PIPELINE_MC_CORES) \
	    -f rtl/pipeline/pipeline_mc.f \
	    rtl/pipeline/test/tb_pipeline_mc.sv $(ARES_HOME)/rtl/pipeline/test/sim_mc_main.cpp \
	    -Mdir $(ARES_HOME)/build/pipeline_mc_run$(PIPELINE_MC_CORES) \
	    -o $(ARES_HOME)/build/pipeline_mc_run$(PIPELINE_MC_CORES)/pipeline_mc
	@$(ARES_HOME)/build/pipeline_mc_run$(PIPELINE_MC_CORES)/pipeline_mc \
	    $(PIPELINE_MC_IMAGE) $(PIPELINE_MC_CORES) 500000

pipeline-mc-test: pipeline-mc-images
	@$(MAKE) pipeline-mc-run PIPELINE_MC_CORES=2
	@$(MAKE) pipeline-mc-run PIPELINE_MC_CORES=4
	@$(ARES_HOME)/build/pipeline_mc_run2/pipeline_mc \
	    $(ARES_HOME)/build/pipeline_mc/accel_read.bin 2 10000 1

#-----------------------------------------------------------------------------
# Housekeeping: build/ holds every Verilator model, ELF and Pango memory image.
#-----------------------------------------------------------------------------
clean:
	@rm -rf $(ARES_HOME)/build
	@echo "removed $(ARES_HOME)/build"
