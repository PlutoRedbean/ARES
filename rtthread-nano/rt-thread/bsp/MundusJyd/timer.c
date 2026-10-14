#include <rtthread.h>

#include "board.h"

uint32_t rt_hw_timer_get_ms(void)
{
    return JYD_MMIO32(JYD_TIMER_ADDR);
}

void rt_hw_timer_init(void)
{
    const uintptr_t machine_timer_enable = 1u << 7;

    JYD_MMIO32(JYD_TIMER_ADDR) = JYD_TIMER_START;
    __asm__ volatile("csrs mie, %0" :: "r"(machine_timer_enable) : "memory");
}
