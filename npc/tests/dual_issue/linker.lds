OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;

  .text : ALIGN(8) {
    *(.text.init)
    *(.text .text.*)
  }

  .rodata : ALIGN(8) {
    *(.rodata .rodata.*)
  }

  . = 0x80100000;

  .data : ALIGN(8) {
    *(.data .data.*)
  }

  .bss : ALIGN(8) {
    *(.bss .bss.*)
    *(COMMON)
  }
}
