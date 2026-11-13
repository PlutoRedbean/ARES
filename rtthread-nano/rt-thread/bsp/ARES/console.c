#include <rtthread.h>

#include "board.h"

void rt_hw_console_output(const char *str)
{
#ifdef ARES_RTOS_AMP
    /* Prevent an AI report from splitting a shell write, and vice versa. */
    const int in_thread = rt_thread_self() != RT_NULL;
    if (in_thread)
        rt_enter_critical();
#endif
    while (*str != '\0')
    {
        if (*str == '\n')
        {
            JYD_MMIO32(JYD_CONSOLE_ADDR) = (uint32_t)'\r';
        }

        JYD_MMIO32(JYD_CONSOLE_ADDR) = (uint32_t)(uint8_t)*str++;
    }
#ifdef ARES_RTOS_AMP
    if (in_thread)
        rt_exit_critical();
#endif
}

char rt_hw_console_getchar(void)
{
    if ((JYD_MMIO32(JYD_CONSOLE_STATUS) & JYD_CONSOLE_RX_VALID) == 0u)
    {
#ifdef ARES_RTOS_AMP
        rt_thread_mdelay(1);
#endif
        return (char)-1;
    }

    return (char)(uint8_t)JYD_MMIO32(JYD_CONSOLE_RX);
}
