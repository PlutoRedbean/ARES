//=============================================================================
// Board-level ARES 2-hart AMP CoreMark simulation main
//-----------------------------------------------------------------------------
// The SystemVerilog testbench drives clk_27m/reset and decodes uart_tx.  This
// file only loads the flat CoreMark image into the DPI memory model and
// advances Verilator time until the TB finishes.
//=============================================================================
#include "Vtb_pipeline_amp_board.h"
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
        // The AMP top adds DATA_OFFSET = hart * 0x8000 before the private
        // BRAM lookup, so each hart's 32 KiB view needs the same image.
        for (size_t h = 0; h * region + n <= sizeof(dram); ++h) {
            std::memcpy(dram + h * region, image.data() + dram_offset, n);
        }
    }
    return true;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <coremark.bin> [max_time_ns]\n", argv[0]);
        return 2;
    }
    if (!load_image(argv[1])) return 2;

    uint64_t max_time_ns = (argc > 2)
        ? strtoull(argv[2], nullptr, 0) : 200000000ull;

    VerilatedContext *ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vtb_pipeline_amp_board *top = new Vtb_pipeline_amp_board{ctx};

    // The SV TB uses integer-nanosecond delays; Verilator's time unit is the
    // 1 ps time precision here, so advance 1000 units (1 ns) per eval.
    const uint64_t step_ps = 1000;
    const uint64_t max_time_ps = max_time_ns * step_ps;

    top->eval();
    while (!Verilated::gotFinish() && ctx->time() < max_time_ps) {
        ctx->timeInc(step_ps);
        top->eval();
    }

    printf("\n[amp-board] uart_done=%d led=%02x time=%llu ns %s\n",
           static_cast<int>(top->done),
           static_cast<unsigned>(top->led),
           static_cast<unsigned long long>(ctx->time() / step_ps),
           top->done ? "PASS" : "FAIL");

    bool ok = top->done;
    top->final();
    delete top;
    delete ctx;
    return ok ? 0 : 1;
}
