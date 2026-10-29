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

ee_u32 default_num_contexts=1;

/* Function : portable_init
	Target specific initialization code
	Test for some common mistakes.
*/
void portable_init(core_portable *p, int *argc, char *argv[])
{
	if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
		ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
	}
	if (sizeof(ee_u32) != 4) {
		ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
	}
	p->portable_id=1;
}
/* Function : portable_fini
	Target specific final code
*/
void portable_fini(core_portable *p)
{
	p->portable_id=0;
}


