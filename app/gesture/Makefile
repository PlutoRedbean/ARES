# =============================================================================
# ARES-L application 2 -- gesture recognition on the ARES nine-stage core.
#
#   make lint            Verilator lint of the SoC
#   make lint-board      Verilator lint of the camera board top
#   make sim             build the Verilator SoC model
#   make fw-sim          detector self-test image (simulation entry)
#   make fw-cam          camera + gesture image (board entry, RPS head)
#   make run-sim         run the self-test image and print the UART log
#   make track-test      host unit tests for the motion tracker
#   make web-build       build the Three.js controller (pnpm)
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
UART_DIV      ?= 8
DET_IMG_COUNT ?= 1
CFLAGS  := $(ARCH) -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
           -mno-relax -msmall-data-limit=0 -Ifirmware/common -Ifirmware/app \
           -DUART_DIV=$(UART_DIV) -DDET_IMG_COUNT=$(DET_IMG_COUNT)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -mno-relax -T firmware/common/linker.ld

# ----------------------------------------------------------------- RTL files
# Identical core package and miniTensor to the language-model project; the
# gesture tree only adds the OV5640 capture front end and its board top.
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

CAM_RTL := \
  rtl/cam/video_dvp_rgb565.v rtl/cam/cam_cap.v rtl/cam/cam_fifo.v rtl/cam/cam_store.v

RTL_ALL   := rtl/common/ares_pkg.sv $(CORE_RTL) $(MT_RTL) $(SOC_RTL) $(CAM_RTL)
RTL_BOARD := $(RTL_ALL) rtl/board/board_gesture.v
TB        := sim/rtl/tb_soc.sv

# ARES_SIM_CLKDIV swaps the Pango clock-divider primitive for a behavioural
# /2 divider so the board top lints without the vendor library.
VFLAGS := --language 1800-2017 -D__VERILATOR__ -DARES_SIM_CLKDIV -Wall -Wno-fatal \
          -Irtl/core/include -Irtl/common -Irtl/minitensor

# -------------------------------------------------------------- firmware sets
COMMON_SRC := firmware/common/start.S firmware/common/runtime.c
MT_SRC     := firmware/app/mt.c firmware/app/mt_net.c

SIM_SRC := $(COMMON_SRC) $(MT_SRC) firmware/app/mt_detect.c \
           firmware/app/mt_track.c firmware/app/main.c
CAM_SRC := $(COMMON_SRC) $(MT_SRC) firmware/app/mt_detect.c \
           firmware/app/mt_track.c firmware/app/mt_cam.c firmware/app/main_cam.c

define build_image
	mkdir -p build/fw/$(1)
	rm -f build/fw/$(1)/*.o
	for f in $(2); do \
	  $(CC) $(CFLAGS) $(3) -Ifirmware/app -c $$f -o build/fw/$(1)/$$(basename $$f).o || exit 1; \
	done
	$(CC) $(LDFLAGS) build/fw/$(1)/*.o -lgcc -o build/fw/$(1)/app.elf
	$(OBJCOPY) -O binary build/fw/$(1)/app.elf build/fw/$(1)/app.bin
	$(PY) sim/tools/bin2hex.py build/fw/$(1)/app.bin build/fw/$(1)/app.hex
	$(SIZE) build/fw/$(1)/app.elf
endef

.PHONY: all lint lint-board sim fw fw-sim fw-cam run-sim track-test web-build web-dev clean help

all: lint

help:
	@sed -n '2,15p' Makefile

lint:
	$(VERILATOR) --lint-only $(VFLAGS) $(RTL_ALL) --top-module ares_soc

lint-board:
	$(VERILATOR) --lint-only $(VFLAGS) $(RTL_BOARD) --top-module board_gesture

sim:
	mkdir -p build/obj_soc
	$(VERILATOR) --binary --timing $(VFLAGS) \
	  $(RTL_ALL) $(TB) --top-module tb_soc --Mdir build/obj_soc -o Vtb_soc

fw: fw-cam

fw-sim:
	$(call build_image,sim,$(SIM_SRC),)

fw-cam:
	$(call build_image,cam,$(CAM_SRC),-DRPS_WEIGHTS)

run-sim: sim fw-sim
	./build/obj_soc/Vtb_soc +DDR=build/fw/sim/app.hex >/dev/null 2>&1 || true
	@echo "--- UART ---"
	@cat build/uart.log

# The tracker is plain C11: the same mt_track.c runs on the host.
track-test:
	mkdir -p build
	gcc -O2 -std=c11 -Wall -Wextra -Ifirmware/common -Ifirmware/app \
	  tests/test_track.c firmware/app/mt_track.c -o build/test_track
	./build/test_track

web-build:
	cd web && pnpm install --frozen-lockfile && pnpm build

web-dev:
	cd web && pnpm dev

clean:
	rm -rf build
