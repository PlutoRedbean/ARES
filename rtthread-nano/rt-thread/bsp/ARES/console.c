#include <rtthread.h>

#include "board.h"

void rt_hw_console_output(const char *str)
{
#ifdef ARES_RTOS_AMP
    /* Prevent an AI report from splitting a shell write, and vice versa. */
    const int in_thread = rt_thread_self() != RT_NULL;
    if (in_thread)
        rt_enter_critical();
    if (guard_console_owned) {
        if (in_thread)
            rt_exit_critical();
        return;
    }
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

int ares_console_read_byte(void)
{
    if (!(JYD_MMIO32(JYD_CONSOLE_STATUS) & JYD_CONSOLE_RX_VALID))
        return -1;
    return (uint8_t)JYD_MMIO32(JYD_CONSOLE_RX);
}

#ifdef ARES_RTOS_AMP
static int last_was_cr;

int ares_console_last_was_cr(void)
{
    return last_was_cr;
}
#endif

char rt_hw_console_getchar(void)
{
    int byte = ares_console_read_byte();
#ifdef ARES_RTOS_AMP
    if (byte < 0)
        rt_thread_mdelay(1);
    else
        last_was_cr = byte == '\r';
#endif
    return (char)byte;
}
