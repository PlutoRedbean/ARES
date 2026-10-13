#ifndef __SIM_H__
#define __SIM_H__

#include <common.h>

#define EBREAK_CODE 0x00100073

/*
 * Statistics normally cover the complete simulation.  A platform may select
 * a narrower window (for example, JYD LED0 around CoreMark) without changing
 * the processor RTL.  Simulation-only counters use this predicate; functional
 * models such as difftest must continue running outside the window.
 */
extern "C" int sim_stats_enabled();
void sim_stats_on_led_write(uint32_t value);

#define DECLARE_COUNTER(name) \
    extern "C" void name##_cnt_add()

#define DEFINE_COUNTER(name) \
    static uint64_t name##_cnt = 0; \
    extern "C" void name##_cnt_add() { \
      if (sim_stats_enabled()) name##_cnt++; \
    }

#define RESET_COUNTER(name) name##_cnt = 0

#define DISPLAY_COUNTER(name) \
    Log(#name"u counter: %ld", name##_cnt)

#define UNIT_COUNTER(func) \
    IFDEF(CONFIG_IF_COUNTER, func(if)); \
    IFDEF(CONFIG_LS_COUNTER, func(ls)); \
    IFDEF(CONFIG_EX_COUNTER, func(ex))

#define TYPE_LIST     \
    func(ARITH_OP)    \
    func(LOGIC_OP)    \
    func(SHIFT_OP)    \
    func(CMP_OP)      \
    func(MUL_OP)      \
    func(DIV_OP)      \
    func(U_IMM)       \
    func(BRANCH)      \
    func(LOAD_STORE)  \
    func(CSR)         \
    func(ENVIRONMENT)

typedef enum {
#define func(name) name,
    TYPE_LIST
#undef func
    TYPE_TOTAL,
    TYPE_COUNT
} Type;

static const char *welcome_name = 
                           " __  __                    _\n"
                           "|  \\/  | _   _  _ __    __| | _   _  ___\n"
                           "| |\\/| || | | || '_ \\  / _` || | | |/ __|\n"
                           "| |  | || |_| || | | || (_| || |_| |\\__ \\\n"
                           "|_|  |_| \\__,_||_| |_| \\__,_| \\__,_||___/\n";

UNIT_COUNTER(DECLARE_COUNTER);
                           
void statistic();

void assert_fail_msg();

extern "C" void test_data(int din);
extern "C" void ebreak();

void sim_init(int argc, char** argv);
void sim_start();
bool sim_run();
void sim_end();

#endif
