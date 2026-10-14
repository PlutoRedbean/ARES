#include <rtthread.h>

#include "board.h"

void rt_hw_board_init(void)
{
    rt_hw_timer_init();
}

void halt(int code)
{
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
