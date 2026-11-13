OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    IROM (rx) : ORIGIN = 0x80000000, LENGTH = 32K
    DRAM (rw) : ORIGIN = 0x80100000, LENGTH = 32K
}

SECTIONS {
    .text : ALIGN(4) { KEEP(*(.text.startup)) *(.text*) } > IROM
    .rodata : ALIGN(16) { *(.rodata*) *(.srodata*) } > DRAM
    .data : ALIGN(16) { *(.data*) *(.sdata*) } > DRAM
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(16); __bss_end = .;
    } > DRAM
    __global_pointer$ = ADDR(.data) + 0x800;
    __stack_top = ORIGIN(DRAM) + LENGTH(DRAM);
    ASSERT(__bss_end <= __stack_top - 4096, "CoreMark data overlaps worker stack")
    /DISCARD/ : { *(.eh_frame*) *(.comment) }
}
