/*=============================================================================
 * ARES multi-hart AMP linker script
 *-----------------------------------------------------------------------------
 * Same IROM/DRAM split as ares-linker.ld, but the DRAM window is one 32 KiB
 * per-hart region:
 *
 *   IROM  0x8000_0000  32 KiB   shared/private instruction image
 *   DRAM  0x8010_0000  32 KiB   hart0 private data, rodata, bss and stack
 *
 * The core adds DATA_OFFSET = hart_id * 0x8000 to cacheable DRAM accesses,
 * so hart1 uses 0x8010_8000..0x8010_FFFF, hart2 0x8011_0000.., etc.  The
 * linker's _stack_top is therefore the end of one region, not the end of the
 * 256 KiB physical DRAM.
 *
 * The image is replicated into each hart's 32 KiB region by the simulation
 * loader (and by a future Pango boot loader/BRAM init).
 *===========================================================================*/

PHDRS {
  boot   PT_LOAD; /* RX */
  text   PT_LOAD; /* RX */
  data   PT_LOAD; /* RW */
  bss    PT_LOAD; /* RW */
  rodata PT_LOAD; /* R  */
}

MEMORY {
  irom (RX): ORIGIN = 0x80000000, LENGTH = 32K
  dram (RW): ORIGIN = 0x80100000, LENGTH = 32K
}

REGION_ALIAS("REGION_BOOT", irom);

REGION_ALIAS("REGION_TEXT", irom);
REGION_ALIAS("REGION_RODATA", dram);
REGION_ALIAS("REGION_DATA", dram);
REGION_ALIAS("REGION_BSS", dram);

REGION_ALIAS("REGION_CODE_LMA", irom);
REGION_ALIAS("REGION_DATA_LMA", dram);

ENTRY(_start)

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
  } > REGION_TEXT AT> REGION_CODE_LMA : text

  .rodata : {
    *(.rodata*)
    *(.srodata*)
  } > REGION_RODATA AT> REGION_DATA_LMA : rodata

  .data : {
    *(.data*)
    *(.sdata*)
  } > REGION_DATA AT> REGION_DATA_LMA : data

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
