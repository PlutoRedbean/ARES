/* Portable integer GRU forward for the A0 English model.
 *
 * No MMIO, no hardware headers: the same source is compiled for the host
 * golden test and for the RV32 firmware.  All arithmetic mirrors
 * tools/gru_int.py exactly (int16 Q15 states, int8 scaled weights).
 */
#include "llm_model.h"
#include "gru_a0_weights.h"

#ifdef LLM_USE_SCRATCH
#ifndef LLM_SCRATCH_BASE
#define LLM_SCRATCH_BASE 0x10000000u
#endif
#define OFF_EMB   0u
#define OFF_WIH   8320u
#define OFF_WHH   26752u
#define OFF_BIH   54400u
#define OFF_BHH   55552u
#define OFF_WOUT  56704u
#define OFF_BOUT  62944u
#define OFF_SIG   63204u
#define OFF_TANH  63716u
static int16_t *W_EMB;
static int8_t  *W_IH;
static int8_t  *W_HH;
static int32_t *B_IH;
static int32_t *B_HH;
static int8_t  *W_OUT;
static int32_t *B_OUT;
static int16_t *SIG;
static int16_t *TANH;
#else
#define W_EMB  gru_emb
#define W_IH   gru_w_ih
#define W_HH   gru_w_hh
#define B_IH   gru_b_ih
#define B_HH   gru_b_hh
#define W_OUT  gru_w_out
#define B_OUT  gru_b_out
#define SIG    gru_sig_lut
#define TANH   gru_tanh_lut
#endif

/* per-output-channel scales live in .rodata, not in the scratch copy */
#define S_IH   gru_s_ih_q15
#define S_HH   gru_s_hh_q15
#define S_OUT  gru_s_out_q15

static int16_t h_state[GRU_H] __attribute__((aligned(4)));

#ifdef LLM_USE_SCRATCH
static void copy_words(void *dst, const void *src, unsigned bytes)
{
    volatile uint32_t *d = (volatile uint32_t *)dst;
    const uint32_t *s = (const uint32_t *)src;
    unsigned i, n = bytes / 4u;
    for (i = 0; i < n; i++) d[i] = s[i];
}

void llm_load_weights(void)
{
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_EMB),  gru_emb,      sizeof(gru_emb));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_WIH),  gru_w_ih,     sizeof(gru_w_ih));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_WHH),  gru_w_hh,     sizeof(gru_w_hh));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_BIH),  gru_b_ih,     sizeof(gru_b_ih));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_BHH),  gru_b_hh,     sizeof(gru_b_hh));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_WOUT), gru_w_out,    sizeof(gru_w_out));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_BOUT), gru_b_out,    sizeof(gru_b_out));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_SIG),  gru_sig_lut,  sizeof(gru_sig_lut));
    copy_words((void *)(LLM_SCRATCH_BASE + OFF_TANH), gru_tanh_lut, sizeof(gru_tanh_lut));

    W_EMB = (int16_t *)(LLM_SCRATCH_BASE + OFF_EMB);
    W_IH  = (int8_t  *)(LLM_SCRATCH_BASE + OFF_WIH);
    W_HH  = (int8_t  *)(LLM_SCRATCH_BASE + OFF_WHH);
    B_IH  = (int32_t *)(LLM_SCRATCH_BASE + OFF_BIH);
    B_HH  = (int32_t *)(LLM_SCRATCH_BASE + OFF_BHH);
    W_OUT = (int8_t  *)(LLM_SCRATCH_BASE + OFF_WOUT);
    B_OUT = (int32_t *)(LLM_SCRATCH_BASE + OFF_BOUT);
    SIG   = (int16_t *)(LLM_SCRATCH_BASE + OFF_SIG);
    TANH  = (int16_t *)(LLM_SCRATCH_BASE + OFF_TANH);
}
#else
void llm_load_weights(void) { }
#endif

static int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void llm_reset(void)
{
    int i;
    for (i = 0; i < GRU_H; i++) h_state[i] = 0;
}

/* Four int8 weights and four int16 activations per iteration.  The core data
 * path is uncached, so cutting the number of loads is the main win. */
static int32_t dot4(const int8_t *w, const int16_t *x, int n)
{
    const uint32_t *wp = (const uint32_t *)w;
    const uint32_t *xp = (const uint32_t *)x;
    int32_t s = 0;
    int i;

    for (i = 0; i < n; i += 4) {
        uint32_t w4 = wp[i >> 2];
        uint32_t xa = *xp++;
        uint32_t xb = *xp++;
        int w0 = (int8_t)(w4);
        int w1 = (int8_t)(w4 >> 8);
        int w2 = (int8_t)(w4 >> 16);
        int w3 = (int8_t)(w4 >> 24);
        int x0 = (int16_t)(xa);
        int x1 = (int16_t)(xa >> 16);
        int x2 = (int16_t)(xb);
        int x3 = (int16_t)(xb >> 16);
        s += w0 * x0 + w1 * x1 + w2 * x2 + w3 * x3;
    }
    return s;
}

static void gemv(const int8_t *w, const int16_t *x, int n, int m, int32_t *acc)
{
    int o;
    for (o = 0; o < m; o++) acc[o] = dot4(w + (long)o * n, x, n);
}

void llm_feed(int token_id)
{
    int32_t acc_ih[3 * GRU_H];
    int32_t acc_hh[3 * GRU_H];
    int32_t pre_ih[3 * GRU_H];
    int32_t pre_hh[3 * GRU_H];
    int32_t pre_r, pre_z, n_pre, h_part;
    int32_t r, z, n, h_new;
    int i;

    if (token_id < 0) token_id = 0;
    if (token_id >= GRU_V) token_id = GRU_V - 1;

    gemv(W_IH, W_EMB + (long)token_id * GRU_E, GRU_E, 3 * GRU_H, acc_ih);
    gemv(W_HH, h_state, GRU_H, 3 * GRU_H, acc_hh);

    for (i = 0; i < 3 * GRU_H; i++) {
        pre_ih[i] = (int32_t)((((int64_t)acc_ih[i] * GRU_S_EMB_Q15) * S_IH[i]) >> 15);
        pre_hh[i] = (int32_t)(((int64_t)acc_hh[i] * S_HH[i]) >> 15);
    }

    for (i = 0; i < GRU_H; i++) {
        pre_r = pre_ih[i] + pre_hh[i] + B_IH[i] + B_HH[i];
        pre_z = pre_ih[GRU_H + i] + pre_hh[GRU_H + i] +
                B_IH[GRU_H + i] + B_HH[GRU_H + i];
        r = SIG[clampi(pre_r >> 11, -128, 127) + 128];
        z = SIG[clampi(pre_z >> 11, -128, 127) + 128];

        h_part = pre_hh[2 * GRU_H + i] + B_HH[2 * GRU_H + i];
        n_pre = pre_ih[2 * GRU_H + i] + B_IH[2 * GRU_H + i] +
                (int32_t)(((int64_t)r * h_part) >> 15);
        n = TANH[clampi(n_pre >> 11, -128, 127) + 128];

        h_new = (int32_t)(((int64_t)(32767 - z) * n + (int64_t)z * h_state[i]) >> 15);
        h_state[i] = (int16_t)clampi(h_new, -32768, 32767);
    }
}

static int argmax_core(const int *recent, int n, int32_t penalty)
{
    int32_t acc;
    int32_t best = -2147483647;
    int best_id = 0;
    int v, j;

    for (v = 0; v < GRU_V; v++) {
        acc = dot4(W_OUT + (long)v * GRU_H, h_state, GRU_H);
        acc = (int32_t)(((int64_t)acc * S_OUT[v]) >> 15) + B_OUT[v];
        for (j = 0; j < n; j++) if (recent[j] == v) acc -= penalty;
        if (acc > best) { best = acc; best_id = v; }
    }
    return best_id;
}

int llm_argmax(void)
{
    return argmax_core(0, 0, 0);
}

int llm_argmax_penalized(const int *recent, int n, int32_t penalty)
{
    return argmax_core(recent, n, penalty);
}

int llm_vocab_size(void) { return GRU_V; }

int llm_char_to_id(char c)
{
    int i;
    for (i = 0; i < GRU_V; i++) if (gru_vocab[i] == c) return i;
    return -1;
}

char llm_id_to_char(int id)
{
    if (id < 0 || id >= GRU_V) return '?';
    return (char)gru_vocab[id];
}

const char *llm_vocab_ptr(void) { return (const char *)gru_vocab; }
