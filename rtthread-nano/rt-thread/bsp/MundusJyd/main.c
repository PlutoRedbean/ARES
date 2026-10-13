#include <rtthread.h>

#include "board.h"

static struct rt_thread worker_a_thread;
static struct rt_thread worker_b_thread;

ALIGN(RT_ALIGN_SIZE)
static rt_uint8_t worker_a_stack[1024];
ALIGN(RT_ALIGN_SIZE)
static rt_uint8_t worker_b_stack[1024];

static volatile rt_uint32_t worker_a_result;
static volatile rt_uint32_t worker_b_result;
static volatile rt_uint32_t worker_a_spins;
static volatile rt_uint32_t worker_b_spins;

static void burn_ticks(rt_tick_t duration, volatile rt_uint32_t *spins)
{
    rt_tick_t start = rt_tick_get();

    while ((rt_tick_t)(rt_tick_get() - start) < duration)
    {
        (*spins)++;
    }
}

static void worker_a_entry(void *parameter)
{
    rt_uint32_t state = 0x11u;
    int step;

    (void)parameter;

    for (step = 0; step < 3; step++)
    {
        burn_ticks(6, &worker_a_spins);
        state += 0x10u + (rt_uint32_t)step;
        rt_kprintf("thread A: step=%d tick=%u\n", step, rt_tick_get());
    }

    worker_a_result = state;
}

static void worker_b_entry(void *parameter)
{
    rt_uint32_t state = 0x22u;
    int step;

    (void)parameter;

    for (step = 0; step < 3; step++)
    {
        burn_ticks(6, &worker_b_spins);
        state += 0x20u + (rt_uint32_t)step;
        rt_kprintf("thread B: step=%d tick=%u\n", step, rt_tick_get());
    }

    worker_b_result = state;
}

int main(void)
{
    rt_err_t result;
    int trap_test_result;
    uint32_t ecall_count_before;
    rt_tick_t delay_start;
    const uint32_t boot_mark = 0x52545401u;

    rt_kprintf("MundusJyd main thread started.\n");

    JYD_MMIO32(JYD_LED_ADDR) = boot_mark;
    if (JYD_MMIO32(JYD_LED_ADDR) != boot_mark)
    {
        halt(1);
    }

    ecall_count_before = rt_hw_trap_ecall_count();
    trap_test_result = rt_hw_trap_self_test();
    if (trap_test_result != 0)
    {
        rt_kprintf("ecall trap register test failed: %d\n", trap_test_result);
        halt(6);
    }
    if ((rt_hw_trap_ecall_count() != ecall_count_before + 1u) ||
        (rt_hw_trap_last_epc() == 0u))
    {
        halt(7);
    }
    rt_kprintf("ecall trap test passed: mepc=0x%08x.\n",
               rt_hw_trap_last_epc());

    result = rt_thread_init(&worker_a_thread, "workerA", worker_a_entry,
                            RT_NULL, worker_a_stack, sizeof(worker_a_stack),
                            RT_MAIN_THREAD_PRIORITY - 1, 5);
    if (result != RT_EOK)
    {
        halt(2);
    }

    result = rt_thread_init(&worker_b_thread, "workerB", worker_b_entry,
                            RT_NULL, worker_b_stack, sizeof(worker_b_stack),
                            RT_MAIN_THREAD_PRIORITY - 1, 5);
    if (result != RT_EOK)
    {
        halt(3);
    }

    rt_enter_critical();
    rt_thread_startup(&worker_a_thread);
    rt_thread_startup(&worker_b_thread);
    rt_exit_critical();

    if ((worker_a_result != 0x44u) || (worker_b_result != 0x85u))
    {
        halt(4);
    }

    if ((rt_tick_get() == 0u) || (rt_hw_trap_timer_irq_count() == 0u) ||
        (worker_a_spins == 0u) || (worker_b_spins == 0u))
    {
        halt(5);
    }

    rt_kprintf("workers completed without yield at tick=%u.\n", rt_tick_get());

    delay_start = rt_tick_get();
    while ((rt_tick_t)(rt_tick_get() - delay_start) < 3u)
    {
    }
    rt_kprintf("main busy-wait tick test passed at tick=%u.\n", rt_tick_get());

    delay_start = rt_tick_get();
    rt_thread_mdelay(3);
    if ((rt_tick_t)(rt_tick_get() - delay_start) < 3u)
    {
        halt(8);
    }

    rt_kprintf("preemptive timer test passed: tick=%u timer_irq=%u.\n",
               rt_tick_get(), rt_hw_trap_timer_irq_count());
    halt(0);
}
