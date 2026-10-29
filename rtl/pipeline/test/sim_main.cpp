#include "Vtb_pipeline_smoke.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

static uint32_t irom[8192];
static uint8_t  dram[1u << 18];
static int      write_events = 0;

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= 0x80000000u && a < 0x80008000u) {
        return static_cast<int>(irom[(a - 0x80000000u) >> 2]);
    }
    if (a >= 0x80100000u && a < 0x80140000u) {
        uint32_t o = a - 0x80100000u;
        return static_cast<int>(dram[o] | (dram[o + 1] << 8) |
                                (dram[o + 2] << 16) | (dram[o + 3] << 24));
    }
    return 0;
}

extern "C" void vaddr_write(int addr, int data, signed char len) {
    uint32_t a = static_cast<uint32_t>(addr);
    int n = 1 << (len & 3);
    if (a >= 0x80100000u && a < 0x80140000u) {
        uint32_t o = a - 0x80100000u;
        for (int i = 0; i < n && o + i < sizeof(dram); ++i) {
            dram[o + i] = static_cast<uint8_t>((static_cast<uint32_t>(data) >> (8 * i)) & 0xff);
        }
        std::printf("write[%d] addr=%08x data=%08x len=%d\n", write_events, a, data, n);
        ++write_events;
    }
}

extern "C" int sim_stats_enabled() { return 0; }
extern "C" void get_store_buffer_counts(unsigned long long, ...) {}
extern "C" int sim_console_getchar() { return -1; }
extern "C" void sim_led_write(int) {}

int main(int argc, char **argv) {
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_smoke *top = new Vtb_pipeline_smoke{ctx};

    // lui x1,0x80100 ; addi x2,x0,0x55 ; sw x2,0(x1) ; fence ;
    // addi x3,x0,0x66 ; sw x3,4(x1) ; ebreak ; jal x0,0
    irom[0] = 0x801000b7u;
    irom[1] = 0x05500113u;
    irom[2] = 0x0020a023u;
    irom[3] = 0x0ff0000fu;  // fence iorw,iorw
    irom[4] = 0x06600193u;  // addi x3,x0,0x66
    irom[5] = 0x0030a223u;  // sw x3,4(x1)
    irom[6] = 0x00100073u;  // ebreak
    irom[7] = 0x0000006fu;  // loop

    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 20; ++i) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->rst = 0;
    for (int i = 0; i < 200; ++i) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }

    std::printf("write_events=%d dram[0]=%02x dram[4]=%02x ebreak_seen=%d\n",
                write_events, dram[0], dram[4], top->ebreak_seen);
    int ok = (write_events == 2 && dram[0] == 0x55 && dram[4] == 0x66 &&
              top->ebreak_seen != 0);
    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
