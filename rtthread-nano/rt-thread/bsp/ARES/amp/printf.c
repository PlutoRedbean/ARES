#include <rtthread.h>
#include <rthw.h>

int printf(const char *fmt, ...)
{
    char text[256];
    va_list args;
    va_start(args, fmt);
    int size = rt_vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);
    rt_hw_console_output(text);
    return size;
}
