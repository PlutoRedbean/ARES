/* A0 English char-GRU demo over UART.
 *
 * Protocol: line-oriented.  Type an English prompt and press Enter; the model
 * generates up to LLM_GEN_TOKENS characters.  "!reset" clears the hidden state,
 * "!help" prints the commands.  Backspace and Ctrl-C work on the input line.
 */
#include "ares_soc.h"
#include "llm_model.h"

#define LINE_MAX 128
#define LLM_GEN_TOKENS 100

static char line_buf[LINE_MAX];

static int str_eq(const char *a, const char *b)
{
    while (*a && *b) {
        if (*a != *b) return 0;
        a++; b++;
    }
    return *a == *b;
}

static int uart_rx_ready(void)
{
    return (ares_mmio_read(UART_STATUS) & 2u) != 0u;
}

static int uart_getc(void)
{
    while (!uart_rx_ready()) { }
    return (int)(ares_mmio_read(UART_TX) & 0xFFu);
}

static void read_line(void)
{
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c == '\r' || c == '\n') {
            uart_putc('\n');
            break;
        }
        if (c == 0x03) { /* Ctrl-C */
            uart_puts("^C\n");
            n = 0;
            break;
        }
        if (c == 0x08 || c == 0x7F) {
            if (n > 0) {
                n--;
                uart_puts("\b \b");
            }
            continue;
        }
        if (c >= 32 && c < 127 && n < LINE_MAX - 1) {
            line_buf[n++] = (char)c;
            uart_putc((char)c);
        }
    }
    line_buf[n] = '\0';
}

static void generate(const char *prompt)
{
    int i, t, count = 0;
    char c;
    uint32_t t0, dt, tps;

    llm_reset();
    for (i = 0; prompt[i]; i++) {
        int id = llm_char_to_id(prompt[i]);
        if (id >= 0) llm_feed(id);
    }

    t0 = (uint32_t)ares_rd_mcycle64();
    for (i = 0; i < LLM_GEN_TOKENS; i++) {
        t = llm_argmax();
        c = llm_id_to_char(t);
        /* A 56K model likes to end the scene early; keep the demo readable. */
        if (c == '\n' && i < 60) c = ' ';
        uart_putc(c);
        llm_feed(t);
        count++;
        if (c == '\n' && i >= 60) break;
    }
    dt = (uint32_t)ares_rd_mcycle64() - t0;
    tps = (uint32_t)(((uint64_t)count * 27000000ULL) / (dt ? dt : 1));
    uart_putc('\n');
    printf("[%u chars, %u cycles, %u char/s @27MHz]\n", (unsigned)count, (unsigned)dt, (unsigned)tps);
}

int llm_demo(void)
{
    uart_init(UART_DIV);
    llm_load_weights();
    printf("\n==================================================\n");
    printf("A0 English char-GRU on ARES + miniTensor\n");
    printf("vocab=%d emb=%d hidden=%d, UART %d baud\n",
           llm_vocab_size(), 64, 96, 115200);
    printf("Type an English prompt, Enter to generate.\n");
    printf("Commands: !reset  !help\n");
    printf("==================================================\n");

    for (;;) {
        printf("> ");
        read_line();
        if (line_buf[0] == '\0') continue;
        if (str_eq(line_buf, "!reset")) {
            llm_reset();
            printf("state reset\n");
            continue;
        }
        if (str_eq(line_buf, "!help")) {
            printf("Enter a prompt; the model continues it for %d chars.\n", LLM_GEN_TOKENS);
            printf("!reset clears the hidden state.\n");
            continue;
        }
        generate(line_buf);
    }
}
