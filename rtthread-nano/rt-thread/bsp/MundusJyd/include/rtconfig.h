#ifndef __RTTHREAD_CFG_H__
#define __RTTHREAD_CFG_H__

#define RT_NAME_MAX                 8
#define RT_ALIGN_SIZE               4
#define RT_THREAD_PRIORITY_MAX      32
#define RT_TICK_PER_SECOND          1000

#define RT_USING_USER_MAIN
#define RT_MAIN_THREAD_STACK_SIZE   1024
#define RT_MAIN_THREAD_PRIORITY     10

/* A complete RV32 trap frame alone occupies 128 bytes.  The Nano default
 * idle stack is also only 128 bytes, so leave room for the C tick handler. */
#define IDLE_THREAD_STACK_SIZE      1024

#define RT_USING_CONSOLE
#define RT_CONSOLEBUF_SIZE          256

#ifdef MUNDUS_JYD_COMPETITION
#define RT_USING_SEMAPHORE
#define RT_USING_FINSH
#define FINSH_USING_MSH
#define FINSH_USING_SYMTAB
#define FINSH_USING_DESCRIPTION
#define FINSH_THREAD_STACK_SIZE     6144
#define FINSH_THREAD_PRIORITY       20
#define FINSH_CMD_SIZE              80
#endif

#endif
