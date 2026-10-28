/*=============================================================================
 * ARES board linker script (ARCH = riscv32-ares, ARES_BOARD=1)
 *-----------------------------------------------------------------------------
 * Compact layout for the Pango board build.  The simulation linker
 * (ares-linker.ld) keeps the JYD memory map: code at 0x8000_0000 (fetch-only
 * IROM) and writable data 1 MiB higher at 0x8010_0000 (DRAM).  The flat
 * readmemh image is dense, so that 1 MiB hole is written out as zeros and the
 * image grows to ~1 MiB for an 8 KiB program.
 *
 * The L2 SoC has no fetch-only window: both the I and D ports of
 * ares_2core_frontend_l2_top reach the same backing memory, so code can live
 * next to the writable region.  Read-only data still belongs in the data
 * region, because hart1's *data* accesses are offset by C1_DATA_OFFSET in
 * hardware: a constant fetched from the code window would be read at
 * pc_address + offset by hart1.  Keeping .rodata in the data region means the
 * per-hart copy below covers it.
 *
 *   irom  0x8000_0000  16 KiB   .boot / .text            (shared by both harts)
 *   dram  0x8000_4000  16 KiB   .rodata / .data / .bss / stack (hart0)
 *   dram  0x8000_8000  16 KiB   hart1 copy of the same region
 *                               (C1_DATA_OFFSET = 0x4000)
 *
 * Backing memory window: 0x8000_0000..0x8000_bfff (48 KiB), one 128-bit BRAM
 * initialised by a single $readmemh file (see scripts/build_coremark_image.py
 * --board).  The stack top is the end of the per-hart 16 KiB data region, so
 * hart1's stack ends at 0x8000_c000.
 *
 * Not valid for student_top (JYD): its data port does not decode 0x8000_0000,
 * so the default ares-linker.ld must be used there.
 *===========================================================================*/

OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS {
  boot   PT_LOAD;
  text   PT_LOAD;
  rodata PT_LOAD;
  data   PT_LOAD;
  bss    PT_LOAD;
}

MEMORY {
  irom (RX): ORIGIN = 0x80000000, LENGTH = 16K
  dram (RW): ORIGIN = 0x80004000, LENGTH = 16K
}

REGION_ALIAS("REGION_BOOT", irom);
REGION_ALIAS("REGION_TEXT", irom);
REGION_ALIAS("REGION_RODATA", dram);
REGION_ALIAS("REGION_DATA", dram);
REGION_ALIAS("REGION_BSS", dram);

SECTIONS {
  _irom_start = ORIGIN(irom);
  _dram_start = ORIGIN(dram);

  /* _program_start and _entry_offset are defined in LDFLAGS */
  . = _program_start + _entry_offset;

  .boot : {
    *(entry)
    *(.boot)
  } > REGION_BOOT : boot

  .text : {
    *(.text*)
  } > REGION_TEXT : text

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > REGION_RODATA : rodata

  .data : {
    *(.data*)
    *(.sdata*)
  } > REGION_DATA : data

  .bss : {
    *(.bss*)
    *(.sbss*)
    *(.scommon)
  } > REGION_BSS : bss

  _text_len   = SIZEOF(.text);
  _rodata_len = SIZEOF(.rodata);
  _data_len   = SIZEOF(.data);
  _bss_len    = SIZEOF(.bss);

  _text_lma_start   = LOADADDR(.text);
  _rodata_lma_start = LOADADDR(.rodata);
  _data_lma_start   = LOADADDR(.data);

  _text_vma_start   = ADDR(.text);
  _rodata_vma_start = ADDR(.rodata);
  _data_vma_start   = ADDR(.data);
  _bss_vma_start    = ADDR(.bss);

  . = ALIGN(8);
  _heap_start = .;

  _dram_end = ORIGIN(dram) + LENGTH(dram);

  _stack_top     = _dram_end;
  _stack_pointer = _stack_top;
}
