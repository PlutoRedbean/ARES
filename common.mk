ifndef MUNDUS_HOME
  $(error MUNDUS_HOME is not set. Please run: export MUNDUS_HOME=/path/to/project)
endif

YSYX_HOME    := $(MUNDUS_HOME)
NEMU_HOME    := $(MUNDUS_HOME)/nemu
NPC_HOME     := $(MUNDUS_HOME)/npc
AM_HOME      := $(MUNDUS_HOME)/abstract-machine
NVBOARD_HOME := $(MUNDUS_HOME)/nvboard
SOC_HOME     := $(MUNDUS_HOME)/ysyxSoC
