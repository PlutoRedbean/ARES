//=============================================================================
// ARES TRM (Turing Machine) runtime.
// Ported from ysyx-workbench abstract-machine/am/src/riscv/jyd/trm.c.
//
// halt(code) retires an EBREAK with a0 = code; the simulation harness turns
// that into HIT GOOD TRAP (a0 == 0) / HIT BAD TRAP.
//=============================================================================
#include <am.h>
#include <klib-macros.h>
#include <ares.h>

extern char _heap_start;
int main(const char *args);

extern char _program_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END  ((uintptr_t)&_program_start + PMEM_SIZE)

#define ebreak(code) asm volatile("mv a0, %0; ebreak" : :"r"(code))

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

// Unlike the JYD runtime, keep the console alive: it makes failing tests
// readable instead of silent.  The simulation decodes SERIAL_PORT as stdout.
void putch(char ch) {
  outb(SERIAL_PORT, ch);
}

void halt(int code) {
  ebreak(code);
  while (1);
}

void _trm_init() {
  int ret = main(mainargs);
  halt(ret);
}
