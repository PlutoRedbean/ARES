/* imu.c - RT-Thread IMU telemetry thread for the 4-hart AMP.
 *
 * Reads 36-byte wire frames from UART2 (AD26) and prints one "D ..." line per
 * valid frame on the shared console UART (C24).  Mapping stays on the PC in
 * this phase: xbox_serial --imu-port.  No imu_map.c here.
 */
#include <rtthread.h>
#include <rthw.h>
#include <finsh.h>
#include "board.h"
#include "wire.h"

#define IMU_RX_DATA   (*(volatile rt_uint32_t *)0xA0000400u)
#define IMU_RX_STATUS (*(volatile rt_uint32_t *)0xA0000404u)
#define IMU_RX_VALID  0x1u
#define IMU_RX_OVF    0x2u

extern volatile int g_bench_active;

static struct rt_thread imu_thread;
static rt_uint8_t imu_stack[2048] __attribute__((aligned(16)));

static unsigned char frame[WIRE_FRAME_LEN];
static unsigned char frame_idx, frame_prev;

static unsigned int frames, bad, overflow_count;
static unsigned short last_seq;
static unsigned char last_flags;
static int overflow_latched;
/* Default silent: the board boots with MSH usable and no D-line flood.
 * Send `imu start` (or tools/amp_cmd.py --cmd "imu start") when the PC
 * mapper should receive telemetry. */
static volatile int imu_enabled = 0;

/* Do not use rt_hw_console_getchar(): char is unsigned on RISC-V, so its
 * (char)-1 sentinel is indistinguishable from a valid 0xFF data byte. */
static int imu_getchar(void)
{
    rt_uint32_t st = IMU_RX_STATUS;

    /* The FIFO overflow bit is sticky; count it once, not once per poll. */
    if (st & IMU_RX_OVF) {
        if (!overflow_latched) {
            overflow_count++;
            overflow_latched = 1;
        }
    } else {
        overflow_latched = 0;
    }

    if ((st & IMU_RX_VALID) == 0u)
        return -1;
    return (int)(IMU_RX_DATA & 0xFFu);
}

static void put_hex16(char *line, int *n, short v)
{
    static const char *H = "0123456789abcdef";
    unsigned short u = (unsigned short)v;

    line[(*n)++] = H[(u >> 12) & 15];
    line[(*n)++] = H[(u >> 8) & 15];
    line[(*n)++] = H[(u >> 4) & 15];
    line[(*n)++] = H[u & 15];
}

static void put_d_line(const wire_data_t *d)
{
    char line[48];
    int n = 0;

    line[n++] = 'D';
    for (int i = 0; i < 3; i++) put_hex16(line, &n, d->acc[i]);
    for (int i = 0; i < 3; i++) put_hex16(line, &n, d->gyro[i]);
    for (int i = 0; i < 3; i++) put_hex16(line, &n, d->angle[i]);
    line[n++] = '\n';
    line[n] = '\0';

    /* Same console critical section as printf/rt_kprintf: an AI "hand:" line
     * cannot split a D line.  rt_hw_console_output emits CRLF, which the PC
     * TelemetryParser strips. */
    rt_hw_console_output(line);
}

static int push_byte(unsigned char b, wire_data_t *out)
{
    if (frame_idx == 0) {
        if (frame_prev == WIRE_SYNC0 && b == WIRE_SYNC1) {
            frame[0] = WIRE_SYNC0;
            frame[1] = WIRE_SYNC1;
            frame_idx = 2;
        }
        frame_prev = b;
        return 0;
    }

    frame[frame_idx++] = b;
    if (frame_idx == WIRE_HDR_LEN) {
        if (frame[2] != WIRE_VERSION || frame[5] != WIRE_BODY_LEN) {
            frame_idx = 0;
            frame_prev = b;
            bad++;
        }
        return 0;
    }
    if (frame_idx < WIRE_FRAME_LEN)
        return 0;

    int ok = wire_decode_data(frame, WIRE_FRAME_LEN, out);
    frame_idx = 0;
    frame_prev = b;
    if (!ok)
        bad++;
    return ok;
}

static void imu_entry(void *arg)
{
    wire_data_t d;

    (void)arg;
    for (;;) {
        if (g_bench_active) {
            /* Do not steal hart0 from CoreMark, and do not let stale FIFO
             * bytes corrupt the first frame after the benchmark. */
            frame_idx = 0;
            while (imu_getchar() >= 0) { }
            rt_thread_mdelay(20);
            continue;
        }

        if (!imu_enabled) {
            /* `imu stop`: keep the UART drained, but do not print D lines. */
            frame_idx = 0;
            while (imu_getchar() >= 0) { }
            rt_thread_mdelay(10);
            continue;
        }

        int ch;
        while ((ch = imu_getchar()) >= 0) {
            if (push_byte((unsigned char)ch, &d)) {
                frames++;
                last_seq = d.seq;
                last_flags = d.flags;

                /* Emit only when acc/gyro/angle are valid and the bridge did
                 * not flag LINK_LOST or IMU_STALE.  DEGRADED (20 Hz) is fine.
                 * The PC times out at 250 ms otherwise. */
                if ((d.flags & 0x37u) == 0x07u)
                    put_d_line(&d);
            }
        }
        rt_thread_mdelay(1);
    }
}

static int imu_command(int argc, char **argv)
{
    if (argc == 2) {
        if (rt_strcmp(argv[1], "stop") == 0) {
            imu_enabled = 0;
            rt_kprintf("imu stopped\n");
            return 0;
        }
        if (rt_strcmp(argv[1], "start") == 0) {
            imu_enabled = 1;
            rt_kprintf("imu started\n");
            return 0;
        }
        if (rt_strcmp(argv[1], "status") != 0) {
            rt_kprintf("usage: imu [start|stop|status]\n");
            return -1;
        }
    } else if (argc != 1) {
        rt_kprintf("usage: imu [start|stop|status]\n");
        return -1;
    }

    rt_kprintf("imu enabled=%d frames=%u bad=%u ovf=%u seq=%u flags=0x%02x bench=%d\n",
               imu_enabled, frames, bad, overflow_count, last_seq, last_flags,
               g_bench_active);
    return 0;
}
MSH_CMD_EXPORT_ALIAS(imu_command, imu, start/stop/status IMU telemetry);

int imu_app_init(void)
{
    if (rt_thread_init(&imu_thread, "imu", imu_entry, RT_NULL,
                       imu_stack, sizeof(imu_stack), 21, 10) != RT_EOK)
        return -1;
    return rt_thread_startup(&imu_thread);
}
