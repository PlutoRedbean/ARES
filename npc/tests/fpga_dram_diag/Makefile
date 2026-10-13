MUNDUS_HOME ?= $(abspath ../../..)
NPC_HOME    ?= $(MUNDUS_HOME)/npc
NEMU_HOME   ?= $(MUNDUS_HOME)/nemu
CCACHE_DIR  ?= /tmp/mundus-fpga-dram-diag-ccache

CROSS_COMPILE ?= riscv64-unknown-elf-
CC              = $(CROSS_COMPILE)gcc
OBJCOPY         = $(CROSS_COMPILE)objcopy
OBJDUMP         = $(CROSS_COMPILE)objdump

BUILD_DIR := $(CURDIR)/build
IMAGE_DIR := $(CURDIR)/images
ELF       := $(BUILD_DIR)/fpga_dram_diag.elf
SIM_ELF   := $(BUILD_DIR)/fpga_dram_diag_sim.elf
BIN       := $(BUILD_DIR)/fpga_dram_diag.bin
SIM_BIN   := $(BUILD_DIR)/fpga_dram_diag_sim.bin
IROM_BIN  := $(BUILD_DIR)/fpga_dram_diag_irom.bin
DRAM_BIN  := $(BUILD_DIR)/fpga_dram_diag_dram.bin
DISASM    := $(BUILD_DIR)/fpga_dram_diag.txt
IROM_COE  := $(IMAGE_DIR)/fpga_dram_diag_irom.coe
DRAM_COE  := $(IMAGE_DIR)/fpga_dram_diag_dram.coe
LOG       := $(BUILD_DIR)/fpga_dram_diag.log

CFLAGS  := -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles -static
LDFLAGS := -Wl,-T,$(CURDIR)/linker.lds -Wl,--build-id=none -Wl,--no-relax

all: coe disasm

$(BUILD_DIR) $(IMAGE_DIR):
	@mkdir -p $@

$(ELF): fpga_dram_diag.S linker.lds | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(SIM_ELF): fpga_dram_diag.S linker.lds | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DSIMULATION $(LDFLAGS) -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -S -O binary $< $@

$(SIM_BIN): $(SIM_ELF)
	$(OBJCOPY) -S -O binary $< $@

$(IROM_BIN): $(ELF)
	$(OBJCOPY) -S -j .text -O binary $< $@

$(DRAM_BIN): $(ELF)
	$(OBJCOPY) -S -j .data -O binary $< $@

$(IROM_COE): $(IROM_BIN) $(NPC_HOME)/tools/pack_irom_coe.py | $(IMAGE_DIR)
	python3 $(NPC_HOME)/tools/pack_irom_coe.py $< $@

$(DRAM_COE): $(DRAM_BIN) $(NPC_HOME)/tools/pack_dram_coe.py | $(IMAGE_DIR)
	python3 $(NPC_HOME)/tools/pack_dram_coe.py $< $@

$(DISASM): $(ELF) | $(BUILD_DIR)
	$(OBJDUMP) -d -M no-aliases,numeric $< > $@

coe: $(IROM_COE) $(DRAM_COE) $(BIN)

disasm: $(DISASM)

run: $(SIM_BIN)
	$(MAKE) -s -C $(NPC_HOME) wave \
		MUNDUS_HOME=$(MUNDUS_HOME) NPC_HOME=$(NPC_HOME) \
		CCACHE_DIR=$(CCACHE_DIR) \
		PLATFORM=jyd MODE=batch ISA=riscv32 PROGRAM=$(SIM_BIN) \
		ARGS="--diff=$(NEMU_HOME)/build/riscv32-nemu-interpreter-so --elf=$(SIM_ELF) --log=$(LOG)" \
		git_commit=

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all coe disasm run clean
