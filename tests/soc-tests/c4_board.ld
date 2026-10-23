OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  IROM (rx) : ORIGIN = 0x80000000, LENGTH = 32K
  DRAM (rw) : ORIGIN = 0x80100000, LENGTH = 256K
}
SECTIONS {
  .reset 0x80000000 : { KEEP(*(.reset)) } > IROM
  .trap  0x80000100 : { KEEP(*(.trap)) } > IROM
  .text  0x80000200 : { *(.text*) *(.rodata*) } > IROM
  .data  0x80100010 : { *(.data*) } > DRAM
  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
