ARES_HOME := $(if $(ARES_HOME),$(ARES_HOME),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..))
include $(ARES_HOME)/common.mk
NAME     := am
SRCS      = $(addprefix src/, $(AM_SRCS))
INC_PATH += $(AM_HOME)/am/src

include $(AM_HOME)/Makefile
