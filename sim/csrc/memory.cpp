//=============================================================================
// ARES simulation - guest memory model
//-----------------------------------------------------------------------------
// One flat 16 MiB array backs the whole 0x8000_0000 window, which is how the
// AM image is linked (IROM first, DRAM at +1 MiB).  MMIO lives at 0xa000_0000
// and is decoded here as well, so the console and the RTC work without any
// RTL change.
//=============================================================================
#include "ares_sim.h"

#include <time.h>

static uint8_t  pmem[PMEM_SIZE];
static uint64_t boot_time_us;
static bool     warned_unmapped[64];

static uint64_t host_time_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

uint64_t sim_host_time_us(void) {
  if (boot_time_us == 0) boot_time_us = host_time_us();
  return host_time_us() - boot_time_us;
}

void mem_reset(void) {
  memset(pmem, 0, sizeof(pmem));
  boot_time_us = host_time_us();
}

//---------------------------------------------------------------------------
// Image loading
//---------------------------------------------------------------------------
void mem_load_image(const char *path) {
  FILE *fp = fopen(path, "rb");
  if (fp == NULL) {
    sim_fail("cannot open image '%s'", path);
    return;
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (size < 0) {
    fclose(fp);
    sim_fail("cannot determine the size of '%s'", path);
    return;
  }
  if ((unsigned long)size > PMEM_SIZE) {
    fclose(fp);
    sim_fail("image '%s' is %ld bytes, the model holds %u bytes",
             path, size, (unsigned)PMEM_SIZE);
    return;
  }
  size_t got = fread(pmem, 1, (size_t)size, fp);
  fclose(fp);
  if (got != (size_t)size) {
    sim_fail("short read on image '%s' (%zu of %ld bytes)", path, got, size);
    return;
  }
  sim_report("image      : %s (%ld bytes)", path, size);
}

//---------------------------------------------------------------------------
// Device decode
//---------------------------------------------------------------------------
static bool is_mmio(uint32_t addr) {
  return addr >= MMIO_BASE && addr < MMIO_END;
}

static void warn_unmapped(uint32_t addr) {
  unsigned slot = (addr >> 20) & 63u;
  if (!warned_unmapped[slot]) {
    warned_unmapped[slot] = true;
    sim_report("warning    : unmapped MMIO read at 0x%08x returns 0", addr);
  }
}

//---------------------------------------------------------------------------
// Physical accesses
//---------------------------------------------------------------------------
uint32_t mem_read32(uint32_t paddr) {
  if (paddr >= PMEM_BASE && paddr < PMEM_BASE + PMEM_SIZE) {
    // The uncached mirror of the cacheable window aliases the same bytes.
    if (paddr >= DRAM_ALIAS_BASE && paddr < DRAM_ALIAS_END) {
      paddr &= ~0x00200000u;
    }
    uint32_t off = paddr - PMEM_BASE;
    return (uint32_t)pmem[off]
         | ((uint32_t)pmem[off + 1] << 8)
         | ((uint32_t)pmem[off + 2] << 16)
         | ((uint32_t)pmem[off + 3] << 24);
  }
  if (is_mmio(paddr)) {
    if (paddr == RTC_ADDR)       return (uint32_t)(sim_host_time_us() & 0xffffffffu);
    if (paddr == RTC_ADDR_UPPER) return (uint32_t)(sim_host_time_us() >> 32);
    if (paddr == SERIAL_PORT)    return 0;
    warn_unmapped(paddr);
    return 0;
  }
  sim_fail("read from unmapped address 0x%08x (pc = 0x%08x)", paddr, sim.pc);
  return 0;
}

uint32_t mem_read_irom(uint32_t addr) {
  if (addr >= PMEM_BASE && (addr - PMEM_BASE) + 4u <= PMEM_SIZE) {
    return mem_read32(addr);
  }
  static bool warned = false;
  if (!warned) {
    warned = true;
    sim_report("note       : out of range instruction fetch at 0x%08x -> 0",
               addr);
  }
  return 0;
}

// NOTE: 'strb' is a *word lane* mask, exactly like the byte enables the
// peripheral bridge derives from perip_mask, and lane i always addresses
// (paddr & ~3) + i - this is how the BRAM write port is wired (BRAM.v
// rebuilds the byte address as {word address, lane}).  Applying the lane
// offset to the unaligned address instead writes every byte store at a
// non-zero offset into the wrong byte.
void mem_write(uint32_t paddr, uint32_t data, uint8_t strb) {
  paddr &= ~3u;
  if (paddr >= PMEM_BASE && paddr < PMEM_BASE + PMEM_SIZE) {
    if (paddr >= DRAM_ALIAS_BASE && paddr < DRAM_ALIAS_END) {
      paddr &= ~0x00200000u;
    }
    uint32_t off = paddr - PMEM_BASE;
    if (strb & 0x1) pmem[off + 0] = (uint8_t)(data & 0xff);
    if (strb & 0x2) pmem[off + 1] = (uint8_t)((data >> 8) & 0xff);
    if (strb & 0x4) pmem[off + 2] = (uint8_t)((data >> 16) & 0xff);
    if (strb & 0x8) pmem[off + 3] = (uint8_t)((data >> 24) & 0xff);
    return;
  }
  if (is_mmio(paddr)) {
    if (paddr == SERIAL_PORT && (strb & 0x1)) {
      putchar((int)(data & 0xff));
      fflush(stdout);
    }
    return;
  }
  sim_fail("write to unmapped address 0x%08x (pc = 0x%08x)", paddr, sim.pc);
}
