include $(MUNDUS_HOME)/common.mk
# Makefile for RTL and simulation

## 0. functions
remove_quote  = $(patsubst "%",%,$(1))
log2          = $(shell awk 'BEGIN {printf "%d", log($(1))/log(2)}')
COLOR_RED    := $(shell echo "\033[1;31m")
COLOR_END    := $(shell echo "\033[0m")

## 1. Basic Setup

### include rules for menuconfig
include $(NPC_HOME)/scripts/config.mk
-include $(DOT_CONFIG)

### platform
VERILATOR = verilator
LINTER    = slang
MILL      = $(NPC_HOME)/mill

### RTL top-module name
ifeq ($(PLATFORM),soc)
	TOPNAME = ysyxSoCFull
else ifeq ($(PLATFORM),npc)
	TOPNAME = MundusNpc
else ifeq ($(PLATFORM),jyd)
	TOPNAME = MundusJyd
endif
TOP_MODULE = $(TOPNAME).v

### Python setup
PYSRC_DIR  := $(NPC_HOME)/tools/pysrc
REQ_TXT    := $(PYSRC_DIR)/requirements.txt
VENV_DIR   := $(PYSRC_DIR)/.venv
PYTHON     := $(VENV_DIR)/bin/python
PIP        := $(VENV_DIR)/bin/pip
VENV_TOUCH := $(VENV_DIR)/.installed # Sentinel file

### varilator ignore warning and error
VERILATOR_ERROR  = -Werror-WIDTHTRUNC
VERILATOR_IGNORE = -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
                   -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-MULTIDRIVEN

### output
BUILD_DIR        = ./build
CHISEL_BUILD_DIR = $(NPC_HOME)/vsrc/build
OBJ_DIR          = $(BUILD_DIR)/obj_dir
BIN              = $(BUILD_DIR)/$(TOPNAME)
WAVEFORM         = waveform.fst

### make arguments
MODES     := batch sdb wave nvboard
MODE      ?= batch
ARGS      ?=

### cachesim project path
CACHESIM_PATH = $(NPC_HOME)/tools/cachesim

### nvboard varibles
NXDC_FILES = constr/top.nxdc
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

### simulation MODE check
ifeq ($(filter $(MODES), $(MODE)), )
  $(error $(COLOR_RED)Expected $$MODE in {$(MODES)}, Got "$(MODE)"$(COLOR_END))
endif

## 2. libary import

### libaries
LIBCAPSTONE := $(NPC_HOME)/tools/capstone/repo/libcapstone.so.5
LIBNEMU     := $(NEMU_HOME)/build/riscv32-nemu-interpreter-so

## 3. C/verilog macros define

### verilog Mundus macros
V_DEF_MACRO := -D__VERILATOR__
V_DEF_MACRO += -DCORE_FREQ=$(if $(CONFIG_CORE_FREQ),$(call remove_quote,$(CONFIG_CORE_FREQ)),500.000)
ifneq ($(filter 1 y yes true,$(JYD_FAST_TIMER)),)
	V_DEF_MACRO += -DJYD_FAST_TIMER
endif
ifeq ($(PLATFORM),soc)
	V_DEF_MACRO += -DCORE_ENTRY=\`CONFIG_SOC_ENTRY
else ifeq ($(PLATFORM),npc)
	V_DEF_MACRO += -DCORE_ENTRY=\`CONFIG_NPC_ENTRY
else ifeq ($(PLATFORM),jyd)
	V_DEF_MACRO += -DCORE_ENTRY=\'h80000000
endif

### C simulation macros
C_DEF_MACRO := -DTOP_NAME="V$(TOPNAME)" \
			   -DVERILATOR_H="\\\"V$(TOPNAME).h\\\"" \
			   -DVERILATOR__DPI_H="\\\"V$(TOPNAME)__Dpi.h\\\"" \
			   -DPROGRAM="\\\"$(PROGRAM)\\\"" \
			   -D__GUEST_ISA__=$(ISA)
C_DEF_MACRO += -DCORE_FREQ=$(if $(CONFIG_CORE_FREQ),$(call remove_quote,$(CONFIG_CORE_FREQ)),500.000)
C_DEF_MACRO += -DITRACE_COND=$(if $(CONFIG_ITRACE_COND),$(call remove_quote,$(CONFIG_ITRACE_COND)),true)
C_DEF_MACRO += -DMTRACE_COND=$(if $(CONFIG_MTRACE_COND),$(call remove_quote,$(CONFIG_MTRACE_COND)),true)
C_DEF_MACRO += -DDTRACE_COND=$(if $(CONFIG_DTRACE_COND),$(call remove_quote,$(CONFIG_DTRACE_COND)),true)
C_DEF_MACRO += -DPTRACE_COND=$(if $(CONFIG_PTRACE_COND),$(call remove_quote,$(CONFIG_PTRACE_COND)),true)
C_DEF_MACRO += -DITRACE_SIZE=$(if $(CONFIG_ITRACE_SIZE),$(call remove_quote,$(CONFIG_ITRACE_SIZE)),1)
C_DEF_MACRO += -DMTRACE_SIZE=$(if $(CONFIG_MTRACE_SIZE),$(call remove_quote,$(CONFIG_MTRACE_SIZE)),1)
C_DEF_MACRO += -DDTRACE_SIZE=$(if $(CONFIG_DTRACE_SIZE),$(call remove_quote,$(CONFIG_DTRACE_SIZE)),1)
C_DEF_MACRO += -DPTRACE_SIZE=$(if $(CONFIG_PTRACE_SIZE),$(call remove_quote,$(CONFIG_PTRACE_SIZE)),1)
ifeq ($(MODE),wave)
	C_DEF_MACRO += -DWAVE
else ifeq ($(MODE),batch)
	C_DEF_MACRO += -DBATCH
else ifeq ($(MODE),sdb)
	C_DEF_MACRO += -DSDB
else ifeq ($(MODE),nvboard)
	C_DEF_MACRO += -DBATCH
	C_DEF_MACRO += -DHAS_NVBOARD
endif
ifeq ($(PLATFORM),soc)
	C_DEF_MACRO += -DIS_SOC
	C_DEF_MACRO += -DCORE_ENTRY=CONFIG_SOC_ENTRY
else ifeq ($(PLATFORM),npc)
	C_DEF_MACRO += -DIS_NPC
	C_DEF_MACRO += -DCORE_ENTRY=CONFIG_NPC_ENTRY
else ifeq ($(PLATFORM),jyd)
	C_DEF_MACRO += -DIS_JYD
	C_DEF_MACRO += -DCORE_ENTRY=0x80000000
endif

## 4. include Path

### verilog include
V_INC_PATH ?= $(NPC_HOME)/vsrc/include \
			  $(NPC_HOME)/configs/build/vsrc/include \
			  $(SOC_HOME)/perip/uart16550/rtl \
			  $(SOC_HOME)/perip/spi/rtl

### C include
C_INC_PATH ?= $(NPC_HOME)/csrc/include \
			  $(C_AUTOGEN_DIR)
C_INC_PATH += $(NPC_HOME)/tools/capstone/repo/include
ifeq ($(MODE),nvboard)
	C_INC_PATH += $(NVBOARD_HOME)/usr/include
endif

## 5. sources Path
SCALA_SRCS_DIR   := $(NPC_HOME)/scsrc
MUNDUS_VSRC_DIR  := $(NPC_HOME)/vsrc
SOC_PERIP_DIR    := $(SOC_HOME)/perip
SOC_BUILD_DIR    := $(SOC_HOME)/build
MUNDUS_SIM_C_DIR := $(NPC_HOME)/csrc

### miniTensor accelerator (see miniTensor/integration/README.md)
MT_HOME ?= $(MUNDUS_HOME)/miniTensor
MT_SRCS := \
	$(MT_HOME)/rtl/interface/core_v_xif.sv \
	$(MT_HOME)/rtl/common/minitensor_pkg.sv \
	$(MT_HOME)/rtl/tensor/tensor_pkg.sv \
	$(MT_HOME)/rtl/vector/vpu_pkg.sv \
	$(MT_HOME)/rtl/vector/vpu_vector_regfile.sv \
	$(MT_HOME)/rtl/vector/vpu_vector_alu.sv \
	$(MT_HOME)/rtl/control/vpu_vector_controller.sv \
	$(MT_HOME)/rtl/tensor/MXU/Systolic_Array/tensor_pe.sv \
	$(MT_HOME)/rtl/tensor/MXU/Systolic_Array/tensor_systolic_array.sv \
	$(MT_HOME)/rtl/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv \
	$(MT_HOME)/rtl/tensor/tensor_controller.sv \
	$(MT_HOME)/rtl/tensor/Epilogue/tensor_epilogue_core.sv \
	$(MT_HOME)/rtl/tensor/Epilogue/tensor_epilogue_controller.sv \
	$(MT_HOME)/rtl/memory/unified_buffer.sv \
	$(MT_HOME)/rtl/memory/vpu_dma.sv \
	$(MT_HOME)/rtl/top/mini_tensor_top.sv \
	$(MT_HOME)/integration/npc/mt_cvxif_shim.sv \
	$(MT_HOME)/integration/npc/mt_dma_bridge.sv

### Chisel src
SCALA_SRCS  = $(shell find $(abspath $(SCALA_SRCS_DIR)) -name "*.scala")
SCALA_SRCS += $(shell find $(abspath $(SCALA_AUTOGEN_DIR)) -name "*.scala")

### Mundus RTL src
CORE_SRCS         := $(shell find $(abspath $(MUNDUS_VSRC_DIR)/Mundus) -name "*.v")
DPIC_SRCS         := $(shell find $(abspath $(MUNDUS_VSRC_DIR)/DPIC) -name "*.v")
IP_SRCS           := $(shell find $(abspath $(MUNDUS_VSRC_DIR)/testbench/IP) -name "*.v")
IP_SRCS           += $(shell find $(abspath $(MUNDUS_VSRC_DIR)/testbench/IP) -name "*.sv")
CHISEL_GEN_SRCS   := $(CHISEL_BUILD_DIR)/Mundus.sv
CHISEL_FINAL_SRCS := $(CHISEL_BUILD_DIR)/Mundus.v
TB_SRCS           ?= 
ifeq ($(PLATFORM),npc)
	TB_SRCS  += $(MUNDUS_VSRC_DIR)/testbench/MundusNpc.v
else ifeq ($(PLATFORM),jyd)
	TB_SRCS  += $(MUNDUS_VSRC_DIR)/testbench/MundusJyd.v
	TB_SRCS  += $(MUNDUS_VSRC_DIR)/testbench/jyd/*.sv
endif
ifeq ($(PLATFORM),jyd)
	MT_ACTIVE_SRCS := $(MT_SRCS)
endif

### SoC RTL src
SOC_SRCS   := $(shell find $(abspath $(SOC_PERIP_DIR)) -name "*.v")
SOC_SRCS   += $(shell find $(abspath $(SOC_BUILD_DIR)) -name "*.v")

### Verilator input src
VSRCS      := $(CORE_SRCS) $(DPIC_SRCS) $(IP_SRCS) $(CHISEL_GEN_SRCS)
ifeq ($(PLATFORM),soc)
	VSRCS  += $(SOC_SRCS)
else ifeq ($(PLATFORM),npc)
	VSRCS  += $(TB_SRCS)
else ifeq ($(PLATFORM),jyd)
	VSRCS  += $(TB_SRCS)
	VSRCS  += $(MT_ACTIVE_SRCS)
endif

### simulation C src
WAVE_CSRCS := $(shell find $(abspath $(MUNDUS_SIM_C_DIR)/wave) -name "*.c" -or -name "*.cc" -or -name "*.cpp")

### nvboard C src
NV_CSRCS   := $(SRC_AUTO_BIND)
ifeq ($(MODE),nvboard)
	WAVE_CSRCS += $(NV_CSRCS)
endif

### Python src
PLOT_PY    := $(NPC_HOME)/tools/pysrc/mtrace_plot.py

## 6. flags define

### libaries flags
LDFLAGS     += $(LIBCAPSTONE)
LDFLAGS     += -lreadline
ifeq ($(CONFIG_DIFFTEST),y)
	LDFLAGS += $(LIBNEMU)
endif
ifeq ($(MODE),nvboard)
	LDFLAGS += $(NVBOARD_ARCHIVE)
endif

### include flags
V_INCFLAGS   = $(addprefix +incdir+, $(V_INC_PATH))
CXX_INCFLAGS = $(addprefix -I, $(C_INC_PATH))

### verilator flags
VERILATOR_FLAGS := $(VERILATOR_IGNORE) --timescale "1ns/1ns" --no-timing \
                   --autoflush --x-assign unique --x-initial unique --build -cc -j 8
VERILATOR_FLAGS += $(V_DEF_MACRO)
VERILATOR_FLAGS += $(V_INCFLAGS)

### cpp flags (for verilator)
CXXFLAGS += -Wall $(CXX_INCFLAGS) $(C_DEF_MACRO)

# The wave simulator's VGA device (csrc/wave/device/vga.c) uses SDL.  Those
# flags used to arrive via nvboard's scripts/nvboard.mk, which made an
# un-initialised nvboard a hidden build dependency.  Request them directly so
# the Verilator platforms build with or without nvboard.
CXXFLAGS += $(shell sdl2-config --cflags 2>/dev/null)
LDFLAGS  += $(shell sdl2-config --libs 2>/dev/null) -lSDL2_image -lSDL2_ttf

### Verilator reset value mode: 0 = zeros, 1 = ones, 2 = random.
### The JYD platform currently needs 0: with the random reset some state that the
### reset does not clear settles into a value that wedges the frontend after
### fetch, so no instruction ever issues.  Mode 1 also hangs; mode 0 boots.
VERILATOR_RESET ?= 2

## 7. targets

### default
all:
	@echo "Write this Makefile by your self."

### build dir
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

### chisel build
verilog: $(CHISEL_GEN_SRCS)
$(CHISEL_GEN_SRCS): $(SCALA_SRCS)
	@rm -rf $(CHISEL_GEN_SRCS)
	@mill -i Mundus.runMain npc.Elaborate \
	      --target-dir $(CHISEL_BUILD_DIR)
	@sed -i 's/\bram_\([0-9]\+x[0-9]\+\)\b/ysyx_25050158_ram_\1/g' $(CHISEL_GEN_SRCS)

### capstone build
$(LIBCAPSTONE):
	$(MAKE) -C tools/capstone

# nvboard is only used by MODE=nvboard (physical-board pin binding and the
# verilator-nvboard glue).  The JYD/Verilator flow does not need it, so the
# include is conditional: an absent or un-initialised nvboard is not an error.
ifneq ($(wildcard $(NVBOARD_HOME)/scripts/nvboard.mk),)
include $(NVBOARD_HOME)/scripts/nvboard.mk
endif

### main simulation for platform.mk
$(CHISEL_BUILD_DIR):
	mkdir -p $(CHISEL_BUILD_DIR)

ifeq ($(MODE),wave)
wave: VERILATOR_FLAGS += --trace-fst
endif
wave: $(BUILD_DIR) $(CHISEL_BUILD_DIR) $(VSRCS) \
      $(NVBOARD_ARCHIVE) $(WAVE_CSRCS) $(LIBCAPSTONE)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@rm -rf $(OBJ_DIR) $(WAVEFORM)
	@$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TOPNAME) $(VSRCS) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(WAVE_CSRCS) \
		$(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))
	@$(abspath $(BIN)) +verilator+rand+reset+$(VERILATOR_RESET) $(ARGS)
ifeq ($(MODE),wave)
	@gtkwave $(WAVEFORM) $(NPC_HOME)/signals.gtkw
endif

# 核心目标：生成图表
# 依赖：CSV文件, 脚本本身, 以及虚拟环境标记文件
plot: $(PLOT_PY) $(VENV_TOUCH)
	@echo "[INFO] Processing mtrace data..."
	$(PYTHON) $(PLOT_PY) -i $(BUILD_DIR)/mtrace.csv -o $(BUILD_DIR)
	@echo "[INFO] Done. Charts are in $(abspath $(BUILD_DIR))"

# 环境构建目标：自动创建 venv 并安装依赖
# 只有当 requirements.txt 发生变化或 .venv 不存在时才会触发
$(VENV_TOUCH): $(REQ_TXT)
	@echo "[INFO] Setting up Python virtual environment..."
	@test -d $(VENV_DIR) || python3 -m venv $(VENV_DIR)
	@echo "[INFO] Installing dependencies..."
	@$(PIP) install -U pip
	@$(PIP) install -r $(REQ_TXT)
	@touch $(VENV_TOUCH)

### show performance
perf:
	@echo TODO

cachesim:
	@$(MAKE) -s -C $(CACHESIM_PATH) run

### linter test
lint:
	@$(LINTER) $(VSRCS) -I $(NPC_HOME)/vsrc/include -I $(NPC_HOME)/vsrc/include -I $(NPC_HOME)/configs/build/vsrc/include

### clean build files
clean:
	rm -rf $(BUILD_DIR) $(CHISEL_BUILD_DIR) $(WAVEFORM)

.PHONY: wave verilog plot perf lint clean

-include $(YSYX_HOME)/Makefile
