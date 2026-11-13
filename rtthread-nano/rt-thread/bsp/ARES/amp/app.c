#include <finsh.h>
#include <rtthread.h>
#include <string.h>
#include "board.h"
#include "mt_detect.h"

int printf(const char *fmt, ...);
void gesture_reset(void);
void gesture_neutral(void);
int gesture_step(void);
int gesture_dma_idle(void);

extern int coremark_main(void);
extern int coremark_workers_ok(void);
extern volatile int32_t seed1_volatile, seed2_volatile, seed4_volatile;

static struct rt_thread ai_thread, bench_thread;
static struct rt_semaphore ai_request, bench_request;
static rt_uint8_t ai_stack[4096] __attribute__((aligned(16)));
static rt_uint8_t bench_stack[12288] __attribute__((aligned(16)));
/* MSH submits requests. The AI thread hands off to CoreMark only between
 * frames. These flags are shared by threads on hart0. */
static volatile int live_requested, selftest_requested, bench_pending;

static void ai_entry(void *parameter)
{
    (void)parameter;
    int live = 0;
    for (;;) {
        if (bench_pending) {
            if (live) {
                gesture_neutral();
                live = 0;
            }
            if (gesture_dma_idle()) {
                rt_sem_release(&bench_request);
            } else {
                printf("CoreMark refused: miniTensor DMA is busy\n");
                live_requested = 0;
                bench_pending = 0;
            }
        }

        if (selftest_requested) {
            int32_t scores[3];
            int differences = rps_check_golden(0, scores);
            if (differences == 0)
                printf("AI selftest PASS: scores %d,%d,%d, golden diff 0\n",
                       scores[0], scores[1], scores[2]);
            else
                printf("AI selftest FAIL: golden diff %d\n", differences);
            selftest_requested = 0;
        }

        if (live != live_requested) {
            live = live_requested;
            if (live)
                gesture_reset();
            else
                gesture_neutral();
        }
        if (live && gesture_step() < 0) {
            gesture_neutral();
            printf("AI stopped: miniTensor inference failed\n");
            live_requested = 0;
            live = 0;
        }
        rt_sem_take(&ai_request, live ? 2 : RT_WAITING_FOREVER);
    }
}

static void bench_entry(void *parameter)
{
    (void)parameter;
    for (;;) {
        rt_sem_take(&bench_request, RT_WAITING_FOREVER);
        int result = coremark_main();
        printf("AMP CoreMark %s\n", result == 0 && coremark_workers_ok() ? "PASS" : "FAIL");
        bench_pending = 0;
    }
}

static int ai_command(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        rt_kprintf("AI %s\n", live_requested ? "running" : "stopped");
        return 0;
    }
    if (argc != 2 || (strcmp(argv[1], "start") != 0 &&
                     strcmp(argv[1], "stop") != 0 && strcmp(argv[1], "selftest") != 0)) {
        rt_kprintf("usage: ai start|stop|status|selftest\n");
        return -1;
    }
    if (bench_pending || selftest_requested) {
        rt_kprintf("AI or CoreMark already running\n");
        return -1;
    }

    if (strcmp(argv[1], "selftest") == 0) {
        if (live_requested) {
            rt_kprintf("Stop live AI before selftest\n");
            return -1;
        }
        selftest_requested = 1;
    } else {
        live_requested = strcmp(argv[1], "start") == 0;
    }
    return rt_sem_release(&ai_request);
}
MSH_CMD_EXPORT_ALIAS(ai_command, ai, control live gestures and run miniTensor self-test);

static int bench_command(int argc, char **argv)
{
    unsigned iterations = 20000;
    if (argc < 2 || argc > 4 || strcmp(argv[1], "start") != 0)
        goto usage;
    if (argc >= 3) {
        iterations = 0;
        for (const char *p = argv[2]; *p; p++) {
            if (*p < '0' || *p > '9' || iterations > 10000)
                goto usage;
            iterations = iterations * 10 + (unsigned)(*p - '0');
        }
        if (iterations == 0 || iterations > 100000)
            goto usage;
    }
    if (argc == 4 && strcmp(argv[3], "validation") != 0)
        goto usage;
    if (bench_pending || selftest_requested) {
        rt_kprintf("AI or CoreMark already running\n");
        return -1;
    }
    seed4_volatile = (int32_t)iterations;
    seed1_volatile = seed2_volatile = argc == 4 ? 0x3415 : 0;
    bench_pending = 1;
    return rt_sem_release(&ai_request);

usage:
    rt_kprintf("usage: coremark start [iterations-per-hart [validation]]\n");
    return -1;
}
MSH_CMD_EXPORT_ALIAS(bench_command, coremark, run four-hart CoreMark);

void amp_apps_init(void)
{
    rt_sem_init(&ai_request, "aireq", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&bench_request, "cmreq", 0, RT_IPC_FLAG_FIFO);
    rt_thread_init(&ai_thread, "ai", ai_entry, RT_NULL,
                   ai_stack, sizeof(ai_stack), 19, 5);
    rt_thread_init(&bench_thread, "coremark", bench_entry, RT_NULL,
                   bench_stack, sizeof(bench_stack), 18, 5);
    rt_thread_startup(&ai_thread);
    rt_thread_startup(&bench_thread);
}
