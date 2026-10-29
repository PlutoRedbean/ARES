#ifndef ARES_H__
#define ARES_H__

// ARES platform device map.  Ported from ysyx-workbench
// abstract-machine/am/src/riscv/jyd/include/npc.h and kept identical to the
// npc / Mundus peripheral map so the same RTL can be simulated.

#define DEVICE_BASE     0xa0000000
#define MMIO_BASE       0xa0000000

#define SERIAL_PORT     (DEVICE_BASE + 0x00003f8)
#define SERIAL_STATUS   (DEVICE_BASE + 0x00003fc)
#define BENCH_CYCLE_LO  (DEVICE_BASE + 0x0000050)
#define BENCH_CYCLE_HI  (DEVICE_BASE + 0x0000054)
#define KBD_ADDR        (DEVICE_BASE + 0x0000060)
#define RTC_ADDR        (DEVICE_BASE + 0x0000048)
#define RTC_ADDR_UPPER  (DEVICE_BASE + 0x000004c)
#define VGACTL_ADDR     (DEVICE_BASE + 0x0000100)
#define AUDIO_ADDR      (DEVICE_BASE + 0x0000200)
#define DISK_ADDR       (DEVICE_BASE + 0x0000300)
#define FB_ADDR         (MMIO_BASE   + 0x1000000)
#define AUDIO_SBUF_ADDR (MMIO_BASE   + 0x1200000)

static inline uint8_t  inb(uintptr_t addr) { return *(volatile uint8_t  *)addr; }
static inline uint16_t inw(uintptr_t addr) { return *(volatile uint16_t *)addr; }
static inline uint32_t inl(uintptr_t addr) { return *(volatile uint32_t *)addr; }

static inline void outb(uintptr_t addr, uint8_t  data) { *(volatile uint8_t  *)addr = data; }
static inline void outw(uintptr_t addr, uint16_t data) { *(volatile uint16_t *)addr = data; }
static inline void outl(uintptr_t addr, uint32_t data) { *(volatile uint32_t *)addr = data; }

#endif
