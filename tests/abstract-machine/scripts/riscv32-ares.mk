#=============================================================================
# ARES platform (ARCH = riscv32-ares)
#-----------------------------------------------------------------------------
# Ported from ysyx-workbench abstract-machine/scripts/{riscv32-jyd.mk,
# platform/jyd.mk}.  Images are linked for the Mundus memory map and handed to
# the ARES Verilator simulation in $(ARES_HOME)/sim.
#=============================================================================
include $(AM_HOME)/scripts/isa/riscv.mk
include $(AM_HOME)/scripts/platform/ares.mk

RISCV_MARCH  ?= rv32im_zicsr
COMMON_CFLAGS += -march=$(RISCV_MARCH) -mabi=ilp32
LDFLAGS       += -melf32lriscv

AM_SRCS += riscv/ares/libgcc/multi3.c \
           riscv/ares/libgcc/ashldi3.c \
           riscv/ares/libgcc/unused.c
