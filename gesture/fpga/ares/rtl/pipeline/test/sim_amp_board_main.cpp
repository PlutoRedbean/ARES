//=============================================================================
// Board-level ARES 2-hart AMP CoreMark simulation main
//-----------------------------------------------------------------------------
// The SystemVerilog testbench drives clk_27m/reset and decodes uart_tx.  This
// file only loads the two Pango readmemh files into the DPI memory model and
// advances Verilator time until the TB finishes.
//
// The files are the same ones the PDS flow \$readmemh-initializes the BRAMs
// from (build/pipeline/irom.hex / dram.hex, produced by
// scripts/pipeline_image.py from the same ELF), so the simulated image and
// the on-board image are the same bytes.  The per-hart DRAM replication is
// already inside dram.hex (--replicate-dram-words 8192).
//=============================================================================
#include "Vtb_pipeline_amp_board.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static constexpr uint32_t IROM_BASE  = 0x80000000u;
static constexpr uint32_t IROM_BYTES = 32u * 1024u;
static constexpr uint32_t DRAM_BASE  = 0x80100000u;
static constexpr uint32_t DRAM_BYTES = 256u * 1024u;

// Flat byte views of the two local memories, addressed like the DPI models in
// rtl/pipeline/soc/ip/BRAM.v and rtl/pipeline/soc/jyd/irom_bmem32.sv.
static uint8_t irom[IROM_BYTES];
static uint8_t dram[DRAM_BYTES];

static uint32_t load_le32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

static void store_le32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<uint8_t>(v >> (8 * i));
}

extern "C" int vaddr_read(int addr) {
    uint32_t a = static_cast<uint32_t>(addr);
    if (a >= IROM_BASE && a + 3 < IROM_BASE + IROM_BYTES) {
        return static_cast<int>(load_le32(irom + (a - IROM_BASE)));
    }
    if (a >= DRAM_BASE && a + 3 < DRAM_BASE + DRAM_BYTES) {
        return static_cast<int>(load_le32(dram + (a - DRAM_BASE)));
    }
    return 0;
}

extern "C" void vaddr_write(int addr, int data, signed char len) {
    uint32_t a = static_cast<uint32_t>(addr);
    int n = 1 << (len & 3);
    if (a >= DRAM_BASE && a < DRAM_BASE + DRAM_BYTES) {
        uint32_t o = a - DRAM_BASE;
        for (int i = 0; i < n && o + i < DRAM_BYTES; ++i) {
            dram[o + i] = static_cast<uint8_t>(
                (static_cast<uint32_t>(data) >> (8 * i)) & 0xff);
        }
    }
}

extern "C" int sim_stats_enabled() { return 0; }
extern "C" void get_store_buffer_counts(unsigned long long, ...) {}
extern "C" int sim_console_getchar() { return -1; }
extern "C" void sim_led_write(int) {}

// Reads one word per line ("%08x"), the format scripts/pipeline_image.py
// emits.  A short file leaves part of the memory zero-filled on the board, so
// treat it as an error instead of running with a silently truncated image.
static bool load_hex(const char *path, uint8_t *dst, uint32_t bytes) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        perror(path);
        return false;
    }
    uint32_t filled = 0;
    uint32_t word;
    while (filled < bytes && fscanf(fp, "%x", &word) == 1) {
        store_le32(dst + filled, word);
        filled += 4;
    }
    fclose(fp);
    if (filled != bytes) {
        fprintf(stderr, "%s: expected %u words, got %u\n",
                path, bytes / 4, filled / 4);
        return false;
    }
    return true;
}

static uint32_t nonzero_words(const uint8_t *p, uint32_t bytes) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < bytes; i += 4) n += load_le32(p + i) != 0;
    return n;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <irom.hex> <dram.hex> [max_time_ns]\n", argv[0]);
        return 2;
    }
    if (!load_hex(argv[1], irom, sizeof(irom))) return 2;
    if (!load_hex(argv[2], dram, sizeof(dram))) return 2;

    printf("[amp-board] image: irom %u/%u, dram %u/%u nonzero words\n",
           nonzero_words(irom, sizeof(irom)), IROM_BYTES / 4,
           nonzero_words(dram, sizeof(dram)), DRAM_BYTES / 4);

    uint64_t max_time_ns = (argc > 3)
        ? strtoull(argv[3], nullptr, 0) : 200000000ull;

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
