OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;

  .text : ALIGN(8)
  {
    *(.text.init)
    *(.text*)
  }

  .rodata : ALIGN(8)
  {
    *(.rodata*)
  }

  . = 0x80100000;

  .data : ALIGN(8)
  {
    *(.data*)
  }

  .bss : ALIGN(8)
  {
    *(.bss*)
    *(COMMON)
  }
}
