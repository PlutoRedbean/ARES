OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss : { *(.bss*) *(COMMON) }
  __bss_end = .;
  . = ALIGN(16);
  PROVIDE(__global_pointer$ = . + 0x800);
  /* Keep every CPU data address below 0x8010_0000: that is the lower bound of
   * the ARES core's L1 D-cache window, and the application baseline keeps the
   * data view uncached so the CPU and the miniTensor DMA always agree.  The
   * 1 MiB board DDR therefore ends at 0x8010_0000 and the stack starts below
   * it, leaving room for the 152 KiB H112 image. */
  PROVIDE(__stack_top = 0x800F0000);
}