MUNDUS_HOME ?= $(abspath ../../..)
NPC_HOME    ?= $(MUNDUS_HOME)/npc
NEMU_HOME   ?= $(MUNDUS_HOME)/nemu
CCACHE_DIR  ?= /tmp/mundus-frp-lite-ccache

CROSS_COMPILE ?= riscv64-unknown-elf-
CC              = $(CROSS_COMPILE)gcc
OBJCOPY         = $(CROSS_COMPILE)objcopy

BUILD_DIR := $(CURDIR)/build
ELF       := $(BUILD_DIR)/frp_lite.elf
BIN       := $(BUILD_DIR)/frp_lite.bin
LOG       := $(BUILD_DIR)/frp_lite.log
BRANCH_REPORT := $(BUILD_DIR)/branch_difftest_report.txt

CFLAGS  := -march=rv32im -mabi=ilp32 \
           -nostdlib -nostartfiles -static
LDFLAGS := -Wl,-T,$(CURDIR)/linker.lds -Wl,--build-id=none

all: run

$(BUILD_DIR):
	@mkdir -p $@

$(ELF): frp_lite.S linker.lds | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -S -O binary $< $@

run: $(BIN)
	$(MAKE) -s -C $(NPC_HOME) wave \
		MUNDUS_HOME=$(MUNDUS_HOME) NPC_HOME=$(NPC_HOME) \
		CCACHE_DIR=$(CCACHE_DIR) \
		PLATFORM=jyd MODE=batch ISA=riscv32 PROGRAM=$(BIN) \
		ARGS="--diff=$(NEMU_HOME)/build/riscv32-nemu-interpreter-so --elf=$(ELF) --log=$(LOG) --branch-report=$(BRANCH_REPORT)" \
		git_commit=
	python3 check_stats.py $(LOG) $(BRANCH_REPORT)

clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: all run clean
