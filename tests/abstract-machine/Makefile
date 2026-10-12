# Locate the ARES root from this file's own path so the test flow does not
# depend on ARES_HOME being exported (the ysyx-workbench environment exports
# AM_HOME / MUNDUS_HOME / NPC_HOME, which must not leak into ARES builds).
ARES_HOME := $(if $(ARES_HOME),$(ARES_HOME),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..))

include $(ARES_HOME)/common.mk
# Makefile for the ARES AbstractMachine subset
#
# This is a trimmed port of ysyx-workbench/abstract-machine/Makefile.  Only the
# pieces the ported cpu-tests need are kept: image/archive/run, the riscv ISA
# glue and the ARES platform runtime (am/src/riscv/ares).

### Default to create a bare-metal kernel image
ifeq ($(MAKECMDGOALS),)
  MAKECMDGOALS  = image
  .DEFAULT_GOAL = image
endif

### Override checks when cleaning
ifeq ($(findstring $(MAKECMDGOALS),clean|clean-all),)

### Print build info message
$(info # Building $(NAME)-$(MAKECMDGOALS) [$(ARCH)])

### Check: $AM_HOME looks sane
ifeq ($(wildcard $(AM_HOME)/am/include/am.h),)
  $(error $$AM_HOME must be an AbstractMachine repo)
endif

### Check: $ARCH must be in the supported list
ARCHS = $(basename $(notdir $(shell ls $(AM_HOME)/scripts/*.mk)))
ifeq ($(filter $(ARCHS), $(ARCH)), )
  $(error Expected $$ARCH in {$(ARCHS)}, Got "$(ARCH)")
endif

### Split ARCH into ISA and platform, e.g. riscv32-ares -> ISA=riscv32, PLATFORM=ares
ARCH_SPLIT = $(subst -, ,$(ARCH))
ISA        = $(word 1,$(ARCH_SPLIT))
PLATFORM   = $(word 2,$(ARCH_SPLIT))

### Check if there is something to build
ifeq ($(flavor SRCS), undefined)
  $(error Nothing to build)
endif

endif

## 2. General Compilation Targets

WORK_DIR  = $(shell pwd)
DST_DIR   = $(WORK_DIR)/build/$(ARCH)
$(shell mkdir -p $(DST_DIR))

IMAGE_REL = build/$(NAME)-$(ARCH)
IMAGE     = $(abspath $(IMAGE_REL))
ARCHIVE   = $(WORK_DIR)/build/$(NAME)-$(ARCH).a

OBJS      = $(addprefix $(DST_DIR)/, $(addsuffix .o, $(basename $(SRCS))))
LIBS     := $(sort $(LIBS) am klib)
LINKAGE   = $(OBJS)

## 3. General Compilation Flags

AS        = $(CROSS_COMPILE)gcc
CC        = $(CROSS_COMPILE)gcc
CXX       = $(CROSS_COMPILE)g++
LD        = $(CROSS_COMPILE)ld
AR        = $(CROSS_COMPILE)ar
OBJDUMP   = $(CROSS_COMPILE)objdump
OBJCOPY   = $(CROSS_COMPILE)objcopy
READELF   = $(CROSS_COMPILE)readelf

INC_PATH += $(WORK_DIR)/include $(addsuffix /include/, $(addprefix $(AM_HOME)/, $(LIBS)))
INCFLAGS += $(addprefix -I, $(INC_PATH))

ARCH_H := arch/$(ARCH).h
CFLAGS   += -O2 -MMD -Werror $(INCFLAGS) \
            -D__ISA__=\"$(ISA)\" -D__ISA_$(shell echo $(ISA) | tr a-z A-Z)__ \
            -D__ARCH__=$(ARCH) -D__ARCH_$(shell echo $(ARCH) | tr a-z A-Z | tr - _) \
            -D__PLATFORM__=$(PLATFORM) -D__PLATFORM_$(shell echo $(PLATFORM) | tr a-z A-Z | tr - _) \
            -DARCH_H=\"$(ARCH_H)\" \
            -fno-asynchronous-unwind-tables -fno-builtin -fno-stack-protector \
            -Wno-main -U_FORTIFY_SOURCE -fvisibility=hidden
CXXFLAGS += $(CFLAGS) -ffreestanding -fno-rtti -fno-exceptions
ASFLAGS  += -MMD $(INCFLAGS)
LDFLAGS  += -z noexecstack $(addprefix -T, $(LDSCRIPTS))

## 4. Arch-Specific Configurations

-include $(AM_HOME)/scripts/$(ARCH).mk

## 5. Compilation Rules

$(DST_DIR)/%.o: %.c
	@mkdir -p $(dir $@) && echo + CC $<
	@$(CC) -std=gnu11 $(CFLAGS) -c -o $@ $(realpath $<)

$(DST_DIR)/%.o: %.cc
	@mkdir -p $(dir $@) && echo + CXX $<
	@$(CXX) -std=c++17 $(CXXFLAGS) -c -o $@ $(realpath $<)

$(DST_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@) && echo + CXX $<
	@$(CXX) -std=c++17 $(CXXFLAGS) -c -o $@ $(realpath $<)

$(DST_DIR)/%.o: %.S
	@mkdir -p $(dir $@) && echo + AS $<
	@$(AS) $(ASFLAGS) -c -o $@ $(realpath $<)

ifeq ($(MAKECMDGOALS),archive)
$(ARCHIVE): $(OBJS)
	@echo + AR "->" $(shell realpath $@ --relative-to .)
	@$(AR) rcs $@ $^
else
define LIB_TEMPLATE =
$$(AM_HOME)/$(1)/build/$(1)-$$(ARCH).a: force
	@$$(MAKE) -s -C $$(AM_HOME)/$(1) archive
LINKAGE += $$(AM_HOME)/$(1)/build/$(1)-$$(ARCH).a
endef

$(foreach lib, $(LIBS), $(eval $(call LIB_TEMPLATE,$(lib))))
endif

$(IMAGE).elf: $(LINKAGE) $(LDSCRIPTS)
	@echo \# Creating image [$(ARCH)]
	@echo + LD "->" $(IMAGE_REL).elf
	@$(LD) $(LDFLAGS) -o $@ --start-group $(LINKAGE) --end-group

-include $(addprefix $(DST_DIR)/, $(addsuffix .d, $(basename $(SRCS))))

## 6. Miscellaneous

image: image-dep
archive: $(ARCHIVE)
image-dep: $(IMAGE).elf
.PHONY: image image-dep archive run

force:
.PHONY: force

clean:
	rm -rf $(WORK_DIR)/build/
.PHONY: clean

CLEAN_ALL = $(dir $(shell find . -mindepth 2 -name Makefile))
clean-all: $(CLEAN_ALL) clean
$(CLEAN_ALL):
	-@$(MAKE) -s -C $@ clean
.PHONY: clean-all $(CLEAN_ALL)
