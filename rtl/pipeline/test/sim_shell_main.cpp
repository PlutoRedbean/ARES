// Host terminal <-> 115200 8N1 RX/TX pins, with real inferred BRAMs and clocks.
#include "Vtb_pipeline_shell.h"
#include "verilated.h"
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fcntl.h>
#include <limits>
#include <string>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t stopped = 0;
static void stop(int) { stopped=1; }
struct Terminal {
    int flags;
    bool tty;
    termios saved;
    Terminal(): flags(fcntl(STDIN_FILENO,F_GETFL)), tty(isatty(STDIN_FILENO)) {
        if(flags<0 || fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)<0) {
            perror("terminal flags"); std::exit(2);
        }
        if(tty) {
            if(tcgetattr(STDIN_FILENO,&saved)<0) { perror("tcgetattr"); std::exit(2); }
            termios raw=saved;
            cfmakeraw(&raw);
            if(tcsetattr(STDIN_FILENO,TCSANOW,&raw)<0) { perror("tcsetattr"); std::exit(2); }
        }
    }
    ~Terminal() {
        if(tty) tcsetattr(STDIN_FILENO,TCSANOW,&saved);
        fcntl(STDIN_FILENO,F_SETFL,flags);
    }
};
int main(int argc,char **argv) {
    uint64_t max_ms=0;
    bool burst=false;
    for(int i=1;i<argc;i++) {
        if(std::string(argv[i])=="--burst") burst=true;
        else if(std::string(argv[i])=="--max-ms" && i+1<argc) {
            char *end;
            errno=0;
            max_ms=strtoull(argv[++i],&end,10);
            if(errno || *end || max_ms>std::numeric_limits<uint64_t>::max()/1000000000ull) {
                fprintf(stderr,"invalid --max-ms\n"); return 2;
            }
        } else {
            fprintf(stderr,"usage: %s [--max-ms N] [--burst]\n",argv[0]); return 2;
        }
    }
    Terminal terminal;
    std::signal(SIGINT,stop); std::signal(SIGTERM,stop);
    fprintf(stderr,"ARES serial shell: type help; quit or Ctrl-C exits.\n");
    VerilatedContext ctx;
    ctx.commandArgs(argc,argv);
    Vtb_pipeline_shell top{&ctx};
    top.rx=1;
    std::deque<unsigned char> input;
    uint64_t next_bit=std::numeric_limits<uint64_t>::max();
    const uint64_t bit_ps=8680000;
    int bit=-1;
    unsigned frame=0;
    unsigned char active=0;
    uint32_t seen=0;
    unsigned polls=0, prompts=0;
    bool eof=false, cr=false, success=false;
    std::string line, tail;
    top.eval();
    while(!stopped && !ctx.gotFinish()) {
        if((++polls & 4095)==0 && input.size()<4096 && !eof) {
            unsigned char bytes[256];
            ssize_t n=read(STDIN_FILENO,bytes,sizeof(bytes));
            if(n==0) eof=true;
            else if(n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) {
                perror("stdin"); break;
            }
            for(ssize_t i=0;i<n;i++) {
                unsigned char c=bytes[i];
                if(c==3 || c==4) { stopped=1; break; }
                if(c=='\n' && cr) { cr=false; continue; }
                cr=(c=='\r');
                input.push_back(cr ? '\n' : c);
            }
        }
        if(bit>=0 && ctx.time()==next_bit) {
            if(++bit==10) {
                bit=-1; top.rx=1;
                next_bit=std::numeric_limits<uint64_t>::max();
            } else { top.rx=(frame>>bit)&1; next_bit+=bit_ps; }
        }
        if(bit<0 && !input.empty() && (burst || top.rx_available) && prompts) {
            active=input.front(); input.pop_front();
            frame=(1u<<9)|(static_cast<unsigned>(active)<<1);
            bit=0; top.rx=0; next_bit=ctx.time()+bit_ps;
        }
        top.eval();
        if(top.tx_count!=seen) {
            seen=top.tx_count;
            char c=static_cast<char>(top.tx_char);
            putchar(c); fflush(stdout);
            tail+=c;
            if(tail.size()>5) tail.erase(0,tail.size()-5);
            if(tail=="msh >") prompts++;
            if(c=='\n') {
                if(line=="ARES SHELL EXIT") { success=true; break; }
                if(line.rfind("ARES RTOS FAIL",0)==0) break;
                line.clear();
            } else if(c!='\r') line+=c;
        }
        if(max_ms && ctx.time()>=max_ms*1000000000ull) {
            fprintf(stderr,"shell simulation timeout\n"); break;
        }
        if(!top.eventsPending()) break;
        ctx.time(std::min(top.nextTimeSlot(),next_bit));
    }
    top.final();
    return success || stopped ? 0 : 1;
}
