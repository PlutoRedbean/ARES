MUNDUS_HOME ?= $(abspath ../../..)
NPC_HOME    ?= $(MUNDUS_HOME)/npc

CROSS_COMPILE ?= riscv32-unknown-elf-
CC              = $(CROSS_COMPILE)gcc
OBJCOPY         = $(CROSS_COMPILE)objcopy

BUILD_DIR := $(CURDIR)/build
ELF       := $(BUILD_DIR)/crc16.elf
BIN       := $(BUILD_DIR)/crc16.bin
LOG       := $(BUILD_DIR)/crc16.log
PIPELINE_REPORT := $(BUILD_DIR)/pipeline_report.txt
MEMORY_REPORT   := $(BUILD_DIR)/memory_report.txt

CFLAGS  := -march=rv32im -mabi=ilp32 \
           -nostdlib -nostartfiles -static
LDFLAGS := -Wl,-T,$(CURDIR)/linker.lds -Wl,--build-id=none

all: run

$(BUILD_DIR):
	@mkdir -p $@

$(ELF): crc16.S linker.lds | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -S -O binary $< $@

run: $(BIN)
	python3 verify_model.py
	$(MAKE) -s -C $(NPC_HOME) wave \
		MUNDUS_HOME=$(MUNDUS_HOME) NPC_HOME=$(NPC_HOME) \
		PLATFORM=jyd MODE=batch ISA=riscv32 PROGRAM=$(BIN) \
		ARGS="--elf=$(ELF) --log=$(LOG) --pipeline-report=$(PIPELINE_REPORT) --memory-report=$(MEMORY_REPORT)" \
		git_commit=
	python3 check_run.py $(LOG)

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all run clean
