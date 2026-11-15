// guard/sim/main_redact.cpp
//
// 全 RTL 脱敏驱动：读文件 → l1_redact_top（检测+合并+mask 替换）→ 写脱敏文件，
// 审计记录打到 stdout（每行 "start len type"）。
//
// 用法：Vredact <input> <output>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>

#include "Vl1_redact_top.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <input> <output>\n", argv[0]);
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    if (!in) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }
    std::vector<unsigned char> data((std::istreambuf_iterator<char>(in)),
                                    std::istreambuf_iterator<char>());

    Vl1_redact_top *dut = new Vl1_redact_top;
    auto tick = [&]() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    };

    std::vector<unsigned char> out;
    auto record = [&]() {
        if (dut->out_valid) out.push_back((unsigned char)dut->out_char);
        if (dut->a_valid)
            std::printf("%u %u %u\n", dut->a_start, dut->a_len, dut->a_type);
    };

    dut->rst_n = 0;
    dut->in_valid = 0;
    dut->in_last = 0;
    dut->in_char = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1;
    for (int i = 0; i < 2; i++) tick();

    for (unsigned char b : data) {
        dut->in_valid = 1;
        dut->in_char = b;
        tick();
        record();
    }
    dut->in_valid = 0;
    tick();
    record();
    dut->in_last = 1;
    tick();
    record();
    dut->in_last = 0;

    int waited = 0;
    while (!dut->done && waited < 1000000) {
        tick();
        record();
        waited++;
    }
    for (int i = 0; i < 4; i++) {
        tick();
        record();
    }
    if (!dut->done) std::fprintf(stderr, "warning: done never asserted\n");
    if (dut->ovf) std::fprintf(stderr, "warning: pipeline overflow\n");
    if (dut->dropped) std::fprintf(stderr, "warning: %u hits dropped\n", (unsigned)dut->dropped);

    std::ofstream ofs(argv[2], std::ios::binary);
    ofs.write(reinterpret_cast<const char *>(out.data()), (std::streamsize)out.size());
    ofs.close();

    delete dut;
    return 0;
}
