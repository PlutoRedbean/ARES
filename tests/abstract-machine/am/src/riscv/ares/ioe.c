//=============================================================================
// ARES IOE runtime.
//-----------------------------------------------------------------------------
// Ported from ysyx-workbench abstract-machine/am/src/riscv/jyd/ioe.c and made
// functional for the two devices the simulation model provides: the console
// (already handled by putch in trm.c) and the CLINT style RTC at
// 0xa000_0048 / 0xa000_004c.
//=============================================================================
#include <am.h>
#include <ares.h>
#include <klib-macros.h>

static void __am_timer_config(AM_TIMER_CONFIG_T *cfg) {
  cfg->present = true;
  cfg->has_rtc = true;
}

static void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour   = 0;
  rtc->day    = 0;
  rtc->month  = 0;
  rtc->year   = 1900;
}

static void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  uint32_t hi, lo;
  do {
    hi = inl(RTC_ADDR_UPPER);
    lo = inl(RTC_ADDR);
  } while (hi != inl(RTC_ADDR_UPPER));
  uptime->us = ((uint64_t)hi << 32) | (uint64_t)lo;
}

static void __am_input_config(AM_INPUT_CONFIG_T *cfg) { cfg->present = false; }
static void __am_uart_config(AM_UART_CONFIG_T *cfg)   { cfg->present = true;  }

typedef void (*handler_t)(void *buf);
static void *lut[128] = {
  [AM_TIMER_CONFIG] = __am_timer_config,
  [AM_TIMER_RTC   ] = __am_timer_rtc,
  [AM_TIMER_UPTIME] = __am_timer_uptime,
  [AM_INPUT_CONFIG] = __am_input_config,
  [AM_UART_CONFIG ] = __am_uart_config,
};

static void fail(void *buf) { panic("access nonexistent register"); }

bool ioe_init() {
  for (int i = 0; i < LENGTH(lut); i++)
    if (!lut[i]) lut[i] = fail;
  return true;
}

void ioe_read (int reg, void *buf) { ((handler_t)lut[reg])(buf); }
void ioe_write(int reg, void *buf) { ((handler_t)lut[reg])(buf); }
