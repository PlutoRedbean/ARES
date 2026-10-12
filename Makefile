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
#   make all            lint + both unit tests (the C0 gate)
#   make sim            build the default ARES top (tb_ares_core)
#   make run PROGRAM=<image.bin>    run one image
#   make wave PROGRAM=<image.bin>   same, with an FST waveform
#   make isa            cpu-tests ISA regression (needs the riscv toolchain)
#   make lint-npc       lint the legacy npc/Mundus DUT (default sim flow)
#
# See docs/c0_decisions.md (C0 decisions + verification evidence) and
# docs/core_verification_flow.md (test strategy).
#=============================================================================
ARES_HOME := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
RTL_ROOT  ?= $(ARES_HOME)/rtl
SIM       := $(MAKE) -s -C $(ARES_HOME)/sim ARES_RTL=1 RTL_ROOT=$(RTL_ROOT)
KCONFIG   := python3 $(ARES_HOME)/scripts/kconfig/ares_kconfig.py

PROGRAM ?=

.PHONY: all lint lint-all tb-ares-pkg tb-fe-stub tb-mem-model sim run wave isa \
        lint-npc clean menuconfig defconfig oldconfig savedefconfig loaddefconfig \
        showconfig test-config

all: lint tb-ares-pkg tb-fe-stub tb-mem-model

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

lint-npc:
	@$(MAKE) -s -C $(ARES_HOME)/sim lint

clean:
	@$(MAKE) -s -C $(ARES_HOME)/sim clean
