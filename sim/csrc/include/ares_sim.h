//=============================================================================
// ARES simulation - shared declarations
//-----------------------------------------------------------------------------
// Ported from ysyx-workbench/npc (csrc/include), trimmed down to the pieces
// the ARES Verilator flow needs: a guest memory model, the architectural
// state rebuilt from the RTL retirement interface, and the DPI-C surface the
// temporary NPC (Mundus) RTL expects.
//=============================================================================
#ifndef ARES_SIM_H
#define ARES_SIM_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

//---------------------------------------------------------------------------
// Guest memory map (Mundus / npc platform)
//
//   0x8000_0000 + 32 KiB   IROM   - instruction port only
//   0x8010_0000 + 256 KiB  DRAM   - D-cacheable window
//   0x8030_0000 + 256 KiB  DRAM   - uncached mirror of 0x8010_0000
//   0x8040_0000 ..         DRAM   - uncached extension
//   0xa000_0000 ..         MMIO   - console / RTC
//
// The image is loaded as one flat blob at 0x8000_0000, which is exactly how
// the AM linker script lays it out (IROM section first, DRAM at +1 MiB).
//---------------------------------------------------------------------------
#define PMEM_BASE       0x80000000u
#define PMEM_SIZE       0x01000000u  // 16 MiB flat model

#define IROM_BASE       0x80000000u
#define IROM_SIZE       0x00008000u  // 32 KiB (CONFIG_IROM_SIZE_BYTES)

#define DRAM_BASE       0x80100000u
#define DRAM_CACHE_END  0x80140000u  // end of the D-cacheable window
#define DRAM_ALIAS_BASE 0x80300000u  // bit 21 alias of the cacheable window
#define DRAM_ALIAS_END  0x80340000u
#define DRAM_HI_END     0x81000000u  // uncached extension, model limit

#define MMIO_BASE       0xa0000000u
#define MMIO_END        0xa1000000u
#define SERIAL_PORT     (MMIO_BASE + 0x00003f8u)
#define RTC_ADDR        (MMIO_BASE + 0x0000048u)
#define RTC_ADDR_UPPER  (MMIO_BASE + 0x000004cu)

//---------------------------------------------------------------------------
// Architectural state, rebuilt from the RTL retirement events so that the
// harness never has to poke at internal RTL signals.
//---------------------------------------------------------------------------
struct SimState {
  uint32_t gpr[32];
  uint32_t pc;             // last retired instruction address
  uint32_t pc_next;        // its architectural successor
  uint32_t fetch_pc;       // combinational fetch address (debug aid)
  uint32_t fetch_pc_next;
  uint64_t retire_cnt;     // retired instructions
  uint64_t cycles;         // simulated clock cycles
  bool     halt_seen;      // an EBREAK retirement was observed
  bool     halted;         // simulation finished because of that EBREAK
  uint32_t halt_code;      // a0 at the EBREAK (0 = HIT GOOD TRAP)
  bool     error;          // unrecoverable model error (bad address, ...)
  char     error_msg[256];
};

extern SimState sim;

//---------------------------------------------------------------------------
// memory.cpp
//---------------------------------------------------------------------------
void     mem_reset(void);
void     mem_load_image(const char *path);
uint32_t mem_read32(uint32_t paddr);
// Instruction fetch is tolerant on purpose: the fetch unit drives
// io_irom_addr combinationally, so the very first evaluation (before any clock
// edge, with the whole design at its initial value) asks for address 0.
uint32_t mem_read_irom(uint32_t addr);
void     mem_write(uint32_t paddr, uint32_t data, uint8_t strb);

//---------------------------------------------------------------------------
// dut.cpp - DPI-C entry points
//---------------------------------------------------------------------------
uint64_t sim_host_time_us(void);
void     sim_dump_regs(void);

//---------------------------------------------------------------------------
// main.cpp - harness helpers shared with dut.cpp
//---------------------------------------------------------------------------
void sim_report(const char *fmt, ...);
void sim_fail(const char *fmt, ...);
extern bool sim_itrace;
extern bool sim_verbose;
extern bool sim_perip_trace;

#endif  // ARES_SIM_H
