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
        coremark-image coremark-mt-image unit-2core-coremark-mt \
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
