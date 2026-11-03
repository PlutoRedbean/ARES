/* UART demo for the miniTensor INT8 GRU. */
#include "ares_soc.h"
#include "llm_mt_model.h"
#include "gru_mt_weights.h"

#define LINE_MAX 128
#define GEN_TOKENS 100

static char line_buf[LINE_MAX];

static int str_eq(const char *a, const char *b)
{
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return *a == *b;
}

static int uart_getc(void)
{
    while ((ares_mmio_read(UART_STATUS) & 2u) == 0u) { }
    return (int)(ares_mmio_read(UART_TX) & 0xFFu);
}

static void read_line(void)
{
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c == '\r' || c == '\n') { uart_putc('\n'); break; }
        if (c == 0x03) { uart_puts("^C\n"); n = 0; break; }
        if (c == 0x08 || c == 0x7F) {
            if (n > 0) { n--; uart_puts("\b \b"); }
            continue;
        }
        if (c >= 32 && c < 127 && n < LINE_MAX - 1) {
            line_buf[n++] = (char)c;
            uart_putc((char)c);
        }
    }
    line_buf[n] = '\0';
}

static int selftest(void)
{
    int i, n = (int)(sizeof(gru_mt_golden) / sizeof(gru_mt_golden[0]));
    int bad = 0;
    llm_mt_reset();
    for (i = 0; gru_mt_prompt[i]; i++) {
        int id = llm_mt_char_to_id(gru_mt_prompt[i]);
        if (id >= 0) llm_mt_feed(id);
    }
    printf("MT out: ");
    for (i = 0; i < n; i++) {
        int t = llm_mt_argmax();
        if (t < 0) { printf("\nMT selftest: hardware error %d\n", llm_mt_last_error()); return -1; }
        uart_putc(llm_mt_id_to_char(t));
        if (t != gru_mt_golden[i]) bad++;
        llm_mt_feed(t);
    }
    printf("\nMT selftest: %d/%d mismatches%s err=%d\n", bad, n, bad ? " FAIL" : " PASS", llm_mt_last_error());
    llm_mt_reset();
    return bad;
}

static void generate(const char *prompt)
{
    int i, t, count = 0;
    char c;
    uint32_t t0, dt, tps;

    llm_mt_reset();
    for (i = 0; prompt[i]; i++) {
        int id = llm_mt_char_to_id(prompt[i]);
        if (id >= 0) llm_mt_feed(id);
    }
    t0 = (uint32_t)ares_rd_mcycle64();
    for (i = 0; i < GEN_TOKENS; i++) {
        t = llm_mt_argmax();
        if (t < 0) { printf("\nMT error %d\n", llm_mt_last_error()); break; }
        c = llm_mt_id_to_char(t);
        if (c == '\n' && i < 60) c = ' ';
        uart_putc(c);
        llm_mt_feed(t);
        count++;
        if (c == '\n' && i >= 60) break;
    }
    dt = (uint32_t)ares_rd_mcycle64() - t0;
    tps = (uint32_t)(((uint64_t)count * 27000000ULL) / (dt ? dt : 1));
    uart_putc('\n');
    printf("[%u chars, %u cycles, %u char/s @27MHz]\n", (unsigned)count, (unsigned)dt, (unsigned)tps);
}

int llm_mt_demo(void)
{
    uart_init(UART_DIV);
    printf("\n==================================================\n");
    printf("A0 English char-GRU on miniTensor (INT8)\n");
    printf("vocab=%d emb=%d hidden=%d, UART %d baud\n", llm_mt_vocab_size(), 64, 96, 115200);
    printf("Type an English prompt, Enter to generate.\n");
    printf("==================================================\n");
    selftest();

    for (;;) {
        printf("> ");
        read_line();
        if (!line_buf[0]) continue;
        if (str_eq(line_buf, "!reset")) { llm_mt_reset(); printf("state reset\n"); continue; }
        generate(line_buf);
    }
}
