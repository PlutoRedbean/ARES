#include <rtthread.h>

#include "board.h"

#define RISCV_MCAUSE_ECALL_FROM_M_MODE 11u
#define RISCV_MCAUSE_MACHINE_TIMER_IRQ  0x80000007u

static volatile uint32_t trap_count;
static volatile uint32_t trap_last_cause;
static volatile uint32_t trap_last_epc;
static volatile uint32_t trap_ecall_count;
static volatile uint32_t trap_timer_irq_count;

/* Called with the interrupted register set already saved by trap.S. */
uintptr_t rt_hw_trap_handler(uintptr_t cause, uintptr_t epc)
{
    trap_count++;
    trap_last_cause = (uint32_t)cause;
    trap_last_epc = (uint32_t)epc;

    if (cause == RISCV_MCAUSE_ECALL_FROM_M_MODE)
    {
        trap_ecall_count++;
        /* ecall is one 32-bit instruction in the current RV32IM image. */
        return epc + 4u;
    }

    if (cause == RISCV_MCAUSE_MACHINE_TIMER_IRQ)
    {
        trap_timer_irq_count++;
        rt_interrupt_enter();
        rt_tick_increase();
        rt_interrupt_leave();
        return epc;
    }

    rt_kprintf("unhandled trap: mcause=0x%08x mepc=0x%08x\n",
               (uint32_t)cause, (uint32_t)epc);
    halt(0x40 | ((int)cause & 0x3f));
}

uint32_t rt_hw_trap_count(void)
{
    return trap_count;
}

uint32_t rt_hw_trap_last_cause(void)
{
    return trap_last_cause;
}

uint32_t rt_hw_trap_last_epc(void)
{
    return trap_last_epc;
}

uint32_t rt_hw_trap_ecall_count(void)
{
    return trap_ecall_count;
}

uint32_t rt_hw_trap_timer_irq_count(void)
{
    return trap_timer_irq_count;
}
