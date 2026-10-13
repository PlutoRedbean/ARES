PROJ_PATH := $(shell pwd)
INC_PATH  := $(PROJ_PATH)/include
BUILD_DIR := $(PROJ_PATH)/build

CC        := gcc
CFLAGS    := -Wall -Werror -I$(INC_PATH) -O2 -g -MMD -MP
LDFLAGS   := -pthread

PC_TRACE  ?= $(PROJ_PATH)/data/pc_trace.bin
ASM_FILE  ?= $(PROJ_PATH)/data/irom_data.asm
REPORT    ?= $(BUILD_DIR)/pc_trace_analysis.txt
THREADS   ?= 16
MISPRED_PENALTY ?= 2
BASE_CPI  ?= 1.0

SRC       := $(PROJ_PATH)/trace_parser_multithread.c
OBJ       := $(patsubst $(PROJ_PATH)/%.c, $(BUILD_DIR)/%.o, $(SRC))
DEPS      := $(OBJ:.o=.d)
TARGET    := $(BUILD_DIR)/branchsim

.PHONY: all clean run

all: $(TARGET)

run: $(TARGET)
	@if [ ! -f "$(PC_TRACE)" ]; then \
		echo "PC trace file not found: $(PC_TRACE)"; \
		echo "Usage: make run PC_TRACE=/path/to/pc_trace.bin ASM_FILE=/path/to/disasm.asm REPORT=$(BUILD_DIR)/pc_trace_analysis.txt THREADS=16 MISPRED_PENALTY=8 BASE_CPI=1.0"; \
		exit 1; \
	fi
	@if [ ! -f "$(ASM_FILE)" ]; then \
		echo "ASM file not found: $(ASM_FILE)"; \
		echo "Usage: make run PC_TRACE=/path/to/pc_trace.bin ASM_FILE=/path/to/disasm.asm REPORT=$(BUILD_DIR)/pc_trace_analysis.txt THREADS=16 MISPRED_PENALTY=8 BASE_CPI=1.0"; \
		exit 1; \
	fi
	@echo "Running branchsim: PC_TRACE=$(PC_TRACE) ASM_FILE=$(ASM_FILE) THREADS=$(THREADS) MISPRED_PENALTY=$(MISPRED_PENALTY) BASE_CPI=$(BASE_CPI)"
	@$(abspath $(TARGET)) "$(PC_TRACE)" "$(ASM_FILE)" "$(REPORT)" "$(THREADS)" "$(MISPRED_PENALTY)" "$(BASE_CPI)"
	@echo "Report saved to $(REPORT)"

$(TARGET): $(OBJ)
	@echo "Linking $@"
	@$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD_DIR)/%.o: $(PROJ_PATH)/%.c | $(BUILD_DIR)
	@echo "Compiling $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	@rm -rf $(BUILD_DIR)

-include $(DEPS)