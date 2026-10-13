#ifndef __MEM_H__
#define __MEM_H__

#include <common.h>

#define SERIAL_PORT         (DBASE + 0x00003f8)
#define RTC_ADDR            (DBASE + 0x0000048)
#define RTC_ADDR_LOWER      (RTC_ADDR    + 0x0000000)
#define RTC_ADDR_UPPER      (RTC_ADDR    + 0x0000004)
#define VGACTL_ADDR         (DBASE + 0x0000100)
#define VGACTL_SCREEN_ADDR  (DBASE + 0x0000100)
#define VGACTL_SYNC_ADDR    (DBASE + 0x0000104)
#define VGA_VMEM_ADDR       (DBASE + 0x1000000)

#define RESET_VECTOR CORE_ENTRY

static inline bool in_range(word_t addr, word_t base, word_t size) { return (addr - base) < size; }

static inline bool in_mrom(word_t addr)  { return in_range(addr, CONFIG_MROM_BASE,  CONFIG_MROM_SIZE); }
static inline bool in_sram(word_t addr)  { return in_range(addr, CONFIG_SRAM_BASE,  CONFIG_SRAM_SIZE); }
static inline bool in_flash(word_t addr) { return in_range(addr, CONFIG_FLASH_BASE, CONFIG_FLASH_SIZE); }
static inline bool in_psram(word_t addr) { return in_range(addr, CONFIG_PSRAM_BASE, CONFIG_PSRAM_SIZE); }
static inline bool in_sdram(word_t addr) { return in_range(addr, CONFIG_SDRAM_BASE, CONFIG_SDRAM_SIZE); }
static inline bool in_npc_mem(word_t addr) { return in_range(addr, CONFIG_MEM_BASE, CONFIG_MEM_SIZE); }
static inline bool in_irom(word_t addr)  { return in_range(addr, 0x80000000, CONFIG_IROM_SIZE_BYTES); }

/* JYD external memory (simulation model).
 *
 * perip_bridge decodes 0x8010_0000-0x80FF_FFFF as DRAM, so DRAM_SIZE must stay
 * in step with its dram_read_hit/dram_write_hit.  Only the first 256 KiB is
 * D-cacheable (scsrc/Mundus.scala:543-544); the rest is uncached but still
 * CPU-addressable, which is what lets the firmware reach weights and activation
 * buffers that are far larger than the on-chip 256 KiB.
 *
 * 0x8030_0000-0x8033_FFFF is the uncached mirror of 0x8010_0000-0x8013_FFFF
 * (address bit 21 set) and is where the miniTensor scratch buffers live. */
#define DRAM_BASE 0x80100000u
#define DRAM_SIZE 0x00F00000u   /* 15 MiB, ending at 0x80FF_FFFF */

static inline bool in_dram(word_t addr)  { return in_range(addr, DRAM_BASE, DRAM_SIZE); }

void program_ROM(FILE *bin);

void out_of_bound(word_t addr);

uintptr_t vir_to_phy(word_t paddr);

extern "C" void sram_write(int32_t addr, uint32_t data, uint8_t wmask);
extern "C" void flash_read(int32_t addr, int32_t *data);
extern "C" void mrom_read(int32_t addr, int32_t *data);
extern "C" void psram_read(int32_t addr, int32_t *data);
extern "C" void psram_write(int32_t addr, uint8_t data);
extern "C" void sdram_read(int32_t addr, int32_t *data);
extern "C" void sdram_write(int32_t addr, uint8_t data);

extern "C" void mem_read(int32_t addr, int32_t *data);
extern "C" void mem_write(int32_t addr, uint32_t data, uint8_t wmask);

bool in_pmem(word_t addr);

extern "C" int vaddr_read(int raddr);
extern "C" void vaddr_write(int addr, word_t data, int w_len);

// miniTensor 128-bit uncached DMA (one 16-byte beat per call).
extern "C" void mt_dma_read(int addr, int *w0, int *w1, int *w2, int *w3);
extern "C" void mt_dma_write(int addr, int w0, int w1, int w2, int w3);

int paddr_read(uintptr_t raddr);
void paddr_write(uintptr_t addr, word_t data, int len);

int host_read(uintptr_t raddr);
void host_write(uintptr_t addr, word_t data, int len);

#endif
