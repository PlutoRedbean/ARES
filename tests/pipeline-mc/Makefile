#=============================================================================
# ARES pipeline multi-hart coherence test images
#-----------------------------------------------------------------------------
# mc_linear2.bin / mc_linear4.bin are the same branch-free coherence test with
# the hart count baked in.  smoke.bin is a minimal FENCE/store check.
#=============================================================================
HOME    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ARES    ?= $(abspath $(HOME)/../..)
BUILD   ?= $(ARES)/build/pipeline_mc
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
ASFLAGS := -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -Wl,-Ttext=0x80000000

.PHONY: all clean
all: $(BUILD)/mc_linear2.bin $(BUILD)/mc_linear4.bin $(BUILD)/smoke.bin

$(BUILD)/mc_linear2.elf: $(HOME)/mc_linear.S
	@mkdir -p $(BUILD)
	$(CC) $(ASFLAGS) -o $@ $<

$(BUILD)/mc_linear2.bin: $(BUILD)/mc_linear2.elf
	$(OBJCOPY) -O binary $< $@
	@size=$$(stat -c %s $@); \
	 if [ $$size -gt 32768 ]; then \
	     echo "error: $@ is $$size bytes, larger than 32 KiB IROM" >&2; \
	     rm -f $@; exit 1; \
	 fi

$(BUILD)/mc_linear4.S: $(HOME)/mc_linear.S
	@mkdir -p $(BUILD)
	sed 's/^\( *\)\.set NCPU, 2/\1.set NCPU, 4/' $< > $@

$(BUILD)/mc_linear4.elf: $(BUILD)/mc_linear4.S
	$(CC) $(ASFLAGS) -o $@ $<

$(BUILD)/mc_linear4.bin: $(BUILD)/mc_linear4.elf
	$(OBJCOPY) -O binary $< $@
	@size=$$(stat -c %s $@); \
	 if [ $$size -gt 32768 ]; then \
	     echo "error: $@ is $$size bytes, larger than 32 KiB IROM" >&2; \
	     rm -f $@; exit 1; \
	 fi

$(BUILD)/smoke.elf: $(HOME)/smoke.S
	@mkdir -p $(BUILD)
	$(CC) $(ASFLAGS) -o $@ $<

$(BUILD)/smoke.bin: $(BUILD)/smoke.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -rf $(BUILD)
