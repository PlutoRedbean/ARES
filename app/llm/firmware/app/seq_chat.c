/* Word-level seq2seq GRU dialogue on the RV32: real generative replies. */
#include "ares_soc.h"
#include "seq_weights.h"
#include "seq_chat.h"

#define LINE_MAX 128
static char line[LINE_MAX];
static char user_name[32];

static int lower_ch(int c){return (c>='A'&&c<='Z')?c+32:c;}
static int word_ch(int c){return (c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='\'';}

static int str_eq(const char *a,const char *b){while(*a&&*b){if(*a!=*b)return 0;a++;b++;}return *a==*b;}

static int word_id(const char *w)
{
    int i;
    for (i=0;i<SEQ_V;i++) if (str_eq(seq_vocab[i],w)) return i;
    return -1;
}

static int uart_getc(void)
{
    while ((ares_mmio_read(UART_STATUS) & 2u) == 0u) { }
    return (int)(ares_mmio_read(UART_TX) & 0xFFu);
}

static void read_line(void)
{
    int n=0;
    for(;;){
        int ch=uart_getc();
        if(ch=='\r'||ch=='\n'){uart_putc('\n');break;}
        if(ch==0x03){uart_puts("^C\n");n=0;break;}
        if(ch==0x08||ch==0x7F){if(n>0){n--;uart_puts("\b \b");}continue;}
        if(ch>=32&&ch<127&&n<LINE_MAX-1){line[n++]=(char)lower_ch(ch);uart_putc((char)ch);}
    }
    line[n]='\0';
}

static void delay_ms(uint32_t ms)
{
    uint64_t start=ares_rd_mcycle64();
    uint64_t wait=(uint64_t)ms*27000ULL;
    while((ares_rd_mcycle64()-start)<wait){}
}

static int32_t dot8(const int8_t *w,const int8_t *x,int n)
{
    int32_t s=0; int i;
    for(i=0;i<n;i++) s += (int32_t)w[i]*(int32_t)x[i];
    return s;
}

static int32_t dot32(const int8_t *w,const int32_t *x,int n)
{
    int32_t s=0; int i;
    for(i=0;i<n;i++) s += (int32_t)w[i]*x[i];
    return s;
}

static int clampi(int v,int lo,int hi){return v<lo?lo:(v>hi?hi:v);}

static void gru_step(const int8_t *wih,const int8_t *whh,
                     const int32_t *sih,const int32_t *shh,
                     const int32_t *bih,const int32_t *bhh,
                     const int8_t *x,const int8_t *h,int8_t *hn)
{
    int H=SEQ_H, g, i;
    int32_t pi[3*SEQ_H], ph[3*SEQ_H];
    for(g=0;g<3*H;g++){
        int32_t a=dot8(wih+g*SEQ_E,x,SEQ_E);
        int32_t b=dot8(whh+g*H,h,H);
        pi[g]=(int32_t)(((int64_t)a*SEQ_S_EMB_Q15*sih[g])>>15);
        ph[g]=(int32_t)(((int64_t)b*shh[g])/127);
    }
    int8_t r[SEQ_H], z[SEQ_H];
    for(i=0;i<H;i++){
        int pr=pi[i]+ph[i]+bih[i]+bhh[i];
        int pz=pi[H+i]+ph[H+i]+bih[H+i]+bhh[H+i];
        r[i]=(int8_t)seq_sig[clampi(pr>>11,-128,127)+128];
        z[i]=(int8_t)seq_sig[clampi(pz>>11,-128,127)+128];
    }
    for(i=0;i<H;i++){
        int32_t npre=pi[2*H+i]+bih[2*H+i]+
            (int32_t)(((int64_t)r[i]*(ph[2*H+i]+bhh[2*H+i]))>>7);
        int32_t n=seq_tanh[clampi(npre>>11,-128,127)+128];
        int32_t v=(((int32_t)(127-z[i])*n+(int32_t)z[i]*h[i])>>7);
        hn[i]=(int8_t)clampi(v,-127,127);
    }
}

static const char *name_tab[] = {"alice","bob","carol","dave","emma","frank","grace","henry"};
static const char *find_sub(const char *s, const char *pat)
{
    const char *p, *q;
    for (; *s; s++) { p=s; q=pat; while (*q && *p==*q) { p++; q++; } if (!*q) return s; }
    return 0;
}
static int is_name(const char *w)
{
    int i;
    for (i=0;i<8;i++) if (str_eq(w,name_tab[i])) return 1;
    return 0;
}
static void remember_name(void)
{
    const char *p=find_sub(line,"my name is ");
    if (p) p+=11;
    else { p=find_sub(line,"call me "); if (p) p+=8; }
    if (!p) return;
    while (*p==' ') p++;
    int i=0;
    while (*p && *p!=' ' && i<31) user_name[i++]=*p++;
    user_name[i]='\0';
}

static int generate(void)
{
    int ids[32], n=0, i, j;
    int8_t x[SEQ_E], henc[SEQ_H], h[SEQ_H];
    for(i=0;i<SEQ_H;i++) henc[i]=0;

    /* tokenize input into ids */
    char *s=line;
    while(*s && n<30){
        while(*s && !word_ch((unsigned char)*s)) s++;
        if(!*s) break;
        char w[32]; int k=0;
        while(*s && word_ch((unsigned char)*s)){
            if(*s!='\'' && k<31) w[k++]=(char)lower_ch((unsigned char)*s);
            s++;
        }
        w[k]='\0'; if(!k) continue;
        int id=word_id(w); if(id<0) id=word_id("<unk>");
        ids[n++]=id;
    }
    ids[n++]=word_id("<eos>");

    for(j=0;j<n;j++){
        for(i=0;i<SEQ_E;i++) x[i]=seq_emb[ids[j]*SEQ_E+i];
        gru_step(seq_enc_ih,seq_enc_hh,seq_s_enc_ih,seq_s_enc_hh,seq_b_enc_ih,seq_b_enc_hh,x,henc,henc);
    }

    int last=word_id("<sos>");
    uart_puts("bot: ");
    int printed=0;
    for(i=0;i<20;i++){
        for(j=0;j<SEQ_E;j++) x[j]=seq_emb[last*SEQ_E+j];
        gru_step(seq_dec_ih,seq_dec_hh,seq_s_dec_ih,seq_s_dec_hh,seq_b_dec_ih,seq_b_dec_hh,x,henc,h);
        for(j=0;j<SEQ_H;j++) henc[j]=h[j];

        int32_t mid[SEQ_R];
        for(j=0;j<SEQ_R;j++){
            int32_t a=dot8(seq_head_v+j*SEQ_H,h,SEQ_H);
            mid[j]=(int32_t)(((int64_t)a*seq_s_head_v[j])/127);
        }
        int best=0; int64_t bestv=0;
        for(j=0;j<SEQ_V;j++){
            int32_t acc=dot32(seq_head_u+j*SEQ_R,mid,SEQ_R);
            int64_t v=(int64_t)acc*seq_s_head_u[j]+seq_b_head[j];
            if(j==0||v>bestv){bestv=v;best=j;}
        }
        if(best==word_id("<eos>")) break;
        const char *w=seq_vocab[best];
        if(str_eq(w,"<unk>")||str_eq(w,"<sos>")) continue;
        if(user_name[0] && is_name(w)) w=user_name;
        int punct=(w[0]=='!'||w[0]=='?'||w[0]=='.'||w[0]==','||w[0]==':') && w[1]=='\0';
        if(printed && !punct) uart_putc(' ');
        uart_puts(w);
        printed=1;
        delay_ms(50); /* 20 tokens/s */
        last=best;
    }
    uart_putc('\n');
    return 0;
}

int seq_chat(void)
{
    user_name[0]='\0';
    uart_init(UART_DIV);
    for(;;){
        uart_puts("you: ");
        read_line();
        if(line[0]) { remember_name(); generate(); }
    }
}
