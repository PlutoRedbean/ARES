//=============================================================================
// ARES first stage boot loader.
// Ported from ysyx-workbench abstract-machine/am/src/riscv/jyd/bootloader.c.
//
// The flat image already carries .data / .rodata at their link addresses
// (DRAM is loaded at file offset 0x100000 by the simulation memory model), so
// _fsbl() only has to clear .bss.
//=============================================================================
#include <klib.h>

extern char _data_vma_start;
extern char _data_lma_start;
extern char _data_len;

extern char _bss_vma_start;
extern char _bss_len;

void _fsbl() __attribute__((section(".boot")));
void *_memcpy(void *out, const void *in, size_t n);
void *_memset(void *s, int c, size_t n);

void _fsbl() {
  _memset(&_bss_vma_start, 0, (size_t)&_bss_len);
}
