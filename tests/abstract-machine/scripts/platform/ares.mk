#=============================================================================
# ARES platform runtime
#=============================================================================
AM_SRCS := riscv/ares/start.S        \
           riscv/ares/memcpy.S       \
           riscv/ares/memset.S       \
           riscv/ares/bootloader.c   \
           riscv/ares/trm.c          \
           riscv/ares/ioe.c          \
           riscv/ares/cte.c          \
           riscv/ares/trap.S         \
           platform/dummy/vme.c      \
           platform/dummy/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
CFLAGS    += -I$(AM_HOME)/am/src/riscv/ares/include
# ARES_BOARD=1 selects the compact board layout (16K code + 16K data per hart)
# instead of the JYD simulation map (32K IROM + 256K DRAM 1 MiB apart).  The
# default stays ares-linker.ld so every simulation/TB image is unchanged.
LDSCRIPTS += $(AM_HOME)/scripts/$(if $(ARES_BOARD),ares-board-linker.ld,ares-linker.ld)
LDFLAGS   += --defsym=_program_start=0x80000000 --defsym=_entry_offset=0x0
LDFLAGS   += --gc-sections -e _start

MAINARGS_MAX_LEN     = 64
MAINARGS_PLACEHOLDER = the_insert-arg_rule_in_Makefile_will_insert_mainargs_here
CFLAGS += -DMAINARGS_MAX_LEN=$(MAINARGS_MAX_LEN) \
          -DMAINARGS_PLACEHOLDER=$(MAINARGS_PLACEHOLDER)

insert-arg: image
	@python3 $(AM_HOME)/tools/insert-arg.py $(IMAGE).bin \
	         $(MAINARGS_MAX_LEN) $(MAINARGS_PLACEHOLDER) "$(mainargs)"

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

# Hand the image to the ARES Verilator simulation.  Extra simulator arguments
# can be passed with SIM_ARGS (for example SIM_ARGS=--itrace).
run: insert-arg
	@$(MAKE) -s -C $(SIM_HOME) run PROGRAM=$(IMAGE).bin ARGS="$(SIM_ARGS)"

.PHONY: insert-arg
