SHELL := /bin/bash

MUNDUS_HOME ?= $(abspath ../../../..)
NPC_HOME    ?= $(MUNDUS_HOME)/npc
RTT_ROOT    ?= $(abspath ../..)
BSP_DIR     := $(CURDIR)
BSP_INC_DIR := $(BSP_DIR)/include
NPC_AUTOCONF := $(NPC_HOME)/configs/build/csrc/include/autoconf.h

# miniTensor integration sources (see miniTensor/integration/README.md).
# MT_COMPAT_DIR holds minimal freestanding libc headers: the riscv64-unknown-elf
# toolchain available on this machine ships without newlib.
MT_HOME       ?= $(MUNDUS_HOME)/miniTensor
MT_BSP_DIR    := $(MT_HOME)/integration/bsp
MT_COMPAT_DIR := $(MT_BSP_DIR)/compat

COREMARK_PORT_DIR   := $(BSP_DIR)/coremark
COREMARK_SCRIPTS_DIR := $(COREMARK_PORT_DIR)/scripts
# Vendored, pinned EEMBC main snapshot.  COREMARK_ROOT remains overridable so
# an external tree can still be tested without editing this Makefile.
COREMARK_ROOT       ?= $(COREMARK_PORT_DIR)/eembc
COREMARK_SRC_DIR    ?= $(COREMARK_ROOT)
COREMARK_INC_DIR    ?= $(COREMARK_ROOT)
COREMARK_ITERATIONS ?= 100
COREMARK_REPORT_MODE ?= 1
COREMARK_HW_CRC     ?= 1
COREMARK_HW_MATRIX  ?= 1
COREMARK_PROFILE    ?= 0
COREMARK_LIST_SCHEDULE ?= mundus
COREMARK_STATE_SCHEDULE ?= register-return-scheduled
# Equivalent strict control for the generated matrix translation unit.
COREMARK_MATRIX_LINK_BOUNDARY ?= $(COREMARK_HW_MATRIX)

ifeq ($(COREMARK_PROFILE),1)
ifneq ($(COREMARK_HW_CRC),1)
$(error COREMARK_PROFILE=1 currently requires COREMARK_HW_CRC=1)
endif
ifneq ($(COREMARK_HW_MATRIX),1)
$(error COREMARK_PROFILE=1 currently requires COREMARK_HW_MATRIX=1)
endif
endif

CROSS_COMPILE ?= /home/dragonflame/tools/riscv-gcc-16.1-rv32im/bin/riscv32-unknown-elf-

CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump
SIZE    := $(CROSS_COMPILE)size
PYTHON  ?= python3

BUILD_DIR ?= $(BSP_DIR)/build
OBJ_DIR   := $(BUILD_DIR)/obj
TARGET    := $(BUILD_DIR)/mundus-jyd-nano
ELF       := $(TARGET).elf
BIN       := $(TARGET).bin
IROM_BIN  := $(BUILD_DIR)/mundus-jyd-irom.bin
DRAM_BIN  := $(BUILD_DIR)/mundus-jyd-dram.bin
IROM_COE  := $(BUILD_DIR)/mundus-jyd-irom.coe
DRAM_COE  := $(BUILD_DIR)/mundus-jyd-dram.coe
MAP       := $(TARGET).map
DISASM    := $(TARGET).txt
COREMARK_RESULTS_DIR ?= $(BUILD_DIR)/coremark
LOG       ?= $(COREMARK_RESULTS_DIR)/npc-jyd.log
CONSOLE_LOG := $(BUILD_DIR)/console.log
COREMARK_REPORT ?= $(COREMARK_RESULTS_DIR)/coremark_report.txt
BRANCH_REPORT ?= $(COREMARK_RESULTS_DIR)/branch_difftest_report.txt
PIPELINE_REPORT ?= $(COREMARK_RESULTS_DIR)/pipeline_report.txt
MEMORY_REPORT ?= $(COREMARK_RESULTS_DIR)/memory_report.txt
LINKER_SCRIPT := $(BUILD_DIR)/linker.ld
NPC_CONFIG    := $(NPC_HOME)/configs/build/.config
IROM_PACKER   := $(NPC_HOME)/tools/pack_irom_coe.py
DRAM_PACKER   := $(NPC_HOME)/tools/pack_mem_coe.py
DRAM_CAPACITY_BYTES := 0x40000

ARCH_FLAGS := -march=rv32im_zicsr -mabi=ilp32
MUNDUS_TUNE_FLAGS ?=
LTO_FLAGS  := -flto

COMMON_FLAGS := $(ARCH_FLAGS) $(MUNDUS_TUNE_FLAGS) \
	-mcmodel=medany -mstrict-align \
	-ffreestanding -fno-builtin -fno-common \
	-fno-pic -fno-pie \
	-ffunction-sections -fdata-sections -MMD -MP \
	-I$(BSP_INC_DIR) -I$(MT_COMPAT_DIR) -I$(MT_BSP_DIR) \
	-I$(RTT_ROOT)/include \
	-I$(RTT_ROOT)/libcpu/risc-v/common \
	-I$(RTT_ROOT)/components/finsh \
	-DMUNDUS_JYD_COMPETITION \
	$(LTO_FLAGS) -g -Wall -Wextra

RTT_CFLAGS      := $(COMMON_FLAGS) -Os -std=c11
# GCC 16.1 A/B on the dual-issue core: split-paths increases dynamic work in
# CoreMark.  Aligning functions, branch targets, and loops to the core's
# 8-byte issue/fetch group improves frontend supply with modest code growth.
# Keep matrix-only loop unrolling and variable expansion, but explicitly
# disable register renaming: -funroll-loops enables it implicitly and its
# changed assignment slightly worsens pairing.
COREMARK_OPT_FLAGS ?= -O3 -fno-split-paths \
	-falign-functions=8 -falign-jumps=8 -falign-loops=8
COREMARK_MATRIX_EXTRA_CFLAGS ?= \
	-funroll-loops -fvariable-expansion-in-unroller -fno-rename-registers
COREMARK_CFLAGS := $(COMMON_FLAGS) $(COREMARK_OPT_FLAGS) -std=c11
COREMARK_INCLUDES := -I$(COREMARK_INC_DIR) -I$(COREMARK_PORT_DIR)
COREMARK_DEFINES := \
	-DCOREMARK_ITERATIONS=$(COREMARK_ITERATIONS) \
	-DCOREMARK_REPORT_MODE=$(COREMARK_REPORT_MODE) \
	-DCOREMARK_HW_CRC=$(COREMARK_HW_CRC) \
	-DCOREMARK_HW_MATRIX=$(COREMARK_HW_MATRIX)
ASFLAGS         := $(COMMON_FLAGS) -Os
LDFLAGS         := $(ARCH_FLAGS) $(MUNDUS_TUNE_FLAGS) $(LTO_FLAGS) \
	-nostdlib -nostartfiles -static \
	-Wl,-T,$(LINKER_SCRIPT) \
	-Wl,-Map,$(MAP) \
	-Wl,--gc-sections \
	-Wl,--build-id=none

KERNEL_C_SRCS := \
	$(RTT_ROOT)/src/clock.c \
	$(RTT_ROOT)/src/components.c \
	$(RTT_ROOT)/src/cpu.c \
	$(RTT_ROOT)/src/idle.c \
	$(RTT_ROOT)/src/ipc.c \
	$(RTT_ROOT)/src/irq.c \
	$(RTT_ROOT)/src/kservice.c \
	$(RTT_ROOT)/src/object.c \
	$(RTT_ROOT)/src/scheduler.c \
	$(RTT_ROOT)/src/thread.c \
	$(RTT_ROOT)/src/timer.c \
	$(RTT_ROOT)/libcpu/risc-v/common/cpuport.c

# CoreMark and the miniTensor drivers no longer fit together in the 32 KiB IROM
# with this toolchain, so the benchmark can be dropped when the image only needs
# to exercise the accelerator.
MT_WITH_COREMARK ?= 1

ifeq ($(MT_WITH_COREMARK),1)
APP_ENTRY_SRC      := $(COREMARK_PORT_DIR)/competition_app.c
COREMARK_PORT_SRCS := $(COREMARK_PORT_DIR)/coremark_portme.c
COREMARK_C_SRCS    := \
	$(COREMARK_SRC_DIR)/core_list_join.c \
	$(COREMARK_SRC_DIR)/core_matrix.c \
	$(COREMARK_SRC_DIR)/core_state.c \
	$(COREMARK_SRC_DIR)/core_util.c \
	$(COREMARK_SRC_DIR)/core_main.c
COREMARK_PORT_OBJ  := $(OBJ_DIR)/coremark_portme.o
else
APP_ENTRY_SRC      := $(MT_BSP_DIR)/mt_main.c
COREMARK_PORT_SRCS :=
COREMARK_C_SRCS    :=
COREMARK_PORT_OBJ  :=
endif

# miniTensor test/demo commands (mt.c, the driver, is always built).  The full
# set does not fit in the 32 KiB IROM together with CoreMark under this
# toolchain, so it is selectable:
#   make ... MT_WITH_COREMARK=1 MT_TESTS="" image                # CoreMark only
#   make ... MT_WITH_COREMARK=1 MT_TESTS="mt_app.c mt_conv.c" image
MT_TESTS ?= mt_app.c mt_conv.c mt_net.c mt_detect.c mt_wide.c mt_res.c \
            mt_yolocnn.c mt_yolomodel.c mt_yolo.c
MT_TEST_SRCS := $(addprefix $(MT_BSP_DIR)/, $(MT_TESTS))

BSP_C_SRCS := \
	$(BSP_DIR)/board.c \
	$(BSP_DIR)/console.c \
	$(APP_ENTRY_SRC) \
	$(COREMARK_PORT_DIR)/finsh_compat.c \
	$(MT_BSP_DIR)/mt.c \
	$(MT_TEST_SRCS) \
	$(RTT_ROOT)/components/finsh/shell.c \
	$(RTT_ROOT)/components/finsh/msh.c

ifeq ($(MT_WITH_COREMARK),1)
ifeq ($(COREMARK_MATRIX_LINK_BOUNDARY),1)
COREMARK_FORCE_OBJS += $(OBJ_DIR)/cm_core_matrix.o
endif
endif

COREMARK_CRC_CONFIG_STAMP := \
	$(OBJ_DIR)/.crc-config-hw$(COREMARK_HW_CRC)-profile$(COREMARK_PROFILE)
COREMARK_MATRIX_CONFIG_STAMP := \
	$(OBJ_DIR)/.matrix-config-hw$(COREMARK_HW_MATRIX)-boundary$(COREMARK_MATRIX_LINK_BOUNDARY)-profile$(COREMARK_PROFILE)
COREMARK_MATRIX_MULBE_GENERATED := $(OBJ_DIR)/cm_core_matrix_mulbe.c
COREMARK_MATRIX_CRC_GENERATED := $(OBJ_DIR)/cm_core_matrix_crc.c
COREMARK_MATRIX_CRC_MULBE_GENERATED := $(OBJ_DIR)/cm_core_matrix_crc_mulbe.c
COREMARK_CRC_INLINE_HEADER := $(COREMARK_PORT_DIR)/mundus_hw_crc_inline.h
COREMARK_CRC_GENERATOR := $(COREMARK_SCRIPTS_DIR)/generate_crc_accel.py
COREMARK_LIST_GENERATOR := $(COREMARK_SCRIPTS_DIR)/generate_list_schedule.py
COREMARK_MATRIX_GENERATOR := $(COREMARK_SCRIPTS_DIR)/generate_matrix_accel.py
COREMARK_STATE_GENERATOR := $(COREMARK_SCRIPTS_DIR)/generate_state_schedule.py
COREMARK_INSTRUMENTER := $(COREMARK_SCRIPTS_DIR)/instrument_coremark.py
COREMARK_LIST_SCHEDULE_GENERATED := $(OBJ_DIR)/cm_core_list_join_crc_sched.c
COREMARK_STATE_SCHEDULE_GENERATED := \
	$(OBJ_DIR)/cm_core_state_crc_sched_$(COREMARK_STATE_SCHEDULE).c
COREMARK_LIST_PROFILE_GENERATED := $(OBJ_DIR)/cm_core_list_join_crc_profile.c
COREMARK_MAIN_PROFILE_GENERATED := $(OBJ_DIR)/cm_core_main_crc_profile.c
COREMARK_MATRIX_PROFILE_GENERATED := $(OBJ_DIR)/cm_core_matrix_crc_mulbe_profile.c

ASM_SRCS := \
	$(BSP_DIR)/start.S \
	$(BSP_DIR)/trap.S \
	$(RTT_ROOT)/libcpu/risc-v/common/context_gcc.S

COREMARK_OBJS := $(addprefix $(OBJ_DIR)/cm_,$(notdir $(COREMARK_C_SRCS:.c=.o)))
OBJS := $(addprefix $(OBJ_DIR)/,$(notdir $(KERNEL_C_SRCS:.c=.o))) \
	$(addprefix $(OBJ_DIR)/,$(notdir $(BSP_C_SRCS:.c=.o))) \
	$(COREMARK_PORT_OBJ) \
	$(addprefix $(OBJ_DIR)/,$(notdir $(ASM_SRCS:.S=.o))) \
	$(OBJ_DIR)/bsp_timer.o \
	$(OBJ_DIR)/bsp_trap.o \
	$(COREMARK_OBJS)
DEPS := $(OBJS:.o=.d)

vpath %.c $(sort $(dir $(KERNEL_C_SRCS) $(BSP_C_SRCS)))
vpath %.S $(sort $(dir $(ASM_SRCS)))

all: image

$(BUILD_DIR) $(OBJ_DIR):
	@mkdir -p $@

$(LINKER_SCRIPT): $(BSP_DIR)/linker.ld $(NPC_AUTOCONF) | $(BUILD_DIR)
	$(CC) -E -P -x c -I$(dir $(NPC_AUTOCONF)) $< -o $@

$(COREMARK_CRC_CONFIG_STAMP): | $(OBJ_DIR)
	@touch $@

$(COREMARK_MATRIX_CONFIG_STAMP): | $(OBJ_DIR)
	@touch $@

$(OBJ_DIR)/%.o: %.S | $(OBJ_DIR)
	$(CC) $(ASFLAGS) -c $< -o $@

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(RTT_CFLAGS) -c $< -o $@

$(OBJ_DIR)/timer.o: $(RTT_ROOT)/src/timer.c | $(OBJ_DIR)
	$(CC) $(RTT_CFLAGS) -c $< -o $@

$(OBJ_DIR)/bsp_timer.o: $(BSP_DIR)/timer.c | $(OBJ_DIR)
	$(CC) $(RTT_CFLAGS) -c $< -o $@

$(OBJ_DIR)/bsp_trap.o: $(BSP_DIR)/trap.c | $(OBJ_DIR)
	$(CC) $(RTT_CFLAGS) -c $< -o $@

$(OBJ_DIR)/coremark_portme.o: $(COREMARK_PORT_SRCS) | $(OBJ_DIR)
	$(CC) $(COREMARK_CFLAGS) $(COREMARK_INCLUDES) \
		$(COREMARK_DEFINES) \
		-c $< -o $@

ifeq ($(COREMARK_HW_CRC),1)
$(OBJ_DIR)/cm_%_crc.c: $(COREMARK_SRC_DIR)/%.c \
		$(COREMARK_CRC_GENERATOR) $(COREMARK_CRC_INLINE_HEADER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_CRC_GENERATOR) $< $@

$(COREMARK_LIST_SCHEDULE_GENERATED): $(OBJ_DIR)/cm_core_list_join_crc.c \
		$(COREMARK_LIST_GENERATOR) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_LIST_GENERATOR) $< $@

ifeq ($(COREMARK_LIST_SCHEDULE),mundus)
COREMARK_LIST_BUILD_SOURCE := $(COREMARK_LIST_SCHEDULE_GENERATED)
else ifeq ($(COREMARK_LIST_SCHEDULE),none)
COREMARK_LIST_BUILD_SOURCE := $(OBJ_DIR)/cm_core_list_join_crc.c
else
$(error COREMARK_LIST_SCHEDULE must be 'mundus' or 'none')
endif
COREMARK_STATE_BUILD_SOURCE := $(COREMARK_STATE_SCHEDULE_GENERATED)
COREMARK_MAIN_BUILD_SOURCE := $(OBJ_DIR)/cm_core_main_crc.c

$(COREMARK_STATE_SCHEDULE_GENERATED): $(OBJ_DIR)/cm_core_state_crc.c \
		$(COREMARK_STATE_GENERATOR) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_STATE_GENERATOR) \
		--strategy $(COREMARK_STATE_SCHEDULE) $< $@

ifeq ($(COREMARK_PROFILE),1)
$(COREMARK_LIST_PROFILE_GENERATED): $(COREMARK_LIST_SCHEDULE_GENERATED) \
		$(COREMARK_INSTRUMENTER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_INSTRUMENTER) $< $@

$(COREMARK_MAIN_PROFILE_GENERATED): $(OBJ_DIR)/cm_core_main_crc.c \
		$(COREMARK_INSTRUMENTER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_INSTRUMENTER) $< $@

COREMARK_LIST_BUILD_SOURCE := $(COREMARK_LIST_PROFILE_GENERATED)
COREMARK_MAIN_BUILD_SOURCE := $(COREMARK_MAIN_PROFILE_GENERATED)
endif

$(OBJ_DIR)/cm_core_list_join.o: $(COREMARK_LIST_BUILD_SOURCE)
$(OBJ_DIR)/cm_core_state.o: $(COREMARK_STATE_BUILD_SOURCE)
$(OBJ_DIR)/cm_core_main.o: $(COREMARK_MAIN_BUILD_SOURCE)

$(OBJ_DIR)/cm_core_list_join.o $(OBJ_DIR)/cm_core_state.o \
		$(OBJ_DIR)/cm_core_main.o:
	$(CC) $(COREMARK_CFLAGS) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@
else
# Full LTO expands the software bit-at-a-time CRC into several hot callers and
# overflows the fixed IROM.  Keep only its defining translation unit as a
# normal call boundary when hardware CRC is disabled.
$(OBJ_DIR)/cm_core_util.o: $(COREMARK_SRC_DIR)/core_util.c | $(OBJ_DIR)
	$(CC) $(filter-out -flto,$(COREMARK_CFLAGS)) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@
endif

ifeq ($(COREMARK_HW_MATRIX),1)
$(COREMARK_MATRIX_MULBE_GENERATED): $(COREMARK_SRC_DIR)/core_matrix.c \
		$(COREMARK_MATRIX_GENERATOR) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_MATRIX_GENERATOR) $< $@

ifeq ($(COREMARK_HW_CRC),1)
$(COREMARK_MATRIX_CRC_MULBE_GENERATED): $(COREMARK_MATRIX_MULBE_GENERATED) \
		$(COREMARK_CRC_GENERATOR) $(COREMARK_CRC_INLINE_HEADER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_CRC_GENERATOR) $< $@
COREMARK_MATRIX_BUILD_SOURCE := $(COREMARK_MATRIX_CRC_MULBE_GENERATED)

ifeq ($(COREMARK_PROFILE),1)
$(COREMARK_MATRIX_PROFILE_GENERATED): $(COREMARK_MATRIX_CRC_MULBE_GENERATED) \
		$(COREMARK_INSTRUMENTER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_INSTRUMENTER) $< $@
COREMARK_MATRIX_BUILD_SOURCE := $(COREMARK_MATRIX_PROFILE_GENERATED)
endif
else
COREMARK_MATRIX_BUILD_SOURCE := $(COREMARK_MATRIX_MULBE_GENERATED)
endif

$(OBJ_DIR)/cm_core_matrix.o: $(COREMARK_MATRIX_BUILD_SOURCE) | $(OBJ_DIR)
	$(CC) $(filter-out -flto,$(COREMARK_CFLAGS)) \
		$(COREMARK_MATRIX_EXTRA_CFLAGS) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@
else ifeq ($(COREMARK_HW_CRC),1)
$(COREMARK_MATRIX_CRC_GENERATED): $(COREMARK_SRC_DIR)/core_matrix.c \
		$(COREMARK_CRC_GENERATOR) $(COREMARK_CRC_INLINE_HEADER) | $(OBJ_DIR)
	$(PYTHON) $(COREMARK_CRC_GENERATOR) $< $@

$(OBJ_DIR)/cm_core_matrix.o: $(COREMARK_MATRIX_CRC_GENERATED) | $(OBJ_DIR)
	$(CC) $(COREMARK_CFLAGS) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@
else ifeq ($(COREMARK_MATRIX_LINK_BOUNDARY),1)
$(OBJ_DIR)/cm_core_matrix.o: $(COREMARK_SRC_DIR)/core_matrix.c | $(OBJ_DIR)
	$(CC) $(filter-out -flto,$(COREMARK_CFLAGS)) \
		$(COREMARK_MATRIX_EXTRA_CFLAGS) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@
endif

$(OBJ_DIR)/cm_%.o: $(COREMARK_SRC_DIR)/%.c | $(OBJ_DIR)
	$(CC) $(COREMARK_CFLAGS) \
		$(COREMARK_INCLUDES) \
		-include $(COREMARK_PORT_DIR)/core_portme.h \
		$(COREMARK_DEFINES) \
		-Dmain=coremark_main \
		-c $< -o $@

# Rebuild the benchmark objects so command-line optimization overrides and the
# iteration count cannot accidentally reuse objects built with stale flags.
$(OBJ_DIR)/coremark_portme.o $(COREMARK_OBJS): FORCE

$(OBJ_DIR)/cm_core_util.o $(ELF): $(COREMARK_CRC_CONFIG_STAMP)
$(OBJ_DIR)/cm_core_matrix.o $(ELF): $(COREMARK_MATRIX_CONFIG_STAMP)

FORCE:

# Optional weight blob, linked into the uncached extension window.  Only built
# when the packer has produced one, so a checkout without a model still builds.
WEIGHTS_BIN := $(wildcard $(MT_HOME)/models/yc_weights.bin)
ifneq ($(WEIGHTS_BIN),)
WEIGHTS_OBJ := $(OBJ_DIR)/yc_weights.o
EXTRA_OBJS  += $(WEIGHTS_OBJ)
endif

$(WEIGHTS_OBJ): $(WEIGHTS_BIN) | $(OBJ_DIR)
	$(OBJCOPY) -I binary -O elf32-littleriscv -B riscv \
		--rename-section .data=.weights,alloc,load,readonly,data,contents \
		$< $@

MODEL_BIN := $(wildcard $(MT_HOME)/models/ym_weights.bin)
ifneq ($(MODEL_BIN),)
MODEL_OBJ := $(OBJ_DIR)/ym_weights.o
EXTRA_OBJS += $(MODEL_OBJ)
endif

$(MODEL_OBJ): $(MODEL_BIN) | $(OBJ_DIR)
	$(OBJCOPY) -I binary -O elf32-littleriscv -B riscv \
		--rename-section .data=.model,alloc,load,readonly,data,contents \
		$< $@

$(ELF): $(OBJS) $(EXTRA_OBJS) $(LINKER_SCRIPT)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(EXTRA_OBJS) -lgcc
	$(SIZE) $@

$(BIN): $(ELF)
	$(OBJCOPY) -S -O binary $< $@
	$(OBJDUMP) -d -S $< > $(DISASM)

$(IROM_BIN): $(ELF)
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(DRAM_BIN): $(ELF)
	$(OBJCOPY) -O binary --only-section=.rodata --only-section=.data $< $@

$(IROM_COE): $(IROM_BIN) $(IROM_PACKER) $(NPC_CONFIG)
	$(PYTHON) $(IROM_PACKER) $< $@ --config $(NPC_CONFIG)

$(DRAM_COE): $(DRAM_BIN) $(DRAM_PACKER)
	$(PYTHON) $(DRAM_PACKER) $< $@ \
		--capacity-bytes $(DRAM_CAPACITY_BYTES)

image: $(BIN) $(IROM_COE) $(DRAM_COE)
	@echo "IROM COE: $(IROM_COE)"
	@echo "DRAM COE: $(DRAM_COE)"

verify-coremark-source:
	cd $(COREMARK_PORT_DIR)/eembc && sha256sum -c SHA256SUMS

JYD_FAST_TIMER ?= 0
NPC_CCACHE_DISABLE ?= 1
# 0 = zero-filled Verilator reset values.  The JYD platform currently hangs with
# the upstream default of 2; see npc/Makefile VERILATOR_RESET.
VERILATOR_RESET ?= 0

run: $(BIN)
	@mkdir -p "$(COREMARK_RESULTS_DIR)"
	@set -o pipefail; \
	CCACHE_DISABLE=$(NPC_CCACHE_DISABLE) $(MAKE) -s -C $(NPC_HOME) wave \
		MUNDUS_HOME=$(MUNDUS_HOME) NPC_HOME=$(NPC_HOME) \
		PLATFORM=jyd MODE=batch ISA=riscv32 JYD_FAST_TIMER=$(JYD_FAST_TIMER) \
		VERILATOR_RESET=$(VERILATOR_RESET) PROGRAM=$(BIN) \
		ARGS="--elf=$(ELF) --log=$(LOG) --branch-report=$(BRANCH_REPORT) --pipeline-report=$(PIPELINE_REPORT) --memory-report=$(MEMORY_REPORT) --stats-window=led0" \
		git_commit= 2>&1 | tee "$(CONSOLE_LOG)"
	@awk '\
		/^2K performance run parameters for coremark\./ { capture = 1 } \
		capture && /^\[LED\] cycle=/ { exit } \
		capture { sub(/\r$$/, ""); print } \
	' "$(CONSOLE_LOG)" > "$(COREMARK_REPORT)"
	@if [[ -s "$(COREMARK_REPORT)" ]]; then \
		echo "CoreMark-only artifacts: $(COREMARK_RESULTS_DIR)"; \
		for report in "$(COREMARK_REPORT)" "$(LOG)" "$(BRANCH_REPORT)" \
		              "$(PIPELINE_REPORT)" "$(MEMORY_REPORT)"; do \
			[[ -s "$$report" ]] && echo "  $$report"; \
		done; \
	else \
		echo "CoreMark report not generated: no CoreMark output was found."; \
	fi

clean:
	$(RM) -r $(BUILD_DIR)

-include $(DEPS)

.PHONY: all image verify-coremark-source run clean FORCE
