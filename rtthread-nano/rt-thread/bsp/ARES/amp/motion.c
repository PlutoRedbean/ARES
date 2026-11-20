#include <finsh.h>
#include <rtthread.h>
#include "board.h"

#define MOTION_BASE 0xd0003020u
#define MOTION_WORD(n) JYD_MMIO32(MOTION_BASE + 4u * (n))
#define READY 1u
#define PRESENT 2u

extern int amp_console_work_pending(void);

/* FinSH owns UART RX for the duration of the command. A single console
 * write per report keeps M1 lines intact alongside optional IMU telemetry. */
static int motion_command(int argc, char **argv)
{
    (void)argv;
    if (argc != 1 || !(MOTION_WORD(0) & PRESENT)) {
        rt_kprintf("motion requires the AMP+HDMI image and takes no arguments\n");
        return -1;
    }
    if (amp_console_work_pending()) {
        rt_kprintf("Stop live AI and wait for pending work before motion\n");
        return -1;
    }
    MOTION_WORD(0) = 1;  /* Discard any report predating the session. */
    rt_kprintf("MOTION READY (Ctrl+] exits)\n");
    while (ares_console_read_byte() != 0x1d) {
        if (MOTION_WORD(0) & READY) {
            static const char hex[] = "0123456789abcdef";
            char mask[37];
            MOTION_WORD(0) = 1;
            unsigned seq = MOTION_WORD(1), info = MOTION_WORD(2);
            unsigned word = 0;
            for (unsigned i = 0; i < 18; ++i) {
                if (i % 4 == 0)
                    word = MOTION_WORD(3 + i / 4);
                mask[i * 2] = hex[(word >> 4) & 15];
                mask[i * 2 + 1] = hex[word & 15];
                word >>= 8;
            }
            mask[36] = 0;
            rt_kprintf("M1 %u %u %u %u %s\n", seq, info >> 16,
                       info & 255, (info >> 8) & 255, mask);
        }
        rt_thread_mdelay(2);
    }
    rt_kprintf("MOTION EXIT\n");
    return 0;
}
MSH_CMD_EXPORT_ALIAS(motion_command, motion, stream FPGA motion summaries);
