#ifndef MUNDUS_JYD_BOARD_H
#define MUNDUS_JYD_BOARD_H

#include <stdint.h>

#define JYD_SEG_ADDR        0x80200020u
#define JYD_LED_ADDR        0x80200040u
#define JYD_TIMER_ADDR      0x80200050u
#define JYD_CONSOLE_ADDR    0x80200060u
#define JYD_CONSOLE_STATUS  0x80200064u
#define JYD_CONSOLE_RX      0x80200068u
#define JYD_CONSOLE_RX_VALID 0x00000001u
#define JYD_TIMER_START     0x80000000u
#define JYD_TIMER_STOP      0xffffffffu
#define JYD_MMIO32(address) (*(volatile uint32_t *)(address))

void rt_hw_timer_init(void);
uint32_t rt_hw_timer_get_ms(void);
char rt_hw_console_getchar(void);

uintptr_t rt_hw_trap_handler(uintptr_t cause, uintptr_t epc);
int rt_hw_trap_self_test(void);
uint32_t rt_hw_trap_count(void);
uint32_t rt_hw_trap_last_cause(void);
uint32_t rt_hw_trap_last_epc(void);
uint32_t rt_hw_trap_ecall_count(void);
uint32_t rt_hw_trap_timer_irq_count(void);

void halt(int code) __attribute__((noreturn));

#endif
