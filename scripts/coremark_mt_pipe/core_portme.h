/* Topic : Description
	This file contains configuration constants required to execute on different platforms
*/


#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <am.h>
#include <klib.h>
#include <klib-macros.h>

/* ARES pipeline 2/4-hart MULTITHREAD overlay (staged copy only).
 *
 * The build flow passes the run configuration as compile-time macros:
 *   ARES_MT_CORES      number of harts / CoreMark contexts (2 or 4)
 *   ARES_MT_ITERATIONS iterations per context (TOTAL_ITERATIONS / CORES)
 * scripts/build_coremark_image.py --mt-pipe appends these to the staged
 * Makefile, so the same overlay serves the 2- and 4-hart images.
 *
 * core_main.c rejects MEM_STATIC when MULTITHREAD>1, so each context gets
 * its data block on its own private stack (see core_main.c). */
#ifndef ARES_MT_CORES
#define ARES_MT_CORES 2
#endif
#ifndef ARES_MT_ITERATIONS
#define ARES_MT_ITERATIONS 5000
#endif

/* Reported total iterations must stay consistent across CORES. */
#define ITERATIONS ARES_MT_ITERATIONS
#define MEM_METHOD MEM_STACK
#define COREMARK_CLOCK_HZ 100000000u

/************************/
/* Data types and settings */
/************************/
/* Configuration : HAS_FLOAT
	Define to 1 if the platform supports floating point.
*/
#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif
/* Configuration : HAS_TIME_H
	Define to 1 if platform has the time.h header file,
	and implementation of functions thereof.
*/
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
/* Configuration : USE_CLOCK
	Define to 1 if platform has the time.h header file,
	and implementation of functions thereof.
*/
#ifndef USE_CLOCK
#define USE_CLOCK 1
#endif
/* Configuration : HAS_STDIO
	Define to 1 if the platform has stdio.h.
*/
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
/* Configuration : HAS_PRINTF
	Define to 1 if the platform has stdio.h and implements the printf function.
*/
#ifndef HAS_PRINTF
#define HAS_PRINTF 1
#endif

/* Configuration : CORE_TICKS
	Define type of return from the timing functions.
 */
	typedef uint64_t CORE_TICKS;

/* Definitions : COMPILER_VERSION, COMPILER_FLAGS, MEM_LOCATION
	Initialize these strings per platform
*/
#ifndef COMPILER_VERSION
 #ifdef __GNUC__
 #define COMPILER_VERSION "GCC"__VERSION__
 #else
 #define COMPILER_VERSION "Please put compiler version here (e.g. gcc 4.1)"
 #endif
#endif
#ifndef COMPILER_FLAGS
 #define COMPILER_FLAGS
#endif
#ifndef MEM_LOCATION
 #define MEM_LOCATION "STACK"
#endif

/* Data Types :
	To avoid compiler issues, define the data types that need ot be used for 8b, 16b and 32b.

	*Imprtant* :
	ee_ptr_int needs to be the data type used to hold pointers, otherwise coremark may fail!!!
*/
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef double ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef unsigned long ee_ptr_int;
typedef size_t ee_size_t;
/* align_mem :
	This macro is used to align an offset to point to a 32b value. It is used in the Matrix algorithm to initialize the input memory blocks.
*/
#define align_mem(x) (void *)(4 + (((unsigned long)(x) - 1) & ~3))

/* Configuration : SEED_METHOD
	Defines method to get seed values that cannot be computed at compile time.

	Valid values :
	SEED_ARG - from command line.
	SEED_FUNC - from a system function.
	SEED_VOLATILE - from volatile variables.
*/
#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

/* Configuration : MEM_METHOD
	Defines method to get a block of memry.

	Valid values :
	MEM_MALLOC - for platforms that implement malloc and have malloc.h.
	MEM_STATIC - to use a static memory array.
	MEM_STACK - to allocate the data block on the stack (NYI).
*/
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STACK
#endif

/* Configuration : MULTITHREAD
	Define for parallel execution

	Valid values :
	1 - only one context (default).
	N>1 - will execute N copies in parallel.

	Note :
	If this flag is defined to more then 1, an implementation for launching parallel contexts must be defined.

	Two sample implementations are provided. Use <USE_PTHREAD> or <USE_FORK> to enable them.

	It is valid to have a different implementation of <core_start_parallel> and <core_end_parallel> in <core_portme.c>,
	to fit a particular architecture.
*/
#ifndef MULTITHREAD
#define MULTITHREAD ARES_MT_CORES
#endif

/* Reported by core_main.c after the single aggregate CoreMark report. */
#define PARALLEL_METHOD "ares-mt-mbox"

/* Configuration : MAIN_HAS_NOARGC
	Needed if platform does not support getting arguments to main.

	Valid values :
	0 - argc/argv to main is supported
	1 - argc/argv to main is not supported

	Note :
	This flag only matters if MULTITHREAD has been defined to a value greater then 1.
*/
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 0
#endif

/* Configuration : MAIN_HAS_NORETURN
	Needed if platform does not support returning a value from main.

	Valid values :
	0 - main returns an int, and return value will be 0.
	1 - platform does not support returning a value from main
*/
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

/* Variable : default_num_contexts
	Number of parallel contexts launched by core_main.c (one per hart).
*/
extern ee_u32 default_num_contexts;
void coremark_report_time(CORE_TICKS ticks, ee_u32 iterations);

/* Hart identity and shared 2/4-hart mailbox (rtl/pipeline/soc/mc/
 * pipeline_coremark_mbox.sv).  MMIO at 0xA000_F000, one 16-word slot per
 * hart, slot h base = MBOX_BASE + h * MBOX_SLOT_STRIDE.
 *
 * The mailbox is uncached MMIO: it bypasses the private L1 D$ and every
 * access is a commit-head, strongly ordered device operation, so no cache
 * maintenance or atomics are required. */
#define HART_ID_ADDR      0xa0000ff0u
#define HART_COUNT_ADDR   0xa0000ff4u
#define MBOX_BASE         0xa000f000u
#define MBOX_SLOT_STRIDE  0x40u
#define MBOX_GO           0x00u  /* hart0 -> hart h: descriptors valid      */
#define MBOX_DONE         0x04u  /* hart h -> hart0: result registers valid */
#define MBOX_ITER         0x08u
#define MBOX_EXECS        0x0cu
#define MBOX_SIZE         0x10u
#define MBOX_SEED1        0x14u
#define MBOX_SEED2        0x18u
#define MBOX_SEED3        0x1cu
#define MBOX_CRCLIST      0x20u
#define MBOX_CRCMATRIX    0x24u
#define MBOX_CRCSTATE     0x28u
#define MBOX_CRCFINAL     0x2cu
#define MBOX_ERR          0x30u

typedef struct CORE_PORTABLE_S {
	ee_u8	portable_id;
} core_portable;

/* target specific init/fini */
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE==1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE==2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif


#endif /* CORE_PORTME_H */
