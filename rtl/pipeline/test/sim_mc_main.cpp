#include "Vtb_pipeline_mc.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// Private IROM image for every hart.  The DPI read is shared by all IROM
// instances; the image is read-only so replication is coherent by construction.
static uint8_t irom[1u << 15];

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= 0x80000000u && a < 0x80008000u) {
        uint32_t o = a - 0x80000000u;
        return irom[o] | (irom[o + 1] << 8) |
               (irom[o + 2] << 16) | (irom[o + 3] << 24);
    }
    return 0;
}

static bool load_image(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); return false; }
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0 || size > static_cast<long>(sizeof(irom))) {
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
    std::memset(irom, 0, sizeof(irom));
    std::memcpy(irom, image.data(), image.size());
    return true;
}

static void cycle(Vtb_pipeline_mc *top) {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <program.bin> <cores> [max_cycles] [core_mask]\n", argv[0]);
        return 2;
    }
    if (!load_image(argv[1])) return 2;

    int cores = atoi(argv[2]);
    if (cores != 2 && cores != 4) {
        fprintf(stderr, "cores must be 2 or 4\n");
        return 2;
    }
    uint64_t max_cycles = (argc > 3) ? strtoull(argv[3], nullptr, 0) : 2000000ull;
    unsigned all = (cores == 4) ? 0xFu : 0x3u;
    unsigned active = (argc > 4) ? (static_cast<unsigned>(strtoul(argv[4], nullptr, 0)) & all)
                                 : all;

    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_mc *top = new Vtb_pipeline_mc{ctx};

    top->core_en = active;
    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 20; ++i) cycle(top);
    top->rst = 0;

    const unsigned mask = active;
    uint64_t cycles = 0;
    auto done_bits = [&]() -> unsigned {
        return (top->done_0 ? 1u : 0u) |
               (top->done_1 ? 2u : 0u) |
               (top->done_2 ? 4u : 0u) |
               (top->done_3 ? 8u : 0u);
    };

    while ((done_bits() & mask) != mask && cycles < max_cycles) {
        cycle(top);
        ++cycles;
    }

    unsigned done = done_bits() & mask;
    unsigned a0[4] = {top->a0_0, top->a0_1, top->a0_2, top->a0_3};

    bool ok = (done == mask);
    for (int i = 0; i < cores; ++i) {
        if ((active & (1u << i)) && a0[i] != 0) ok = false;
    }
    if (cycles >= max_cycles && done != mask) {
        fprintf(stderr, "TIMEOUT after %llu cycles\n",
                static_cast<unsigned long long>(cycles));
        ok = false;
    }

    printf("pipeline-mc: cores=%d active=%x cycles=%llu done=%x/%x a0=[%08x,%08x,%08x,%08x] %s\n",
           cores, active, static_cast<unsigned long long>(cycles),
           done, mask, a0[0], a0[1], a0[2], a0[3],
           ok ? "PASS" : "FAIL");

    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
