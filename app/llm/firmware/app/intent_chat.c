/* Hybrid English intent chat: keyword rules + a bag-of-words/ngram classifier. */
#include "ares_soc.h"
#include "intent_weights.h"
#include "intent_chat.h"

#define LINE_MAX 128
#define MAX_TOK  32
static char line[LINE_MAX];
static char user_name[32];

static int slen(const char *s) { int n = 0; while (*s++) n++; return n; }
static int lower_ch(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
static int is_word_ch(int c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '\''; }

static void lower_line(char *s) { for (; *s; s++) *s = (char)lower_ch((unsigned char)*s); }

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

static int has_word(const char *s, const char *w)
{
    while (*s) {
        while (*s && !is_word_ch((unsigned char)*s)) s++;
        const char *p = s;
        while (*s && is_word_ch((unsigned char)*s)) s++;
        int n = (int)(s - p);
        if (n == slen(w)) {
            int i, ok = 1;
            for (i = 0; i < n; i++) if (p[i] != w[i]) { ok = 0; break; }
            if (ok) return 1;
        }
    }
    return 0;
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
    lower_line(line);
}

static void delay_ms(uint32_t ms)
{
    uint64_t start = ares_rd_mcycle64();
    uint64_t wait = (uint64_t)ms * 27000ULL;
    while ((ares_rd_mcycle64() - start) < wait) { }
}

static void bot_str(const char *s)
{
    for (; *s; s++) {
        uart_putc(*s);
        if (*s != '\n') delay_ms(50); /* 20 chars/s */
    }
}

static void reply_idx(int idx)
{
    if (idx < 0 || idx >= INTENT_I) idx = INTENT_FALLBACK;
    uart_puts("bot: ");
    bot_str(intent_reply[idx]);
    uart_putc('\n');
}

static void stem_word(char *w)
{
    static const char *suf[] = {"ing", "ed", "es", "s", "ly"};
    int i, n = slen(w);
    for (i = 0; i < 5; i++) {
        int k = slen(suf[i]);
        if (n > k + 2 && str_eq(w + n - k, suf[i])) { w[n - k] = '\0'; return; }
    }
}

static int word_id(const char *w)
{
    int i;
    for (i = 0; i < INTENT_V; i++) if (str_eq(intent_words[i], w)) return i;
    return -1;
}

/* Return number of feature ids; unigrams plus adjacent bigrams. */
static int features(const char *s, int *ids, int max_ids)
{
    char prev[32], w[32];
    int n = 0, prev_ok = 0;
    prev[0] = '\0';
    while (*s) {
        while (*s && !is_word_ch((unsigned char)*s)) s++;
        if (!*s) break;
        int k = 0;
        while (*s && is_word_ch((unsigned char)*s)) {
            if (*s != '\'' && k < 31) w[k++] = (char)lower_ch((unsigned char)*s);
            s++;
        }
        w[k] = '\0';
        if (!k) continue;
        stem_word(w);
        int id = word_id(w);
        if (id >= 0 && n < max_ids) ids[n++] = id;
        if (prev_ok && n < max_ids) {
            char bg[66]; int j;
            for (j = 0; prev[j] && j < 31; j++) bg[j] = prev[j];
            bg[j++] = '_';
            for (k = 0; w[k] && j < 64; k++) bg[j++] = w[k];
            bg[j] = '\0';
            id = word_id(bg);
            if (id >= 0) ids[n++] = id;
        }
        for (k = 0; w[k] && k < 31; k++) prev[k] = w[k];
        prev[k] = '\0'; prev_ok = 1;
    }
    return n;
}

static int classify(int *best_margin)
{
    int ids[MAX_TOK], n, i, j;
    int32_t score[INTENT_I];
    n = features(line, ids, MAX_TOK);
    if (n == 0) { *best_margin = 0; return INTENT_FALLBACK; }
    for (i = 0; i < INTENT_I; i++) {
        int32_t s = intent_b[i];
        for (j = 0; j < n; j++) s += intent_w[i][ids[j]];
        score[i] = s;
    }
    int best = 0, second = 1;
    if (score[1] > score[0]) { best = 1; second = 0; }
    for (i = 2; i < INTENT_I; i++) {
        if (score[i] > score[best]) { second = best; best = i; }
        else if (score[i] > score[second]) second = i;
    }
    *best_margin = (int)(score[best] - score[second]);
    return best;
}

/* High-precision rules for common short inputs. */
static int rule_intent(void)
{
    if (has_word(line, "hello") || has_word(line, "hi") || has_word(line, "hey") ||
        has_word(line, "howdy") || has_word(line, "hiya") || has_word(line, "greetings") ||
        contains(line, "good morning") || contains(line, "good evening") || contains(line, "good afternoon")) return 0;
    if (contains(line, "how are you") || contains(line, "how is it going") || contains(line, "how do you feel") ||
        contains(line, "what is up") || contains(line, "how have you been")) return 1;
    if (contains(line, "who are you") || contains(line, "what are you") || contains(line, "your name")) return 2;
    if (contains(line, "what can you do") || contains(line, "what do you do") || has_word(line, "help") ||
        contains(line, "how can you help")) return 3;
    if (has_word(line, "thanks") || has_word(line, "thank") || has_word(line, "cheers")) return 4;
    if (has_word(line, "bye") || has_word(line, "goodbye") || has_word(line, "farewell") ||
        contains(line, "see you") || contains(line, "good night") || contains(line, "take care")) return 5;
    if (contains(line, "where is the fpga") || contains(line, "where is your")) return 12;
    if (has_word(line, "fpga")) return 6;
    if (has_word(line, "cpu")) return 7;
    if (contains(line, "language model") || has_word(line, "llm")) return 8;
    if (has_word(line, "weather") || has_word(line, "raining") || has_word(line, "sunny")) return 9;
    if (has_word(line, "time")) return 10;
    if (has_word(line, "joke") || has_word(line, "jokes") || has_word(line, "funny") || has_word(line, "laugh")) return 11;
    if (contains(line, "where are you") || contains(line, "where do you live")) return 12;
    if (contains(line, "can you learn") || contains(line, "do you learn") ||
        contains(line, "update your weights")) return 13;
    if (has_word(line, "sad") || has_word(line, "unhappy") || has_word(line, "upset") || has_word(line, "down")) return 14;
    if (has_word(line, "happy") || has_word(line, "glad") || has_word(line, "excited") ||
        has_word(line, "wonderful") || has_word(line, "great")) return 15;
    if (str_eq(line, "yes") || str_eq(line, "ok") || str_eq(line, "okay") ||
        str_eq(line, "sure") || str_eq(line, "yep") || str_eq(line, "yeah") ||
        contains(line, "that is right") || contains(line, "i agree")) return 16;
    if (str_eq(line, "no") || str_eq(line, "nope") || str_eq(line, "nah")) return 17;
    if (contains(line, "my name is") || contains(line, "call me")) return INTENT_NAME;
    return -1;
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
    if (contains(line, "call me ")) {
        p = line + 8; int i = 0;
        while (*p == ' ') p++;
        while (*p && *p != ' ' && i < 31) user_name[i++] = *p++;
        user_name[i] = '\0';
        uart_puts("bot: "); bot_str("ok, i will call you "); bot_str(user_name); bot_str(".\n");
        return;
    }
    if (contains(line, "what is my name") || contains(line, "who am i")) {
        if (user_name[0]) { uart_puts("bot: "); bot_str("your name is "); bot_str(user_name); bot_str(".\n"); }
        else reply_idx(INTENT_FALLBACK);
        return;
    }

    int ri = rule_intent();
    if (ri >= 0 && ri != INTENT_NAME) {
        if (ri == 0 && user_name[0]) {
            uart_puts("bot: "); bot_str("hello, "); bot_str(user_name); bot_str("! how can i help?\n");
        } else reply_idx(ri);
        return;
    }

    int margin;
    int best = classify(&margin);
    if (best == INTENT_FALLBACK || margin < 1200) reply_idx(INTENT_FALLBACK);
    else {
        if (best == 0 && user_name[0]) {
            uart_puts("bot: "); bot_str("hello, "); bot_str(user_name); bot_str("! how can i help?\n");
        } else reply_idx(best);
    }
}

int intent_chat(void)
{
    user_name[0] = '\0';
    uart_init(UART_DIV);
    printf("\n==================================================\n");
    printf("A0 English intent chat (rules + ngram classifier)\n");
    printf("Output is paced at 20 chars/s. Type a sentence, Enter to send.\n");
    printf("Try: hello / who are you / my name is alice / how are you\n");
    printf("==================================================\n");
    for (;;) {
        printf("you: ");
        read_line();
        handle();
    }
}
