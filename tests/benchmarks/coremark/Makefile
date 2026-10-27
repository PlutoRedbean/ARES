#=============================================================================
# CoreMark port for the ARES AbstractMachine runtime (ARCH = riscv32-ares)
#-----------------------------------------------------------------------------
# The benchmark sources under src/ and include/ are the EEMBC CoreMark 1.0
# reference files and stay unmodified; only this build file and the port layer
# (include/core_portme.h, src/core_portme.c) are ARES-specific.  Provenance,
# frozen parameters and the trademark boundary are in NOTICE.md.
#
# scripts/build_coremark_image.py stages this port into build/coremark/port,
# builds it and records hashes together with the ELF/bin/hex image.  Building
# in place is supported but leaves artefacts under build/ (git-ignored):
#
#   make -C tests/benchmarks/coremark ARES_HOME=$PWD ARCH=riscv32-ares \
#        CROSS_COMPILE=riscv64-unknown-elf- image
#=============================================================================

ARES_HOME := $(if $(ARES_HOME),$(ARES_HOME),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..))

NAME = coremark
SRCS = $(sort $(wildcard src/*.c))

include $(ARES_HOME)/tests/abstract-machine/Makefile
