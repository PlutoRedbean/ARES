COLOR_RED := $(shell echo "\033[1;31m")
COLOR_END := $(shell echo "\033[0m")

Q                   := @
PYTHON              := python
CFG_BUILD_DIR       := $(NPC_HOME)/configs/build
C_AUTOGEN_DIR       := $(CFG_BUILD_DIR)/csrc/include
V_AUTOGEN_DIR       := $(CFG_BUILD_DIR)/vsrc/include
SCALA_AUTOGEN_DIR   := $(CFG_BUILD_DIR)/scsrc
KCONFIG_PATH        := $(NPC_HOME)/tools/kconfig
Kconfig             := $(NPC_HOME)/configs/Kconfig
AUTOGEN_CFG_SCRIPT  := $(NPC_HOME)/tools/pysrc/autogen_cfg.py
DOT_CONFIG          := $(CFG_BUILD_DIR)/.config
silent := -s

ifeq ($(wildcard $(DOT_CONFIG)),)
$(warning $(COLOR_RED)Warning: .config does not exist!$(COLOR_END))
$(warning $(COLOR_RED)To build the project, first run 'make menuconfig'.$(COLOR_END))
endif

MCONF  := $(KCONFIG_PATH)/build/mconf

PYSRC_DIR  := $(NPC_HOME)/tools/pysrc
REQ_TXT    := $(PYSRC_DIR)/requirements.txt
VENV_DIR   := $(PYSRC_DIR)/.venv
PYTHON     := $(VENV_DIR)/bin/python
PIP        := $(VENV_DIR)/bin/pip
VENV_TOUCH := $(VENV_DIR)/.installed # Sentinel file

$(MCONF):
	$(Q)$(MAKE) $(silent) -C $(KCONFIG_PATH) NAME=mconf

$(CFG_BUILD_DIR):
	$(Q)mkdir $(CFG_BUILD_DIR)

# TODO: "rm -rf" looks so fucking dumb. Try disable mconf output.
export KCONFIG_CONFIG := $(DOT_CONFIG)
menuconfig: $(CFG_BUILD_DIR) $(MCONF) $(VENV_TOUCH)
	$(Q)$(MCONF) $(Kconfig)
	$(Q)$(PYTHON) $(AUTOGEN_CFG_SCRIPT) -i $(DOT_CONFIG) \
                  --out-c $(C_AUTOGEN_DIR)/ --out-v $(V_AUTOGEN_DIR)/  --out-s $(SCALA_AUTOGEN_DIR)/
	$(Q)rm -rf $(NPC_HOME)/include

.PHONY: menuconfig savedefconfig defconfig

distclean:
	$(Q)rm -rf $(CFG_BUILD_DIR)

# Help text used by make help
help:
	@echo  '  menuconfig	  - Update current config utilising a menu based program'

.PHONY: help distclean
