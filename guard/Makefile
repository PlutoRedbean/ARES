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

KW_PKG := $(BUILD)/gen/l1_keywords_pkg.sv

$(KW_PKG): tools/gen_keywords.py host/golden/keywords.py
	$(PYTHON) tools/gen_keywords.py $(KW_PKG)

L1_RTL := $(KW_PKG) rtl/l1/l1_digit_engine.sv rtl/l1/l1_text_engines.sv \
          rtl/l1/l1_keyword_match.sv rtl/l1/l1_engine.sv
L1_TB  := sim/tb_l1_engine.sv
OBJ_L1 := $(BUILD)/obj_l1
TOP    := tb_l1_engine
VEC    := $(BUILD)/vectors

VFLAGS := --binary --timing -j 0 -O2 -Wall -Wno-fatal --top-module

.PHONY: all test golden vectors sim bench edges kw redact demo demo-check harness lint clean tools

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

$(OBJ_DET)/Vdetect: $(L1_RTL) sim/main_detect.cpp
	$(VERILATOR) --cc --exe --build -j 0 -O2 -Wall -Wno-fatal --top-module l1_engine \
	    --Mdir $(OBJ_DET) -o Vdetect $(L1_RTL) sim/main_detect.cpp

$(BUILD)/obj_redtop/Vredact: $(RED_RTL) sim/main_redact.cpp
	$(VERILATOR) --cc --exe --build -j 0 -O2 -Wall -Wno-fatal --top-module l1_redact_top \
	    --Mdir $(BUILD)/obj_redtop -o Vredact $(RED_RTL) sim/main_redact.cpp

redact-harness: $(BUILD)/obj_redtop/Vredact

harness: $(OBJ_DET)/Vdetect

demo: harness redact-harness
	$(PYTHON) tools/demo.py --in examples/sample.txt --rtl --policy token --json $(BUILD)/audit.json

demo-check: harness redact-harness
	$(PYTHON) tools/verify_demo.py $(VEC) 200

lint:
	$(VERILATOR) --lint-only -Wall -Wno-fatal --top-module l1_engine $(L1_RTL)

test: golden vectors sim edges kw redact demo-check

clean:
	rm -rf $(BUILD)
