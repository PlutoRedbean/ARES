/*
 * mt_yolomodel.c -- a scheduled slice of a real YOLO model on miniTensor.
 *
 * Runs five consecutive stages of the tiny-yolov3 backbone with the model's real
 * trained weights (BatchNormalization folded) and its real LeakyReLU(0.1):
 *
 *     x -> conv3x3(3->16)  -> pool -> conv3x3(16->32)
 *       -> pool -> conv3x3(32->64)  -> pool -> conv3x3(64->128)
 *       -> pool -> conv3x3(128->256)
 *
 * at 64x64.  This is NOT a detector at that size -- the model was trained at
 * 416x416 -- the point is that the model's layer stack executes correctly and
 * can be checked bit for bit against an integer reference.
 *
 * Everything is addressed relative to ONE base, YM_BASE, in the uncached
 * extension window: the weight blob, the input, the activation buffers and the
 * goldens all live there.  Two consequences matter:
 *
 *   * the activations do not fit in the 64 KiB miniTensor scratch (the stem's
 *     output is 64 KiB and its padding buffer another 51 KiB), so this test
 *     would not be possible without the per-layer base added in Y16;
 *   * the accelerator's DMA reaches the same memory the CPU does, so a layer
 *     reads its weights straight out of the blob with no staging copy.
 *
 * A small scheduler walks the table emitted by pack_model.py, so adding layers
 * is a data change rather than a code change.
 */
#include <rtthread.h>
#include <finsh.h>

#include "board.h"
#include "mt.h"
#include "mt_net.h"
#include "mt_yolomodel_weights.h"

static inline volatile uint8_t *ym_at(uint32_t off)
{
    return (volatile uint8_t *)(uintptr_t)(YM_BASE + off);
}

static int mt_yolomodel_command(int argc, char **argv)
{
    uint32_t i, cmds = 0u, start, end;
    int rc, bad_total = 0;
    uint32_t stage = 0u;

    (void)argc;
    (void)argv;

    rt_kprintf("miniTensor scheduled real YOLO slice: %u layers from tiny-yolov3,"
               " base 0x%08x.\n", (unsigned)YM_LAYERS, (unsigned)YM_BASE);

    mt_reset_status();
    start = mt_rd_mcycle();
    JYD_MMIO32(JYD_LED_ADDR) = 1u;

    for (i = 0; i < YM_LAYERS; i++)
    {
        const ym_layer_t *T = &ym_layers[i];
        uint32_t j, bad = 0u, t0, t1;

        t0 = mt_rd_mcycle();

        if (T->kind == 0u)
        {
            net_layer_t L;

            L = (net_layer_t){T->h, T->w, T->cin, T->cout, T->k, T->pad, 0u, 0,
                              0u, 0, 0u, YM_PAD_OFF, T->out, 0u, 0u, 0u, 0u};
            L.base      = YM_BASE;
            L.src_w     = T->w;
            L.wpad      = T->w;
            L.wt_off    = T->wt;
            L.bias_off  = T->bias;
            L.cfg_off   = T->cfg;
            L.nmt       = ym_at(T->cfg)[4];
            L.leaky     = 1u;
            /* Layer 0's input is the blob's first bytes; every later layer
             * consumes the previous stage's output. */
            L.src_off   = (i == 0u) ? YM_IMG_OFF : ym_layers[i - 1u].out;

            net_pad(&L);
            if ((rc = net_conv(&L, &cmds)) != 0)
            {
                JYD_MMIO32(JYD_LED_ADDR) = 0u;
                rt_kprintf("  layer %u (conv %ux%ux%u->%u) FAILED, rc=%d\n",
                           (unsigned)i, (unsigned)T->h, (unsigned)T->w,
                           (unsigned)T->cin, (unsigned)T->cout, rc);
                halt(100);
                return rc;
            }
            stage++;
        }
        else
        {
            net_pool2(YM_BASE, ym_layers[i - 1u].out, T->out, T->cin / 4u,
                      T->h, T->w, 0u, 0u);
            stage++;
        }

        t1 = mt_rd_mcycle();

        /* Compare this stage against its golden, byte for byte. */
        for (j = 0; j < T->glen; j++)
        {
            if (ym_at(T->out)[j] != ym_at(T->gold)[j])
            {
                if (bad < 3u)
                {
                    rt_kprintf("  layer %u byte %u: got %02x expect %02x\n",
                               (unsigned)i, (unsigned)j,
                               (unsigned)ym_at(T->out)[j],
                               (unsigned)ym_at(T->gold)[j]);
                }
                bad++;
            }
        }
        bad_total += (int)bad;
        rt_kprintf("  layer %2u %-4s %3ux%-3u %4u->%-4u %6u B  %s  (%u cycles)\n",
                   (unsigned)i, T->kind ? "pool" : "conv", (unsigned)T->h,
                   (unsigned)T->w, (unsigned)T->cin, (unsigned)T->cout,
                   (unsigned)T->glen, bad ? "MISMATCH" : "ok",
                   (unsigned)(t1 - t0));
    }

    JYD_MMIO32(JYD_LED_ADDR) = 0u;
    end = mt_rd_mcycle();

    if (bad_total != 0)
    {
        rt_kprintf("miniTensor model slice FAILED: %d bytes differ\n", bad_total);
        halt(101);
        return -1;
    }

    rt_kprintf("miniTensor model slice PASSED (%u stages, 5 convs + 4 pools,"
               " %u commands, %u cycles)\n", (unsigned)stage, (unsigned)cmds,
               (unsigned)(end - start));
    return 0;
}
MSH_CMD_EXPORT_ALIAS(mt_yolomodel_command, mt_yolomodel, run 5 real YOLO stages.);
