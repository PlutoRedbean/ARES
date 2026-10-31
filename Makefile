#=============================================================================
# ARES - top level convenience targets
#-----------------------------------------------------------------------------
# The real build lives in sim/ (Verilator) and tests/ (AbstractMachine).  This
# Makefile only wires the ARES core flow together:
#
#   make menuconfig     configure MUL_LATENCY / LINE_BYTES (saved in .config)
#   make test-config    self-test for the configuration tool
#   make defconfig      write the configuration defaults (no UI)
#   make showconfig     print the effective configuration
#   make savedefconfig  write configs/defconfig (non-default values only)
#   make lint           ARES core RTL lint (-Wall --assert, zero-warning gate)
#   make lint-all       lint every ARES test bench top
#   make tb-ares-pkg    package layout / encoding self-test
#   make tb-fe-stub     build + run the fe_stub contract test
#   make tb-mem-model   build + run the TB memory model test
#   make lint-backend   backend lint (be_top, -Wall --assert, zero warnings)
#   make unit           backend unit + integration self-tests (C1 gate)
#   make lint-lsu       LSU/memory lint + ares_core_top (C2/C3, zero warnings)
#   make lint-mt        miniTensor SoC integration (S09) lint
#   make unit-lsu       LSU unit + integration self-tests (C2 gate)
#   make all            lint + unit tests (C0 + C1 + C2 gate)
#   make sim            build the default ARES top (tb_ares_core)
#   make run PROGRAM=<image.bin>    run one image
#   make wave PROGRAM=<image.bin>   same, with an FST waveform
#   make isa            cpu-tests ISA regression (needs the riscv toolchain)
#
# See docs/c0_decisions.md (C0 decisions + verification evidence) and
# docs/core_verification_flow.md (test strategy).
#=============================================================================
ARES_HOME := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
RTL_ROOT  ?= $(ARES_HOME)/rtl
SIM       := $(MAKE) -s -C $(ARES_HOME)/sim ARES_RTL=1 RTL_ROOT=$(RTL_ROOT)
KCONFIG   := python3 $(ARES_HOME)/scripts/kconfig/ares_kconfig.py

PROGRAM ?=

# Debug defaults stay on; CoreMark scoring explicitly uses SIM_HEAVY_CHECKS=0 SIM_INFO=0.
# Compile out only expensive invariant scans; normal assertions stay on.
SIM_HEAVY_CHECKS ?= 1
ARES_SIM_CHECK_FLAGS := $(if $(filter 0,$(SIM_HEAVY_CHECKS)),-DARES_DISABLE_HEAVY_CHECKS)
# Runtime CoreMark harness output; UART text and errors remain visible.
SIM_INFO ?= 1
SIM_COLOR ?= 1
COREMARK_LOG_ARGS = +SIM_INFO=$(SIM_INFO) +SIM_COLOR=$(SIM_COLOR) $(if $(filter 0,$(SIM_INFO)),+verilator+quiet)

.PHONY: all lint lint-all lint-backend lint-lsu lint-l2 unit unit-lsu unit-l2 \
        lint-fe-adapter unit-fe-adapter unit-coremark unit-2core-coremark test-coremark-harness \
        build-coremark-sim build-2core-coremark-sim \
        unit-benchmark-io test-coremark-output \
        unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic tb-ares-pkg tb-fe-stub tb-mem-model \
        coremark-image coremark-mt-image unit-2core-coremark-mt coremark-crc-image \
        coremark-array-image coremark-matrix-image coremark-matrix-array-image \
        coremark-state-image coremark-full-image coremark-full-mt-image \
        test-coremark-image test-coremark-array test-l2-ref-faults \
        sim run wave isa clean menuconfig defconfig oldconfig savedefconfig \
        loaddefconfig showconfig test-config

all: lint lint-backend lint-lsu lint-l2 lint-fe-adapter lint-mt tb-ares-pkg tb-fe-stub tb-mem-model \
     unit unit-lsu unit-l2 unit-l2-frontend unit-fe-adapter unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic unit-frontend unit-soc

# FPGA project generation is independent of legacy npc/ and vendor build files.
# Explicit frequency keeps the requested clock visible in every team's command.
VIVADO ?= vivado
FPGA_CPU_MHZ ?=
FPGA_OUT ?= $(ARES_HOME)/build/vivado/ares
FPGA_PROFILE ?= soc
FPGA_ARGS ?=
.PHONY: vivado-project vivado-synth vivado-route test-vivado lint-soc unit-soc unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic lint-mt
vivado-project vivado-synth vivado-route:
	@test -n "$(FPGA_CPU_MHZ)" || { echo "set FPGA_CPU_MHZ to a target strictly above 200"; exit 1; }
	@python3 "$(ARES_HOME)/scripts/vivado/create_project.py" \
	    --profile "$(FPGA_PROFILE)" --cpu-mhz "$(FPGA_CPU_MHZ)" \
	    --output "$(FPGA_OUT)" --vivado "$(VIVADO)" \
	    --stage $(if $(filter vivado-synth,$@),synth,$(if $(filter vivado-route,$@),route,generate)) $(FPGA_ARGS)

test-vivado:
	@python3 "$(ARES_HOME)/scripts/vivado/test_create_project.py"

ARES_SOC_SRCS := $(filter-out %/ares_irom_bridge.sv,$(wildcard $(RTL_ROOT)/soc/jyd/*.sv)) \
                $(RTL_ROOT)/soc/jyd/test/memory_ip_models.sv \
                $(RTL_ROOT)/soc/jyd/test/xpm_cdc_models.sv

.PHONY: board-firmware lint-board unit-board
board-firmware:
	@python3 $(ARES_HOME)/scripts/build_board_smoke.py

ARES_BOARD_SRCS := $(RTL_ROOT)/board/ares_uart.sv $(RTL_ROOT)/board/top.sv \
                   $(RTL_ROOT)/board/test/pll_model.sv
ARES_BOARD_PLATFORM = $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv \
    $(RTL_ROOT)/common/lsu_pkg.sv $(wildcard $(RTL_ROOT)/backend/*.sv) \
    $(wildcard $(RTL_ROOT)/memory/*.sv) $(RTL_ROOT)/top/ares_core_top.sv \
    $(RTL_ROOT)/top/student_top.sv $(ARES_FE_SRCS) $(ARES_SOC_SRCS) $(ARES_BOARD_SRCS)

lint-board: config-gen
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --timing --top-module top $(ARES_BOARD_PLATFORM)

unit-board: config-gen board-firmware
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_board_io $(ARES_HOME)/sim/build/unit/tb_board
	@verilator --binary -j 4 --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    --top-module tb_board_io --Mdir $(ARES_HOME)/sim/build/unit/tb_board_io -o tb_board_io \
	    $(RTL_ROOT)/soc/jyd/ares_reset_sync.sv $(RTL_ROOT)/board/ares_uart.sv $(RTL_ROOT)/board/test/tb_board_io.sv
	@$(ARES_HOME)/sim/build/unit/tb_board_io/tb_board_io
	@verilator --binary -j 4 --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_board \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_board -o tb_board $(ARES_BOARD_PLATFORM) $(RTL_ROOT)/board/test/tb_board.sv
	@$(ARES_HOME)/sim/build/unit/tb_board/tb_board +IROM_HEX=$(ARES_HOME)/build/firmware/c4-board/irom.hex +DRAM_HEX=$(ARES_HOME)/build/firmware/c4-board/dram.hex

# miniTensor SoC integration (S09): the vendored accelerator RTL plus the ARES
# CV-X-IF host adapter and the JYD-platform integration top ares_soc_top.
MINITENSOR_HOME ?= $(ARES_HOME)/miniTensor
ARES_MT_SRCS := \
    $(RTL_ROOT)/soc/ares_mt_host_adapter.sv \
    $(MINITENSOR_HOME)/rtl/interface/core_v_xif.sv \
    $(MINITENSOR_HOME)/rtl/common/minitensor_pkg.sv \
    $(MINITENSOR_HOME)/rtl/tensor/tensor_pkg.sv \
    $(MINITENSOR_HOME)/rtl/vector/vpu_pkg.sv \
    $(MINITENSOR_HOME)/rtl/vector/vpu_vector_regfile.sv \
    $(MINITENSOR_HOME)/rtl/vector/vpu_vector_alu.sv \
    $(MINITENSOR_HOME)/rtl/control/vpu_vector_controller.sv \
    $(MINITENSOR_HOME)/rtl/tensor/MXU/Systolic_Array/tensor_pe.sv \
    $(MINITENSOR_HOME)/rtl/tensor/MXU/Systolic_Array/tensor_systolic_array.sv \
    $(MINITENSOR_HOME)/rtl/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv \
    $(MINITENSOR_HOME)/rtl/tensor/tensor_controller.sv \
    $(MINITENSOR_HOME)/rtl/tensor/Epilogue/tensor_epilogue_core.sv \
    $(MINITENSOR_HOME)/rtl/tensor/Epilogue/tensor_epilogue_controller.sv \
    $(MINITENSOR_HOME)/rtl/memory/unified_buffer.sv \
    $(MINITENSOR_HOME)/rtl/memory/vpu_dma.sv \
    $(MINITENSOR_HOME)/rtl/top/mini_tensor_top.sv

ARES_FE_SRCS := $(RTL_ROOT)/frontend/bpu/direction/tage_pkg.sv \
    $(RTL_ROOT)/frontend/interface/axi_if.sv $(RTL_ROOT)/frontend/interface/miniTensor_if.sv \
    $(wildcard $(RTL_ROOT)/frontend/*.sv) $(wildcard $(RTL_ROOT)/frontend/bpu/*.sv) \
    $(filter-out $(RTL_ROOT)/frontend/bpu/direction/tage_pkg.sv,$(wildcard $(RTL_ROOT)/frontend/bpu/direction/*.sv)) $(wildcard $(RTL_ROOT)/frontend/bpu/target/*.sv) \
    $(wildcard $(RTL_ROOT)/frontend/ifu/*.sv) $(RTL_ROOT)/soc/jyd/ares_irom_bridge.sv \
    $(RTL_ROOT)/top/ares_cpu_top.sv

# Empty pins are intentional debug observations / unused mailbox status.
lint-soc: config-gen
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module student_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv $(ARES_FE_SRCS) $(ARES_SOC_SRCS)

# miniTensor SoC integration (S09): elaborate the real JYD subtree together
# with mini_tensor_top and the ARES CV-X-IF host adapter.  The DMA master is
# exported by ares_soc_top and left for the future Fabric (SPEC-M7/M20/M21).
lint-mt: config-gen
	@echo "[lint] ares_soc_top + mini_tensor_top + ares_mt_host_adapter"
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module ares_soc_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv \
	    $(RTL_ROOT)/top/ares_soc_top.sv $(ARES_FE_SRCS) $(ARES_SOC_SRCS) $(ARES_MT_SRCS)

unit-soc: config-gen
	@python3 $(ARES_HOME)/scripts/build_soc_smoke.py
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_jyd_bus
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_jyd_bus \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_jyd_bus -o tb_jyd_bus \
	    $(ARES_SOC_SRCS) $(RTL_ROOT)/soc/jyd/test/tb_jyd_bus.sv
	@$(ARES_HOME)/sim/build/unit/tb_jyd_bus/tb_jyd_bus
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_student_top
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_student_top \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_student_top -o tb_student_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv $(ARES_FE_SRCS) $(ARES_SOC_SRCS) \
	    $(RTL_ROOT)/soc/jyd/test/tb_student_top.sv
	@$(ARES_HOME)/sim/build/unit/tb_student_top/tb_student_top +IROM_HEX=$(ARES_HOME)/sim/build/soc-smoke/irom.hex +DRAM_HEX=$(ARES_HOME)/sim/build/soc-smoke/dram.hex

# miniTensor host-adapter IRQ slice: behavioural CV-X-IF slave, MMIO command
# pushes, need_work/done/error interrupts, mask/ack and status-clear semantics.
unit-mt-irq: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_mt_irq
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_mt_irq \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_mt_irq -o tb_mt_irq \
	    $(RTL_ROOT)/soc/ares_mt_host_adapter.sv \
	    $(MINITENSOR_HOME)/rtl/interface/core_v_xif.sv \
	    $(RTL_ROOT)/soc/test/tb_mt_irq.sv
	@$(ARES_HOME)/sim/build/unit/tb_mt_irq/tb_mt_irq

# CPU-level tensor IRQ: real student_top frontend/IROM + adapter; the program
# masks need_work, kicks one command, enables MEIE, traps on mip.MEIP, checks
# mcause=0x8000000B, ACKs need_work and exits with a0=0.
unit-mt-cpu-irq: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_mt_cpu_irq \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq -o tb_mt_cpu_irq \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv \
	    $(RTL_ROOT)/soc/ares_mt_host_adapter.sv \
	    $(MINITENSOR_HOME)/rtl/interface/core_v_xif.sv \
	    $(ARES_FE_SRCS) $(ARES_SOC_SRCS) \
	    $(RTL_ROOT)/soc/test/tb_mt_cpu_irq.sv
	@$(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq/tb_mt_cpu_irq

# Per-hart CLINT: 64-bit mtime, two mtimecmp/msip, byte strobes, single
# outstanding 32-bit MMIO response.
unit-clint: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_clint
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_clint \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_clint -o tb_clint \
	    $(RTL_ROOT)/soc/soc_clint.sv $(RTL_ROOT)/soc/test/tb_clint.sv
	@$(ARES_HOME)/sim/build/unit/tb_clint/tb_clint

# PLIC: 32 sources, 2 machine contexts, priority/enable/threshold,
# claim/complete with a level gateway and per-context MEIP.
unit-plic: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_plic
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_plic \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_plic -o tb_plic \
	    $(RTL_ROOT)/soc/soc_plic.sv $(RTL_ROOT)/soc/test/tb_plic.sv
	@$(ARES_HOME)/sim/build/unit/tb_plic/tb_plic

#-----------------------------------------------------------------------------
# Backend (C1): lint the backend subsystem top and run the standalone
# self-checking benches under rtl/backend/test/unit/ (each has its own clock,
# so they are built with "verilator --binary --timing" and are deliberately
# outside the sim/Makefile VSRCS glob).
#-----------------------------------------------------------------------------
ARES_UNIT_TBS  := tb_decode tb_fu_exec tb_bru_csr tb_backend tb_issue_equiv tb_p0_csr_irq
ARES_UNIT_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(wildcard $(RTL_ROOT)/backend/*.sv) \
                  $(RTL_ROOT)/backend/test/lsu_stub.sv \
                  $(wildcard $(RTL_ROOT)/backend/test/unit/*.sv)
ARES_UNIT_SRCS += $(wildcard $(RTL_ROOT)/backend/test/unit/reference/*.sv)

#-----------------------------------------------------------------------------
# LSU / memory (C2): unit self-checking benches under rtl/memory/test/unit/.
# The benches are their own top modules (own clock, no DPI model, no harness),
# so they are built with "verilator --binary --timing" and are deliberately
# outside the sim/Makefile VSRCS glob.
#-----------------------------------------------------------------------------
ARES_LSU_UNIT_TBS  := tb_lsu_agu tb_store_forward tb_sq tb_lq tb_lsu_completion \
                      tb_line_adapter tb_lsu \
                      tb_dcache_arrays tb_dcache_top tb_wb_buffer tb_mshr tb_mmio_bridge
LSU_UNIT_BUILD ?= $(ARES_HOME)/sim/build/unit
ARES_LSU_UNIT_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
                      $(wildcard $(RTL_ROOT)/memory/*.sv) \
                      $(wildcard $(RTL_ROOT)/memory/test/unit/*.sv)
# Shared L2 + two-hart bring-up: l2_top itself and the 2-core top.
ARES_L2_UNIT_TBS := tb_l2 tb_l2_ref tb_two_core_l2
ARES_L2_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
                $(RTL_ROOT)/l2/l2_pkg.sv $(RTL_ROOT)/l2/l2_top.sv \
                $(wildcard $(RTL_ROOT)/backend/*.sv) \
                $(RTL_ROOT)/backend/test/unit/fe_model.sv \
                $(wildcard $(RTL_ROOT)/memory/*.sv) \
                $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/ares_2core_l2_top.sv

ARES_CFG_INC := +incdir+$(ARES_HOME)/configs/build/vsrc/include
VERILATOR_LINT_FLAGS := --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
                        -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC)

# fe_pkg.sv includes the generated configuration header (configs/Kconfig).
config-gen:
	@$(KCONFIG) gen >/dev/null

lint-backend: config-gen
	@for top in be_top ciq be_issue_sched be_operand_read be_commit be_flush be_trap_ctrl \
	            be_completion be_checkpoint be_producer_map be_bpu_update be_redirect be_gpr; do \
	  echo "[lint] $$top"; \
	  verilator $(VERILATOR_LINT_FLAGS) --top-module $$top \
	      $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(wildcard $(RTL_ROOT)/backend/*.sv) || exit 1; \
	done

# LSU / memory lint, including the C3 core top (ares_core_top needs both
# subsystems, so it is linted together with the backend and memory sources).
lint-lsu: config-gen
	@for top in store_forward lsu_agu lq sq lsu_completion line_adapter \
	            dcache_arrays dcache_top mshr wb_buffer mmio_bridge lsu_top; do \
	  echo "[lint] $$top"; \
	  verilator $(VERILATOR_LINT_FLAGS) --top-module $$top \
	      $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	      $(wildcard $(RTL_ROOT)/memory/*.sv) $(wildcard $(RTL_ROOT)/memory/test/*.sv) || exit 1; \
	done
	@echo "[lint] ares_core_top"; \
	verilator $(VERILATOR_LINT_FLAGS) --top-module ares_core_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
    $(RTL_ROOT)/top/ares_core_top.sv || exit 1

lint-l2: config-gen
	@echo "[lint] l2_top"
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module l2_top \
	    $(RTL_ROOT)/l2/l2_pkg.sv $(RTL_ROOT)/l2/l2_top.sv
	@echo "[lint] ares_2core_l2_top"
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module ares_2core_l2_top \
	    $(ARES_L2_SRCS)

# L2 harts must also elaborate against the native real-frontend contract.
.PHONY: lint-l2-frontend
lint-l2: lint-l2-frontend
lint-l2-frontend: config-gen
	@set -e; for top in ares_frontend_l2_top ares_2core_frontend_l2_top; do \
	  echo "[lint] $$top"; \
	  verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module $$top \
	      $(ARES_COREMARK_SRCS) \
	      $(RTL_ROOT)/top/ares_frontend_hart.sv \
	      $(RTL_ROOT)/top/ares_2core_frontend_l2_top.sv; \
	done

# Matrix engine (standalone + 2-core integration)
.PHONY: lint-mtx9 unit-mtx9
lint-mtx9:
	@echo "[lint] mtx9_engine"
	@verilator $(VERILATOR_LINT_FLAGS) --top-module mtx9_engine \
	    $(RTL_ROOT)/accel/mtx9_engine.sv

unit-mtx9:
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_mtx9_engine
	@verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
	    -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -DCONFIG_SIMULATION \
	    --top-module tb_mtx9_engine \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_mtx9_engine \
	    -o $(ARES_HOME)/sim/build/unit/tb_mtx9_engine/tb_mtx9_engine \
	    $(RTL_ROOT)/accel/mtx9_engine.sv \
	    $(RTL_ROOT)/accel/test/unit/tb_mtx9_engine.sv
	@$(ARES_HOME)/sim/build/unit/tb_mtx9_engine/tb_mtx9_engine

# State-machine token scanner (standalone + SoC integration)
.PHONY: lint-state9 unit-state9
lint-state9:
	@echo "[lint] state9_engine"
	@verilator $(VERILATOR_LINT_FLAGS) --top-module state9_engine \
	    $(RTL_ROOT)/accel/state9_engine.sv

unit-state9:
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_state9_engine
	@verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
	    -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -Wno-UNSIGNED -DCONFIG_SIMULATION \
	    --top-module tb_state9_engine \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_state9_engine \
	    -o $(ARES_HOME)/sim/build/unit/tb_state9_engine/tb_state9_engine \
	    $(RTL_ROOT)/accel/state9_engine.sv \
	    $(RTL_ROOT)/accel/test/unit/tb_state9_engine.sv
	@$(ARES_HOME)/sim/build/unit/tb_state9_engine/tb_state9_engine

# Retained legacy adapter unit fixture. Current CPU/L2 tops use native C5
# recovery and two-lane training directly, without this adapter.
lint-fe-adapter: config-gen
	@echo "[lint] fe_legacy_adapter"
	@verilator $(VERILATOR_LINT_FLAGS) --top-module fe_legacy_adapter \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/frontend/fe_legacy_adapter.sv

unit-fe-adapter: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter
	@verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	    --top-module tb_fe_legacy_adapter \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter \
	    -o $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter/tb_fe_legacy_adapter \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/frontend/fe_legacy_adapter.sv \
	    $(RTL_ROOT)/frontend/test/tb_fe_legacy_adapter.sv
	@$(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter/tb_fe_legacy_adapter | tail -2

# CoreMark software image.  The repository builds it from tests/benchmarks/
# coremark (vendored EEMBC sources + ARES port) and stamps build/coremark/
# inputs.json with the frozen parameters, source hashes and tool versions.
# The 128-bit-wide $readmemh format is documented in
# rtl/top/test/tb_ares_coremark.sv.
COREMARK_OUT ?= $(ARES_HOME)/build/coremark
COREMARK_HEX ?= $(COREMARK_OUT)/coremark_dmem.hex
# Full-check and light models must not reuse each other's generated C++.
COREMARK_SIM_DIR ?= $(ARES_HOME)/sim/build/unit$(if $(filter 0,$(SIM_HEAVY_CHECKS)),_light)
COREMARK_IMAGE_FLAGS ?=
COREMARK_IMAGE_CMD = python3 "$(ARES_HOME)/scripts/build_coremark_image.py" --out "$(COREMARK_OUT)" $(COREMARK_IMAGE_FLAGS)
COREMARK_PORT_SRCS := $(wildcard $(ARES_HOME)/tests/benchmarks/coremark/src/*.c) \
                      $(wildcard $(ARES_HOME)/tests/benchmarks/coremark/include/*.h) \
                      $(ARES_HOME)/scripts/build_coremark_image.py \
                      $(ARES_HOME)/scripts/elf_image.py

# Explicit rebuild request; the long-program targets depend on the hex file
# instead so an existing image is reused.
coremark-image:
	@$(COREMARK_IMAGE_CMD)

# Two-hart MULTITHREAD=2 image.  The EEMBC tree is NOT modified: the driver
# stages it under build/coremark_mt/port and overlays scripts/coremark_mt/
# (MEM_STACK, MULTITHREAD=2, mailbox hooks) onto the copy.
coremark-mt-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_image.py" --mt \
	    --out "$(ARES_HOME)/build/coremark_mt" --jobs 4

# CRC-only variant (custom-0 CRC8 instruction; EEMBC sources untouched).
coremark-crc-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" 	    --out "$(ARES_HOME)/build/coremark_crc" --jobs 4

# CRC + software array-shadow core_bench_list variant.  The EEMBC sources are
# only staged/copied; the array replacement is a new TU generated by the build
# script, and core_list_join.c keeps its original bytes.
coremark-array-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --array-list \
	    --out "$(ARES_HOME)/build/coremark_array" --jobs 4

# CRC + 9-PE INT16 matrix engine variant.
coremark-matrix-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --matrix-engine \
	    --out "$(ARES_HOME)/build/coremark_matrix" --jobs 4

# CRC + array-shadow list + 9-PE matrix engine variant.
coremark-matrix-array-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --matrix-engine --array-list \
	    --out "$(ARES_HOME)/build/coremark_matrix_array" --jobs 4

# CRC + state-machine token scanner variant.
coremark-state-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --state-engine \
	    --out "$(ARES_HOME)/build/coremark_state" --jobs 4

# CRC + array-shadow list + matrix engine + state scanner.
coremark-full-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --state-engine \
	    --matrix-engine --array-list --out "$(ARES_HOME)/build/coremark_full" --jobs 4

# Same accelerations plus MULTITHREAD=2: one aggregate report from hart0.
coremark-full-mt-image:
	@python3 "$(ARES_HOME)/scripts/build_coremark_crc.py" --state-engine \
	    --matrix-engine --array-list --mt \
	    --out "$(ARES_HOME)/build/coremark_full_mt" --jobs 4

$(COREMARK_HEX): $(COREMARK_PORT_SRCS)
	@$(COREMARK_IMAGE_CMD)

# Negative/positive tests for the image chain (ELF32 -> bin -> readmemh), no RTL.
test-coremark-image:
	@python3 "$(ARES_HOME)/scripts/test_coremark_image.py"

# Host-side equivalence over the full 100x2 core_bench_list call sequence.
test-coremark-array:
	@python3 "$(ARES_HOME)/scripts/test_coremark_array.py"

# Fault injection proving the L2 reference-model testbench is discriminating.
test-l2-ref-faults:
	@python3 "$(ARES_HOME)/scripts/test_l2_ref_faults.py"

# Real frontend + shared L2 CoreMark (single-hart bring-up).  Without DMEM= the
# image is taken from (and built by) coremark-image; an explicit DMEM= still wins.
ifeq ($(strip $(DMEM)),)
unit-coremark: $(COREMARK_HEX)
endif
ARES_COREMARK_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
    $(ARES_FE_SRCS) $(RTL_ROOT)/frontend/interface/axi_l2_bridge.sv \
    $(RTL_ROOT)/l2/l2_pkg.sv $(RTL_ROOT)/l2/l2_top.sv \
    $(RTL_ROOT)/accel/mtx9_engine.sv \
    $(RTL_ROOT)/accel/state9_engine.sv \
    $(RTL_ROOT)/board/ares_uart.sv $(RTL_ROOT)/top/ares_benchmark_io.sv \
    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/ares_frontend_l2_top.sv

unit-coremark: build-coremark-sim
	@hex="$(if $(strip $(DMEM)),$(DMEM),$(COREMARK_HEX))"; 	 test -f "$$hex" || { echo "error: CoreMark image not found: $$hex"; 	   echo "       run 'make coremark-image' (or pass DMEM=<coremark_dmem.hex>)"; exit 1; }
	@$(COREMARK_SIM_DIR)/tb_ares_coremark/tb_ares_coremark \
	    +DMEM=$(if $(strip $(DMEM)),$(DMEM),$(COREMARK_HEX)) $(COREMARK_LOG_ARGS) $(COREMARK_ARGS)

build-coremark-sim: config-gen
	@mkdir -p $(COREMARK_SIM_DIR)/tb_ares_coremark
	@verilator -O3 -CFLAGS -O3 --binary -j 4 --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL \
	    -Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_ares_coremark \
	    --Mdir $(COREMARK_SIM_DIR)/tb_ares_coremark \
	    -o $(COREMARK_SIM_DIR)/tb_ares_coremark/tb_ares_coremark \
	    $(ARES_COREMARK_SRCS) $(RTL_ROOT)/top/test/uart_console_monitor.sv \
	    $(RTL_ROOT)/top/test/coremark_sim_log_pkg.sv $(RTL_ROOT)/top/test/tb_ares_coremark.sv

# Two-hart AMP CoreMark on the shared L2 (two full CoreMark copies, hart1's
# data/stack offset by 1 MiB).  Uses the same generated image as unit-coremark
# and is likewise kept out of 'all'.  See docs/m1_closure_decisions.md for the
# diagnostic-only status of the 1 MiB private-data offset.
ARES_2CORE_COREMARK_SRCS := $(ARES_COREMARK_SRCS) \
    $(RTL_ROOT)/top/ares_frontend_hart.sv \
    $(RTL_ROOT)/top/ares_coremark_mbox.sv \
    $(RTL_ROOT)/top/ares_2core_frontend_l2_top.sv \
    $(RTL_ROOT)/top/test/uart_console_monitor.sv \
    $(RTL_ROOT)/top/test/coremark_sim_log_pkg.sv \
    $(RTL_ROOT)/top/test/tb_2core_coremark.sv

ifeq ($(strip $(DMEM)),)
unit-2core-coremark: $(COREMARK_HEX)
endif

unit-2core-coremark: build-2core-coremark-sim
	@hex="$(if $(strip $(DMEM)),$(DMEM),$(COREMARK_HEX))"; 	 test -f "$$hex" || { echo "error: CoreMark image not found: $$hex"; 	   echo "       run 'make coremark-image' (or pass DMEM=<coremark_dmem.hex>)"; exit 1; }
	@$(COREMARK_SIM_DIR)/tb_2core_coremark/tb_2core_coremark \
	    +DMEM=$(if $(strip $(DMEM)),$(DMEM),$(COREMARK_HEX)) $(COREMARK_LOG_ARGS) $(COREMARK_ARGS)

build-2core-coremark-sim: config-gen
	@mkdir -p $(COREMARK_SIM_DIR)/tb_2core_coremark
	@verilator -O3 -CFLAGS -O3 --binary -j 4 --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL \
	    -Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) --top-module tb_2core_coremark \
	    --Mdir $(COREMARK_SIM_DIR)/tb_2core_coremark \
	    -o $(COREMARK_SIM_DIR)/tb_2core_coremark/tb_2core_coremark \
	    $(ARES_2CORE_COREMARK_SRCS)

# Same testbench, MULTITHREAD=2 image: one aggregate report from hart0.
COREMARK_MT_OUT ?= $(ARES_HOME)/build/coremark_mt
COREMARK_MT_HEX ?= $(COREMARK_MT_OUT)/coremark_dmem.hex

ifeq ($(strip $(DMEM)),)
unit-2core-coremark-mt: $(COREMARK_MT_HEX)
$(COREMARK_MT_HEX): coremark-mt-image
endif

unit-2core-coremark-mt: build-2core-coremark-sim
	@$(COREMARK_SIM_DIR)/tb_2core_coremark/tb_2core_coremark \
	    +DMEM=$(if $(strip $(DMEM)),$(DMEM),$(COREMARK_MT_HEX)) \
	    +TIMEOUT_NS=2000000000 $(COREMARK_LOG_ARGS) $(COREMARK_ARGS)

test-coremark-harness:
	@python3 "$(ARES_HOME)/scripts/test_coremark_harness.py" \
	    --single $(COREMARK_SIM_DIR)/tb_ares_coremark/tb_ares_coremark \
	    --dual $(COREMARK_SIM_DIR)/tb_2core_coremark/tb_2core_coremark

unit-benchmark-io:
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_benchmark_io
	@verilator -O3 -CFLAGS -O3 --binary -j 4 --timing --assert -Wall \
	    -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET \
	    --top-module tb_benchmark_io --Mdir $(ARES_HOME)/sim/build/unit/tb_benchmark_io \
	    -o tb_benchmark_io $(RTL_ROOT)/board/ares_uart.sv \
	    $(RTL_ROOT)/top/ares_benchmark_io.sv $(RTL_ROOT)/top/test/uart_console_monitor.sv \
	    $(RTL_ROOT)/top/test/tb_benchmark_io.sv
	@$(ARES_HOME)/sim/build/unit/tb_benchmark_io/tb_benchmark_io

test-coremark-output:
	@python3 "$(ARES_HOME)/scripts/test_coremark_output.py" \
	    --single $(COREMARK_SIM_DIR)/tb_ares_coremark/tb_ares_coremark \
	    --dual $(COREMARK_SIM_DIR)/tb_2core_coremark/tb_2core_coremark

.PHONY: unit-l2-frontend
unit-l2-frontend: config-gen
	@set -e; for dual in 0 1; do \
	  d=$(ARES_HOME)/sim/build/unit/tb_frontend_l2_$$dual; mkdir -p $$d; \
	  verilator --binary -j 4 --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	      -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	      --top-module tb_frontend_l2 -GDUAL=$$dual --Mdir $$d -o $$d/tb_frontend_l2 \
	      $(ARES_COREMARK_SRCS) \
	      $(RTL_ROOT)/top/ares_frontend_hart.sv \
	      $(RTL_ROOT)/top/ares_2core_frontend_l2_top.sv $(RTL_ROOT)/top/test/tb_frontend_l2.sv; \
	  $$d/tb_frontend_l2; \
	done

unit-l2: config-gen
	@set -e; for tb in $(ARES_L2_UNIT_TBS); do \
	  d=$(ARES_HOME)/sim/build/unit/$$tb; \
	  echo "[unit-l2] $$tb"; \
	  case $$tb in \
	    tb_l2)          tb_src=$(RTL_ROOT)/l2/test/tb_l2.sv ;; \
	    tb_l2_ref)      tb_src="$(RTL_ROOT)/l2/test/l2_ref_model.sv $(RTL_ROOT)/l2/test/tb_l2_ref.sv" ;; \
	    tb_two_core_l2) tb_src=$(RTL_ROOT)/top/test/tb_two_core_l2.sv ;; \
	    *) echo "unknown L2 TB $$tb"; exit 1 ;; \
	  esac; \
	  rm -rf $$d; mkdir -p $$d/ccache-tmp; \
	  CCACHE_TEMPDIR=$$d/ccache-tmp verilator --binary --timing -sv --assert \
	      -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-SIDEEFFECT -Wno-BLKSEQ \
	      -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	      --top-module $$tb --Mdir $$d -o $$d/$$tb $(ARES_L2_SRCS) $$tb_src; \
	  if $$d/$$tb > $$d/run.log 2>&1; then \
	    grep -E "ALL TESTS PASSED" $$d/run.log | head -1; \
	  else \
	    echo "*** $$tb FAILED ***"; tail -30 $$d/run.log; exit 1; \
	  fi; \
	done

unit: config-gen
	@set -e; for tb in $(ARES_UNIT_TBS); do \
	  d=$(ARES_HOME)/sim/build/unit/$$tb; \
	  echo "[unit] $$tb"; \
	  rm -rf $$d; mkdir -p $$d/ccache-tmp; \
	  CCACHE_TEMPDIR=$$d/ccache-tmp verilator --binary --timing -sv --assert \
	      -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-SIDEEFFECT -Wno-BLKSEQ \
	      -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	      --top-module $$tb --Mdir $$d -o $$d/$$tb $(ARES_UNIT_SRCS); \
	  if $$d/$$tb > $$d/run.log 2>&1; then \
	    grep -E 'ALL TESTS PASSED|coverage:|phase[123]' $$d/run.log; \
	  else \
	    tail -20 $$d/run.log; exit 1; \
	  fi; \
	done

unit-lsu: config-gen
	@set -e; for tb in $(ARES_LSU_UNIT_TBS); do \
	  d=$(abspath $(LSU_UNIT_BUILD))/$$tb; \
	  echo "[unit-lsu] $$tb"; \
	  rm -rf $$d; mkdir -p $$d/ccache-tmp; \
	  CCACHE_TEMPDIR=$$d/ccache-tmp verilator --binary --timing -sv --assert \
	      -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-SIDEEFFECT -Wno-BLKSEQ \
	      -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	      --top-module $$tb --Mdir $$d -o $$d/$$tb $(ARES_LSU_UNIT_SRCS); \
	  if $$d/$$tb > $$d/run.log 2>&1; then \
	    grep -E "ALL TESTS PASSED" $$d/run.log | head -1; \
	  else \
	    echo "*** $$tb FAILED ***"; tail -20 $$d/run.log; exit 1; \
	  fi; \
	done

#-----------------------------------------------------------------------------
# Core configuration (Kconfig subset, see scripts/kconfig/README.md).
# .config lands in configs/build/.config and drives both the Verilator -D
# defines and the generated ares_autoconf.vh header.
#-----------------------------------------------------------------------------
menuconfig:
	@$(KCONFIG) menuconfig

defconfig:
	@$(KCONFIG) defconfig

oldconfig:
	@$(KCONFIG) oldconfig

savedefconfig:
	@$(KCONFIG) savedefconfig

loaddefconfig:
	@$(KCONFIG) loaddefconfig

showconfig:
	@$(KCONFIG) show

test-config:
	@python3 $(ARES_HOME)/scripts/kconfig/test_kconfig.py

lint:
	@$(SIM) lint

lint-all:
	@$(SIM) lint-all

tb-ares-pkg:
	@$(SIM) tb-ares-pkg

tb-fe-stub:
	@$(SIM) tb-fe-stub

tb-mem-model:
	@$(SIM) tb-mem-model

sim:
	@$(SIM)

run:
	@test -n "$(PROGRAM)" || { echo "usage: make run PROGRAM=<image.bin>"; exit 1; }
	@$(SIM) run PROGRAM=$(PROGRAM)

wave:
	@test -n "$(PROGRAM)" || { echo "usage: make wave PROGRAM=<image.bin>"; exit 1; }
	@$(SIM) wave PROGRAM=$(PROGRAM)

isa:
	@$(MAKE) -C $(ARES_HOME)/tests/cpu-tests ARCH=riscv32-ares run

clean:
	@$(MAKE) -s -C $(ARES_HOME)/sim clean

.PHONY: unit-frontend lint-frontend isa-stub isa-real-fe
lint-frontend: config-gen
	@$(SIM) TOPNAME=tb_ares_cpu lint

FE_UNIT_TBS ?= tb_iq tb_bpu_contract tb_bpu_history tb_fe_be_contract tb_irom_bridge tb_ubtb_equiv tb_icache_way tb_ftq_correction tb_bpu_s2
FE_UNIT_BUILD ?= $(ARES_HOME)/sim/build/unit
unit-frontend: config-gen
	@set -e; for tb in $(FE_UNIT_TBS); do \
	  d=$(FE_UNIT_BUILD)/$$tb; mkdir -p $$d; \
	  echo "[unit-frontend] $$tb"; \
	  verilator --binary -j 4 --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	      -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -DCONFIG_SIMULATION $(ARES_SIM_CHECK_FLAGS) $(ARES_CFG_INC) \
	      --top-module $$tb --Mdir $$d -o $$d/$$tb \
	      $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	      $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	      $(RTL_ROOT)/top/ares_core_top.sv $(ARES_FE_SRCS) \
	      $(RTL_ROOT)/frontend/test/reference/ubtb_reference.sv $(RTL_ROOT)/frontend/test/$$tb.sv; \
	  $$d/$$tb; \
	done

isa-stub:
	@$(MAKE) -C $(ARES_HOME)/tests/cpu-tests ARCH=riscv32-ares TOPNAME=tb_ares_core run

isa-real-fe:
	@$(MAKE) -C $(ARES_HOME)/tests/cpu-tests ARCH=riscv32-ares TOPNAME=tb_ares_cpu run

.PHONY: unit-frontend-modes test-images
unit-frontend-modes:
	@python3 $(ARES_HOME)/scripts/test_frontend_modes.py

test-images:
	@python3 $(ARES_HOME)/scripts/test_split_image.py

.PHONY: pipeline-core-gen pipeline-lint pipeline-div-test pipeline-smoke pipeline-isa-sim pipeline-isa pipeline-coremark pipeline-coremark-nocache pipeline-coremark-serial pipeline-coremark-crc pipeline-coremark-matrix pipeline-coremark-state pipeline-coremark-full pipeline-coremark-images pipeline-coremark-mc pipeline-coremark-mt pipeline-coremark-mt-test pipeline-coremark-full-mt pipeline-coremark-mt-image pipeline-coremark-full-mt-image coremark-full-mc-image pipeline-image pipeline-pango-lint pipeline-console pipeline-mc-images pipeline-mc-lint pipeline-mc-run pipeline-mc-test

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
	@$(MAKE) coremark-crc-image coremark-matrix-image coremark-state-image coremark-full-image

# Full accelerated CoreMark image linked for per-hart AMP data regions.
# The image is still MULTITHREAD=1: each hart runs its own CoreMark instance;
# DATA_STRIDE provides the private 32 KiB data/rodata/bss/stack window.
coremark-full-mc-image:
	@python3 $(ARES_HOME)/scripts/build_coremark_crc.py \
	    --array-list --matrix-engine --state-engine \
	    --ldscript $(PIPELINE_MC_LDSCRIPT) \
	    --out $(PIPELINE_COREMARK_FULL_MC_OUT)

# Standard CoreMark MULTITHREAD image: one aggregate report over CORES harts,
# each context running COREMARK_MT_TOTAL_ITERATIONS/CORES iterations.  The
# image is linked with the per-hart 32 KiB AMP window and never shared
# between 2- and 4-hart builds.  (The legacy OoO 'coremark-mt-image'
# target keeps its own 2-hart MULTITHREAD=2 image under build/coremark_mt.)
pipeline-coremark-mt-image:
	@case "$(CORES)" in 2|4) ;; *) echo "error: CORES must be 2 or 4 (got '$(CORES)')"; exit 1;; esac
	@python3 $(ARES_HOME)/scripts/build_coremark_image.py \
	    --mt-pipe --cores $(CORES) \
	    --total-iterations $(COREMARK_MT_TOTAL_ITERATIONS) \
	    --ldscript $(PIPELINE_MC_LDSCRIPT) --jobs 4 \
	    --out $(PIPELINE_MT_OUT)

# Full-accelerated variant of the pipeline MULTITHREAD image (same
# semantics, CRC8 + matrix + state engines, per-hart private windows).
# CORES=4 does not fit: its text needs ~33,068 B versus a 32 KiB IROM; use
# 'make pipeline-coremark-mc CORES=4' (MULTITHREAD=1 AMP image) for 4 harts.
pipeline-coremark-full-mt-image:
	@case "$(CORES)" in 2) ;; *) echo "error: $(CORES)-hart full-accelerated MT needs ~33 KiB and does not fit the 32 KiB IROM; use 'make pipeline-coremark-mc CORES=$(CORES)' or grow the IROM"; exit 1;; esac
	@python3 $(ARES_HOME)/scripts/build_coremark_crc.py \
	    --array-list --matrix-engine --state-engine \
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

# 2/4-hart standard CoreMark MULTITHREAD on the private-memory AMP top.
# The Verilator profile uses PIPELINE_MT_SIM_TOTAL total iterations (200 by
# default: 2x100 or 4x50) so the run finishes in minutes.  The canonical
# 10,000-iteration report image is the default of 'make coremark-mt-image';
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
