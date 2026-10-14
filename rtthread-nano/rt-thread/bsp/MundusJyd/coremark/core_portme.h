#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <rtthread.h>

#ifndef NULL
#define NULL ((void *)0)
#endif

#define MEM_METHOD       MEM_STACK
#define MULTITHREAD      1
#define MAIN_HAS_NOARGC  1
#define MAIN_HAS_NORETURN 0
#define SEED_METHOD      SEED_VOLATILE

#define HAS_FLOAT  1
#define HAS_TIME_H 0
#define USE_CLOCK  1
#define HAS_STDIO  0
#define HAS_PRINTF 1

#define PERFORMANCE_RUN 1
#define TOTAL_DATA_SIZE 2000

#ifndef COREMARK_ITERATIONS
#define COREMARK_ITERATIONS 10
#endif
#define ITERATIONS COREMARK_ITERATIONS

#ifndef COREMARK_REPORT_MODE
#define COREMARK_REPORT_MODE 1
#endif

#define COMPILER_VERSION "GCC " __VERSION__
#if COREMARK_REPORT_MODE == 0
#define COMPILER_FLAGS \
    "-O2 -fno-common -funroll-loops -finline-functions " \
    "--param max-inline-insns-auto=300 -falign-functions=4 " \
    "-falign-jumps=4 -falign-loops=4 -specs=nano.specs " \
    "-ffunction-sections -fdata-sections"
#else
#if COREMARK_HW_CRC
#if COREMARK_HW_MATRIX
#define COMPILER_FLAGS \
    "-O3 -flto -fno-split-paths -falign-fn/jump/loop=8;CRC:custom-0; " \
    "list:find-ni/sched+rev-asm; " \
    "state:trans-ni+reg-ret-sched; " \
    "mat:N9-acc9-MULBE -fno-lto -funroll -fno-rename"
#else
#define COMPILER_FLAGS \
    "-O3 -flto -fno-split-paths -falign-fn/jump/loop=8;CRC:custom-0; " \
    "list:find-ni/sched+rev-asm; " \
    "state:trans-ni+reg-ret-sched"
#endif
#else
#if COREMARK_HW_MATRIX
#define COMPILER_FLAGS \
    "-O3 -flto -fno-split-paths -falign-fn/jump/loop=8; " \
    "software CRC TU: -fno-lto; " \
    "matrix TU: -fno-lto -funroll-loops " \
    "-fvariable-expansion-in-unroller -frename-registers"
#else
#define COMPILER_FLAGS \
    "-O3 -flto -fno-split-paths -falign-fn/jump/loop=8; " \
    "software CRC TU: -fno-lto"
#endif
#endif
#endif
#define MEM_LOCATION     "STACK"

typedef rt_int16_t  ee_s16;
typedef rt_uint16_t ee_u16;
typedef rt_int32_t  ee_s32;
typedef double      ee_f32;
typedef rt_uint8_t  ee_u8;
typedef rt_uint32_t ee_u32;
typedef rt_ubase_t  ee_ptr_int;
typedef rt_size_t   ee_size_t;
typedef rt_uint32_t CORE_TICKS;

#define align_mem(x) \
    ((void *)(4u + (((ee_ptr_int)(x) - 1u) & ~(ee_ptr_int)3u)))

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

extern ee_u32 default_num_contexts;

void portable_init(core_portable *portable, int *argc, char *argv[]);
void portable_fini(core_portable *portable);

/* The repository CoreMark source has this AM hook.  It is a no-op in RT. */
void ioe_init(void);

/*
 * coremark.h maps ee_printf to printf when HAS_PRINTF is enabled.  RT-Thread
 * Nano's rt_kprintf intentionally has no %f conversion, so route CoreMark
 * through the port formatter.  With -march=rv32im all double arithmetic used
 * by this formatter is provided by libgcc's software-float helpers.
 */
int coremark_printf(const char *format, ...);
#define printf coremark_printf

#endif
