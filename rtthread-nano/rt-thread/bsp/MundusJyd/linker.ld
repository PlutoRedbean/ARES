#include <autoconf.h>

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IROM (rx)  : ORIGIN = 0x80000000, LENGTH = CONFIG_IROM_SIZE_BYTES
    /* The top 64 KiB (0x8013_0000-0x8013_FFFF) is reserved for the
       miniTensor scratch buffers.  The CPU reaches it only through the
       uncached alias 0x8033_0000, so the D-cache never holds a line of it
       and no cache maintenance is required. */
    DRAM (rwx) : ORIGIN = 0x80100000, LENGTH = 192K

    /* The whole uncached extension window (0x8040_0000-0x80FF_FFFF, decoded by
       perip_bridge).  Package-sized networks cannot carry their weights in
       .rodata -- tiny-yolov3's convolutions alone are 8.8 MB against 192 KiB of
       DRAM -- so the weights are a separate load, the way they would come from
       external storage on a real board.  Being outside the cacheable window
       also means the DMA sees them without any cache maintenance.

       Both blobs share it: the small regression blob (.weights, ~25 KiB) is
       placed first, and the complete tiny-yolov3 blob (.model, 8.7 MiB of
       weights plus its input and per-stage goldens) immediately after it.
       Putting them in one region is what lets a single run own the full 12 MiB:
       the linker exports __model_start and the C side addresses the whole blob
       relative to it, so the packer does not need to know the address. */
    WEIGHTS (rw) : ORIGIN = 0x80400000, LENGTH = 12M
}

SECTIONS
{
    .text : ALIGN(8)
    {
        KEEP(*(.text.startup))
        *(.text*)
    } > IROM

    .rodata : ALIGN(8)
    {
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
        __fsymtab_start = .;
        KEEP(*(FSymTab))
        __fsymtab_end = .;
        . = ALIGN(4);
        __vsymtab_start = .;
        KEEP(*(VSymTab))
        __vsymtab_end = .;
    } > DRAM

    .data : ALIGN(8)
    {
        *(.data*)
        *(.sdata*)
    } > DRAM

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DRAM

    . = ALIGN(16);
    __heap_start = .;
    __global_pointer$ = ADDR(.data) + 0x800;
    __stack_top = ORIGIN(DRAM) + LENGTH(DRAM);

    /* LAST: placing a section in another region moves the location counter, so
       this must come after __heap_start/__stack_top or the DRAM overflow check
       compares a weights address against the stack top. */
    .weights : ALIGN(16)
    {
        __weights_start = .;
        KEEP(*(.weights))
        __weights_end = .;
    } > WEIGHTS

    /* Placed right after .weights inside the same region, so __model_start
       lands on the second blob. */
    .model : ALIGN(16)
    {
        __model_start = .;
        KEEP(*(.model))
        __model_end = .;
    } > WEIGHTS

    ASSERT(SIZEOF(.text) <= LENGTH(IROM), "MundusJyd IROM overflow")
    ASSERT(__heap_start < __stack_top, "MundusJyd DRAM overflow")
}
