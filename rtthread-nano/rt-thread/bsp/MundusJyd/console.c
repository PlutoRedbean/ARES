#include <rtthread.h>

#include "board.h"

void rt_hw_console_output(const char *str)
{
    while (*str != '\0')
    {
        if (*str == '\n')
        {
            JYD_MMIO32(JYD_CONSOLE_ADDR) = (uint32_t)'\r';
        }

        JYD_MMIO32(JYD_CONSOLE_ADDR) = (uint32_t)(uint8_t)*str++;
    }
}

char rt_hw_console_getchar(void)
{
    if ((JYD_MMIO32(JYD_CONSOLE_STATUS) & JYD_CONSOLE_RX_VALID) == 0u)
    {
        return (char)-1;
    }

    return (char)(uint8_t)JYD_MMIO32(JYD_CONSOLE_RX);
}
