#include <rtthread.h>
#include "board.h"
uint32_t rt_hw_timer_last_ms;
uint32_t rt_hw_timer_get_ms(void) { return JYD_MMIO32(JYD_TIMER_ADDR); }
void rt_hw_timer_init(void)
{
    JYD_MMIO32(JYD_TIMER_ACK) = 1;
    rt_hw_timer_last_ms = rt_hw_timer_get_ms();
    JYD_MMIO32(JYD_TIMER_ADDR) = JYD_TIMER_START;
    __asm__ volatile("csrs mie, %0" :: "r"(1u << 7) : "memory");
}
