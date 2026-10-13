#include <trace.h>
#include <cpu.h>
#include <mem.h>
#include <sim.h>
#include <device.h>
#include <verilator_ctrl.h>
#include <difftest.h>
#include <dbg.h>

static uint8_t mrom[CONFIG_MROM_SIZE];
static uint8_t sram[CONFIG_SRAM_SIZE];
static uint8_t flash[CONFIG_FLASH_SIZE];
static uint8_t psram[CONFIG_PSRAM_SIZE];
static uint8_t sdram[CONFIG_SDRAM_SIZE];
static uint8_t mem[CONFIG_MEM_SIZE];
static uint8_t irom[CONFIG_IROM_SIZE_BYTES];
static uint8_t dram[DRAM_SIZE];

bool in_pmem(word_t addr) {
#if defined(IS_SOC)
  return in_mrom(addr)  ||
         in_sram(addr)  ||
         in_flash(addr) ||
         in_psram(addr) ||
         in_sdram(addr);
#elif defined(IS_NPC)
  return in_npc_mem(addr);
#else
  return in_irom(addr) || in_dram(addr);
#endif
}

uintptr_t vir_to_phy(word_t vaddr) {
#if defined(IS_SOC)
  if (in_mrom(vaddr)) { return (uintptr_t)mrom + vaddr - CONFIG_MROM_BASE; }
  if (in_sram(vaddr)) { return (uintptr_t)sram + vaddr - CONFIG_SRAM_BASE; }
  if (in_psram(vaddr)) { return (uintptr_t)psram + vaddr - CONFIG_PSRAM_BASE; }
  if (in_flash(vaddr)) { return (uintptr_t)flash + vaddr - CONFIG_FLASH_BASE; }
  if (in_sdram(vaddr)) { return (uintptr_t)sdram + vaddr - CONFIG_SDRAM_BASE; }
#elif defined(IS_NPC)
  if (in_npc_mem(vaddr)) { return (uintptr_t)mem + vaddr - CONFIG_MEM_BASE; }
#else
  if (in_irom(vaddr)) { return (uintptr_t)irom + vaddr - 0x80000000; }
  if (in_dram(vaddr)) { return (uintptr_t)dram + vaddr - DRAM_BASE; }
#endif
  out_of_bound(vaddr);
  return 0; 
}

void program_ROM(FILE *bin) {
#ifdef FLASH_TEST
  for (int i = 0; i < CONFIG_FLASH_SIZE; i++) {
    flash[i] = i % 256;
  }
  
#else
  int rc = 0;
  int i;
  fseek(bin, 0, SEEK_SET);
#if defined(IS_SOC)
  for (i = 0; i < CONFIG_FLASH_SIZE; i++) {
    int c = fgetc(bin);
    if (c == -1) break;
    flash[i] = (uint8_t)c;
  }
#elif defined(IS_NPC)
  for (i = 0; i < CONFIG_FLASH_SIZE; i++) {
    int c = fgetc(bin);
    if (c == -1) break;
    mem[i] = (uint8_t)c;
  }
#else
  for (i = 0; i < CONFIG_IROM_SIZE_BYTES; i++) {
    int c = fgetc(bin);
    if (c == -1) break;
    irom[i] = (uint8_t)c;
  }
  /* The flat image spans 0x8000_0000 upwards, so 0x8010_0000 lands at file
   * offset 0x100000.  Read to end-of-file: the firmware carries its own data,
   * and any appended weight blob is picked up automatically. */
  fseek(bin, 0x100000, SEEK_SET);
  for (i = 0; i < (int)DRAM_SIZE; i++) {
    int c = fgetc(bin);
    if (c == -1) break;
    dram[i] = (uint8_t)c;
  }
#endif

#endif
}

void out_of_bound(word_t addr) {
  Assert(0, "Address: " FMT_WORD " is out of bound at pc: " FMT_WORD, addr, cpu.pc);
}

extern "C" void flash_read(int32_t addr, int32_t *data) {
  uint32_t rdata = vaddr_read(addr);
  uint32_t byte0 = (rdata & 0x000000ff) >> 0;
  uint32_t byte1 = (rdata & 0x0000ff00) >> 8;
  uint32_t byte2 = (rdata & 0x00ff0000) >> 16;
  uint32_t byte3 = (rdata & 0xff000000) >> 24;
  *data = (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3;
}

extern "C" void mrom_read(int32_t addr, int32_t *data) {
  if (is_reset()) return;
  uint32_t rdata = vaddr_read(addr);
  *data = rdata;
}

extern "C" void psram_read(int32_t addr, int32_t *data) {
  if (is_reset()) return;
  uint32_t rdata = vaddr_read(addr);
  *data = rdata;
}

extern "C" void sdram_read(int32_t addr, int32_t *data) {
  if (is_reset()) return;
  uint32_t rdata = vaddr_read(addr);
  *data = rdata;
}

extern "C" void sram_write(int32_t addr, uint32_t data, uint8_t wmask) {
  if (!in_sram(addr)) out_of_bound(addr);
  uint32_t byte[4] = {
    ((uint32_t)data & 0x000000ff)      ,
    ((uint32_t)data & 0x0000ff00) >> 8 ,
    ((uint32_t)data & 0x00ff0000) >> 16,
    ((uint32_t)data & 0xff000000) >> 24
  };

  int index = 0;
  if ((wmask      & 0x1u) == 1) *((uint8_t *)sram + (addr - CONFIG_SRAM_BASE) + index++) = byte[0];
  if ((wmask >> 1 & 0x1u) == 1) *((uint8_t *)sram + (addr - CONFIG_SRAM_BASE) + index++) = byte[1];
  if ((wmask >> 2 & 0x1u) == 1) *((uint8_t *)sram + (addr - CONFIG_SRAM_BASE) + index++) = byte[2];
  if ((wmask >> 3 & 0x1u) == 1) *((uint8_t *)sram + (addr - CONFIG_SRAM_BASE) + index++) = byte[3];
}

extern "C" void psram_write(int32_t addr, uint8_t data) {
  *(psram + (addr - CONFIG_PSRAM_BASE)) = data;
}

extern "C" void sdram_write(int32_t addr, uint8_t data) {
  *((uint8_t *)sdram + (addr - CONFIG_SDRAM_BASE)) = (uint8_t)data;
}

extern "C" void mem_read(int32_t addr, int32_t *data) {
  if (is_reset()) return;
  uint32_t rdata = vaddr_read(addr);
  *data = rdata;
}

extern "C" void mem_write(int32_t addr, uint32_t data, uint8_t wmask) {
  if (!in_npc_mem(addr)) out_of_bound(addr);
  uint32_t byte[4] = {
    ((uint32_t)data & 0x000000ff)      ,
    ((uint32_t)data & 0x0000ff00) >> 8 ,
    ((uint32_t)data & 0x00ff0000) >> 16,
    ((uint32_t)data & 0xff000000) >> 24
  };

  int index = 0;
  if ((wmask      & 0x1u) == 1) *((uint8_t *)mem + (addr - CONFIG_MEM_BASE) + index++) = byte[0];
  if ((wmask >> 1 & 0x1u) == 1) *((uint8_t *)mem + (addr - CONFIG_MEM_BASE) + index++) = byte[1];
  if ((wmask >> 2 & 0x1u) == 1) *((uint8_t *)mem + (addr - CONFIG_MEM_BASE) + index++) = byte[2];
  if ((wmask >> 3 & 0x1u) == 1) *((uint8_t *)mem + (addr - CONFIG_MEM_BASE) + index++) = byte[3];
}

extern "C" int vaddr_read(int raddr) {
  if (is_reset()) return 0;
  return paddr_read(vir_to_phy(raddr));
}
extern "C" void vaddr_write(int addr, word_t data, int w_len) {
  if (is_reset()) return;
  int len = 1 << w_len;
  paddr_write(vir_to_phy(addr), data, len);
}

/* The accelerator addresses its scratch through the DRAM mirror at
 * 0x8030_0000, and BRAM.v only decodes 0x8013_0000-0x8013_FFFF for it.  That
 * mirror is translated here, and ONLY that mirror: masking bit 21 off every
 * address (which is what this used to do) also aliases 0x8040_0000 against
 * 0x8060_0000, 0x80C0_0000 against 0x80E0_0000 and so on, halving the window
 * the model's weight blobs and activation buffers live in.  Two buffers 2 MiB
 * apart then silently share storage, and the symptom shows up as corrupted
 * weights rather than as a bad address. */
static uint32_t mt_dma_phys(uint32_t addr) {
  if (addr >= 0x80300000u && addr < 0x80400000u) {
    return 0x80100000u + (addr - 0x80300000u);
  }
  return addr;
}

/* ---------------------------------------------------------------------------
 * miniTensor 128-bit uncached DMA.
 *
 * The accelerator addresses its scratch buffers through the DRAM mirror at
 * 0x8030_0000; the physical slice it may touch is 0x8013_0000-0x8013_FFFF, so
 * clear address bit 21 and index the same dram[] array the CPU reaches through
 * BRAM.v's vaddr_read/vaddr_write.  Sharing one array is what makes the
 * accelerator a coherent second master without any cache maintenance: the CPU
 * only ever touches that slice through the uncached alias, so the D-cache never
 * holds a line of it.
 * ------------------------------------------------------------------------- */
extern "C" void mt_dma_read(int addr, int *w0, int *w1, int *w2, int *w3) {
  uint32_t a = mt_dma_phys((uint32_t)addr);
  if (!in_dram(a)) { out_of_bound(a); }
  const uint32_t *p = (const uint32_t *)(dram + (a - DRAM_BASE));
  *w0 = (int)p[0];
  *w1 = (int)p[1];
  *w2 = (int)p[2];
  *w3 = (int)p[3];
}

extern "C" void mt_dma_write(int addr, int w0, int w1, int w2, int w3) {
  uint32_t a = mt_dma_phys((uint32_t)addr);
  if (!in_dram(a)) { out_of_bound(a); }
  uint32_t *p = (uint32_t *)(dram + (a - DRAM_BASE));
  p[0] = (uint32_t)w0;
  p[1] = (uint32_t)w1;
  p[2] = (uint32_t)w2;
  p[3] = (uint32_t)w3;
}

int paddr_read(uintptr_t raddr) { return host_read(raddr); }
void paddr_write(uintptr_t addr, word_t data, int len) { host_write(addr, data, len); }

int host_read(uintptr_t raddr) {
  uint8_t *addr = (uint8_t *)(raddr & ~((uintptr_t)0x3u));
  uint32_t data = *(uint32_t *)addr;

  return data;
}

void host_write(uintptr_t addr, word_t data, int len) {
  switch (len) {
    case 1: *(uint8_t  *)addr = data; return;
    case 2: *(uint16_t *)addr = data; return;
    case 4: *(uint32_t *)addr = data; return;
    default: Assert(0, "host_write error");
  }
}
