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

.PHONY: all lint lint-all lint-backend lint-lsu lint-l2 unit unit-lsu unit-l2 \
        lint-fe-adapter unit-fe-adapter unit-coremark \
        unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic tb-ares-pkg tb-fe-stub tb-mem-model \
        sim run wave isa clean menuconfig defconfig oldconfig savedefconfig \
        loaddefconfig showconfig test-config

all: lint lint-backend lint-lsu lint-l2 lint-fe-adapter lint-mt tb-ares-pkg tb-fe-stub tb-mem-model \
     unit unit-lsu unit-l2 unit-fe-adapter unit-mt-irq unit-mt-cpu-irq unit-clint unit-plic

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

ARES_SOC_SRCS := $(wildcard $(RTL_ROOT)/soc/jyd/*.sv) \
                $(RTL_ROOT)/soc/jyd/test/memory_ip_models.sv \
                $(RTL_ROOT)/soc/jyd/test/xpm_cdc_models.sv

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

# Empty pins are intentional debug observations / unused mailbox status.
lint-soc: config-gen
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module student_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv $(ARES_SOC_SRCS)

# miniTensor SoC integration (S09): elaborate the real JYD subtree together
# with mini_tensor_top and the ARES CV-X-IF host adapter.  The DMA master is
# exported by ares_soc_top and left for the future Fabric (SPEC-M7/M20/M21).
lint-mt: config-gen
	@echo "[lint] ares_soc_top + mini_tensor_top + ares_mt_host_adapter"
	@verilator $(VERILATOR_LINT_FLAGS) -Wno-PINCONNECTEMPTY --top-module ares_soc_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv \
	    $(RTL_ROOT)/top/ares_soc_top.sv $(ARES_SOC_SRCS) $(ARES_MT_SRCS)

unit-soc: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_jyd_bus
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_jyd_bus \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_jyd_bus -o tb_jyd_bus \
	    $(ARES_SOC_SRCS) $(RTL_ROOT)/soc/jyd/test/tb_jyd_bus.sv
	@$(ARES_HOME)/sim/build/unit/tb_jyd_bus/tb_jyd_bus
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_student_top
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_student_top \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_student_top -o tb_student_top \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv $(ARES_SOC_SRCS) \
	    $(RTL_ROOT)/soc/jyd/test/tb_student_top.sv
	@$(ARES_HOME)/sim/build/unit/tb_student_top/tb_student_top

# miniTensor host-adapter IRQ slice: behavioural CV-X-IF slave, MMIO command
# pushes, need_work/done/error interrupts, mask/ack and status-clear semantics.
unit-mt-irq: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_mt_irq
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_mt_irq \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_mt_irq -o tb_mt_irq \
	    $(RTL_ROOT)/soc/ares_mt_host_adapter.sv \
	    $(MINITENSOR_HOME)/rtl/interface/core_v_xif.sv \
	    $(RTL_ROOT)/soc/test/tb_mt_irq.sv
	@$(ARES_HOME)/sim/build/unit/tb_mt_irq/tb_mt_irq

# CPU-level tensor IRQ: real student_top + adapter + FE model; the program
# masks need_work, kicks one command, enables MEIE, traps on mip.MEIP, checks
# mcause=0x8000000B, ACKs need_work and exits with a0=0.
unit-mt-cpu-irq: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_mt_cpu_irq \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq -o tb_mt_cpu_irq \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
	    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
	    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/student_top.sv \
	    $(RTL_ROOT)/soc/ares_mt_host_adapter.sv \
	    $(MINITENSOR_HOME)/rtl/interface/core_v_xif.sv \
	    $(RTL_ROOT)/backend/test/unit/fe_model.sv $(ARES_SOC_SRCS) \
	    $(RTL_ROOT)/soc/test/tb_mt_cpu_irq.sv
	@$(ARES_HOME)/sim/build/unit/tb_mt_cpu_irq/tb_mt_cpu_irq

# Per-hart CLINT: 64-bit mtime, two mtimecmp/msip, byte strobes, single
# outstanding 32-bit MMIO response.
unit-clint: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_clint
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_clint \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_clint -o tb_clint \
	    $(RTL_ROOT)/soc/soc_clint.sv $(RTL_ROOT)/soc/test/tb_clint.sv
	@$(ARES_HOME)/sim/build/unit/tb_clint/tb_clint

# PLIC: 32 sources, 2 machine contexts, priority/enable/threshold,
# claim/complete with a level gateway and per-context MEIP.
unit-plic: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_plic
	@verilator --binary --timing --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_plic \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_plic -o tb_plic \
	    $(RTL_ROOT)/soc/soc_plic.sv $(RTL_ROOT)/soc/test/tb_plic.sv
	@$(ARES_HOME)/sim/build/unit/tb_plic/tb_plic

#-----------------------------------------------------------------------------
# Backend (C1): lint the backend subsystem top and run the standalone
# self-checking benches under rtl/backend/test/unit/ (each has its own clock,
# so they are built with "verilator --binary --timing" and are deliberately
# outside the sim/Makefile VSRCS glob).
#-----------------------------------------------------------------------------
ARES_UNIT_TBS  := tb_decode tb_fu_exec tb_bru_csr tb_backend tb_p0_csr_irq
ARES_UNIT_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(wildcard $(RTL_ROOT)/backend/*.sv) \
                  $(RTL_ROOT)/backend/test/lsu_stub.sv \
                  $(wildcard $(RTL_ROOT)/backend/test/unit/*.sv)

#-----------------------------------------------------------------------------
# LSU / memory (C2): unit self-checking benches under rtl/memory/test/unit/.
# The benches are their own top modules (own clock, no DPI model, no harness),
# so they are built with "verilator --binary --timing" and are deliberately
# outside the sim/Makefile VSRCS glob.
#-----------------------------------------------------------------------------
ARES_LSU_UNIT_TBS  := tb_lsu_agu tb_store_forward tb_sq tb_lq tb_lsu_completion \
                      tb_line_adapter tb_lsu \
                      tb_dcache_arrays tb_wb_buffer tb_mshr tb_mmio_bridge
ARES_LSU_UNIT_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
                      $(wildcard $(RTL_ROOT)/memory/*.sv) \
                      $(wildcard $(RTL_ROOT)/memory/test/unit/*.sv)
# Shared L2 + two-hart bring-up: l2_top itself and the 2-core top.
ARES_L2_UNIT_TBS := tb_l2 tb_two_core_l2
ARES_L2_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
                $(RTL_ROOT)/l2/l2_pkg.sv $(RTL_ROOT)/l2/l2_top.sv \
                $(wildcard $(RTL_ROOT)/backend/*.sv) \
                $(RTL_ROOT)/backend/test/unit/fe_model.sv \
                $(wildcard $(RTL_ROOT)/memory/*.sv) \
                $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/ares_2core_l2_top.sv

ARES_CFG_INC := +incdir+$(ARES_HOME)/configs/build/vsrc/include
VERILATOR_LINT_FLAGS := --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
                        -DCONFIG_SIMULATION $(ARES_CFG_INC)

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

# C5 step 1: the legacy frontend contract adapter.  The real frontend is
# deliberately not migrated yet; this gate proves the zero-cycle IQ/redirect
# mapping and the 2->1 BPU update FIFO.
lint-fe-adapter: config-gen
	@echo "[lint] fe_legacy_adapter"
	@verilator $(VERILATOR_LINT_FLAGS) --top-module fe_legacy_adapter \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/frontend/fe_legacy_adapter.sv

unit-fe-adapter: config-gen
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter
	@verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -DCONFIG_SIMULATION $(ARES_CFG_INC) \
	    --top-module tb_fe_legacy_adapter \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter \
	    -o $(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter/tb_fe_legacy_adapter \
	    $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/frontend/fe_legacy_adapter.sv \
	    $(RTL_ROOT)/frontend/test/tb_fe_legacy_adapter.sv
	@$(ARES_HOME)/sim/build/unit/tb_fe_legacy_adapter/tb_fe_legacy_adapter | tail -2

# Real frontend + shared L2 CoreMark (single-hart bring-up).  The image is a
# 128-bit-wide $readmemh file; see rtl/top/test/tb_ares_coremark.sv for format.
ARES_COREMARK_SRCS := $(RTL_ROOT)/common/fe_pkg.sv $(RTL_ROOT)/common/ares_pkg.sv $(RTL_ROOT)/common/lsu_pkg.sv \
    $(RTL_ROOT)/frontend/interface/axi_if.sv $(RTL_ROOT)/frontend/interface/axi_l2_bridge.sv \
    $(RTL_ROOT)/frontend/fe_legacy_adapter.sv $(RTL_ROOT)/frontend/frontend.sv \
    $(RTL_ROOT)/frontend/ftq.sv $(RTL_ROOT)/frontend/iq.sv \
    $(wildcard $(RTL_ROOT)/frontend/bpu/*.sv) \
    $(wildcard $(RTL_ROOT)/frontend/bpu/direction/*.sv) \
    $(wildcard $(RTL_ROOT)/frontend/bpu/target/*.sv) \
    $(wildcard $(RTL_ROOT)/frontend/ifu/*.sv) \
    $(RTL_ROOT)/l2/l2_pkg.sv $(RTL_ROOT)/l2/l2_top.sv \
    $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/memory/*.sv) \
    $(RTL_ROOT)/top/ares_core_top.sv $(RTL_ROOT)/top/ares_frontend_l2_top.sv

unit-coremark: config-gen
	@test -n "$(DMEM)" || { echo "usage: make unit-coremark DMEM=<coremark_dmem.hex>"; exit 1; }
	@mkdir -p $(ARES_HOME)/sim/build/unit/tb_ares_coremark
	@verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	    -Wno-SIDEEFFECT -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL \
	    -Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -DCONFIG_SIMULATION $(ARES_CFG_INC) --top-module tb_ares_coremark \
	    --Mdir $(ARES_HOME)/sim/build/unit/tb_ares_coremark \
	    -o $(ARES_HOME)/sim/build/unit/tb_ares_coremark/tb_ares_coremark \
	    $(ARES_COREMARK_SRCS) $(RTL_ROOT)/top/test/tb_ares_coremark.sv
	@$(ARES_HOME)/sim/build/unit/tb_ares_coremark/tb_ares_coremark +DMEM=$(DMEM)

unit-l2: config-gen
	@set -e; for tb in $(ARES_L2_UNIT_TBS); do \
	  d=$(ARES_HOME)/sim/build/unit/$$tb; \
	  echo "[unit-l2] $$tb"; \
	  case $$tb in \
	    tb_l2)          tb_src=$(RTL_ROOT)/l2/test/tb_l2.sv ;; \
	    tb_two_core_l2) tb_src=$(RTL_ROOT)/top/test/tb_two_core_l2.sv ;; \
	    *) echo "unknown L2 TB $$tb"; exit 1 ;; \
	  esac; \
	  rm -rf $$d; mkdir -p $$d/ccache-tmp; \
	  CCACHE_TEMPDIR=$$d/ccache-tmp verilator --binary --timing -sv --assert \
	      -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-SIDEEFFECT -Wno-BLKSEQ \
	      -Wno-PINCONNECTEMPTY -DCONFIG_SIMULATION $(ARES_CFG_INC) \
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
	      -DCONFIG_SIMULATION $(ARES_CFG_INC) \
	      --top-module $$tb --Mdir $$d -o $$d/$$tb $(ARES_UNIT_SRCS); \
	  $$d/$$tb | tail -3; \
	done

unit-lsu: config-gen
	@set -e; for tb in $(ARES_LSU_UNIT_TBS); do \
	  d=$(ARES_HOME)/sim/build/unit/$$tb; \
	  echo "[unit-lsu] $$tb"; \
	  rm -rf $$d; mkdir -p $$d/ccache-tmp; \
	  CCACHE_TEMPDIR=$$d/ccache-tmp verilator --binary --timing -sv --assert \
	      -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-SIDEEFFECT -Wno-BLKSEQ \
	      -DCONFIG_SIMULATION $(ARES_CFG_INC) \
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
