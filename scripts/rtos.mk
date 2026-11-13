# RTOS firmware and simulations never write build/pipeline/ or rebuild CoreMark.
.PHONY: rtos-image pipeline-rtos pipeline-rtos-board-sim pipeline-rtos-pango-lint
rtos-image:
	@$(MAKE) -C $(ARES_HOME)/rtthread-nano/rt-thread/bsp/ARES
	@python3 scripts/pipeline_image.py --elf build/rtos/ares-rtos.elf \
	    --irom build/rtos/irom.hex --dram build/rtos/dram.hex --json build/rtos/image.json
	@python3 scripts/rtos_sim_filelist.py

RTOS_BOARD ?= 0
pipeline-rtos: rtos-image
	@CCACHE_DISABLE=1 verilator --binary --timing -j 4 --language 1800-2017 \
	    -U__VERILATOR__ -Wno-fatal --top-module tb_pipeline_rtos -GBOARD=$(RTOS_BOARD) \
	    -f build/rtos/sim.f rtl/pipeline/test/tb_pipeline_rtos.sv \
	    --Mdir $(ARES_HOME)/build/rtos_sim$(RTOS_BOARD) -o run
	@$(ARES_HOME)/build/rtos_sim$(RTOS_BOARD)/run

pipeline-rtos-board-sim:
	@$(MAKE) pipeline-rtos RTOS_BOARD=1

pipeline-rtos-pango-lint: rtos-image
	@verilator --lint-only --timing -U__VERILATOR__ -Wall -Wno-fatal \
	    --top-module pipeline_rtos_board_top -f build/rtos/sim.f

.PHONY: pipeline-irq-test
pipeline-irq-test: rtos-image
	@mkdir -p build/rtos_irq
	@riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
	    -Os -ffreestanding -fno-builtin -nostdlib -nostartfiles -static \
	    -Irtthread-nano/rt-thread/bsp/ARES/include \
	    -Irtthread-nano/rt-thread/libcpu/risc-v/common \
	    -Wl,-T,rtthread-nano/rt-thread/bsp/ARES/linker.ld \
	    rtthread-nano/rt-thread/bsp/ARES/start.S rtthread-nano/rt-thread/bsp/ARES/trap.S \
	    rtl/pipeline/test/irq_test.c -lgcc -o build/rtos_irq/test.elf
	@python3 scripts/pipeline_image.py --elf build/rtos_irq/test.elf \
	    --irom build/rtos_irq/irom.hex --dram build/rtos_irq/dram.hex --json build/rtos_irq/image.json
	@CCACHE_DISABLE=1 verilator --binary --timing -j 4 -U__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_irq -f build/rtos/sim.f \
	    rtl/pipeline/test/tb_pipeline_rtos.sv rtl/pipeline/test/tb_pipeline_irq.sv \
	    --Mdir $(ARES_HOME)/build/rtos_irq/model -o run
	@$(ARES_HOME)/build/rtos_irq/model/run

.PHONY: pipeline-timer-irq-test
pipeline-timer-irq-test:
	@mkdir -p build/rtos_irq
	@iverilog -g2012 -DJYD_FAST_TIMER -Irtl/pipeline/include \
	    -Irtl/pipeline/core/vsrc/include -s tb_timer_irq -o build/rtos_irq/timer \
	    rtl/pipeline/soc/pango/pipeline_cdc.v rtl/pipeline/soc/jyd/counter.v \
	    rtl/pipeline/test/tb_timer_irq.sv
	@vvp build/rtos_irq/timer

pipeline-irq-test: pipeline-timer-irq-test

.PHONY: rtos-shell-image pipeline-rtos-shell-build pipeline-rtos-shell
rtos-shell-image:
	@$(MAKE) -C $(ARES_HOME)/rtthread-nano/rt-thread/bsp/ARES PROFILE=shell OUT=$(ARES_HOME)/build/rtos_shell
	@python3 scripts/pipeline_image.py --elf build/rtos_shell/ares-rtos.elf \
	    --irom build/rtos_shell/irom.hex --dram build/rtos_shell/dram.hex --json build/rtos_shell/image.json
	@python3 scripts/rtos_sim_filelist.py build/rtos_shell/sim.f

pipeline-rtos-shell-build: rtos-shell-image
	@CCACHE_DISABLE=1 verilator --cc --exe --build --timing -j 4 -U__VERILATOR__ -Wno-fatal \
	    --top-module tb_pipeline_shell -f build/rtos_shell/sim.f \
	    rtl/pipeline/board/pipeline_uart_rx_fifo.v \
	    rtl/pipeline/board/pipeline_rtos_shell_board_top.v rtl/pipeline/test/tb_pipeline_shell.sv \
	    $(ARES_HOME)/rtl/pipeline/test/sim_shell_main.cpp \
	    --Mdir $(ARES_HOME)/build/rtos_shell/model -o run

pipeline-rtos-shell: pipeline-rtos-shell-build
	@$(ARES_HOME)/build/rtos_shell/model/run

.PHONY: pipeline-rtos-shell-test pipeline-rtos-shell-fifo-test
pipeline-rtos-shell-fifo-test:
	@mkdir -p build/rtos_shell
	@iverilog -g2012 -s tb_uart_rx_fifo -o build/rtos_shell/rx_fifo \
	    rtl/pipeline/board/pipeline_uart_rx_fifo.v rtl/pipeline/test/tb_uart_rx_fifo.sv
	@vvp build/rtos_shell/rx_fifo

pipeline-rtos-shell-test: pipeline-rtos-shell-build pipeline-rtos-shell-fifo-test
	@python3 scripts/test_rtos_shell.py

.PHONY: pipeline-rtos-shell-pango-lint
pipeline-rtos-shell-pango-lint: rtos-shell-image
	@verilator --lint-only --timing -U__VERILATOR__ -Wall -Wno-fatal \
	    --top-module pipeline_rtos_shell_board_top -f build/rtos_shell/sim.f \
	    rtl/pipeline/board/pipeline_uart_rx_fifo.v rtl/pipeline/board/pipeline_rtos_shell_board_top.v

.PHONY: rtos-amp-image pipeline-rtos-amp-build pipeline-rtos-amp pipeline-rtos-amp-test \
        pipeline-rtos-amp-pango-prep pipeline-rtos-amp-pango-lint
rtos-amp-image:
	@$(MAKE) -C $(ARES_HOME)/rtthread-nano/rt-thread/bsp/ARES PROFILE=amp
	@python3 scripts/pipeline_image.py --elf build/rtos_amp/ares-rtos.elf \
	    --irom-kib 64 --dram-kib 128 --irom build/rtos_amp/irom.hex \
	    --dram build/rtos_amp/dram.hex --json build/rtos_amp/image.json
	@python3 scripts/pipeline_image.py --elf build/rtos_amp/worker.elf \
	    --dram-kib 32 --irom build/rtos_amp/worker_irom.hex \
	    --dram build/rtos_amp/worker_dram.hex --json build/rtos_amp/worker.json

pipeline-rtos-amp-build: rtos-amp-image
	@sed 's@rtl/pipeline/board/pipeline_pll.v@rtl/pipeline/board/pipeline_pll_sim.v@' \
	    rtl/pipeline/pipeline_amp_pango.f > build/rtos_amp/sim.f
	@CCACHE_DISABLE=1 verilator --cc --exe --build --timing -j 6 -U__VERILATOR__ \
	    -DARES_RTOS_AMP -DVIDEO_SIM -Wno-fatal --top-module tb_pipeline_shell \
	    -f build/rtos_amp/sim.f -f rtl/pipeline/pipeline_rtos_amp_extra.f \
	    rtl/video/sim/GTP_IOCLKDIV_E2.v \
	    rtl/pipeline/test/tb_pipeline_shell.sv $(ARES_HOME)/rtl/pipeline/test/sim_shell_main.cpp \
	    --Mdir $(ARES_HOME)/build/rtos_amp/model -o run

pipeline-rtos-amp: pipeline-rtos-amp-build
	@$(ARES_HOME)/build/rtos_amp/model/run

pipeline-rtos-amp-test: pipeline-rtos-amp-build
	@python3 scripts/test_rtos_amp.py

pipeline-rtos-amp-pango-prep: rtos-amp-image
	@python3 app/llm/tools/pango_prep.py --source-root app/gesture --output-dir build/rtos_amp/pango
	@sed 's@^app/gesture/rtl/\(.*\)\.sv$$@build/rtos_amp/pango/rtl/\1.v@' \
	    rtl/pipeline/pipeline_rtos_amp_extra.f > build/rtos_amp/pango_extra.f

pipeline-rtos-amp-pango-lint: pipeline-rtos-amp-pango-prep
	@sed 's@rtl/pipeline/board/pipeline_pll.v@rtl/pipeline/board/pipeline_pll_sim.v@' \
	    rtl/pipeline/pipeline_amp_pango.f > build/rtos_amp/pango_lint.f
	@verilator --lint-only --timing -U__VERILATOR__ -DARES_FPGA -Wno-fatal \
	    --top-module pipeline_rtos_amp_board_top -f build/rtos_amp/pango_lint.f \
	    -f build/rtos_amp/pango_extra.f rtl/video/sim/GTP_IOCLKDIV_E2.v
