# Minimal bring-up image for the Pango board build.
# scripts/build_hello_image.py stages this directory, builds it with
# ARES_BOARD=1 and writes build/hello/coremark-style board image.
ARES_HOME := $(if $(ARES_HOME),$(ARES_HOME),$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..))

NAME = hello
SRCS = hello.c

include $(ARES_HOME)/tests/abstract-machine/Makefile
