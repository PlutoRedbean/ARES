VERILATOR ?= verilator
OBJ_DIR    ?= $(CURDIR)/obj_dir
COMMON_FLAGS := --binary --timing --Wall --Wno-fatal

VECTOR_SOURCES := \
	$(CURDIR)/rtl/vector/vpu_pkg.sv \
	$(CURDIR)/rtl/vector/vpu_vector_regfile.sv \
	$(CURDIR)/rtl/vector/vpu_vector_alu.sv \
	$(CURDIR)/rtl/control/vpu_vector_controller.sv \
	$(CURDIR)/tb/control/tb_vpu_vector_controller.sv

UB_SOURCES := \
	$(CURDIR)/rtl/memory/unified_buffer.sv \
	$(CURDIR)/tb/memory/tb_unified_buffer.sv

DMA_SOURCES := \
	$(CURDIR)/rtl/memory/unified_buffer.sv \
	$(CURDIR)/rtl/memory/vpu_dma.sv \
	$(CURDIR)/tb/memory/tb_vpu_dma.sv

.PHONY: sim regress clean vector-sim vrf-sim ub-sim dma-sim

sim: regress

regress:
	$(MAKE) vector-sim
	$(MAKE) vrf-sim
	$(MAKE) ub-sim
	$(MAKE) dma-sim

vector-sim:
	mkdir -p $(OBJ_DIR)/vector
	CCACHE_DISABLE=1 $(VERILATOR) $(COMMON_FLAGS) $(VERILATOR_FLAGS) \
		--Mdir $(OBJ_DIR)/vector --top-module tb_vpu_vector_controller $(VECTOR_SOURCES)
	$(OBJ_DIR)/vector/Vtb_vpu_vector_controller

vrf-sim:
	mkdir -p $(OBJ_DIR)/vrf
	CCACHE_DISABLE=1 $(VERILATOR) $(COMMON_FLAGS) --Mdir $(OBJ_DIR)/vrf \
		--top-module tb_vpu_vector_regfile \
		$(CURDIR)/rtl/vector/vpu_vector_regfile.sv \
		$(CURDIR)/tb/vector/tb_vpu_vector_regfile.sv
	$(OBJ_DIR)/vrf/Vtb_vpu_vector_regfile

ub-sim:
	mkdir -p $(OBJ_DIR)/ub
	CCACHE_DISABLE=1 $(VERILATOR) $(COMMON_FLAGS) --Mdir $(OBJ_DIR)/ub \
		--top-module tb_unified_buffer $(UB_SOURCES)
	$(OBJ_DIR)/ub/Vtb_unified_buffer

dma-sim:
	mkdir -p $(OBJ_DIR)/dma
	CCACHE_DISABLE=1 $(VERILATOR) $(COMMON_FLAGS) --Mdir $(OBJ_DIR)/dma \
		--top-module tb_vpu_dma $(DMA_SOURCES)
	$(OBJ_DIR)/dma/Vtb_vpu_dma

clean:
	rm -rf $(OBJ_DIR)
