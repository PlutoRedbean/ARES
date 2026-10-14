#include <rtthread.h>
#include <finsh.h>

#include "board.h"

int coremark_main(void);
int finsh_system_init(void);

static int coremark_command(int argc, char **argv)
{
    int result;

    (void)argc;
    (void)argv;

    rt_kprintf("CoreMark starts when LED0 turns on.\n");
    JYD_MMIO32(JYD_LED_ADDR) = 1u;
    result = coremark_main();
    JYD_MMIO32(JYD_LED_ADDR) = 0u;
    rt_kprintf("CoreMark finished with result %d.\n", result);

    return result;
}
MSH_CMD_EXPORT_ALIAS(coremark_command, coremark, run CoreMark benchmark.);

static int quit_command(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    rt_kprintf("Exit simulation.\n");
    halt(0);
}
MSH_CMD_EXPORT_ALIAS(quit_command, quit, exit Verilator simulation.);

int main(void)
{
    JYD_MMIO32(JYD_LED_ADDR) = 0u;
    rt_kprintf("MundusJyd competition shell ready.\n");
    rt_kprintf("Type 'help', 'coremark' or 'quit'.\n");

    return finsh_system_init();
}
