#=============================================================================
# ARES - am-kernels cpu-tests
#-----------------------------------------------------------------------------
# Ported from ysyx-workbench/am-kernels/tests/cpu-tests.  Each test is turned
# into a tiny makefile that links the program against the ARES AbstractMachine
# subset and then runs it in the ARES Verilator simulation.
#
#   make ARCH=riscv32-ares run            build and run every test
#   make ARCH=riscv32-ares ALL=add run    build and run one test
#   make ARCH=riscv32-ares add            build and run a single test
#   make clean
#=============================================================================
CPU_TESTS_HOME := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ARES_HOME      ?= $(abspath $(CPU_TESTS_HOME)/../..)
export ARES_HOME

include $(ARES_HOME)/common.mk

ARCH ?= riscv32-ares

.PHONY: all run clean latest $(ALL)

RESULT = .result
$(shell > $(RESULT))

COLOR_RED   = \033[1;31m
COLOR_GREEN = \033[1;32m
COLOR_NONE  = \033[0m

ALL = $(basename $(notdir $(shell find tests/. -name "*.c")))

all: $(addprefix Makefile., $(ALL))
	@echo "test list [$(words $(ALL)) item(s)]:" $(ALL)

$(ALL): %: Makefile.%

Makefile.%: tests/%.c latest
	@/bin/echo -e "NAME = $*\nSRCS = $<\ninclude ${ARES_HOME}/tests/abstract-machine/Makefile" > $@
	@if make -s -f $@ ARCH=$(ARCH) $(MAKECMDGOALS); then \
		printf "[%14s] $(COLOR_GREEN)PASS$(COLOR_NONE)\n" $* >> $(RESULT); \
	else \
		printf "[%14s] $(COLOR_RED)***FAIL***$(COLOR_NONE)\n" $* >> $(RESULT); \
	fi
	-@rm -f Makefile.$*

run: all
	@cat $(RESULT)
	@grep -q "FAIL" $(RESULT); FAIL=$$?; rm $(RESULT); test $$FAIL -ne 0

clean:
	rm -rf Makefile.* build/ .result

latest:
