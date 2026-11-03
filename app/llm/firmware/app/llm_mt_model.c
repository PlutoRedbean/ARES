/* INT8 GRU on miniTensor: one flat MT_GEMM burst per 4 output channels. */
#include "llm_mt_model.h"
#include "gru_mt_weights.h"
#include "mt.h"

int printf(const char *fmt, ...);

#define A_ROW   0
#define B_ROW   32
#define C_ROW   128
#define GBATCH  32

static int8_t h_state[GRU_H] __attribute__((aligned(16)));
static int8_t apack[24 * 16] __attribute__((aligned(16)));
static int32_t cbuf[GBATCH * 4 * 4] __attribute__((aligned(16)));
static const int32_t zeros[GBATCH * 4 * 4] __attribute__((aligned(16))) = {0};
static int last_error;

static int mt_gemv_i8(const int8_t *wpack, const int8_t *x, int K, int M, int32_t *y)
{
    int t, k, o, j, g, nb, nt = K / 4;
    uint32_t base;

    for (t = 0; t < nt; t++) {
        base = (uint32_t)t * 16u;
        /* A is row-major: row 0 holds x[4t..4t+3], rows 1..3 are zero. */
        for (k = 0; k < 4; k++) {
            apack[base + k] = x[t * 4 + k];
            apack[base + 4 + k] = 0;
            apack[base + 8 + k] = 0;
            apack[base + 12 + k] = 0;
        }
    }

    mt_push(MT_LOAD, (uint32_t)apack, MT_ROWS(A_ROW, nt));

    for (g = 0; g < M / 4; g += 32) {
        nb = M / 4 - g;
        if (nb > 32) nb = 32;
        for (j = 0; j < nb; j++) {
            mt_push(MT_LOAD, (uint32_t)(wpack + (uint32_t)(g + j) * nt * 16u), MT_ROWS(B_ROW, nt));
            mt_push(MT_GEMM, MT_GEMM_RS1(A_ROW, B_ROW), MT_GEMM_RS2(C_ROW + j * 4, 0));
            MT_SET_STEPS(1, 1, 0);
            mt_push(MT_BURST(MT_GEMM, nt - 1), MT_GEMM_RS1(A_ROW + 1, B_ROW + 1),
                    MT_GEMM_RS2(C_ROW + j * 4, 1));
            mt_push(MT_STORE, (uint32_t)(cbuf + j * 4), MT_ROWS(C_ROW + j * 4, 4));
        }
        if (mt_drain() != 0) { last_error = 1; return -1; }
        for (j = 0; j < nb; j++)
            for (o = 0; o < 4; o++) y[(g + j) * 4 + o] = cbuf[j * 4 + o];
    }
    return 0;
}

void llm_mt_reset(void)
{
    int i;
    for (i = 0; i < GRU_H; i++) h_state[i] = 0;
    last_error = 0;
}

static int clampi(int v, int lo, int hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

int llm_mt_feed(int token_id)
{
    static int32_t ai[3 * GRU_H], ah[3 * GRU_H];
    int32_t pre_r, pre_z, n_pre, h_part;
    int32_t r, z, n, h_new;
    int i;

    if (token_id < 0) token_id = 0;
    if (token_id >= GRU_V) token_id = GRU_V - 1;

    if (mt_gemv_i8(gru_mt_w_ih, gru_mt_emb + (long)token_id * GRU_E, GRU_E, 3 * GRU_H, ai) != 0)
        return -1;
    if (mt_gemv_i8(gru_mt_w_hh, h_state, GRU_H, 3 * GRU_H, ah) != 0)
        return -1;

    for (i = 0; i < GRU_H; i++) {
        int32_t pi_r = (int32_t)(((int64_t)ai[i] * GRU_S_EMB_Q15 * gru_mt_s_ih[i]) >> 15);
        int32_t ph_r = ((int32_t)ah[i] * (int32_t)gru_mt_s_hh[i]) / 127;
        int32_t pi_z = (int32_t)(((int64_t)ai[GRU_H + i] * GRU_S_EMB_Q15 * gru_mt_s_ih[GRU_H + i]) >> 15);
        int32_t ph_z = ((int32_t)ah[GRU_H + i] * (int32_t)gru_mt_s_hh[GRU_H + i]) / 127;
        int32_t pi_n = (int32_t)(((int64_t)ai[2 * GRU_H + i] * GRU_S_EMB_Q15 * gru_mt_s_ih[2 * GRU_H + i]) >> 15);
        int32_t ph_n = ((int32_t)ah[2 * GRU_H + i] * (int32_t)gru_mt_s_hh[2 * GRU_H + i]) / 127;

        pre_r = pi_r + ph_r + gru_mt_b_ih[i] + gru_mt_b_hh[i];
        pre_z = pi_z + ph_z + gru_mt_b_ih[GRU_H + i] + gru_mt_b_hh[GRU_H + i];
        r = gru_mt_sig[clampi(pre_r >> 11, -128, 127) + 128];
        z = gru_mt_sig[clampi(pre_z >> 11, -128, 127) + 128];

        n_pre = pi_n + gru_mt_b_ih[2 * GRU_H + i] +
                ((r * (ph_n + gru_mt_b_hh[2 * GRU_H + i])) >> 15);
        n = gru_mt_tanh[clampi(n_pre >> 11, -128, 127) + 128];

        h_new = (int32_t)(((int64_t)(127 - z) * n + (int64_t)z * h_state[i]) >> 7);
        h_state[i] = (int8_t)clampi(h_new, -127, 127);
    }
    return 0;
}

int llm_mt_argmax(void)
{
    int32_t acc[GRU_MOUT];
    int32_t best = -2147483647;
    int best_id = 0;
    int v;

    if (mt_gemv_i8(gru_mt_w_out, h_state, GRU_H, GRU_MOUT, acc) != 0) return -1;
    for (v = 0; v < GRU_V; v++) {
        int32_t z = (int32_t)(((int64_t)acc[v] * gru_mt_s_out[v]) >> 15);
        if (z > best) { best = z; best_id = v; }
    }
    return best_id;
}

int llm_mt_test_simple(void)
{
    static const int8_t w4[16] __attribute__((aligned(16))) = {1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1};
    static const int8_t w8[32] __attribute__((aligned(16))) = {1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1,
                                                               1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1};
    static int8_t x8[8] __attribute__((aligned(16))) = {1,2,3,4,5,6,7,8};
    int32_t y[4];
    mt_gemv_i8(w4, x8, 4, 4, y);
    printf("simple4: %d %d %d %d (want 10)\n", (int)y[0], (int)y[1], (int)y[2], (int)y[3]);
    mt_gemv_i8(w8, x8, 8, 4, y);
    printf("simple8: %d %d %d %d (want 36)\n", (int)y[0], (int)y[1], (int)y[2], (int)y[3]);
    return 0;
}

int llm_mt_test_hh(void)
{
    static int8_t x[GRU_H] __attribute__((aligned(16)));
    static int32_t y[3 * GRU_H] __attribute__((aligned(16)));
    int g, t, k, o, oo, nt = GRU_H / 4;
    int bad = 0;
    for (k = 0; k < GRU_H; k++) x[k] = (int8_t)((k % 5) - 2);
    if (mt_gemv_i8(gru_mt_w_hh, x, GRU_H, 3 * GRU_H, y) != 0) return -1;
    for (g = 0; g < 3 * GRU_H / 4; g++) {
        for (o = 0; o < 4; o++) {
            int32_t cpu = 0;
            for (t = 0; t < nt; t++)
                for (k = 0; k < 4; k++)
                    cpu += (int32_t)gru_mt_w_hh[((g * nt + t) * 16) + k * 4 + o] *
                           (int32_t)x[t * 4 + k];
            oo = g * 4 + o;
            if (cpu != y[oo]) { if (bad < 5) printf("hh o=%d cpu=%d mt=%d\n", oo, (int)cpu, (int)y[oo]); bad++; }
        }
    }
    printf("hh gemv mismatches %d/%d\n", bad, 3 * GRU_H);
    return bad;
}

int llm_mt_debug_i2(void)
{
    int32_t ai[3 * GRU_H], ah[3 * GRU_H];
    int id = llm_mt_char_to_id('R');
    int i = 2;
    int32_t pi, ph, pre, r, z, npre, n;
    llm_mt_reset();
    mt_gemv_i8(gru_mt_w_ih, gru_mt_emb + (long)id * GRU_E, GRU_E, 3 * GRU_H, ai);
    mt_gemv_i8(gru_mt_w_hh, h_state, GRU_H, 3 * GRU_H, ah);
    pi = (int32_t)(((int64_t)ai[i] * GRU_S_EMB_Q15 * gru_mt_s_ih[i]) >> 15);
    ph = (int32_t)(((int64_t)ah[i] * gru_mt_s_hh[i]) / 127);
    pre = pi + ph + gru_mt_b_ih[i] + gru_mt_b_hh[i];
    r = gru_mt_sig[clampi(pre >> 11, -128, 127) + 128];
    pi = (int32_t)(((int64_t)ai[GRU_H + i] * GRU_S_EMB_Q15 * gru_mt_s_ih[GRU_H + i]) >> 15);
    ph = (int32_t)(((int64_t)ah[GRU_H + i] * gru_mt_s_hh[GRU_H + i]) / 127);
    pre = pi + ph + gru_mt_b_ih[GRU_H + i] + gru_mt_b_hh[GRU_H + i];
    z = gru_mt_sig[clampi(pre >> 11, -128, 127) + 128];
    pi = (int32_t)(((int64_t)ai[2 * GRU_H + i] * GRU_S_EMB_Q15 * gru_mt_s_ih[2 * GRU_H + i]) >> 15);
    ph = (int32_t)(((int64_t)ah[2 * GRU_H + i] * gru_mt_s_hh[2 * GRU_H + i]) / 127);
    npre = pi + gru_mt_b_ih[2 * GRU_H + i] + (int32_t)(((int64_t)r * (ph + gru_mt_b_hh[2 * GRU_H + i])) >> 15);
    n = gru_mt_tanh[clampi(npre >> 11, -128, 127) + 128];
    printf("i2 ai=%d ah=%d s_ih=%d s_hh=%d r=%d z=%d n=%d\n", (int)ai[2], (int)ah[2], (int)gru_mt_s_ih[2], (int)gru_mt_s_hh[2], (int)r, (int)z, (int)n);
    return 0;
}

int llm_mt_debug_state(void)
{
    int32_t acc[GRU_MOUT];
    int i, best = 0;
    llm_mt_reset();
    for (i = 0; gru_mt_prompt[i]; i++) {
        int id = llm_mt_char_to_id(gru_mt_prompt[i]);
        if (id >= 0) llm_mt_feed(id);
        printf("step %c h %d %d %d %d\n", gru_mt_prompt[i], (int)h_state[0], (int)h_state[1], (int)h_state[2], (int)h_state[3]);
    }
    printf("h:");
    for (i = 0; i < 6; i++) printf(" %d", (int)h_state[i]);
    mt_gemv_i8(gru_mt_w_out, h_state, GRU_H, GRU_MOUT, acc);
    printf("\nlogits:");
    for (i = 0; i < 6; i++) printf(" %d/%d", (int)acc[i], (int)gru_mt_s_out[i]);
    for (i = 0; i < GRU_V; i++) if (acc[i] > acc[best]) best = i;
    printf("\nbest %d '%c'\n", best, llm_mt_id_to_char(best));
    return 0;
}

int llm_mt_test_full(void)
{
    static int32_t y[3 * GRU_H] __attribute__((aligned(16)));
    int id = llm_mt_char_to_id('R');
    const int8_t *x = gru_mt_emb + (long)id * GRU_E;
    int g, t, k, o, oo, nt = GRU_E / 4;
    int bad = 0;

    if (mt_gemv_i8(gru_mt_w_ih, x, GRU_E, 3 * GRU_H, y) != 0) return -1;
    for (g = 0; g < 3 * GRU_H / 4; g++) {
        for (o = 0; o < 4; o++) {
            int32_t cpu = 0;
            for (t = 0; t < nt; t++)
                for (k = 0; k < 4; k++)
                    cpu += (int32_t)gru_mt_w_ih[((g * nt + t) * 16) + k * 4 + o] *
                           (int32_t)x[t * 4 + k];
            oo = g * 4 + o;
            if (cpu != y[oo]) {
                if (bad < 5) printf("full o=%d cpu=%d mt=%d\n", oo, (int)cpu, (int)y[oo]);
                bad++;
            }
        }
    }
    printf("full gemv mismatches %d/%d\n", bad, 3 * GRU_H);
    return bad;
}

int llm_mt_test_gemv(void)
{
    static int8_t x[GRU_E] __attribute__((aligned(16)));
    int32_t y[4];
    int t, k, o, nt = GRU_E / 4;

    for (k = 0; k < GRU_E; k++) x[k] = (int8_t)((k % 7) - 3);
    if (mt_gemv_i8(gru_mt_w_ih, x, GRU_E, 4, y) != 0) {
        printf("gemv: mt error %d\n", last_error);
        return -1;
    }
    for (o = 0; o < 4; o++) {
        int32_t cpu = 0;
        for (t = 0; t < nt; t++)
            for (k = 0; k < 4; k++)
                cpu += (int32_t)gru_mt_w_ih[(t * 16) + k * 4 + o] * (int32_t)x[t * 4 + k];
        printf("gemv o=%d cpu=%d mt=%d\n", o, (int)cpu, (int)y[o]);
    }
    return 0;
}

int llm_mt_last_error(void) { return last_error; }
int llm_mt_vocab_size(void) { return GRU_V; }

int llm_mt_char_to_id(char c)
{
    int i;
    for (i = 0; i < GRU_V; i++) if (gru_mt_vocab[i] == (unsigned char)c) return i;
    return -1;
}

char llm_mt_id_to_char(int id)
{
    if (id < 0 || id >= GRU_V) return '?';
    return (char)gru_mt_vocab[id];
}
