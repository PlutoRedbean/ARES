#=============================================================================
# ARES - shared path setup for the test infrastructure
#-----------------------------------------------------------------------------
# Ported from ysyx-workbench/common.mk.  Every test/AM makefile includes this
# file, so ARES_HOME has to be exported (or passed on the command line):
#
#   export ARES_HOME=/path/to/ARES
#=============================================================================
ifndef ARES_HOME
  $(error ARES_HOME is not set. Please run: export ARES_HOME=/path/to/ARES)
endif

SIM_HOME := $(ARES_HOME)/sim
AM_HOME  := $(ARES_HOME)/tests/abstract-machine
TESTS    := $(ARES_HOME)/tests
