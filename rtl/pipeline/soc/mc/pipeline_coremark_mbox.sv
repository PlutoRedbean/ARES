//=============================================================================
// ARES pipeline SoC - shared uncached CoreMark mailbox
//-----------------------------------------------------------------------------
// One 256-byte MMIO window (0xA000_F000..0xA000_F0FF) shared by all harts of
// the private-memory AMP profile.  The window is divided into CORES slots of
// 16 words (stride 0x40); hart h owns slot h:
//
//   0x00 + h*0x40  hart0 -> hart h  GO
//   0x04 + h*0x40  hart h -> hart0  DONE
//   0x08          ITERATIONS
//   0x0C          EXECS
//   0x10          SIZE
//   0x14..0x1C    SEED1..SEED3
//   0x20..0x2C    CRCLIST/CRCMATRIX/CRCSTATE/CRCFINAL
//   0x30          ERR
//
// Reads are registered: the slot index is captured on the request clock, the
// flat 64:1 mux is split into 16:1 bank partials registered one cycle later
// plus a final 4:1, and perip_bridge takes rsp_data (RESP_SHARED) in the
// second response cycle.  Writes are captured on req_valid && req_write with
// byte strobes in the accept cycle.
// The port is uncached in the SoC (it bypasses the L1 D$) and every access is
// a single commit-head MMIO operation, so no atomics or coherence are needed.
// Four slots are decoded regardless of CORES so the address index is always
// in range; slots above CORES-1 are simply unused.
//=============================================================================
module pipeline_coremark_mbox #(
    parameter integer CORES = 2
) (
    input  wire                   clk,
    input  wire                   rst,

    input  wire [CORES-1:0]       req_valid,
    input  wire [CORES-1:0]       req_write,
    input  wire [CORES-1:0][31:0] req_addr,
    input  wire [CORES-1:0][31:0] req_wdata,
    input  wire [CORES-1:0][ 3:0] req_wstrb,

    output wire [CORES-1:0][31:0] rsp_data,
    // Goes high once the boot-time clear has walked the whole window.  The AMP
    // top holds every hart in reset until then, so no hart can observe (or
    // race) a partially cleared mailbox.
    output wire                   init_done
);
    localparam [23:0]  MBOX_ADDR_TAG = 24'hA000F0;  /* addr[31:8] */
    localparam integer SLOT_WORDS    = 16;
    localparam integer WORDS         = 4 * SLOT_WORDS;
    localparam integer WORD_IDX_W    = $clog2(WORDS);
    localparam integer INIT_W        = WORD_IDX_W + 1;

    reg [31:0] slot [0:WORDS-1];
    reg [INIT_W-1:0] init_cnt;

    // One word per cycle, through the array's own write port: the 2,048-bit
    // slot array never touches the global reset net.  init_cnt[WORD_IDX_W] is
    // the done flag, so a reset drops the mailbox straight back into INIT.
    wire init_busy = ~init_cnt[WORD_IDX_W];

    assign init_done = ~init_busy;

    // Read pipeline.  The flat 64:1 read mux was the design-wide setup
    // critical path (16~17 levels, 67~72% route), so it is split into two
    // registered stages that both stay inside this module:
    //
    //   cycle T     CPU request accepted, address stable
    //   edge T+1    rd_idx_q  <= req_addr[7:2]
    //   cycle T+1   16:1 mux per bank, selected by rd_idx_q[3:0]
    //   edge T+2    rd_bank_q <= the four partial words
    //               rd_sel_q  <= rd_idx_q[5:4]
    //   cycle T+2   4:1 mux -> rsp_data, taken by the bridge at r2
    //
    // The MMIO read latency is still two cycles; only the amount of mux that
    // has to settle inside one cycle changed.  All registers here are pure
    // payload (written on every clock) and stay off the reset net.
    localparam integer BANK_COUNT = 4;
    localparam integer BANK_SEL_W = 2;
    localparam integer BANK_WORDS = WORDS / BANK_COUNT;
    localparam integer WORD_SEL_W = WORD_IDX_W - BANK_SEL_W;

    reg [WORD_IDX_W-1:0] rd_idx_q  [0:CORES-1];
    reg [BANK_SEL_W-1:0] rd_sel_q  [0:CORES-1];
    reg [31:0]           rd_bank_q [0:CORES*BANK_COUNT-1];

    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_read
            integer b;
            always @(posedge clk) begin
                rd_idx_q[g] <= req_addr[g][7:2];
                rd_sel_q[g] <= rd_idx_q[g][WORD_IDX_W-1:WORD_SEL_W];
                for (b = 0; b < BANK_COUNT; b = b + 1) begin
                    rd_bank_q[g*BANK_COUNT + b] <=
                        slot[b*BANK_WORDS + rd_idx_q[g][WORD_SEL_W-1:0]];
                end
            end
            assign rsp_data[g] = rd_bank_q[g*BANK_COUNT + rd_sel_q[g]];
        end
    endgenerate

    integer h;
    always @(posedge clk) begin
        if (rst) begin
            init_cnt <= {INIT_W{1'b0}};
        end else if (init_busy) begin
            slot[init_cnt[WORD_IDX_W-1:0]] <= 32'd0;
            init_cnt <= init_cnt + 1'b1;
        end else begin
            for (h = 0; h < CORES; h = h + 1) begin
                if (req_valid[h] && req_write[h] &&
                    (req_addr[h][31:8] == MBOX_ADDR_TAG)) begin
                    if (req_wstrb[h][0])
                        slot[req_addr[h][7:2]][ 7: 0] <= req_wdata[h][ 7: 0];
                    if (req_wstrb[h][1])
                        slot[req_addr[h][7:2]][15: 8] <= req_wdata[h][15: 8];
                    if (req_wstrb[h][2])
                        slot[req_addr[h][7:2]][23:16] <= req_wdata[h][23:16];
                    if (req_wstrb[h][3])
                        slot[req_addr[h][7:2]][31:24] <= req_wdata[h][31:24];
                end
            end
        end
    end
endmodule
