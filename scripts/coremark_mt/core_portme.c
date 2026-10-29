/*=============================================================================
 * ARES CoreMark port - MULTITHREAD=2 overlay (staged copy only)
 *-----------------------------------------------------------------------------
 * This file is NOT part of tests/benchmarks/coremark/.  scripts/
 * build_coremark_image.py copies the vendored EEMBC port into build/ and
 * replaces include/core_portme.h + src/core_portme.c with the files in
 * scripts/coremark_mt/ when --mt is given.  The repository copy of CoreMark
 * therefore stays byte-identical.
 *
 * Two harts, one CoreMark report:
 *   hart0  core_main() master: start_time(), launch context 0 (inline) and
 *          context 1 (mailbox GO), stop_time(), print the single aggregate.
 *   hart1  portable_init() slave: waits for GO, re-initialises its own private
 *          data block exactly like core_main did for context 1, runs iterate()
 *          and publishes the CRCs through the shared MMIO mailbox, then EBREAKs
 *          with a0=0 so the existing 2-core testbench keeps its done/a0 checks.
 *
 * The mailbox is MMIO (memory.md 3.1): it bypasses the private L1D, the shared
 * L2 and the +1 MiB D-side offset, and its loads/stores are commit-head
 * serialized, so no cache maintenance or fence is required.  No shared DRAM is
 * used, which keeps the AMP private-window checker in tb_2core_coremark valid.
 *===========================================================================*/
#include "coremark.h"
#include <ares.h>

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
  /* Finish the startup banner before entering the timed section. */
  while (inl(SERIAL_STATUS) & 1u) {}
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
  assert(ticks != 0);
  ee_printf("CPU clock (MHz) : %d\n", COREMARK_CLOCK_HZ / 1000000u);
  ee_printf("Total ticks     : ");
  print_u64(ticks);
  ee_printf("\n");
  print_ratio("Total time (secs): ", ticks, COREMARK_CLOCK_HZ);
  ee_printf("Iterations      : %d\n", iterations);
  print_ratio("Iterations/Sec  : ", (uint64_t)iterations * COREMARK_CLOCK_HZ, ticks);
  print_ratio("CoreMark/MHz    : ", (uint64_t)iterations * 1000000u, ticks);
}

ee_u32 default_num_contexts=2;

/*---------------------------------------------------------------------------
 * Shared mailbox helpers
 *-------------------------------------------------------------------------*/
static uint32_t hart_id(void) {
  uint32_t id;
  __asm__ volatile("csrr %0, mhartid" : "=r"(id));
  return id;
}

static uint32_t mbox_get(uint32_t off) {
  return inl(MBOX_BASE + off);
}

static void mbox_put(uint32_t off, uint32_t value) {
  outl(MBOX_BASE + off, value);
}

/*---------------------------------------------------------------------------
 * hart1: private context 1 data, initialised exactly as core_main.c does
 * before it calls core_start_parallel(&results[1]).
 *-------------------------------------------------------------------------*/
static core_results mt_results;
static ee_u8 mt_memblock[TOTAL_DATA_SIZE] __attribute__((aligned(8)));

static void coremark_hart1(void) {
  ee_u32 size;

  while (mbox_get(MBOX_GO) == 0u) {}
  __asm__ volatile("" ::: "memory");

  size = mbox_get(MBOX_SIZE);
  mt_results.size       = size;
  mt_results.iterations = mbox_get(MBOX_ITER);
  mt_results.execs      = mbox_get(MBOX_EXECS);
  mt_results.seed1      = (ee_s16)mbox_get(MBOX_SEED1);
  mt_results.seed2      = (ee_s16)mbox_get(MBOX_SEED2);
  mt_results.seed3      = (ee_s16)mbox_get(MBOX_SEED3);

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

  iterate(&mt_results);

  mbox_put(MBOX_CRCLIST,   mt_results.crclist);
  mbox_put(MBOX_CRCMATRIX, mt_results.crcmatrix);
  mbox_put(MBOX_CRCSTATE,  mt_results.crcstate);
  mbox_put(MBOX_CRCFINAL,  mt_results.crc);
  mbox_put(MBOX_ERR,       0u);
  mbox_put(MBOX_DONE,      1u);

  /* Same retire signature as halt(0): a0 = 0 + EBREAK, then spin. */
  __asm__ volatile("li a0, 0\n\tebreak\n1: j 1b" ::: "a0", "memory");
  while (1) {}
}

/*---------------------------------------------------------------------------
 * CoreMark parallel hooks (called by core_main.c when MULTITHREAD>1)
 *-------------------------------------------------------------------------*/
ee_u8 core_start_parallel(core_results *res) {
  static ee_u32 ctx; /* 0 = context 0, 1 = context 1 */

  if (ctx == 1u) {
    mbox_put(MBOX_ITER,  res->iterations);
    mbox_put(MBOX_EXECS, res->execs);
    mbox_put(MBOX_SIZE,  res->size);
    mbox_put(MBOX_SEED1, (ee_u32)res->seed1);
    mbox_put(MBOX_SEED2, (ee_u32)res->seed2);
    mbox_put(MBOX_SEED3, (ee_u32)res->seed3);
    mbox_put(MBOX_GO,    1u);
  }
  ctx++;
  return 0;
}

ee_u8 core_stop_parallel(core_results *res) {
  static ee_u32 ctx;

  if (ctx == 0u) {
    /* Context 0 runs on this hart between start and stop so that it overlaps
     * hart1, which was released by core_start_parallel(&results[1]). */
    iterate(res);
  } else {
    while (mbox_get(MBOX_DONE) == 0u) {}
    res->crclist   = (ee_u16)mbox_get(MBOX_CRCLIST);
    res->crcmatrix = (ee_u16)mbox_get(MBOX_CRCMATRIX);
    res->crcstate  = (ee_u16)mbox_get(MBOX_CRCSTATE);
    res->crc       = (ee_u16)mbox_get(MBOX_CRCFINAL);
    res->err       = (ee_s16)mbox_get(MBOX_ERR);
  }
  ctx++;
  return 0;
}

/* Function : portable_init
	Target specific initialization code
	Test for some common mistakes.
*/
void portable_init(core_portable *p, int *argc, char *argv[])
{
	(void)argc;
	(void)argv;
	if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
		ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
	}
	if (sizeof(ee_u32) != 4) {
		ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
	}
	p->portable_id=1;
	if (hart_id() == 1u) {
		coremark_hart1();
	}
}
/* Function : portable_fini
	Target specific final code
*/
void portable_fini(core_portable *p)
{
	p->portable_id=0;
}
