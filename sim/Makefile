#=============================================================================
# ARES - RTL simulation (Verilator)
#-----------------------------------------------------------------------------
# Ported from ysyx-workbench/npc/Makefile.  This is the ARES owned simulation
# flow: it builds a Verilator model of the RTL selected by RTL_ROOT (for now
# the npc / Mundus RTL from ysyx-workbench) together with the ARES test bench
# and the DPI-C memory model in csrc/.
#
#   make            build the simulation binary
#   make run PROGRAM=<image.bin>   run one image
#   make wave PROGRAM=<image.bin>  same, with an FST waveform
#   make lint       lint the RTL only
#   make gen-rtl    re-elaborate the Chisel RTL (needs mill + the npc project)
#   make clean
#
#   ARES_RTL=1 selects the ARES core RTL in this repository (rtl/) instead of
#   the temporary npc DUT; the top module then defaults to tb_ares_core.
#
# Variables:
#   ARES_RTL   build the ARES core RTL                 (default 0 = npc DUT)
#   RTL_ROOT   directory holding the DUT RTL      (default $(NPC_HOME)/vsrc)
#   NPC_HOME   npc project directory              (default ysyx-workbench/npc)
#   TOPNAME    Verilator top module               (default tb_mundus_npc)
#   PROGRAM    test image to run
#   ARGS       extra simulator arguments
#
# ARES quick start (see docs/core_verification_flow.md section 4):
#   make menuconfig                    # MUL_LATENCY / LINE_BYTES (configs/Kconfig)
#   make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl                       # build
#   make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl lint                  # lint only
#   make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl tb-fe-stub            # unit TB
#   make -C sim ARES_RTL=1 RTL_ROOT=$(pwd)/rtl run \
#        PROGRAM=tests/cpu-tests/build/add-riscv32-ares.bin
#=============================================================================

SIM_HOME  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ARES_HOME ?= $(abspath $(SIM_HOME)/..)

#-----------------------------------------------------------------------------
# DUT selection
#-----------------------------------------------------------------------------
NPC_HOME  ?= /home/redbean/ysyx-workbench/npc

ifeq ($(ARES_RTL),1)
  RTL_ROOT ?= $(ARES_HOME)/rtl
  TOPNAME  ?= tb_ares_core
else
  RTL_ROOT ?= $(NPC_HOME)/vsrc
  TOPNAME  ?= tb_mundus_npc
endif

VERILATOR ?= verilator

PROGRAM   ?=
ARGS      ?=
MODE      ?= batch
MAX_CYCLES ?= 20000000

ifeq ($(MODE),wave)
  BUILD_TAG  := _wave
  V_MODE_DEF := -DWAVE
  V_MODE_OPT := --trace-fst
else
  BUILD_TAG  :=
  V_MODE_DEF :=
  V_MODE_OPT :=
endif

# One build directory per top module: switching TOPNAME never reuses a stale
# binary (the ARES unit test benches share this Makefile).
BUILD_DIR := $(SIM_HOME)/build$(BUILD_TAG)/$(TOPNAME)
OBJ_DIR   := $(BUILD_DIR)/obj_dir
BIN       := $(BUILD_DIR)/ares-sim

#-----------------------------------------------------------------------------
# RTL sources
#-----------------------------------------------------------------------------
ifeq ($(ARES_RTL),1)
  # ares_pkg.sv must be listed before every module that imports it.
  ARES_PKG  := $(RTL_ROOT)/common/ares_pkg.sv
  ARES_TBS  := $(SIM_HOME)/rtl/tb_ares_core.sv \
               $(SIM_HOME)/rtl/tb_mem_beat_if.sv \
               $(SIM_HOME)/rtl/tb_mmio_if.sv

  VSRCS  := $(ARES_PKG)
  VSRCS  += $(filter-out $(ARES_PKG), $(wildcard $(RTL_ROOT)/common/*.sv))
  VSRCS  += $(wildcard $(RTL_ROOT)/common/*/*.sv)
  VSRCS  += $(wildcard $(RTL_ROOT)/backend/*.sv) $(wildcard $(RTL_ROOT)/backend/*/*.sv)
  VSRCS  += $(wildcard $(RTL_ROOT)/memory/*.sv)  $(wildcard $(RTL_ROOT)/memory/*/*.sv)
  VSRCS  += $(ARES_TBS)

  # Self-checking unit tops (docs/implementation_plan.md section 9.2).
  ARES_UNIT_TOPS  := tb_ares_core tb_ares_pkg tb_fe_stub tb_mem_model
  ARES_UNIT_IMAGE ?= $(ARES_HOME)/tests/cpu-tests/build/add-riscv32-ares.bin

  # ---- core configuration ("make menuconfig") ------------------------------
  # configs/build/.config drives both the Verilator -D defines and the
  # generated SV header configs/build/vsrc/include/ares_autoconf.vh.
  ARES_CFG_SCRIPT := $(ARES_HOME)/scripts/kconfig/ares_kconfig.py
  ARES_CFG_DIR    := $(ARES_HOME)/configs/build
  ARES_CFG_VH     := $(ARES_CFG_DIR)/vsrc/include/ares_autoconf.vh
  ARES_CFG_DEPS   := $(ARES_CFG_VH)
  ARES_CFG_DEFS   := $(shell python3 $(ARES_CFG_SCRIPT) defs 2>/dev/null)

  V_INC_PATH := $(SIM_HOME)/config
  V_DEF_MACRO := -D__VERILATOR__ -DCONFIG_SIMULATION $(ARES_CFG_DEFS)
  V_ASSERT := --assert
  VERILATOR_IGNORE := -Wno-DECLFILENAME -Wno-TIMESCALEMOD
  VERILATOR_WARN := -Wall
else
  VSRCS  := $(SIM_HOME)/rtl/tb_mundus_npc.sv
  VSRCS  += $(SIM_HOME)/rtl/generated/Mundus.sv
  VSRCS  += $(wildcard $(RTL_ROOT)/Mundus/*.v)
  VSRCS  += $(wildcard $(RTL_ROOT)/DPIC/*.v)
  VSRCS  += $(wildcard $(RTL_ROOT)/testbench/IP/*.v)
  VSRCS  += $(wildcard $(RTL_ROOT)/testbench/IP/*.sv)
  VSRCS  += $(wildcard $(RTL_ROOT)/modules/*.v)

  V_INC_PATH := $(SIM_HOME)/config $(RTL_ROOT)/include

  # CORE_ENTRY seeds the reset PC of the fetch unit (see Mundus/Mundus_PC.v).
  # Keep it in step with CONFIG_NPC_ENTRY in sim/config/autoconf.vh.
  V_DEF_MACRO := -D__VERILATOR__ -DCONFIG_SIMULATION -DCORE_ENTRY=32\'h80000000

  V_ASSERT :=
  ARES_CFG_DEPS :=
  VERILATOR_IGNORE := -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                      -Wno-UNDRIVEN -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC \
                      -Wno-CASEINCOMPLETE -Wno-SYNCASYNCNET -Wno-TIMESCALEMOD \
                      -Wno-PINMISSING -Wno-VARHIDDEN
  VERILATOR_WARN :=
endif

VERILATOR_FLAGS := $(VERILATOR_IGNORE) $(VERILATOR_WARN) $(V_ASSERT) \
                   --timescale "1ns/1ns" --no-timing \
                   --autoflush --x-assign unique --x-initial unique \
                   --build -cc -j 8 \
                   $(V_MODE_OPT) $(V_DEF_MACRO) \
                   $(addprefix -I, $(V_INC_PATH))

#-----------------------------------------------------------------------------
# C++ sources
#-----------------------------------------------------------------------------
CXX_SRCS := $(wildcard $(SIM_HOME)/csrc/*.cpp)
CXX_INC  := $(SIM_HOME)/csrc/include

# The Verilator model header name and the top module string are emitted into
# a generated header (see the $(BIN) recipe) instead of being passed with -D,
# which keeps the quoting correct through make -> shell -> verilator -> make.
TOP_HEADER := $(BUILD_DIR)/verilator_top.h
C_DEF_MACRO := $(V_MODE_DEF)

CXXFLAGS := -O2 -std=c++17 -Wall -Wno-unused-variable -Wno-unused-parameter \
            -I$(CXX_INC) -I$(BUILD_DIR) $(C_DEF_MACRO)

# ccache (when the toolchain is wrapped with it) defaults to a temporary
# directory outside the workspace, which the DSH sandbox refuses to write.
# Keep the compiler temporaries inside the build directory instead.
export CCACHE_TEMPDIR := $(BUILD_DIR)/ccache-tmp

#-----------------------------------------------------------------------------
# Targets
#-----------------------------------------------------------------------------
# Fail early with a useful message when the temporary DUT is not where the
# flow expects it.  The ARES core RTL lives in this repository and does not
# have the npc include tree.
ifneq ($(ARES_RTL),1)
ifeq ($(wildcard $(RTL_ROOT)/include/common_para.vh),)
  $(error RTL_ROOT ("$(RTL_ROOT)") does not look like the npc vsrc tree; \
          set RTL_ROOT to the directory holding include/common_para.vh)
endif
endif

.PHONY: all run wave lint lint-all clean help gen-rtl check-unit-image \
        tb-ares-pkg tb-fe-stub tb-mem-model

all: $(BIN)

ifeq ($(ARES_RTL),1)
# Refresh the generated configuration header (and create .config with the
# defaults on a first build) whenever the menu, the tool or .config changes.
$(ARES_CFG_VH): $(ARES_CFG_SCRIPT) $(wildcard $(ARES_HOME)/configs/Kconfig) \
                $(wildcard $(ARES_CFG_DIR)/.config)
	@python3 $(ARES_CFG_SCRIPT) gen
endif

$(BIN): $(VSRCS) $(CXX_SRCS) $(wildcard $(CXX_INC)/*.h) $(ARES_CFG_DEPS)
	@mkdir -p $(BUILD_DIR) $(BUILD_DIR)/ccache-tmp
	@printf '#define TOP_NAME V%s\n#define TOP_STR "%s"\n#include "V%s.h"\n' \
		'$(TOPNAME)' '$(TOPNAME)' '$(TOPNAME)' > $(TOP_HEADER)
	@echo "[verilator] building $(TOPNAME) ($(MODE))"
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TOPNAME) $(VSRCS) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) \
		$(addprefix -CFLAGS , -I$(OBJ_DIR)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN)) $(CXX_SRCS)

run: $(BIN)
	@$(BIN) +verilator+rand+reset+0 --max-cycles=$(MAX_CYCLES) $(ARGS) $(PROGRAM)

wave:
	@$(MAKE) MODE=wave run PROGRAM=$(PROGRAM) \
		ARGS="$(ARGS) --wave=$(SIM_HOME)/build_wave/waveform.fst"

lint:
	$(VERILATOR) --lint-only $(VERILATOR_IGNORE) $(VERILATOR_WARN) $(V_ASSERT) \
		$(V_DEF_MACRO) $(addprefix -I, $(V_INC_PATH)) \
		--top-module $(TOPNAME) $(VSRCS)

# Lint every ARES top module (C0 exit gate: zero warnings).
lint-all:
	@rc=0; \
	for top in $(ARES_UNIT_TOPS); do \
	  echo "[lint] $$top"; \
	  $(VERILATOR) --lint-only $(VERILATOR_IGNORE) $(VERILATOR_WARN) $(V_ASSERT) \
	      $(V_DEF_MACRO) $(addprefix -I, $(V_INC_PATH)) \
	      --top-module $$top $(VSRCS) || rc=1; \
	done; \
	exit $$rc

#-----------------------------------------------------------------------------
# ARES unit test benches (self-checking; they end with ebreak(), so the normal
# harness reports HIT GOOD TRAP).  The image only has to exist: tb_fe_stub reads
# the same words back through the DPI model, tb_mem_model never fetches.
#-----------------------------------------------------------------------------
check-unit-image:
	@test -f "$(ARES_UNIT_IMAGE)" || { \
	  echo "missing ARES_UNIT_IMAGE: $(ARES_UNIT_IMAGE)"; \
	  echo "build one with: make -C tests/cpu-tests ARCH=riscv32-ares ALL=add"; \
	  exit 1; }

tb-ares-pkg: check-unit-image
	@$(MAKE) --no-print-directory TOPNAME=tb_ares_pkg all
	@echo "[run] tb_ares_pkg"
	@$(SIM_HOME)/build$(BUILD_TAG)/tb_ares_pkg/ares-sim \
		+verilator+rand+reset+0 --max-cycles=$(MAX_CYCLES) $(ARES_UNIT_IMAGE)

tb-fe-stub: check-unit-image
	@$(MAKE) --no-print-directory TOPNAME=tb_fe_stub all
	@echo "[run] tb_fe_stub"
	@$(SIM_HOME)/build$(BUILD_TAG)/tb_fe_stub/ares-sim \
		+verilator+rand+reset+0 --max-cycles=$(MAX_CYCLES) $(ARES_UNIT_IMAGE)

tb-mem-model: check-unit-image
	@$(MAKE) --no-print-directory TOPNAME=tb_mem_model all
	@echo "[run] tb_mem_model"
	@$(SIM_HOME)/build$(BUILD_TAG)/tb_mem_model/ares-sim \
		+verilator+rand+reset+0 --max-cycles=$(MAX_CYCLES) $(ARES_UNIT_IMAGE)

clean:
	rm -rf $(SIM_HOME)/build $(SIM_HOME)/build_wave waveform.fst

help:
	@sed -n '2,20p' $(SIM_HOME)/Makefile

# Re-elaborate the Chisel RTL with the simulation configuration and refresh
# rtl/generated/Mundus.sv (requires mill and the npc project).
gen-rtl:
	@$(SIM_HOME)/scripts/gen_mundus.sh
