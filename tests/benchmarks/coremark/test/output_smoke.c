#include "coremark.h"

int main(void) {
  ee_printf("UART smoke: %04x %d\n", 0x1234, 42);
  start_time();
  for (volatile unsigned i = 0; i < 1000; i++) {}
  stop_time();
  CORE_TICKS ticks = get_time();
  coremark_report_time(ticks, 4);
  ee_printf("UART smoke PASS\n");
  return 0;
}
