// Short-reset regression for student_top (docs/pipeline_reset_analysis.md §11).
//
// Each run fills the pipeline with one program, pulses reset for a few cycles
// and then checks the restart: the first retirement must be the reset vector
// and the first DRAM write must be the restarted program's own first store.
// Anything else came from an instruction that was in flight before the pulse.
#include "Vtb_reset_pulse.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

static uint32_t irom[8192];
static uint8_t  dram[1u << 18];

static bool     after_reset = false;
static bool     first_write_seen = false;
static int      stale_writes = 0;

static const uint32_t FIRST_STORE_ADDR = 0x80100000u;

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= 0x80000000u && a < 0x80008000u)
        return static_cast<int>(irom[(a - 0x80000000u) >> 2]);
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
        for (int i = 0; i < n && o + i < sizeof(dram); ++i)
            dram[o + i] = static_cast<uint8_t>((static_cast<uint32_t>(data) >> (8 * i)) & 0xff);
        if (after_reset && !first_write_seen) {
            if (a == FIRST_STORE_ADDR) first_write_seen = true;
            else ++stale_writes;
        }
    }
}

extern "C" int sim_stats_enabled() { return 0; }
extern "C" void get_store_buffer_counts(unsigned long long, ...) {}
extern "C" int sim_console_getchar() { return -1; }
extern "C" void sim_led_write(int) {}

// lui x1,0x80100 ; addi x3,x0,0xAA ; sw x3,0(x1) ; then a long body ; ebreak
static void load_program(uint32_t body) {
    std::memset(irom, 0, sizeof(irom));
    std::memset(dram, 0, sizeof(dram));
    irom[0] = 0x801000b7u;
    irom[1] = 0x0aa00193u;
    irom[2] = 0x0030a023u;
    for (int i = 3; i < 300; ++i) irom[i] = body;
    irom[300] = 0x00100073u;
    irom[301] = 0x0000006fu;
}

struct Result { int stale_retires; int stale_writes; bool restarted; };

static Result run(uint32_t body, int pulse_len, int pulse_at) {
    load_program(body);
    VerilatedContext ctx;
    Vtb_reset_pulse top{&ctx};
    auto tick = [&]() {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    };

    after_reset = false;
    first_write_seen = false;
    stale_writes = 0;

    top.clk = 0; top.rst = 1;
    for (int i = 0; i < 20; ++i) tick();
    top.rst = 0;
    for (int i = 0; i < pulse_at; ++i) tick();
    top.rst = 1;
    for (int i = 0; i < pulse_len; ++i) tick();
    top.rst = 0;
    after_reset = true;

    Result r{0, 0, false};
    for (int i = 0; i < 60; ++i) {
        top.eval();
        if (top.retire_valid) {
            if (!r.restarted && top.retire_pc == 0x80000000u) r.restarted = true;
            else if (!r.restarted) ++r.stale_retires;
        }
        tick();
    }
    r.stale_writes = stale_writes;
    top.final();
    return r;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    // addi x3,x3,1 keeps the pipeline full; sw x3,0x100(x1) keeps the store
    // path busy with writes the restarted program has not reached yet.
    const struct { const char *name; uint32_t body; } progs[] = {
        {"addi", 0x00118193u},
        {"store", 0x1030a023u},
    };
    const int pulses[] = {1, 2, 3, 4, 6, 8};
    const int phases[] = {34, 35, 38, 42, 58};

    int runs = 0, failures = 0;
    for (const auto &p : progs) {
        for (int len : pulses) {
            for (int at : phases) {
                Result r = run(p.body, len, at);
                ++runs;
                if (r.stale_retires || r.stale_writes || !r.restarted) {
                    ++failures;
                    std::printf("FAIL prog=%s pulse=%d at=%d stale_retires=%d stale_writes=%d restarted=%d\n",
                                p.name, len, at, r.stale_retires, r.stale_writes, r.restarted);
                }
            }
        }
    }
    if (failures) {
        std::printf("RESET PULSE TEST FAILED: %d of %d runs\n", failures, runs);
        return 1;
    }
    std::printf("RESET PULSE TEST PASS (%d runs, pulses 1-8 cycles)\n", runs);
    return 0;
}
