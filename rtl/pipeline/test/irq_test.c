#include <stdint.h>
#include "board.h"
volatile uint32_t irq_count;
uintptr_t rt_thread_switch_interrupt_flag, rt_interrupt_from_thread, rt_interrupt_to_thread;
static volatile uint32_t data[3072];
static volatile uint32_t cold[128];
static void puts_uart(const char *s) { while (*s) JYD_MMIO32(JYD_CONSOLE_ADDR) = *s++; }
void halt(int code)
{
    puts_uart("ARES RTOS FAIL irq-test\n");
    __asm__ volatile("mv a0,%0; ebreak" :: "r"(code) : "a0");
    for (;;) {}
}
uintptr_t rt_hw_trap_handler(uintptr_t cause, uintptr_t pc)
{
    if (cause == 11) return pc + 4;
    if (cause != 0x80000007u) halt(1);
    JYD_MMIO32(JYD_TIMER_ACK) = 1;
    irq_count++;
    return pc;
}
static void check(int good) { if (!good) halt(2); }
static void csr_test(void)
{
    uintptr_t old, value, vector;
    __asm__ volatile("csrrw %0,mie,%1" : "=r"(old) : "r"(128u)); check(old == 0);
    __asm__ volatile("csrrs %0,mie,zero" : "=r"(old)); check(old == 128);
    __asm__ volatile("csrrc %0,mie,%1" : "=r"(old) : "r"(128u)); check(old == 128);
    __asm__ volatile("csrrsi %0,mstatus,8" : "=r"(old)); check((old & 8) == 0);
    __asm__ volatile("csrrci %0,mstatus,8" : "=r"(old)); check((old & 8) == 8);
    __asm__ volatile("csrrwi %0,mstatus,8" : "=r"(old));
    __asm__ volatile("csrrwi %0,mstatus,0" : "=r"(old)); check((old & 8) == 8);
    __asm__ volatile("csrw mip,%0" :: "r"(~0u));
    __asm__ volatile("csrr %0,mip" : "=r"(value)); check(value == 0);
    __asm__ volatile("csrr %0,mtvec" : "=r"(vector));
    __asm__ volatile("csrw mtvec,%0" :: "r"(vector | 3u));
    __asm__ volatile("csrr %0,mtvec" : "=r"(value)); check(value == vector);
    check(rt_hw_trap_self_test() == 0);
    __asm__ volatile("csrw mie,%0; csrsi mstatus,8" :: "r"(128u) : "memory");
}
void entry(void)
{
    uint32_t old, n, sum, expected;
    volatile uint32_t divisor = 7;
    csr_test();
    for (uint32_t phase = 1; phase <= 5; phase++) {
        old = irq_count;
        JYD_MMIO32(JYD_SEG_ADDR) = phase;
        sum = 0; expected = 0;
        for (n = 0; n < 128; n++) {
            data[n] = n + 11;
            data[n + 1024] = n + 17;
            data[n + 2048] = n + 23;
            sum += data[n] + data[n+1024] + data[n+2048];
            sum += n / divisor;
            expected += 3*n + 51 + n/7;
            // The TB checks each accepted LED write exactly once and in order.
            JYD_MMIO32(JYD_LED_ADDR) = (phase-1)*128 + n + 1;
            if (phase == 5 && n < 2) puts_uart("x\n");
        }
        if (phase == 2) {
            for (n=0; n<128; n++) {
                uint32_t value;
                __asm__ volatile("lw %0,0(%1); addi %0,%0,1" : "=&r"(value) : "r"(&cold[n]) : "memory");
                check(value == 1);
            }
        }
        check(sum == expected);
        while (irq_count == old) {}
        check(irq_count == old+1);
    }
    // Real timer pending survives both MTIE and global MIE masking.
    __asm__ volatile("csrci mstatus,8; csrw mie,zero" ::: "memory");
    old = irq_count;
    JYD_MMIO32(JYD_TIMER_ADDR) = JYD_TIMER_START;
    n = rt_hw_timer_get_ms();
    while (rt_hw_timer_get_ms() - n < 3) {}
    check(irq_count == old);
    check(JYD_MMIO32(JYD_TIMER_ACK) == 1);
    __asm__ volatile("csrw mie,%0" :: "r"(128u));
    check(irq_count == old);
    __asm__ volatile("csrsi mstatus,8" ::: "memory");
    while (irq_count == old) {}
    JYD_MMIO32(JYD_TIMER_ADDR) = JYD_TIMER_STOP;
    __asm__ volatile("csrci mstatus,8" ::: "memory");
    puts_uart("IRQ CSR/precision/masking PASS\nARES RTOS PASS\n");
    for (;;) {}
}
uint32_t rt_hw_timer_get_ms(void) { return JYD_MMIO32(JYD_TIMER_ADDR); }
