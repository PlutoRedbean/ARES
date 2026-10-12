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
# Variables:
#   RTL_ROOT   directory holding the DUT RTL      (default $(NPC_HOME)/vsrc)
#   NPC_HOME   npc project directory              (default ysyx-workbench/npc)
#   TOPNAME    Verilator top module               (default tb_mundus_npc)
#   PROGRAM    test image to run
#   ARGS       extra simulator arguments
#=============================================================================

SIM_HOME  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ARES_HOME ?= $(abspath $(SIM_HOME)/..)

#-----------------------------------------------------------------------------
# Temporary DUT: the npc (Mundus) RTL from ysyx-workbench
#-----------------------------------------------------------------------------
NPC_HOME  ?= /home/redbean/ysyx-workbench/npc
RTL_ROOT  ?= $(NPC_HOME)/vsrc

VERILATOR ?= verilator

TOPNAME   ?= tb_mundus_npc
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

BUILD_DIR := $(SIM_HOME)/build$(BUILD_TAG)
OBJ_DIR   := $(BUILD_DIR)/obj_dir
BIN       := $(BUILD_DIR)/ares-sim

#-----------------------------------------------------------------------------
# RTL sources
#-----------------------------------------------------------------------------
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

VERILATOR_IGNORE := -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                    -Wno-UNDRIVEN -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC \
                    -Wno-CASEINCOMPLETE -Wno-SYNCASYNCNET -Wno-TIMESCALEMOD \
                    -Wno-PINMISSING -Wno-VARHIDDEN

VERILATOR_FLAGS := $(VERILATOR_IGNORE) \
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
# flow expects it.
ifeq ($(wildcard $(RTL_ROOT)/include/common_para.vh),)
  $(error RTL_ROOT ("$(RTL_ROOT)") does not look like the npc vsrc tree; \
          set RTL_ROOT to the directory holding include/common_para.vh)
endif

.PHONY: all run wave lint clean help gen-rtl

all: $(BIN)

$(BIN): $(VSRCS) $(CXX_SRCS) $(wildcard $(CXX_INC)/*.h)
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
	$(VERILATOR) --lint-only $(VERILATOR_IGNORE) $(V_DEF_MACRO) \
		$(addprefix -I, $(V_INC_PATH)) --top-module $(TOPNAME) $(VSRCS)

clean:
	rm -rf $(SIM_HOME)/build $(SIM_HOME)/build_wave waveform.fst

help:
	@sed -n '2,20p' $(SIM_HOME)/Makefile

# Re-elaborate the Chisel RTL with the simulation configuration and refresh
# rtl/generated/Mundus.sv (requires mill and the npc project).
gen-rtl:
	@$(SIM_HOME)/scripts/gen_mundus.sh
