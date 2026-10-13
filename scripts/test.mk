# Regression tests for the standalone front-end testbenches.
#
# Ported from ysyx-workbench/npc/scripts/test.mk.  Every
# rtl/frontend/test/tb_*.sv is a self-checking Verilator testbench; it pulls in
# the package / DUT with `include so that it can be compiled on its own.  For
# each testbench a temporary Makefile is generated that sets TOP_NAME to the
# testbench module and includes this file again to build+run it -- the same
# idea as am-kernels/tests/cpu-tests.
#
# Usage (ARES_HOME must be exported):
#   make -f $(ARES_HOME)/scripts/test.mk test

ifndef ARES_HOME
  $(error ARES_HOME is not set. Please run: export ARES_HOME=/path/to/ARES)
endif

TEST_DIR  = $(ARES_HOME)/rtl/frontend/test
TEST_SRCS = $(shell find $(TEST_DIR) -maxdepth 1 -name "tb_*.sv")
TESTS     = $(basename $(notdir $(TEST_SRCS)))

TEST_BUILD_DIR ?= $(ARES_HOME)/build/test
TEST_INCDIRS = +incdir+$(ARES_HOME)/rtl/frontend +incdir+$(ARES_HOME)/rtl/frontend/include +incdir+$(TEST_DIR)
VERILATOR ?= verilator

# testbenches `include the DUT, so rebuild whenever any RTL source changes
TEST_DEPS  = $(shell find $(ARES_HOME)/rtl/frontend -not -path "*/test/*" -not -path "*/obj_dir/*" -name "*.sv")
TEST_DEPS += $(shell find $(ARES_HOME)/rtl/frontend -not -path "*/test/*" -not -path "*/obj_dir/*" -name "*.v")
TEST_DEPS += $(shell find $(ARES_HOME)/rtl/frontend -not -path "*/test/*" -not -path "*/obj_dir/*" -name "*.vh")

COLOR_RED   = \033[1;31m
COLOR_GREEN = \033[1;32m
COLOR_NONE  = \033[0m

.PHONY: test test-run

ifndef TEST_SRC

test:
	@mkdir -p $(TEST_BUILD_DIR)
	@fail=0; \
	results=$(TEST_BUILD_DIR)/.test_results.$$$$; \
	: > $$results; \
	for t in $(TESTS); do \
		printf 'TOP_NAME = %s\nTEST_SRC = %s\ninclude %s/scripts/test.mk\n' \
			"$$t" "$(TEST_DIR)/$$t.sv" "$(ARES_HOME)" > $(TEST_BUILD_DIR)/Makefile.$$t; \
		if $(MAKE) -s -f $(TEST_BUILD_DIR)/Makefile.$$t test-run; then \
			printf '[%14s] $(COLOR_GREEN)PASS$(COLOR_NONE)\n' "$$t" >> $$results; \
		else \
			printf '[%14s] $(COLOR_RED)***FAIL***$(COLOR_NONE)\n' "$$t" >> $$results; fail=1; \
		fi; \
		rm -f $(TEST_BUILD_DIR)/Makefile.$$t; \
	done; \
	echo "test list [$(words $(TESTS)) item(s)]:" $(TESTS); \
	cat $$results; \
	rm -f $$results; \
	if [ $$fail -ne 0 ]; then echo "REGRESSION FAILED"; exit 1; fi; \
	echo "REGRESSION PASSED"

else

test-run: $(TEST_BUILD_DIR)/$(TOP_NAME)
	@$(TEST_BUILD_DIR)/$(TOP_NAME)

$(TEST_BUILD_DIR)/$(TOP_NAME): $(TEST_SRC) $(TEST_DEPS)
	@mkdir -p $(TEST_BUILD_DIR)
	@$(VERILATOR) --binary --timing -sv -Wno-fatal $(TEST_INCDIRS) \
		-Mdir $(TEST_BUILD_DIR)/obj_$(TOP_NAME) \
		--top-module $(TOP_NAME) $(TEST_SRC) -o $@

endif
