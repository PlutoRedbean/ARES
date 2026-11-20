#include <rtthread.h>
#include "board.h"
#include "mt_detect.h"
#include "mt_track.h"
#include "mt.h"
#include "ares_soc.h"

#define CAMERA_FRAME_READY 0xd0003000u
#define REPORT_PERIOD (RT_TICK_PER_SECOND / 10)

/* Gesture classes: 0=idle, 1=defense, 2=point; -1=unknown/invalid.
 * This matches the retrained model's CLASSES order in tools/ml. */
#define GEST_IDLE    0
#define GEST_DEFENSE 1
#define GEST_POINT   2

#define GEST_F_NO_CONTRAST 0x01u
#define GEST_F_LOW_CONF    0x02u
#define GEST_F_INFER_ERR   0x04u
#define GEST_F_AI_OFF      0x08u

static const trk_t roi = {.cx = 16, .cy = 14, .w = 13, .h = 11};
static uint8_t patch[32 * 32];
static int candidate, consecutive, shown;
static int margin;
static unsigned int gesture_seq;
static rt_tick_t last_report;

int gesture_dma_idle(void)
{
    return !(MT_MMIO32(MT_STATUS) & MT_ST_BUSY);
}

/* G line, 10 Hz:
 *
 *   G <seq> <stable> <raw> <s_idle> <s_defense> <s_point> <margin> <flags>
 *
 * stable/raw: -1 unknown, 0 idle, 1 defense, 2 point.
 * scores are raw model scores in idle/defense/point order.
 */
static void gesture_report(int stable, int raw, const int32_t scores[3],
                           int margin_v, unsigned int flags)
{
    printf("G %u %d %d %d %d %d %d %u\n",
           gesture_seq++, stable, raw,
           (int)scores[0], (int)scores[1], (int)scores[2],
           margin_v, flags);
}

void gesture_reset(void)
{
    candidate = shown = -1;
    consecutive = margin = 0;
    gesture_seq = 0;
    last_report = rt_tick_get() - REPORT_PERIOD;
    /* Drop any frame left over from stop or CoreMark. */
    JYD_MMIO32(CAMERA_FRAME_READY) = 1;
}

void gesture_neutral(void)
{
    static const int32_t zero[3] = {0, 0, 0};
    gesture_report(-1, -1, zero, 0, GEST_F_AI_OFF);
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
    int raw = -1;
    int32_t scores[3] = {0, 0, 0};
    unsigned int flags = 0;
    margin = 0;

    if (!valid || high - low < 20) {
        flags |= GEST_F_NO_CONTRAST;
    } else {
        int best = rps_forward(patch, scores);
        if (best < 0) {
            flags |= GEST_F_INFER_ERR;
            gesture_report(-1, -1, scores, 0, flags);
            return best;
        }
        raw = best;
        int second = scores[(best + 1) % 3];
        if (scores[(best + 2) % 3] > second)
            second = scores[(best + 2) % 3];
        margin = scores[best] - second;
        if (margin >= 4)
            current = best;
        else
            flags |= GEST_F_LOW_CONF;
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
        gesture_report(shown < 0 ? -1 : shown, raw, scores, margin, flags);
    }
    return 1;
}
