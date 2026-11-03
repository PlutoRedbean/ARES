# =============================================================================
# ARES-L application 1 -- language model on the ARES nine-stage core.
#
#   make lint            Verilator lint of the SoC
#   make sim             build the Verilator SoC model
#   make fw-a0-cpu       A0 char-GRU on the CPU        (int16 Q15)
#   make fw-a0-mt        A0 char-GRU on miniTensor     (int8 GEMV)
#   make fw-h112         H112 word-level seq2seq GRU   (deployed image)
#   make fw-qa           QA retrieval knowledge base
#   make run-h112        run one image in the simulator and print the UART log
#   make clean
#
# UART_DIV defaults to the 100 MHz simulation divisor; pass UART_DIV=234 for
# the 27 MHz board build.
# =============================================================================
SHELL        := /bin/bash
PY           ?= python3
RISCV_PREFIX ?= riscv64-unknown-elf-
CC           := $(RISCV_PREFIX)gcc
OBJCOPY      := $(RISCV_PREFIX)objcopy
SIZE         := $(RISCV_PREFIX)size
VERILATOR    ?= verilator

ARCH    := -march=rv32im_zicsr_zifencei -mabi=ilp32
UART_DIV ?= 8
CFLAGS  := $(ARCH) -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
           -mno-relax -msmall-data-limit=0 -Ifirmware/common -Ifirmware/app \
           -DUART_DIV=$(UART_DIV)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -mno-relax -T firmware/common/linker.ld

# ----------------------------------------------------------------- RTL files
# The core package is the ARES mainline core copied verbatim from
# /home/ccy/Documents/qs/ARES/rtl/pipeline/core (only Mundus_PC.v carries the
# application line entry point).
CORE_RTL := \
  rtl/core/Mundus.sv \
  rtl/core/myCPU.v rtl/core/Mundus_PC.v rtl/core/RegisterFile.v \
  rtl/core/BimodalRas.v rtl/core/ReturnAddressStack.v \
  rtl/core/Divider.v rtl/core/Multplier.v rtl/core/div.v rtl/core/mult.v \
  rtl/core/DCacheData_BRAM.v rtl/core/DCacheTag_BRAM.v rtl/core/DCacheLru_BRAM.v \
  rtl/core/icache/pipeline_icache.v

MT_RTL := \
  rtl/minitensor/interface/core_v_xif.sv \
  rtl/minitensor/common/minitensor_pkg.sv \
  rtl/minitensor/tensor/tensor_pkg.sv \
  rtl/minitensor/vector/vpu_pkg.sv \
  rtl/minitensor/vector/vpu_vector_regfile.sv \
  rtl/minitensor/vector/vpu_vector_alu.sv \
  rtl/minitensor/control/vpu_vector_controller.sv \
  rtl/minitensor/tensor/MXU/Systolic_Array/tensor_pe.sv \
  rtl/minitensor/tensor/MXU/Systolic_Array/tensor_systolic_array.sv \
  rtl/minitensor/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv \
  rtl/minitensor/tensor/tensor_controller.sv \
  rtl/minitensor/tensor/Epilogue/tensor_epilogue_core.sv \
  rtl/minitensor/tensor/Epilogue/tensor_epilogue_controller.sv \
  rtl/minitensor/memory/unified_buffer.sv \
  rtl/minitensor/memory/vpu_dma.sv \
  rtl/minitensor/top/mt_fsm.sv \
  rtl/minitensor/top/mini_tensor_top.sv

SOC_RTL := \
  rtl/soc/mt/mt_cmd_fifo.sv rtl/soc/mt/mt_cvxif_shim.sv \
  rtl/soc/mt/mt_dma_l2_bridge.sv rtl/soc/mt/mt_cluster.sv \
  rtl/soc/ares_core_complex.sv rtl/soc/ares_icache_refill.sv rtl/soc/ares_perip_bridge.sv \
  rtl/soc/ares_clint.sv rtl/soc/ares_uart.sv rtl/soc/ares_gpio.sv \
  rtl/soc/ares_mmio_bus.sv rtl/soc/ares_l2.sv \
  rtl/soc/ddr/ddr3_model.sv rtl/soc/ares_soc.sv

RTL_ALL := rtl/common/ares_pkg.sv $(CORE_RTL) $(MT_RTL) $(SOC_RTL)
TB      := sim/rtl/tb_soc.sv

VFLAGS := --language 1800-2017 -D__VERILATOR__ -Wall -Wno-fatal \
          -Irtl/core/include -Irtl/common -Irtl/minitensor

# -------------------------------------------------------------- firmware sets
COMMON_SRC := firmware/common/start.S firmware/common/runtime.c

A0_CPU_SRC := $(COMMON_SRC) firmware/app/llm_model.c firmware/app/llm.c firmware/app/main.c
A0_MT_SRC  := $(COMMON_SRC) firmware/app/mt.c firmware/app/mt_net.c \
              firmware/app/llm_mt_model.c firmware/app/llm_mt_demo.c firmware/app/main_mt.c
H112_SRC   := $(COMMON_SRC) firmware/app/seq_chat.c firmware/app/main_seq.c
QA_SRC     := $(COMMON_SRC) firmware/app/cpu_qa.c firmware/app/main_cpu.c
INTENT_SRC := $(COMMON_SRC) firmware/app/intent_chat.c firmware/app/main_intent.c
RULE_SRC   := $(COMMON_SRC) firmware/app/chat_rule.c firmware/app/main_rule.c

define build_image
	mkdir -p build/fw/$(1)
	rm -f build/fw/$(1)/*.o
	for f in $(2); do \
	  $(CC) $(CFLAGS) -c $$f -o build/fw/$(1)/$$(basename $$f).o || exit 1; \
	done
	$(CC) $(LDFLAGS) build/fw/$(1)/*.o -lgcc -o build/fw/$(1)/app.elf
	$(OBJCOPY) -O binary build/fw/$(1)/app.elf build/fw/$(1)/app.bin
	$(PY) sim/tools/bin2hex.py build/fw/$(1)/app.bin build/fw/$(1)/app.hex
	$(SIZE) build/fw/$(1)/app.elf
endef

.PHONY: all lint lint-board sim fw fw-a0-cpu fw-a0-mt fw-h112 fw-qa fw-intent fw-rule \
        run-h112 run-a0-mt clean help

all: lint

help:
	@sed -n '2,14p' Makefile

lint:
	$(VERILATOR) --lint-only $(VFLAGS) $(RTL_ALL) --top-module ares_soc

lint-board:
	$(VERILATOR) --lint-only $(VFLAGS) $(RTL_ALL) rtl/board/board_cpu.v \
	  --top-module board_cpu

sim:
	mkdir -p build/obj_soc
	$(VERILATOR) --binary --timing $(VFLAGS) \
	  $(RTL_ALL) $(TB) --top-module tb_soc --Mdir build/obj_soc -o Vtb_soc

fw: fw-h112

fw-a0-cpu:
	$(call build_image,a0_cpu,$(A0_CPU_SRC))
fw-a0-mt:
	$(call build_image,a0_mt,$(A0_MT_SRC))
fw-h112:
	$(call build_image,h112,$(H112_SRC))
fw-qa:
	$(call build_image,qa,$(QA_SRC))
fw-intent:
	$(call build_image,intent,$(INTENT_SRC))
fw-rule:
	$(call build_image,rule,$(RULE_SRC))

run-h112: sim fw-h112
	./build/obj_soc/Vtb_soc +DDR=build/fw/h112/app.hex >/dev/null 2>&1 || true
	@echo "--- UART ---"
	@cat build/uart.log

run-a0-mt: sim fw-a0-mt
	./build/obj_soc/Vtb_soc +DDR=build/fw/a0_mt/app.hex >/dev/null 2>&1 || true
	@echo "--- UART ---"
	@cat build/uart.log

clean:
	rm -rf build
