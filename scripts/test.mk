# Compatibility entrypoint for the frontend self-checking suite. Source ordering,
# configuration, assertions and strict lint flags are owned by the root rules.
ifndef ARES_HOME
  $(error ARES_HOME is not set. Please export ARES_HOME=/path/to/ARES)
endif
TEST_BUILD_DIR ?= $(ARES_HOME)/build/test
TESTS := $(basename $(notdir $(wildcard $(ARES_HOME)/rtl/frontend/test/tb_*.sv)))
.PHONY: test test-run
test:
	@$(MAKE) -C $(ARES_HOME) unit-frontend FE_UNIT_TBS="$(TESTS)" FE_UNIT_BUILD="$(TEST_BUILD_DIR)"

test-run:
	@$(MAKE) -C $(ARES_HOME) unit-frontend FE_UNIT_TBS="$(TOP_NAME)" FE_UNIT_BUILD="$(TEST_BUILD_DIR)"
