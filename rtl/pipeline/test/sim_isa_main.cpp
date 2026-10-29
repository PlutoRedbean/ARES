#include "Vtb_pipeline_isa.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint8_t irom[1u << 15];
static uint8_t dram[1u << 18];

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= 0x80000000u && a < 0x80008000u) {
        uint32_t o = a - 0x80000000u;
        return irom[o] | (irom[o + 1] << 8) | (irom[o + 2] << 16) | (irom[o + 3] << 24);
    }
    if (a >= 0x80100000u && a < 0x80140000u) {
        uint32_t o = a - 0x80100000u;
        return dram[o] | (dram[o + 1] << 8) | (dram[o + 2] << 16) | (dram[o + 3] << 24);
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
    }
}

extern "C" int sim_stats_enabled() { return 0; }
extern "C" void get_store_buffer_counts(unsigned long long, ...) {}
extern "C" int sim_console_getchar() { return -1; }
extern "C" void sim_led_write(int) {}

static bool load_image(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); return false; }
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size < 0 || size > (1 << 21)) {
        fprintf(stderr, "bad image size %ld\n", size);
        fclose(fp);
        return false;
    }
    std::vector<uint8_t> image(static_cast<size_t>(size));
    if (fread(image.data(), 1, image.size(), fp) != image.size()) {
        fprintf(stderr, "short read\n");
        fclose(fp);
        return false;
    }
    fclose(fp);
    for (size_t i = 0; i < image.size(); ++i) {
        uint32_t addr = 0x80000000u + static_cast<uint32_t>(i);
        if (addr < 0x80008000u) irom[addr - 0x80000000u] = image[i];
        else if (addr >= 0x80100000u && addr < 0x80140000u)
            dram[addr - 0x80100000u] = image[i];
    }
    return true;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <program.bin> [max_cycles]\n", argv[0]);
        return 2;
    }
    if (!load_image(argv[1])) return 2;
    uint64_t max_cycles = (argc > 2) ? strtoull(argv[2], nullptr, 0) : 2000000ull;

    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_isa *top = new Vtb_pipeline_isa{ctx};

    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 20; ++i) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->rst = 0;

    uint64_t cycles = 0;
    while (!top->ebreak_seen && cycles < max_cycles) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        ++cycles;
    }

    std::printf("cycles=%llu retire=%u a0=%08x ebreak=%d\n",
                static_cast<unsigned long long>(cycles),
                top->retire_count, top->a0, top->ebreak_seen);
    bool ok = top->ebreak_seen && top->a0 == 0;
    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
