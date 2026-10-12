# RISC-V ISA glue shared by every riscv* platform.
# Ported from ysyx-workbench/abstract-machine/scripts/isa/riscv.mk; the riscv32
# platform makefile overrides COMMON_CFLAGS / LDFLAGS for RV32.
CROSS_COMPILE ?= riscv32-unknown-linux-gnu-
COMMON_CFLAGS ?= -fno-pic -march=rv64g -mcmodel=medany -mstrict-align
CFLAGS        += $(COMMON_CFLAGS) -static
ASFLAGS       += $(COMMON_CFLAGS) -O0
LDFLAGS       += -melf64lriscv

# overwrite ARCH_H defined in $(AM_HOME)/Makefile
ARCH_H := arch/riscv.h
