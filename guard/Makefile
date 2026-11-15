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

L1_RTL := rtl/l1/l1_digit_engine.sv
L1_TB  := sim/tb_l1_digit_engine.sv
OBJ_L1 := $(BUILD)/obj_l1
VEC    := $(BUILD)/vectors

VFLAGS := --binary --timing -j 0 -O2 -Wall -Wno-fatal --top-module

.PHONY: all test golden vectors sim lint clean tools

all: test

tools:
	@$(VERILATOR) --version
	@$(PYTHON) -V

golden:
	$(PYTHON) -m unittest discover -s tests -v

vectors:
	$(PYTHON) tools/gen_vectors.py --out $(VEC) --n 200

$(VEC)/manifest.txt: tools/gen_vectors.py host/golden/pii_rules.py host/corpus/synth.py
	$(MAKE) --no-print-directory vectors

$(OBJ_L1)/Vtb_l1_digit_engine: $(L1_RTL) $(L1_TB)
	$(VERILATOR) $(VFLAGS) tb_l1_digit_engine --Mdir $(OBJ_L1) -o Vtb_l1_digit_engine $(L1_RTL) $(L1_TB)

sim: $(OBJ_L1)/Vtb_l1_digit_engine $(VEC)/manifest.txt
	$(OBJ_L1)/Vtb_l1_digit_engine +dir=$(VEC)

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module l1_digit_engine $(L1_RTL)

test: golden vectors sim

clean:
	rm -rf $(BUILD)
