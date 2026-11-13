#include <rtthread.h>
#include "board.h"
#include "mt_detect.h"
#include "mt_track.h"
#include "mt.h"
#include "ares_soc.h"

#define CAMERA_FRAME_READY 0xd0003000u
#define REPORT_PERIOD (RT_TICK_PER_SECOND / 10)

static const char *const labels[] = {"rock", "paper", "scissors"};
static const trk_t roi = {.cx = 16, .cy = 14, .w = 13, .h = 11};
static uint8_t patch[32 * 32];
static int candidate, consecutive, shown;
static int margin;
static rt_tick_t last_report;

int gesture_dma_idle(void)
{
    return !(MT_MMIO32(MT_STATUS) & MT_ST_BUSY);
}

void gesture_reset(void)
{
    candidate = shown = -1;
    consecutive = margin = 0;
    last_report = rt_tick_get() - REPORT_PERIOD;
    /* Drop any frame left over from stop or CoreMark. */
    JYD_MMIO32(CAMERA_FRAME_READY) = 1;
}

void gesture_neutral(void)
{
    printf("\nhand: none\n");
}

/* Return when there is no new frame. Release the bank as soon as the ROI
 * is copied, so capture can continue during the accelerator work. */
int gesture_step(void)
{
    if (!(JYD_MMIO32(CAMERA_FRAME_READY) & 1))
        return 0;

    int edge;
    int valid = trk_patch(&roi, patch, &edge) && !edge;
    JYD_MMIO32(CAMERA_FRAME_READY) = 1;

    unsigned low = 255, high = 0;
    for (unsigned i = 0; i < sizeof(patch); i++) {
        if (patch[i] < low) low = patch[i];
        if (patch[i] > high) high = patch[i];
    }

    int current = -1;
    margin = 0;
    if (valid && high - low >= 20) {
        int32_t scores[3];
        int best = rps_forward(patch, scores);
        if (best < 0)
            return best;
        int second = scores[(best + 1) % 3];
        if (scores[(best + 2) % 3] > second)
            second = scores[(best + 2) % 3];
        margin = scores[best] - second;
        if (margin >= 4)
            current = best;
    }

    if (current != candidate) {
        candidate = current;
        consecutive = 0;
        shown = -1;
    }
    if (current < 0) {
        shown = -1;
    } else if (consecutive < 3 && ++consecutive == 3) {
        shown = current;
    }

    rt_tick_t now = rt_tick_get();
    if (now - last_report >= REPORT_PERIOD) {
        last_report = now;
        if (shown < 0)
            gesture_neutral();
        else
            printf("\nhand: %s margin %d\n", labels[shown], margin);
    }
    return 1;
}
