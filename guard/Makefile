# guard —— PC 本机 + 板级验证入口
#
# PC 侧（Verilator）：
#   make test        全套：金标单测 + 向量 + 一致性仿真 + demo + 板级 + 摘要格式
#   make golden      只跑 Python 金标单测
#   make vectors     只生成 RTL 向量到 build/vectors
#   make sim         只回放向量（需先有 vectors）
#   make edges / kw  手工边界集 / 关键词匹配器
#   make redact      合并+mask 替换一致性（1000 例）
#   make demo-check  RTL 检测 + 金标脱敏端到端（200 例）
#   make demo        端到端 demo（examples/sample.txt → 脱敏 + build/audit.json）
#   make bench       吞吐基准（1 字节/拍）
#   make lint        Verilator lint（规则层）
#
# 板级（盘古 200Pro+）：
#   make board-vectors  生成 build/board 向量（.in/.exp/.pace）
#   make board-sim     位级 UART 端到端（18 例，真实位定时）
#   make report-sim    审计摘要格式化穷举（0..255）
#   make board-lint    含板级桥 + PLL 仿真模型的 lint
#   （出位流 / 烧写不在这里：用 tools/build_guard.ps1 / tools/program_guard.ps1，
#     见 docs/board-bringup.md）
#
#   make clean

VERILATOR ?= verilator
PYTHON    ?= python3
BUILD     := build
# Verilator 的并行度。0 = 全部核；受限机器（或 5.020 的线程池 bug）可以 JOBS=2。
JOBS      ?= 0

KW_PKG := $(BUILD)/gen/l1_keywords_pkg.sv

$(KW_PKG): tools/gen_keywords.py host/golden/keywords.py
	$(PYTHON) tools/gen_keywords.py $(KW_PKG)

L1_RTL := $(KW_PKG) rtl/l1/l1_digit_engine.sv rtl/l1/l1_text_engines.sv \
          rtl/l1/l1_keyword_match.sv rtl/l1/l1_engine.sv
L1_TB  := sim/tb_l1_engine.sv
OBJ_L1 := $(BUILD)/obj_l1
TOP    := tb_l1_engine
VEC    := $(BUILD)/vectors

VFLAGS := --binary --timing -j $(JOBS) -O2 -Wall -Wno-fatal --top-module

.PHONY: all test golden vectors sim bench edges kw redact demo demo-check harness run serve cli-smoke lint clean tools board-vectors board-sim board-lint report-sim

all: test

tools:
	@$(VERILATOR) --version
	@$(PYTHON) -V

golden:
	$(PYTHON) -m unittest discover -s tests -v

vectors:
	$(PYTHON) tools/gen_vectors.py --out $(VEC) --n 1000

$(VEC)/manifest.txt: tools/gen_vectors.py host/golden/pii_rules.py host/corpus/synth.py
	$(MAKE) --no-print-directory vectors

$(OBJ_L1)/V$(TOP): $(L1_RTL) $(L1_TB)
	$(VERILATOR) $(VFLAGS) $(TOP) --Mdir $(OBJ_L1) -o V$(TOP) $(L1_RTL) $(L1_TB)

sim: $(OBJ_L1)/V$(TOP) $(VEC)/manifest.txt
	$(OBJ_L1)/V$(TOP) +dir=$(VEC)

BENCH_TB := sim/tb_l1_bench.sv
OBJ_BENCH := $(BUILD)/obj_bench

$(OBJ_BENCH)/Vtb_l1_bench: $(L1_RTL) $(BENCH_TB)
	$(VERILATOR) $(VFLAGS) tb_l1_bench --Mdir $(OBJ_BENCH) -o Vtb_l1_bench $(L1_RTL) $(BENCH_TB)

bench: $(OBJ_BENCH)/Vtb_l1_bench $(VEC)/bench.txt
	$(OBJ_BENCH)/Vtb_l1_bench +file=$(VEC)/bench.txt

edges:
	$(PYTHON) tools/gen_edges.py $(BUILD)/edges
	$(OBJ_L1)/V$(TOP) +dir=$(BUILD)/edges

KW := $(BUILD)/kw
$(KW)/manifest.txt: tools/gen_keyword_vectors.py host/golden/keywords.py host/corpus/synth.py
	$(PYTHON) tools/gen_keyword_vectors.py $(KW)

$(OBJ_L1)/Vtb_l1_keywords: $(L1_RTL) sim/tb_l1_keywords.sv
	$(VERILATOR) $(VFLAGS) tb_l1_keywords --Mdir $(OBJ_L1) -o Vtb_l1_keywords $(L1_RTL) sim/tb_l1_keywords.sv

kw: $(OBJ_L1)/Vtb_l1_keywords $(KW)/manifest.txt
	$(OBJ_L1)/Vtb_l1_keywords +dir=$(KW)

RED_RTL := $(L1_RTL) rtl/l1/l1_redact.sv
OBJ_RED := $(BUILD)/obj_red

$(OBJ_RED)/Vtb_l1_redact: $(RED_RTL) sim/tb_l1_redact.sv
	$(VERILATOR) $(VFLAGS) tb_l1_redact --Mdir $(OBJ_RED) -o Vtb_l1_redact $(RED_RTL) sim/tb_l1_redact.sv

redact: $(OBJ_RED)/Vtb_l1_redact $(VEC)/manifest.txt
	$(OBJ_RED)/Vtb_l1_redact +dir=$(VEC)

OBJ_DET := $(BUILD)/obj_detect

# 注意：C++ 源用 $(abspath) 传给 Verilator。Verilator 5.020 的 --build 会把
# 相对路径原样写进生成的 makefile，然后 make -C <Mdir> 就找不到文件了
# （5.040 没这个问题）。绝对路径两边都对。
CPP_DET := $(abspath sim/main_detect.cpp)
CPP_RED := $(abspath sim/main_redact.cpp)

$(OBJ_DET)/Vdetect: $(L1_RTL) sim/main_detect.cpp
	$(VERILATOR) --cc --exe --build -j $(JOBS) -O2 -Wall -Wno-fatal --top-module l1_engine \
	    --Mdir $(OBJ_DET) -o Vdetect $(L1_RTL) $(CPP_DET)

$(BUILD)/obj_redtop/Vredact: $(RED_RTL) sim/main_redact.cpp
	$(VERILATOR) --cc --exe --build -j $(JOBS) -O2 -Wall -Wno-fatal --top-module l1_redact_top \
	    --Mdir $(BUILD)/obj_redtop -o Vredact $(RED_RTL) $(CPP_RED)

redact-harness: $(BUILD)/obj_redtop/Vredact

harness: $(OBJ_DET)/Vdetect

run: redact-harness
	./run.sh demo

serve: redact-harness
	./run.sh serve

cli-smoke: redact-harness
	./run.sh demo -q | grep -q '\*'
	./run.sh file examples/clean.txt -q | grep -q '下周二的评审'
	@echo "PASS: guard CLI smoke"

demo: harness redact-harness
	$(PYTHON) tools/demo.py --in examples/sample.txt --rtl --policy token --json $(BUILD)/audit.json

demo-check: harness redact-harness
	$(PYTHON) tools/verify_demo.py $(VEC) 200

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module l1_engine $(L1_RTL)

# ---------------------------------------------------------------------------
# 板级（盘古 200Pro+）：串口进 → L1 脱敏 → 串口出
# ---------------------------------------------------------------------------
BOARD_RTL := $(KW_PKG) rtl/l1/l1_digit_engine.sv rtl/l1/l1_text_engines.sv \
             rtl/l1/l1_keyword_match.sv rtl/l1/l1_engine.sv rtl/l1/l1_redact.sv \
             rtl/board/guard_uart_baud.sv rtl/board/guard_uart_rx.sv \
             rtl/board/guard_uart_tx.sv rtl/board/guard_fifo.sv \
             rtl/board/guard_report.sv rtl/board/guard_uart_core.sv \
             rtl/board/guard_pll_sim.sv rtl/board/guard_board_top.sv
BOARD_VEC := $(BUILD)/board
OBJ_BOARD := $(BUILD)/obj_board

board-vectors: $(BOARD_VEC)/manifest.txt

$(BOARD_VEC)/manifest.txt: tools/gen_board_vectors.py host/golden/board_proto.py \
                           host/golden/redact.py host/golden/pii_rules.py \
                           host/corpus/synth.py examples/sample.txt examples/clean.txt
	$(PYTHON) tools/gen_board_vectors.py --out $(BOARD_VEC)

$(OBJ_BOARD)/Vtb_guard_uart: $(BOARD_RTL) sim/tb_guard_uart.sv
	$(VERILATOR) $(VFLAGS) tb_guard_uart --Mdir $(OBJ_BOARD) -o Vtb_guard_uart \
	    $(BOARD_RTL) sim/tb_guard_uart.sv

board-sim: $(OBJ_BOARD)/Vtb_guard_uart $(BOARD_VEC)/manifest.txt
	$(OBJ_BOARD)/Vtb_guard_uart +dir=$(BOARD_VEC)

$(OBJ_BOARD)/Vtb_guard_report: rtl/board/guard_report.sv sim/tb_guard_report.sv
	$(VERILATOR) $(VFLAGS) tb_guard_report --Mdir $(OBJ_BOARD) -o Vtb_guard_report \
	    rtl/board/guard_report.sv sim/tb_guard_report.sv

report-sim: $(OBJ_BOARD)/Vtb_guard_report
	$(OBJ_BOARD)/Vtb_guard_report

board-lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module guard_board_top $(BOARD_RTL)

test: harness redact-harness golden vectors sim edges kw redact demo-check cli-smoke board-sim report-sim

clean:
	rm -rf $(BUILD)