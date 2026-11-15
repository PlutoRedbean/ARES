#include "Vtb_pipeline_console.h"
#include "verilated.h"

#include <cstdio>

int main(int argc, char **argv) {
    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_console *top = new Vtb_pipeline_console{ctx};

    top->clk = 0;
    top->rst = 1;

    for (int i = 0; i < 20; ++i) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->rst = 0;

    int cycles = 0;
    while (!top->done && cycles < 2000000) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        ++cycles;
    }

    std::printf("console_cycles=%d done=%d errors=%u\n",
                cycles, top->done, top->errors);
    bool ok = top->done && top->errors == 0;
    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
