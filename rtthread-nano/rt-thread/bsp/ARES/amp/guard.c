#include <finsh.h>
#include <rtthread.h>
#include <string.h>
#include "board.h"

#define GUARD_STATUS   JYD_MMIO32(0xe0001000u)
#define GUARD_INPUT    JYD_MMIO32(0xe0001004u)
#define GUARD_FINISH   JYD_MMIO32(0xe0001008u)
#define GUARD_OUTPUT   JYD_MMIO32(0xe000100cu)
#define INPUT_READY    (1u << 0)
#define OUTPUT_VALID   (1u << 1)
#define FRAME_BUSY     (1u << 2)
#define LAST_OVERFLOW  (1u << 3)
#define USE_NER        (1u << 4)
#define END_TOKEN      (1u << 8)
#define FRAME_ERROR    (1u << 9)
#define EXIT_SESSION   0x1d
#define IDLE_TICKS     (26u * RT_TICK_PER_SECOND / 10u)

static struct rt_thread worker;
static rt_uint8_t stack[2048] __attribute__((aligned(16)));
static struct rt_semaphore request, finished;
static int selftest, test_result;
static unsigned frames, errors;
int guard_console_owned;

extern int amp_console_work_pending(void);

static void put_wire_byte(unsigned byte)
{
    if (byte == '\n')
        JYD_MMIO32(JYD_CONSOLE_ADDR) = '\r';
    JYD_MMIO32(JYD_CONSOLE_ADDR) = byte;
}

static int run_selftest(void)
{
    static const char input[] = "13800138000\n";
    static const char expected[] = "*******8000\n[guard] ";
    char response[256];
    unsigned sent = 0, size = 0;
    int closed = 0;
    for (;;) {
        unsigned status = GUARD_STATUS;
        if (status & OUTPUT_VALID) {
            unsigned token = GUARD_OUTPUT;
            if (token & END_TOKEN) {
                response[size < sizeof(response) ? size : sizeof(response) - 1] = 0;
                return !(token & FRAME_ERROR) && size < sizeof(response) &&
                       !strncmp(response, expected, sizeof(expected) - 1) &&
                       rt_strstr(response, " mobile=001 ") && rt_strstr(response, " ovf=000 ");
            }
            if (size < sizeof(response)) response[size++] = (char)token;
        } else if (!closed && (status & INPUT_READY)) {
            if (sent < sizeof(input) - 1)
                GUARD_INPUT = (unsigned char)input[sent++];
            else {
                GUARD_FINISH = 1;
                closed = 1;
            }
        } else {
            rt_thread_mdelay(1);
        }
    }
}

static void run_session(void)
{
    int have_frame = 0, need_end = 0, draining = 0;
    int skip_lf = ares_console_last_was_cr();
    rt_tick_t last_byte = 0;
    for (;;) {
        unsigned status = GUARD_STATUS;
        if (status & OUTPUT_VALID) {
            unsigned token = GUARD_OUTPUT;
            if (token & END_TOKEN) {
                frames++;
                if (token & FRAME_ERROR) errors++;
                draining = 0;
            } else {
                put_wire_byte(token & 255u);
            }
        }
        if (!draining && (status & INPUT_READY)) {
            if (need_end) {
                GUARD_FINISH = 1;
                have_frame = need_end = 0;
                draining = 1;
                continue;
            }
            int byte = ares_console_read_byte();
            if (byte >= 0) {
                if (skip_lf) {
                    skip_lf = 0;
                    if (byte == '\n') continue;
                }
                if (!have_frame && byte == EXIT_SESSION)
                    return;
                GUARD_INPUT = (unsigned)byte;
                have_frame = 1;
                need_end = byte == '\n';
                last_byte = rt_tick_get();
                continue;
            }
            if (have_frame && rt_tick_get() - last_byte >= IDLE_TICKS) {
                need_end = 1;
                continue;
            }
        }
        if (!(status & OUTPUT_VALID)) rt_thread_mdelay(1);
    }
}

static void guard_entry(void *arg)
{
    (void)arg;
    for (;;) {
        rt_sem_take(&request, RT_WAITING_FOREVER);
        if (selftest)
            test_result = run_selftest();
        else
            run_session();
        rt_sem_release(&finished);
    }
}

static int guard_command(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "status")) {
        unsigned status = GUARD_STATUS;
        rt_kprintf("Guard %s, NER=%u frames=%u errors=%u last_ovf=%u\n",
                   status & FRAME_BUSY ? "busy" : "ready", !!(status & USE_NER),
                   frames, errors, !!(status & LAST_OVERFLOW));
        return 0;
    }
    if (argc != 2 || (strcmp(argv[1], "start") && strcmp(argv[1], "selftest"))) {
        rt_kprintf("usage: guard start|status|selftest\n");
        return -1;
    }
    if (amp_console_work_pending()) {
        rt_kprintf("Guard needs the console. Stop live AI and wait for pending work.\n");
        return -1;
    }
    selftest = !strcmp(argv[1], "selftest");
    if (!selftest)
        rt_kprintf("GUARD READY (Ctrl+] at frame boundary exits)\n");
    guard_console_owned = 1;
    rt_sem_release(&request);
    // FinSH stays inside this command while the worker owns the UART RX FIFO.
    rt_sem_take(&finished, RT_WAITING_FOREVER);
    guard_console_owned = 0;
    if (selftest) {
        rt_kprintf("Guard selftest %s\n", test_result ? "PASS" : "FAIL");
        return test_result ? 0 : -1;
    }
    rt_kprintf("GUARD EXIT\n");
    return 0;
}
MSH_CMD_EXPORT_ALIAS(guard_command, guard, run the serial PII redaction service);

void guard_app_init(void)
{
    rt_sem_init(&request, "guardreq", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&finished, "guardend", 0, RT_IPC_FLAG_FIFO);
    rt_thread_init(&worker, "guard", guard_entry, RT_NULL, stack, sizeof(stack), 19, 5);
    rt_thread_startup(&worker);
    rt_kprintf("Guard service ready. Type guard start.\n");
}
