# guard —— 本机开发平台入口
#
#   make test     金标单测 + 生成向量 + Verilator 一致性仿真
#   make golden   只跑 Python 金标单测
#   make vectors  只生成 RTL 向量到 build/vectors
#   make lint     Verilator lint（本工程新增 RTL）
#   make clean

VERILATOR ?= verilator
PYTHON    ?= python3
BUILD     := build

L1_RTL := rtl/l1/l1_digit_engine.sv rtl/l1/l1_text_engines.sv rtl/l1/l1_engine.sv
L1_TB  := sim/tb_l1_engine.sv
OBJ_L1 := $(BUILD)/obj_l1
TOP    := tb_l1_engine
VEC    := $(BUILD)/vectors

VFLAGS := --binary --timing -j 0 -O2 -Wall -Wno-fatal --top-module

.PHONY: all test golden vectors sim bench edges lint clean tools

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

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module l1_engine $(L1_RTL)

test: golden vectors sim edges

clean:
	rm -rf $(BUILD)
