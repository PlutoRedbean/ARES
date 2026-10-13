PROJ_PATH := $(shell pwd)
INC_PATH  := $(PROJ_PATH)/include
BUILD_DIR := $(PROJ_PATH)/build

CC        := gcc
CFLAGS    := -Wall -Werror -I$(INC_PATH) -g -MMD -MP

SRC       := $(PROJ_PATH)/cachesim.c
OBJ       := $(patsubst $(PROJ_PATH)/%.c, $(BUILD_DIR)/%.o, $(SRC))
DEPS      := $(OBJ:.o=.d)
TARGET    := $(BUILD_DIR)/cachesim

.PHONY: all clean run

all: $(TARGET)

run: $(TARGET)
	@$(abspath $(TARGET))

$(TARGET): $(OBJ)
	@echo "Linking $@"
	@$(CC) $(CFLAGS) -o $@ $^

$(BUILD_DIR)/%.o: $(PROJ_PATH)/%.c | $(BUILD_DIR)
	@echo "Compiling $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	@rm -rf $(BUILD_DIR)

-include $(DEPS)
