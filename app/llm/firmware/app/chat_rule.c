/* Rule/template English chat: the reliable "simplest interaction" layer. */
#include "ares_soc.h"
#include "chat_rule.h"

#define LINE_MAX 128
static char line[LINE_MAX];
static char user_name[32];

static int str_eq(const char *a, const char *b)
{
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return *a == *b;
}

static int contains(const char *s, const char *pat)
{
    const char *p, *q;
    for (; *s; s++) {
        p = s; q = pat;
        while (*q && *p == *q) { p++; q++; }
        if (!*q) return 1;
    }
    return 0;
}

static int starts_with(const char *s, const char *pat)
{
    while (*pat) { if (*s++ != *pat++) return 0; }
    return 1;
}

static void lower(char *s) { for (; *s; s++) if (*s >= 'A' && *s <= 'Z') *s += 32; }

static int uart_getc(void)
{
    while ((ares_mmio_read(UART_STATUS) & 2u) == 0u) { }
    return (int)(ares_mmio_read(UART_TX) & 0xFFu);
}

static void read_line(void)
{
    int n = 0;
    for (;;) {
        int ch = uart_getc();
        if (ch == '\r' || ch == '\n') { uart_putc('\n'); break; }
        if (ch == 0x03) { uart_puts("^C\n"); n = 0; break; }
        if (ch == 0x08 || ch == 0x7F) {
            if (n > 0) { n--; uart_puts("\b \b"); }
            continue;
        }
        if (ch >= 32 && ch < 127 && n < LINE_MAX - 1) {
            line[n++] = (char)ch;
            uart_putc((char)ch);
        }
    }
    line[n] = '\0';
    lower(line);
}

static void delay_ms(uint32_t ms)
{
    uint64_t start = ares_rd_mcycle64();
    uint64_t wait = (uint64_t)ms * 27000ULL; /* 27 MHz */
    while ((ares_rd_mcycle64() - start) < wait) { }
}

static void bot_str(const char *s)
{
    for (; *s; s++) {
        uart_putc(*s);
        if (*s != '\n') delay_ms(50); /* 20 chars/s */
    }
}

static void reply(const char *s)
{
    uart_puts("bot: ");
    bot_str(s);
    uart_putc('\n');
}

static void handle(void)
{
    const char *p;
    if (!line[0]) return;

    if (contains(line, "my name is ")) {
        p = line + 11; int i = 0;
        while (*p == ' ') p++;
        while (*p && *p != ' ' && i < 31) user_name[i++] = *p++;
        user_name[i] = '\0';
        uart_puts("bot: "); bot_str("nice to meet you, "); bot_str(user_name); bot_str(".\n");
        return;
    }
    if (contains(line, "what is my name") || contains(line, "who am i")) {
        if (user_name[0]) { uart_puts("bot: "); bot_str("your name is "); bot_str(user_name); bot_str(".\n"); }
        else reply("i do not know your name yet.");
        return;
    }
    if (contains(line, "hello") || contains(line, "hi") || contains(line, "hey") || contains(line, "good morning")) {
        if (user_name[0]) { uart_puts("bot: "); bot_str("hello, "); bot_str(user_name); bot_str("! how can i help?\n"); }
        else reply("hello! how can i help?");
        return;
    }
    if (contains(line, "how are you") || contains(line, "how is it going")) { reply("i am fine, thank you."); return; }
    if (contains(line, "who are you") || contains(line, "what are you")) { reply("i am a tiny chat program on an fpga."); return; }
    if (contains(line, "what can you do") || str_eq(line, "help")) { reply("i can answer simple questions and greet you."); return; }
    if (contains(line, "thank")) { reply("you are welcome."); return; }
    if (contains(line, "bye") || contains(line, "goodbye") || contains(line, "see you")) { reply("goodbye! have a nice day."); return; }
    if (contains(line, "fpga")) { reply("an fpga is a field programmable gate array."); return; }
    if (contains(line, "cpu")) { reply("a cpu is a central processing unit."); return; }
    if (contains(line, "language model")) { reply("a language model predicts the next token."); return; }
    if (contains(line, "weather") || contains(line, "raining")) { reply("i do not have a weather sensor."); return; }
    if (contains(line, "time")) { reply("i do not know the time. i have no clock."); return; }
    if (contains(line, "joke") || contains(line, "funny")) { reply("why did the chip cross the board? to get to the other side."); return; }
    if (contains(line, "where are you") || contains(line, "where do you live")) { reply("i live inside an fpga."); return; }
    if (contains(line, "can you learn") || contains(line, "do you learn")) { reply("my weights are fixed after training."); return; }
    if (contains(line, "sad")) { reply("i am sorry to hear that. i hope things get better."); return; }
    if (contains(line, "happy")) { reply("that is great to hear!"); return; }
    if (str_eq(line, "yes") || str_eq(line, "ok") || str_eq(line, "okay")) { reply("ok."); return; }
    if (str_eq(line, "no") || str_eq(line, "nope")) { reply("ok, no problem."); return; }
    reply("i am not sure. try: who are you, what can you do, my name is alice.");
}

int chat_rule(void)
{
    user_name[0] = '\0';
    uart_init(UART_DIV);
    printf("\n==================================================\n");
    printf("A0 English chat (rule/template layer, instant)\n");
    printf("Type a short English sentence, Enter to send.\n");
    printf("Try: hello / who are you / what can you do / my name is alice\n");
    printf("==================================================\n");
    for (;;) {
        printf("you: ");
        read_line();
        handle();
    }
}
