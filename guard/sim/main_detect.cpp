// guard/sim/main_detect.cpp
//
// Verilator 驱动：把文本文件灌进 l1_engine，打印检测结果。
//   P <start> <len> <type>   格式化 PII（type 1..8）
//   K <start> <len> <kid>    关键词提示
//
// 用法：Vdetect <input-file>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <vector>

#include "Vl1_engine.h"
#include "verilated.h"

static void emit(const char *tag, unsigned start, unsigned len, unsigned kind) {
    std::printf("%s %u %u %u\n", tag, start, len, kind);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    if (!in) {
        std::fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }
    std::vector<unsigned char> data((std::istreambuf_iterator<char>(in)),
                                    std::istreambuf_iterator<char>());

    Vl1_engine *dut = new Vl1_engine;
    auto tick = [&]() {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    };
    auto record = [&]() {
        if (dut->digit_valid) emit("P", dut->digit_start, dut->digit_len, dut->digit_type);
        if (dut->email_valid) emit("P", dut->email_start, dut->email_len, 5);
        if (dut->ipv4_valid)  emit("P", dut->ipv4_start,  dut->ipv4_len,  6);
        if (dut->uscc_valid)  emit("P", dut->uscc_start,  dut->uscc_len,  7);
        if (dut->plate_valid) emit("P", dut->plate_start, dut->plate_len, 8);
        if (dut->kw_valid)    emit("K", dut->kw_start,    dut->kw_len,    dut->kw_kid);
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
    for (int i = 0; i < 4; i++) {
        tick();
        record();
    }

    delete dut;
    return 0;
}
