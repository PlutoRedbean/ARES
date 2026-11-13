#include <rtthread.h>
#include <finsh.h>
#include <string.h>
#include "board.h"
int finsh_system_init(void);

long list_thread(void)
{
    struct rt_object_information *info = rt_object_get_information(RT_Object_Class_Thread);
    rt_list_t *node;
    rt_enter_critical();
    rt_kprintf("thread   priority state stack_bytes\n");
    for (node=info->object_list.next; node!=&info->object_list; node=node->next) {
        struct rt_thread *t = rt_list_entry(node, struct rt_thread, list);
        rt_kprintf("%-8.8s %u %u %u\n", t->name, t->current_priority,
                   t->stat & RT_THREAD_STAT_MASK, t->stack_size);
    }
    rt_exit_critical();
    return 0;
}
static int tick_command(int argc, char **argv)
{
    (void)argc; (void)argv;
    rt_kprintf("tick=%u ms=%u\n", rt_tick_get(), rt_hw_timer_get_ms());
    return 0;
}
MSH_CMD_EXPORT_ALIAS(tick_command, tick, show RTOS ticks and hardware milliseconds);
static int irq_command(int argc, char **argv)
{
    (void)argc; (void)argv;
    rt_kprintf("timer_irq=%u ecall=%u last_cause=0x%08x\n",
               rt_hw_trap_timer_irq_count(), rt_hw_trap_ecall_count(), rt_hw_trap_last_cause());
    return 0;
}
MSH_CMD_EXPORT_ALIAS(irq_command, irq, show interrupt counters);
static int led_command(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "0") && strcmp(argv[1], "1"))) {
        rt_kprintf("usage: led 0|1\n"); return -1;
    }
    JYD_MMIO32(JYD_LED_ADDR) = (JYD_MMIO32(JYD_LED_ADDR) & ~1u) | (argv[1][0]=='1');
    rt_kprintf("led=%u\n", JYD_MMIO32(JYD_LED_ADDR) & 1u);
    return 0;
}
MSH_CMD_EXPORT_ALIAS(led_command, led, set LED0 to 0 or 1);
static int echo_command(int argc, char **argv)
{
    for (int i=1; i<argc; i++) rt_kprintf("%s%s", i==1 ? "" : " ", argv[i]);
    rt_kprintf("\n"); return 0;
}
MSH_CMD_EXPORT_ALIAS(echo_command, echo, print arguments);
static int sleep_command(int argc, char **argv)
{
    unsigned ms = 0;
    if (argc != 2 || !argv[1][0]) goto usage;
    for (const char *s=argv[1]; *s; s++) {
        if (*s<'0' || *s>'9' || ms>6000) goto usage;
        ms=ms*10+(*s-'0');
        if (ms>60000) goto usage;
    }
    rt_thread_mdelay(ms);
    rt_kprintf("slept %u ms\n", ms);
    return 0;
usage:
    rt_kprintf("usage: sleep 0..60000\n"); return -1;
}
MSH_CMD_EXPORT_ALIAS(sleep_command, sleep, sleep for milliseconds);
static int ecall_command(int argc, char **argv)
{
    (void)argc; (void)argv;
    int result=rt_hw_trap_self_test();
    rt_kprintf("ecall %s\n", result ? "FAIL" : "PASS");
    return result;
}
MSH_CMD_EXPORT_ALIAS(ecall_command, ecall, test synchronous trap context);
static int quit_command(int argc, char **argv)
{
    (void)argc; (void)argv;
    rt_kprintf("ARES SHELL EXIT\n");
    return 0;
}
MSH_CMD_EXPORT_ALIAS(quit_command, quit, exit the interactive simulator);
int main(void)
{
#ifdef ARES_RTOS_AMP
    void amp_apps_init(void);
    amp_apps_init();
#endif
    rt_kprintf("ARES MSH ready. Type help.\n");
    return finsh_system_init();
}
