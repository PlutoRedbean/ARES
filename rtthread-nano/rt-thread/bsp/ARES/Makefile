ARES_HOME := $(abspath ../../../..)
RTT := $(abspath ../..)
PROFILE ?= test
ifeq ($(PROFILE),amp)
OUT ?= $(ARES_HOME)/build/rtos_amp
else ifeq ($(PROFILE),shell)
OUT ?= $(ARES_HOME)/build/rtos_shell
else
OUT ?= $(ARES_HOME)/build/rtos
endif
CROSS_COMPILE ?= riscv64-unknown-elf-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany -mstrict-align -Os -g \
 -ffreestanding -fno-builtin -fno-common -fno-pic -fno-pie \
 -ffunction-sections -fdata-sections -MMD -MP -Wall -Wextra \
 -Iinclude -I$(RTT)/include -I$(RTT)/libcpu/risc-v/common
KERNEL := clock components cpu idle irq kservice object scheduler thread timer
SOURCES := $(addprefix $(RTT)/src/,$(addsuffix .c,$(KERNEL)))
LOCAL := board console timer trap main cpuport
ifneq ($(filter $(PROFILE),shell amp),)
CFLAGS += -DARES_SHELL -Iinclude/compat -I$(RTT)/components/finsh
KERNEL += ipc
LOCAL := board console timer trap cpuport shell_main shell_runtime
SHELL_OBJECTS := $(OUT)/finsh_shell.o $(OUT)/finsh_msh.o
else ifneq ($(PROFILE),test)
$(error PROFILE must be test, shell or amp)
endif
OBJECTS := $(addprefix $(OUT)/kernel_,$(addsuffix .o,$(KERNEL))) \
 $(addprefix $(OUT)/,$(addsuffix .o,$(LOCAL))) $(OUT)/start.o $(OUT)/trap_entry.o $(OUT)/context.o $(SHELL_OBJECTS)
LINKER := linker.ld
TARGETS := $(OUT)/ares-rtos.elf
ifeq ($(PROFILE),amp)
AMP_CFLAGS := -DARES_RTOS_AMP -DARES_MT_CORES=4 -DMAIN_HAS_NOARGC=1 \
 -I$(OUT)/src_port/include -I$(ARES_HOME)/tests/abstract-machine/am/src/riscv/ares/include
CFLAGS += $(AMP_CFLAGS)
LINKER := amp/host.ld
GESTURE := $(ARES_HOME)/app/gesture/firmware
BENCH := core_main core_util core_list_join core_matrix core_state crc_hw core_list_array matrix_hw state_hw
BENCH_OBJECTS := $(addprefix $(OUT)/bench_,$(addsuffix .o,$(BENCH))) $(OUT)/amp_core_portme.o
OBJECTS += $(BENCH_OBJECTS) $(OUT)/amp_app.o $(OUT)/amp_printf.o $(OUT)/amp_gesture.o \
 $(addprefix $(OUT)/gesture_,mt.o mt_net.o mt_detect.o mt_track.o)
TARGETS += $(OUT)/worker.elf
endif
.PHONY: all
all: $(TARGETS)
$(OUT):
	mkdir -p $@
$(OUT)/finsh_%.o: $(RTT)/components/finsh/%.c | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/kernel_%.o: $(RTT)/src/%.c | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/%.o: %.c | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/start.o: start.S | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/trap_entry.o: trap.S | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/context.o: $(RTT)/libcpu/risc-v/common/context_gcc.S | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OBJECTS): Makefile
$(OUT)/ares-rtos.elf: $(OBJECTS) $(LINKER) Makefile
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -static -Wl,-T,$(LINKER) \
	 -Wl,-Map,$(OUT)/ares-rtos.map -Wl,--gc-sections -Wl,--build-id=none $(OBJECTS) -lgcc -o $@
	$(CROSS_COMPILE)size $@
	$(CROSS_COMPILE)objcopy -O binary $@ $(OUT)/ares-rtos.bin

ifeq ($(PROFILE),amp)
BENCH_GENERATOR := $(ARES_HOME)/scripts/build_coremark_crc.py
BENCH_REFERENCE := $(ARES_HOME)/tests/benchmarks/coremark
$(OUT)/.coremark-staged: Makefile $(BENCH_GENERATOR) $(ARES_HOME)/scripts/coremark_array_list.c \
 $(ARES_HOME)/scripts/coremark_mt_pipe/core_portme.h \
 $(wildcard $(BENCH_REFERENCE)/src/*.c $(BENCH_REFERENCE)/include/*.h) | $(OUT)
	python3 $(BENCH_GENERATOR) --list-engine --matrix-engine --state-engine --stage-only --out $(OUT)
	cp $(ARES_HOME)/scripts/coremark_mt_pipe/core_portme.h $(OUT)/src_port/include/
	touch $@
$(filter $(OUT)/bench_%.o,$(BENCH_OBJECTS)): $(OUT)/bench_%.o: $(OUT)/.coremark-staged
	$(CC) $(CFLAGS) $(BENCH_FLAGS) -c $(OUT)/src_port/src/$*.c -o $@
$(OUT)/bench_core_main.o: BENCH_FLAGS := -O2 -Dmain=coremark_main
$(OUT)/bench_core_util.o: BENCH_FLAGS := -Dcrcu8=crcu8_orig -Dcrcu16=crcu16_orig -Dcrcu32=crcu32_orig -Dcrc16=crc16_orig
$(OUT)/bench_core_list_join.o: BENCH_FLAGS := -Dcore_bench_list=core_bench_list_orig
$(OUT)/bench_core_matrix.o: BENCH_FLAGS := -Dcore_bench_matrix=core_bench_matrix_orig
$(OUT)/bench_core_state.o: BENCH_FLAGS := -Dcore_bench_state=core_bench_state_orig
$(OUT)/bench_core_list_array.o: BENCH_FLAGS := -O3 -funroll-loops -DARES_LIST_ENGINE
$(OUT)/bench_crc_hw.o $(OUT)/bench_matrix_hw.o $(OUT)/bench_state_hw.o: BENCH_FLAGS := -O3 -funroll-loops
$(OUT)/amp_core_portme.o: $(ARES_HOME)/scripts/coremark_mt_pipe/core_portme.c $(OUT)/.coremark-staged
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/amp_%.o: amp/%.c | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/gesture_%.o: $(GESTURE)/app/%.c | $(OUT)
	$(CC) $(CFLAGS) -DRPS_WEIGHTS -I$(GESTURE)/common -c $< -o $@
$(OUT)/amp_app.o $(OUT)/amp_gesture.o: CFLAGS += -DRPS_WEIGHTS -I$(GESTURE)/app -I$(GESTURE)/common
$(OUT)/worker_start.o: amp/worker.S Makefile | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/worker.elf: $(OUT)/worker_start.o $(BENCH_OBJECTS) amp/worker.ld
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -static -Wl,-T,amp/worker.ld \
	 -Wl,-Map,$(OUT)/worker.map -Wl,--gc-sections -Wl,--build-id=none $(filter %.o,$^) -lgcc -o $@
	$(CROSS_COMPILE)size $@
endif
-include $(OBJECTS:.o=.d)
