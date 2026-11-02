#include <rtthread.h>
#include "board.h"
extern uint32_t rt_hw_timer_last_ms;
static volatile uint32_t ecall_count, irq_count, last_cause, last_epc;
uintptr_t rt_hw_trap_handler(uintptr_t cause, uintptr_t epc)
{
    last_cause = cause; last_epc = epc;
    if (cause == 11) { ecall_count++; return epc + 4; }
    if (cause == 0x80000007u) {
        uint32_t now, elapsed;
        irq_count++;
        JYD_MMIO32(JYD_TIMER_ACK) = 1;
        now = rt_hw_timer_get_ms();
        elapsed = now - rt_hw_timer_last_ms;
        rt_hw_timer_last_ms = now;
        rt_interrupt_enter();
        while (elapsed--) rt_tick_increase();
        rt_interrupt_leave();
        return epc;
    }
    rt_kprintf("ARES RTOS FAIL trap=%08x epc=%08x\n", cause, epc);
    halt(1);
}
uint32_t rt_hw_trap_count(void) { return ecall_count + irq_count; }
uint32_t rt_hw_trap_last_cause(void) { return last_cause; }
uint32_t rt_hw_trap_last_epc(void) { return last_epc; }
uint32_t rt_hw_trap_ecall_count(void) { return ecall_count; }
uint32_t rt_hw_trap_timer_irq_count(void) { return irq_count; }
