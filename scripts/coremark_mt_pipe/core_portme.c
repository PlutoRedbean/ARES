/*=============================================================================
 * ARES CoreMark port - parameterized 2/4-hart MULTITHREAD overlay
 *-----------------------------------------------------------------------------
 * This file is NOT part of tests/benchmarks/coremark/.  scripts/
 * build_coremark_image.py --mt-pipe copies the vendored EEMBC port into
 * build/coremark_mt<N>/port and replaces include/core_portme.h +
 * src/core_portme.c with the files in scripts/coremark_mt_pipe/.  The
 * repository copy of CoreMark therefore stays byte-identical.
 *
 * N harts, one CoreMark report (standard CoreMark MULTITHREAD semantics):
 *   hart0     core_main() master: start_time(), launches context 0 (inline)
 *             and contexts 1..N-1 (mailbox GO), stop_time(), prints the single
 *             aggregate report with Iterations = N * ITERATIONS.
 *   hart1..N  portable_init() worker: waits for GO on its own mailbox slot,
 *             re-initialises a private data block exactly like core_main did
 *             for that context, runs iterate() and publishes the CRCs through
 *             the shared MMIO mailbox. The standalone image then EBREAKs;
 *             the RT-Thread AMP image returns to the mailbox wait loop.
 *
 * The mailbox is uncached MMIO (memory.md 3.1): it bypasses the private L1 D$
 * and every access is a strongly ordered commit-head device operation, so no
 * cache maintenance is required.  No shared DRAM is used, which keeps the AMP
 * private-window checker valid.
 *===========================================================================*/
#include "coremark.h"
#include <ares.h>
#ifdef ARES_RTOS_AMP
#include "board.h"

static ee_u32 start_context, stop_context;
static uint32_t round_id;
static ee_u16 final_crc;
static int workers_ok;
void coremark_reset_list_shadow(void);

int coremark_workers_ok(void)
{
  return workers_ok;
}

void ioe_init(void) {}
#endif

#if VALIDATION_RUN
	volatile ee_s32 seed1_volatile=0x3415;
	volatile ee_s32 seed2_volatile=0x3415;
	volatile ee_s32 seed3_volatile=0x66;
#endif
#if PERFORMANCE_RUN
	volatile ee_s32 seed1_volatile=0x0;
	volatile ee_s32 seed2_volatile=0x0;
	volatile ee_s32 seed3_volatile=0x66;
#endif
#if PROFILE_RUN
	volatile ee_s32 seed1_volatile=0x8;
	volatile ee_s32 seed2_volatile=0x8;
	volatile ee_s32 seed3_volatile=0x8;
#endif
	volatile ee_s32 seed4_volatile=ITERATIONS;
	volatile ee_s32 seed5_volatile=0;
/* 100 MHz RTL clock ticks, independent of host execution speed. */
static CORE_TICKS start_time_val, stop_time_val;

static CORE_TICKS read_cycles(void) {
  uint32_t hi, lo;
  do {
    hi = inl(BENCH_CYCLE_HI);
    lo = inl(BENCH_CYCLE_LO);
  } while (hi != inl(BENCH_CYCLE_HI));
  return ((uint64_t)hi << 32) | lo;
}

void start_time(void) {
#ifdef ARES_RTOS_AMP
  start_context = 0;
  stop_context = 0;
  round_id++;
  if (round_id == 0)
    round_id++;
#else
  /* Finish the startup banner before entering the timed section. */
  while (inl(SERIAL_STATUS) & 1u) {}
#endif
  __asm__ volatile("fence iorw, iorw" ::: "memory");
  start_time_val = read_cycles();
  __asm__ volatile("" ::: "memory");
}

void stop_time(void) {
  __asm__ volatile("fence iorw, iorw" ::: "memory");
  stop_time_val = read_cycles();
}

CORE_TICKS get_time(void) {
  return stop_time_val - start_time_val;
}

secs_ret time_in_secs(CORE_TICKS ticks) {
  return ticks / COREMARK_CLOCK_HZ;
}

/* klib printf has no 64-bit or floating-point formatter. Keep all digits
 * using integer arithmetic; six fractional digits resolve sub-second runs. */
static void print_u64(uint64_t value) {
  char text[21];
  char *p = text + sizeof(text);
  *--p = '\0';
  do {
    *--p = '0' + value % 10;
    value /= 10;
  } while (value);
  ee_printf("%s", p);
}

static void print_ratio(const char *label, uint64_t numerator, uint64_t denominator) {
  ee_printf("%s", label);
  print_u64(numerator / denominator);
  ee_printf(".%06d\n", (int)((numerator % denominator) * 1000000u / denominator));
}

void coremark_report_time(CORE_TICKS ticks, ee_u32 iterations) {
#ifdef ARES_RTOS_AMP
  if (ticks == 0)
    halt(2);
  if (ticks < 10ull * COREMARK_CLOCK_HZ)
    ee_printf("CoreMark short run: CRC check only (under 10 seconds)\n");
#else
  assert(ticks != 0);
#endif
  ee_printf("CPU clock (MHz) : %d\n", COREMARK_CLOCK_HZ / 1000000u);
  ee_printf("Total ticks     : ");
  print_u64(ticks);
  ee_printf("\n");
  print_ratio("Total time (secs): ", ticks, COREMARK_CLOCK_HZ);
  ee_printf("Iterations      : %d\n", iterations);
  print_ratio("Iterations/Sec  : ", (uint64_t)iterations * COREMARK_CLOCK_HZ, ticks);
  print_ratio("CoreMark/MHz    : ", (uint64_t)iterations * 1000000u, ticks);
}

ee_u32 default_num_contexts=ARES_MT_CORES;

/*---------------------------------------------------------------------------
 * Hart identity and shared mailbox helpers
 *-------------------------------------------------------------------------*/
static uint32_t hart_id(void) {
  return inl(HART_ID_ADDR);
}

static uint32_t mbox_get(uint32_t hart, uint32_t off) {
  return inl(MBOX_BASE + hart * MBOX_SLOT_STRIDE + off);
}

static void mbox_put(uint32_t hart, uint32_t off, uint32_t value) {
  outl(MBOX_BASE + hart * MBOX_SLOT_STRIDE + off, value);
}

/*---------------------------------------------------------------------------
 * Worker hart h: private context h data, initialised exactly as core_main.c
 * does before it calls core_start_parallel(&results[h]).
 *-------------------------------------------------------------------------*/
static core_results mt_results;
static ee_u8 mt_memblock[TOTAL_DATA_SIZE] __attribute__((aligned(8)));

static void coremark_hart(uint32_t id)
{
#ifndef ARES_RTOS_AMP
  while (mbox_get(id, MBOX_GO) == 0u) {}
#endif
  __asm__ volatile("" ::: "memory");

  ee_u32 size = mbox_get(id, MBOX_SIZE);
  mt_results.size       = size;
  mt_results.iterations = mbox_get(id, MBOX_ITER);
  mt_results.execs      = mbox_get(id, MBOX_EXECS);
  mt_results.seed1      = (ee_s16)mbox_get(id, MBOX_SEED1);
  mt_results.seed2      = (ee_s16)mbox_get(id, MBOX_SEED2);
  mt_results.seed3      = (ee_s16)mbox_get(id, MBOX_SEED3);

  mt_results.memblock[0] = mt_memblock;
  mt_results.memblock[1] = mt_memblock;
  mt_results.memblock[2] = mt_memblock + size;
  mt_results.memblock[3] = mt_memblock + 2u * size;

  mt_results.list = core_list_init(size, (list_head *)mt_results.memblock[1],
                                   mt_results.seed1);
  (void)core_init_matrix(size, mt_results.memblock[2],
                         (ee_s32)mt_results.seed1 |
                             (((ee_s32)mt_results.seed2) << 16),
                         &(mt_results.mat));
  core_init_state(size, mt_results.seed1, (ee_u8 *)mt_results.memblock[3]);

#ifdef ARES_RTOS_AMP
  coremark_reset_list_shadow();
#endif
  iterate(&mt_results);

  mbox_put(id, MBOX_CRCLIST,   mt_results.crclist);
  mbox_put(id, MBOX_CRCMATRIX, mt_results.crcmatrix);
  mbox_put(id, MBOX_CRCSTATE,  mt_results.crcstate);
  mbox_put(id, MBOX_CRCFINAL,  mt_results.crc);
  mbox_put(id, MBOX_ERR,       0u);
  /* MMIO stores are strongly ordered by the in-order perip port; a fence is
   * not required and would stall behind the pending device store. */
  __asm__ volatile("" ::: "memory");
#ifndef ARES_RTOS_AMP
  mbox_put(id, MBOX_DONE, 1u);
  /* Same retire signature as halt(0): a0 = 0 + EBREAK, then spin. */
  __asm__ volatile("li a0, 0\n\tebreak\n1: j 1b" ::: "a0", "memory");
  while (1) {}
#endif
}

#ifdef ARES_RTOS_AMP
void coremark_worker(void)
{
  uint32_t id = hart_id();
  uint32_t completed = 0;

  for (;;) {
    uint32_t round = mbox_get(id, MBOX_GO);
    if (round != completed) {
      coremark_hart(id);
      mbox_put(id, MBOX_DONE, round);
      completed = round;
    }
  }
}
#endif

/*---------------------------------------------------------------------------
 * CoreMark parallel hooks (called by core_main.c when MULTITHREAD>1)
 *-------------------------------------------------------------------------*/
ee_u8 core_start_parallel(core_results *res) {
#ifdef ARES_RTOS_AMP
  ee_u32 ctx = start_context++;
#else
  static ee_u32 ctx; /* 0 = context 0 (runs inline on hart0) */
#endif

  if (ctx >= 1u && ctx < ARES_MT_CORES) {
    mbox_put(ctx, MBOX_ITER,  res->iterations);
    mbox_put(ctx, MBOX_EXECS, res->execs);
    mbox_put(ctx, MBOX_SIZE,  res->size);
    mbox_put(ctx, MBOX_SEED1, (ee_u32)res->seed1);
    mbox_put(ctx, MBOX_SEED2, (ee_u32)res->seed2);
    mbox_put(ctx, MBOX_SEED3, (ee_u32)res->seed3);
    /* Descriptor stores and GO use the same in-order MMIO port, so GO can
     * never be observed before the descriptors it depends on. */
    __asm__ volatile("" ::: "memory");
#ifdef ARES_RTOS_AMP
    mbox_put(ctx, MBOX_GO, round_id);
#else
    mbox_put(ctx, MBOX_GO, 1u);
#endif
  }
#ifndef ARES_RTOS_AMP
  ctx++;
#endif
  return 0;
}

ee_u8 core_stop_parallel(core_results *res) {
#ifdef ARES_RTOS_AMP
  ee_u32 ctx = stop_context++;
#else
  static ee_u32 ctx;
#endif

  if (ctx == 0u) {
    /* Context 0 runs on this hart between start and stop so that it overlaps
     * the workers released by core_start_parallel(&results[1..N-1]). */
    iterate(res);
#ifdef ARES_RTOS_AMP
    final_crc = res->crc;
#endif
  } else if (ctx < ARES_MT_CORES) {
#ifdef ARES_RTOS_AMP
    const CORE_TICKS join_start = read_cycles();
    while (mbox_get(ctx, MBOX_DONE) != round_id) {
      if (read_cycles() - join_start >= 30ull * COREMARK_CLOCK_HZ) {
        ee_printf("CoreMark: timeout waiting for hart %u\n", ctx);
        halt(3);
      }
    }
#else
    while (mbox_get(ctx, MBOX_DONE) == 0u) {}
#endif
    __asm__ volatile("" ::: "memory");
    res->crclist   = (ee_u16)mbox_get(ctx, MBOX_CRCLIST);
    res->crcmatrix = (ee_u16)mbox_get(ctx, MBOX_CRCMATRIX);
    res->crcstate  = (ee_u16)mbox_get(ctx, MBOX_CRCSTATE);
    res->crc       = (ee_u16)mbox_get(ctx, MBOX_CRCFINAL);
    res->err       = (ee_s16)mbox_get(ctx, MBOX_ERR);
#ifdef ARES_RTOS_AMP
    if (res->crc != final_crc || res->err != 0) {
      ee_printf("CoreMark: result mismatch from hart %u\n", ctx);
      workers_ok = 0;
    }
#endif
  }
#ifndef ARES_RTOS_AMP
  ctx++;
#endif
  return 0;
}

/* Function : portable_init
	Target specific initialization code
	Test for some common mistakes.
*/
void portable_init(core_portable *p, int *argc, char *argv[])
{
#ifndef ARES_RTOS_AMP
	uint32_t id = hart_id();
#endif
	(void)argc;
	(void)argv;
	if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
		ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
	}
	if (sizeof(ee_u32) != 4) {
		ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
	}
	p->portable_id=1;
#ifdef ARES_RTOS_AMP
	workers_ok = 1;
	coremark_reset_list_shadow();
#else
	if (id >= 1u && id < ARES_MT_CORES) {
		coremark_hart(id);
	}
#endif
}
/* Function : portable_fini
	Target specific final code
*/
void portable_fini(core_portable *p)
{
	p->portable_id=0;
}
