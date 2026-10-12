ARES_HOME := $(if $(ARES_HOME),$(ARES_HOME),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..))
include $(ARES_HOME)/common.mk
NAME = klib
SRCS = $(shell find src/ -name "*.c")
include $(AM_HOME)/Makefile
