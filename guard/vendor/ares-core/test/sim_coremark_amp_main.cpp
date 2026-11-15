#include "Vtb_pipeline_coremark_amp.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static uint32_t irom[1u << 13];
static uint8_t  dram[1u << 18];

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= 0x80000000u && a < 0x80008000u) {
        return static_cast<int>(irom[(a - 0x80000000u) >> 2]);
    }
    if (a >= 0x80100000u && a < 0x80140000u) {
        uint32_t o = a - 0x80100000u;
        if (o + 3 < sizeof(dram)) {
            return dram[o] | (dram[o + 1] << 8) |
                   (dram[o + 2] << 16) | (dram[o + 3] << 24);
        }
        return 0;
    }
    return 0;
}

extern "C" void vaddr_write(int addr, int data, signed char len) {
    uint32_t a = static_cast<uint32_t>(addr);
    int n = 1 << (len & 3);
    if (a >= 0x80100000u && a < 0x80140000u) {
        uint32_t o = a - 0x80100000u;
        for (int i = 0; i < n && o + i < sizeof(dram); ++i)
            dram[o + i] = static_cast<uint8_t>(
                (static_cast<uint32_t>(data) >> (8 * i)) & 0xff);
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
    if (size < 0) { fclose(fp); return false; }
    std::vector<uint8_t> image(static_cast<size_t>(size));
    if (!image.empty() &&
        fread(image.data(), 1, image.size(), fp) != image.size()) {
        fprintf(stderr, "short read\n");
        fclose(fp);
        return false;
    }
    fclose(fp);

    std::memset(irom, 0, sizeof(irom));
    std::memset(dram, 0, sizeof(dram));
    size_t n_irom = std::min(image.size(), sizeof(irom));
    for (size_t i = 0; i + 3 < n_irom; i += 4) {
        irom[i >> 2] = static_cast<uint32_t>(image[i]) |
                       (static_cast<uint32_t>(image[i + 1]) << 8) |
                       (static_cast<uint32_t>(image[i + 2]) << 16) |
                       (static_cast<uint32_t>(image[i + 3]) << 24);
    }

    const size_t dram_offset = 0x100000u;
    const size_t region = 32u * 1024u;
    if (image.size() > dram_offset) {
        size_t n = std::min(image.size() - dram_offset, region);
        // Replicate the initialized DRAM region into each hart's private
        // 32 KiB view; the core adds DATA_OFFSET before the L1 lookup.
        for (size_t h = 0; h * region + n <= sizeof(dram); ++h) {
            std::memcpy(dram + h * region, image.data() + dram_offset, n);
        }
    }
    return true;
}

static void cycle(Vtb_pipeline_coremark_amp *top) {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <coremark.bin> [max_cycles] [cores]\n", argv[0]);
        return 2;
    }
    if (!load_image(argv[1])) return 2;
    uint64_t max_cycles = (argc > 2) ? strtoull(argv[2], nullptr, 0) : 200000000ull;
    unsigned cores = (argc > 3) ? static_cast<unsigned>(strtoul(argv[3], nullptr, 0)) : 2u;
    if (cores < 1u || cores > 4u) {
        fprintf(stderr, "error: cores must be 1..4, got %u\n", cores);
        return 2;
    }

    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_coremark_amp *top = new Vtb_pipeline_coremark_amp{ctx};

    top->core_en = static_cast<CData>((1u << cores) - 1u);
    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 20; ++i) cycle(top);
    top->rst = 0;

    uint64_t cycles = 0;
    while (!(top->done_0 && top->done_1 && top->done_2 && top->done_3) &&
           cycles < max_cycles) {
        cycle(top);
        ++cycles;
    }

    bool ok = top->done_0 && top->done_1 && top->done_2 && top->done_3 &&
              top->a0_0 == 0 && top->a0_1 == 0 &&
              top->a0_2 == 0 && top->a0_3 == 0;
    printf("\npipeline-coremark-amp: cycles=%llu cores=%u done=%d/%d/%d/%d "
           "a0=[%08x,%08x,%08x,%08x] %s\n",
           static_cast<unsigned long long>(cycles), cores,
           top->done_0, top->done_1, top->done_2, top->done_3,
           top->a0_0, top->a0_1, top->a0_2, top->a0_3,
           ok ? "PASS" : "FAIL");
    if (!ok) fprintf(stderr, "CoreMark AMP failed or timed out\n");

    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
