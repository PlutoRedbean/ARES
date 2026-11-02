ARES_HOME := $(abspath ../../../..)
RTT := $(abspath ../..)
OUT ?= $(ARES_HOME)/build/rtos
CROSS_COMPILE ?= riscv64-unknown-elf-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany -mstrict-align -Os -g \
 -ffreestanding -fno-builtin -fno-common -fno-pic -fno-pie \
 -ffunction-sections -fdata-sections -MMD -MP -Wall -Wextra \
 -Iinclude -I$(RTT)/include -I$(RTT)/libcpu/risc-v/common
KERNEL := clock components cpu idle irq kservice object scheduler thread timer
SOURCES := $(addprefix $(RTT)/src/,$(addsuffix .c,$(KERNEL)))
LOCAL := board console timer trap main cpuport
OBJECTS := $(addprefix $(OUT)/kernel_,$(addsuffix .o,$(KERNEL))) \
 $(addprefix $(OUT)/,$(addsuffix .o,$(LOCAL))) $(OUT)/start.o $(OUT)/trap_entry.o $(OUT)/context.o
.PHONY: all
all: $(OUT)/ares-rtos.elf
$(OUT):
	mkdir -p $@
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
$(OUT)/ares-rtos.elf: $(OBJECTS) linker.ld Makefile
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -static -Wl,-T,linker.ld \
	 -Wl,-Map,$(OUT)/ares-rtos.map -Wl,--gc-sections -Wl,--build-id=none $(OBJECTS) -lgcc -o $@
	$(CROSS_COMPILE)size $@
	$(CROSS_COMPILE)objcopy -O binary $@ $(OUT)/ares-rtos.bin
-include $(OBJECTS:.o=.d)
