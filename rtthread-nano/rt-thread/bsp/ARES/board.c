#include <rtthread.h>

#include "board.h"

void rt_hw_board_init(void)
{
    rt_hw_timer_init();
}

void halt(int code)
{
    rt_kprintf("ARES RTOS FAIL code=%d\n", code);
    __asm__ volatile(
        "mv a0, %0\n"
        "ebreak\n"
        :
        : "r"(code)
        : "a0", "memory");

    for (;;)
    {
    }
}
