MUNDUS_HOME ?= $(abspath ../../..)
NPC_HOME    ?= $(MUNDUS_HOME)/npc

CROSS_COMPILE ?= riscv32-unknown-elf-
CC              = $(CROSS_COMPILE)gcc
OBJCOPY         = $(CROSS_COMPILE)objcopy

BUILD_DIR := $(CURDIR)/build
ELF       := $(BUILD_DIR)/mulbe.elf
BIN       := $(BUILD_DIR)/mulbe.bin
LOG       := $(BUILD_DIR)/mulbe.log
PIPELINE_REPORT := $(BUILD_DIR)/pipeline_report.txt
MEMORY_REPORT   := $(BUILD_DIR)/memory_report.txt

CFLAGS  := -march=rv32im -mabi=ilp32 \
           -nostdlib -nostartfiles -static
LDFLAGS := -Wl,-T,$(CURDIR)/linker.lds -Wl,--build-id=none

all: run

$(BUILD_DIR):
	@mkdir -p $@

$(ELF): mulbe.S linker.lds | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -S -O binary $< $@

run: $(BIN)
	$(MAKE) -s -C $(NPC_HOME) wave \
		MUNDUS_HOME=$(MUNDUS_HOME) NPC_HOME=$(NPC_HOME) \
		PLATFORM=jyd MODE=batch ISA=riscv32 PROGRAM=$(BIN) \
		ARGS="--elf=$(ELF) --log=$(LOG) --pipeline-report=$(PIPELINE_REPORT) --memory-report=$(MEMORY_REPORT)" \
		git_commit=
	@grep -q "HIT GOOD TRAP" $(LOG)
	@echo "MULBE directed regression passed"

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all run clean
