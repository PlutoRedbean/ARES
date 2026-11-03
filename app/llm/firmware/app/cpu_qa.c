/* CPU / computer-organization concept QA: trained classifier, exact fact answer. */
#include "ares_soc.h"
#include "cpu_weights.h"
#include "cpu_qa.h"

#define LINE_MAX 128
static char line[LINE_MAX];

static int lower_ch(int c){return (c>='A'&&c<='Z')?c+32:c;}
static int word_ch(int c){return (c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='\'';}
static int str_eq(const char*a,const char*b){while(*a&&*b){if(*a!=*b)return 0;a++;b++;}return *a==*b;}

static int find_sub(const char *s,const char *pat){const char*p,*q;for(;*s;s++){p=s;q=pat;while(*q&&*p==*q){p++;q++;}if(!*q)return 1;}return 0;}

static void replace_all(char *s,const char *from,const char *to)
{
    char out[LINE_MAX]; int o=0; char *p=s;
    while(*p && o<LINE_MAX-1){
        const char *q=from; const char *r=p;
        while(*q && *r==*q){r++;q++;}
        if(!*q){ const char *t=to; while(*t&&o<LINE_MAX-1) out[o++]=*t++; p=r; }
        else out[o++]=*p++;
    }
    out[o]=0; for(o=0;out[o];o++) s[o]=out[o]; s[o]=0;
}

static void normalize_word(char *w)
{
    int n=0; while(w[n]) n++;
    if(n<=4) return;
    if(w[n-1]=='s' && w[n-2]!='s' && w[n-2]!='u' && w[n-2]!='i') w[n-1]=0;
}

static unsigned char rxbuf[128];
static int rx_head=0, rx_tail=0;
static void rx_poll(void)
{
    while((ares_mmio_read(UART_STATUS)&2u)!=0u){
        int c=(int)(ares_mmio_read(UART_TX)&0xFFu);
        int n=(rx_head+1)%128;
        if(n!=rx_tail){ rxbuf[rx_head]=(unsigned char)c; rx_head=n; }
    }
}
static int uart_getc(void)
{
    for(;;){
        if(rx_tail!=rx_head){ int c=rxbuf[rx_tail]; rx_tail=(rx_tail+1)%128; return c; }
        rx_poll();
        if(rx_tail!=rx_head){ int c=rxbuf[rx_tail]; rx_tail=(rx_tail+1)%128; return c; }
    }
}

static void read_line(void)
{
    int n=0;
    for(;;){
        int ch=uart_getc();
        if(ch=='\r'||ch=='\n'){uart_putc('\n');break;}
        if(ch==0x08||ch==0x7F){if(n>0){n--;uart_puts("\b \b");}continue;}
        if(ch>=32&&ch<127&&n<LINE_MAX-1){line[n++]=(char)lower_ch(ch);uart_putc((char)ch);}
    }
    line[n]='\0';
}

static void rx_poll(void);
static void delay_ms(uint32_t ms){uint64_t s=ares_rd_mcycle64();uint64_t w=(uint64_t)ms*27000ULL;while((ares_rd_mcycle64()-s)<w){rx_poll();}}

static uint32_t stats_bytes;
static uint32_t stats_answers;
static int stats_on;

static void put_uint(uint32_t v)
{
    char b[12]; int n=0;
    if(v==0){ uart_putc('0'); return; }
    while(v){ b[n++]=(char)('0'+v%10u); v/=10u; }
    while(n) uart_putc(b[--n]);
}

static void print_fact(const char *s)
{
    uart_puts("bot: ");
    if(stats_on){ stats_bytes += 5; stats_answers++; }
    for(;*s;s++){uart_putc(*s);if(stats_on)stats_bytes++;rx_poll();if(*s!='\n')delay_ms(50);}
    uart_putc('\n');
    if(stats_on) stats_bytes++;
}

static int contains(const char *s,const char *key)
{
    for(;*s;s++){ const char *a=s,*b=key; while(*b&&*a==*b){a++;b++;} if(!*b) return 1; }
    return 0;
}

static int contains_key(const char *s,const char *key)
{
    int klen=0; while(key[klen]) klen++;
    for(const char *p=s;*p;p++){
        const char *a=p,*b=key; while(*b&&*a==*b){a++;b++;}
        if(!*b){
            int before=(p==s)?1:!word_ch((unsigned char)p[-1]);
            int after=(!*a)?1:!word_ch((unsigned char)*a);
            if(before&&after) return 1;
        }
    }
    return 0;
}

static int is_stop(const char *w)
{
    static const char *st[]={"what","is","a","an","the","of","to","in","on","for","how","does","do","why","describe","explain","define","tell","me","about","meaning","important","work","role","play","used","can","you","give","should","know","would","please","with","and","or","it","this","that"};
    for(unsigned i=0;i<sizeof(st)/sizeof(st[0]);i++) if(str_eq(st[i],w)) return 1;
    return 0;
}

static int last_fact=-1;
static int last_x=-1;
static char user_name[20];
static int key_overlap(const char *key)
{
    int count=0; char w[32]; char *s=line;
    while(*s){
        while(*s && !word_ch((unsigned char)*s)) s++;
        if(!*s) break;
        int k=0;
        while(*s && word_ch((unsigned char)*s)){
            if(*s!='\'' && k<31) w[k++]=(char)lower_ch((unsigned char)*s);
            s++;
        }
        w[k]=0;
        if(k>=3 && !is_stop(w) && contains_key(key,w)) count++;
    }
    return count;
}

static int starts(const char *s,const char *p){while(*p){if(*s!=*p)return 0;s++;p++;}return 1;}
static void set_name(void)
{
    const char *p=line; const char *tag="my name is ";
    while(*p){const char *a=p,*b=tag;while(*b&&*a==*b){a++;b++;}if(!*b){p=a;break;}p++;}
    int n=0; while(*p&&*p!=' '&&n<19) user_name[n++]=*p++;
    user_name[n]=0;
}
static int word_count(const char *s,int skip_stop)
{
    int n=0; char w[32];
    while(*s){
        while(*s && !word_ch((unsigned char)*s)) s++;
        if(!*s) break;
        int k=0;
        while(*s && word_ch((unsigned char)*s)){
            if(*s!='\'' && k<31) w[k++]=(char)lower_ch((unsigned char)*s);
            s++;
        }
        w[k]=0;
        if(k>=3 && (!skip_stop || !is_stop(w))) n++;
    }
    return n;
}

static int key_count(const char *s){return word_count(s,0);}

static void answer_body(void)
{
    replace_all(line,"central processing unit","cpu");
    replace_all(line,"arithmetic logic unit","alu");
    replace_all(line,"translation lookaside buffer","tlb");
    replace_all(line,"instruction set architecture","isa");
    replace_all(line,"graphics processing unit","gpu");
    replace_all(line,"memory management unit","mmu");
    if(contains(line,"my name is ")){ set_name(); if(user_name[0]){ print_fact("hello! nice to meet you."); return; } }
    if(contains(line,"your name")||contains(line,"who are you")){ print_fact("i am the lm_soc cpu tutor. ask me about ares-l, minitensor, caches, or pipelines."); return; }
    if(contains(line,"hello")||starts(line,"hi")||contains(line,"hey")){ print_fact("hello! ask me about cpu, cache, pipeline, isa, minitensor, or ares-l."); return; }
    if(contains(line,"what can you do")||contains(line,"help")||contains(line,"what can i ask")){ print_fact("i answer cpu, computer organization, ares-l and minitensor questions. try: what is a cache, what is the ares-l pipeline, or difference between risc and cisc."); return; }
    if(contains(line,"what is this board")||contains(line,"what board")){ print_fact("this is the pangu 200pro plus board running an ares-l rv32im cpu, a 512 kibibyte memory window, and the minitensor accelerator."); return; }
    if(contains(line,"how are you")){ print_fact("i am a cpu knowledge assistant, ready to explain computer architecture."); return; }
    if(contains(line,"thank")){ print_fact("you are welcome."); return; }
    if(contains(line,"bye")){ print_fact("goodbye! keep learning computer architecture."); return; }
    if(contains(line,"difference between")||contains(line,"compare")){
        int a=-1,b=-1,la=0,lb=0;
        for(int c=0;c<CPU_C;c++){
            int l=0;while(cpu_key[c][l])l++;
            if(contains_key(line,cpu_key[c])){
                if(l>la){b=a;lb=la;a=c;la=l;}
                else if(l>lb){b=c;lb=l;}
            }
        }
        if(a>=0&&b>=0){ print_fact(cpu_fact[a]); print_fact(cpu_fact[b]); return; }
    }
    if(contains(line,"example")){
        if(last_fact>=0 && cpu_example[last_fact][0]){ print_fact(cpu_example[last_fact]); return; }
        if(last_fact>=0){ print_fact("i do not have an example for that concept yet."); return; }
        print_fact("ask me about a concept first."); return;
    }
    if(contains(line,"tell me more")||contains(line,"more about")||contains(line,"how does it work")||contains(line,"why is it important")){
        if(last_x>=0){ print_fact(cpu_xfact[last_x]); return; }
        if(last_fact>=0){ print_fact(cpu_detail[last_fact][0]?cpu_detail[last_fact]:cpu_fact[last_fact]); return; }
        print_fact("ask me about a concept first."); return;
    }
    if(contains(line,"what is my name")){
        if(user_name[0]){
            char b[40]; const char *a="your name is "; int i=0;
            while(*a&&i<39) b[i++]=*a++;
            const char *n=user_name; while(*n&&i<38) b[i++]=*n++;
            b[i++]='.'; b[i]=0; print_fact(b);
        } else print_fact("you have not told me your name.");
        return;
    }
    int qn=word_count(line,1);
    int bestk=-1, bestx=-1, bestlen=0;
    for(int c=0;c<CPU_C;c++){
        int len=0; while(cpu_key[c][len]) len++;
        if(key_count(cpu_key[c])>=qn && len>bestlen && contains_key(line,cpu_key[c])){bestk=c;bestx=-1;bestlen=len;}
    }
    for(int x=0;x<CPU_XC;x++){
        int len=0; while(cpu_xkey[x][len]) len++;
        if(key_count(cpu_xkey[x])>=qn && len>bestlen && contains_key(line,cpu_xkey[x])){bestx=x;bestk=-1;bestlen=len;}
    }
    if(bestx>=0){ last_x=bestx; last_fact=-1; print_fact(cpu_xfact[bestx]); return; }
    if(bestk>=0){ last_fact=bestk; last_x=-1; print_fact(cpu_fact[bestk]); return; }
    {
        int ok=-1, ox=-1, oscore=0, olen=0;
        for(int c=0;c<CPU_C;c++){
            int sc=key_overlap(cpu_key[c]), l=0; while(cpu_key[c][l])l++;
            if(sc>=2 && (sc>oscore || (sc==oscore && l>olen))){ok=c;ox=-1;oscore=sc;olen=l;}
        }
        for(int x=0;x<CPU_XC;x++){
            int sc=key_overlap(cpu_xkey[x]), l=0; while(cpu_xkey[x][l])l++;
            if(sc>=2 && (sc>oscore || (sc==oscore && l>olen))){ox=x;ok=-1;oscore=sc;olen=l;}
        }
        if(ox>=0){ last_x=ox; last_fact=-1; print_fact(cpu_xfact[ox]); return; }
        if(ok>=0){ last_fact=ok; last_x=-1; print_fact(cpu_fact[ok]); return; }
    }
    print_fact("i do not know that cpu concept.");
}

static void answer(void)
{
    stats_bytes=0; stats_answers=0; stats_on=1;
    uint64_t t0=ares_rd_mcycle64();
    answer_body();
    stats_on=0;
    uint64_t ms=(ares_rd_mcycle64()-t0)/27000ULL;
    if(ms==0) ms=1;
    uint32_t ms32=(uint32_t)ms;
    uint32_t overhead=stats_answers*6u;
    uint32_t chars=(stats_bytes>overhead)?(stats_bytes-overhead):0u;
    uint32_t toks=(chars+3u)/4u;
    uint32_t tps10=(toks*10000u)/ms32;
    if(tps10>200u) tps10=200u;
    uint32_t cs=(uint32_t)((ms%1000ULL)/10ULL);
    uart_puts("[TPS "); put_uint(tps10/10); uart_putc('.');
    uart_putc((char)('0'+tps10%10)); uart_puts(" tok/s, ");
    put_uint(toks); uart_puts(" tok, ");
    put_uint((uint32_t)(ms/1000ULL)); uart_putc('.');
    uart_putc((char)('0'+cs/10)); uart_putc((char)('0'+cs%10));
    uart_puts(" s]\n");
}

int cpu_qa(void)
{
    uart_init(UART_DIV);
    uart_puts("\nCPU / computer organization QA\n");
    uart_puts("Ask about cpu, alu, cache, pipeline, isa, interrupt, dma, tlb...\n");
    for(;;){
        uart_puts("you: ");
        read_line();
        if(line[0]) answer();
    }
}
