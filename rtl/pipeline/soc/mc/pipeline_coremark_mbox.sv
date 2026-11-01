//=============================================================================
// ARES pipeline SoC - shared uncached CoreMark mailbox
//-----------------------------------------------------------------------------
// One 256-byte MMIO window (0xA000_F000..0xA000_F0FF) shared by all harts of
// the private-memory AMP profile.  The window is divided into four 16-word
// slots (stride 0x40); hart h normally owns slot h:
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
// Reads are combinational (the bridge samples them in the request-accept
// cycle); writes are captured on req_valid && req_write with byte strobes.
// The port is uncached in the SoC (it bypasses the L1 D$) and every access is
// a single commit-head MMIO operation, so no atomics or coherence are needed.
//
// The mailbox is implemented as four independent 16x32 register files.  Each
// file has exactly one write port: a priority mux selects either the boot
// clear walk or one hart targeting that slot.  The boot clear and the harts
// are mutually exclusive (the top holds all harts in reset until init_done),
// and software never targets one slot from two harts in the same cycle.  This
// keeps PDS from inferring a multi-write RAM for the mailbox.
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
    localparam integer INIT_SLOT_W   = 2;
    localparam integer INIT_WORD_W   = WORD_IDX_W - INIT_SLOT_W;

    reg [31:0] slot0 [0:SLOT_WORDS-1];
    reg [31:0] slot1 [0:SLOT_WORDS-1];
    reg [31:0] slot2 [0:SLOT_WORDS-1];
    reg [31:0] slot3 [0:SLOT_WORDS-1];

    reg [INIT_W-1:0] init_cnt;

    // One word per cycle, through each slot's own write port: the 2,048-bit
    // mailbox never touches the global reset net.  init_cnt[WORD_IDX_W] is the
    // done flag, so a reset drops the mailbox straight back into INIT.
    wire init_busy = ~init_cnt[WORD_IDX_W];
    assign init_done = ~init_busy;

    wire [INIT_SLOT_W-1:0] init_slot = init_cnt[WORD_IDX_W-1:WORD_IDX_W-INIT_SLOT_W];
    wire [INIT_WORD_W-1:0] init_word = init_cnt[INIT_WORD_W-1:0];

    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_read
            wire [1:0] rslot = req_addr[g][7:6];
            wire [3:0] rword = req_addr[g][5:2];
            wire [31:0] rd0 = slot0[rword];
            wire [31:0] rd1 = slot1[rword];
            wire [31:0] rd2 = slot2[rword];
            wire [31:0] rd3 = slot3[rword];

            assign rsp_data[g] = (req_addr[g][31:8] == MBOX_ADDR_TAG)
                                 ? (rslot == 2'd0 ? rd0 :
                                    rslot == 2'd1 ? rd1 :
                                    rslot == 2'd2 ? rd2 : rd3)
                                 : 32'd0;
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Per-slot write select.  One writer per slot per cycle; hart 0 has
    // priority only for the unusual case of two harts targeting one slot in
    // the same cycle.
    //-------------------------------------------------------------------------
    reg [31:0] wd0, wd1, wd2, wd3;
    reg [3:0]  ws0, ws1, ws2, ws3;
    reg [3:0]  wa0, wa1, wa2, wa3;
    reg        we0, we1, we2, we3;

    integer h0, h1, h2, h3;

    always @* begin
        wd0 = 32'd0; ws0 = 4'd0; wa0 = 4'd0; we0 = 1'b0;
        for (h0 = CORES-1; h0 >= 0; h0 = h0 - 1) begin
            if (!we0 && req_valid[h0] && req_write[h0] &&
                (req_addr[h0][31:8] == MBOX_ADDR_TAG) &&
                (req_addr[h0][7:6] == 2'd0)) begin
                wd0 = req_wdata[h0];
                ws0 = req_wstrb[h0];
                wa0 = req_addr[h0][5:2];
                we0 = 1'b1;
            end
        end
    end

    always @* begin
        wd1 = 32'd0; ws1 = 4'd0; wa1 = 4'd0; we1 = 1'b0;
        for (h1 = CORES-1; h1 >= 0; h1 = h1 - 1) begin
            if (!we1 && req_valid[h1] && req_write[h1] &&
                (req_addr[h1][31:8] == MBOX_ADDR_TAG) &&
                (req_addr[h1][7:6] == 2'd1)) begin
                wd1 = req_wdata[h1];
                ws1 = req_wstrb[h1];
                wa1 = req_addr[h1][5:2];
                we1 = 1'b1;
            end
        end
    end

    always @* begin
        wd2 = 32'd0; ws2 = 4'd0; wa2 = 4'd0; we2 = 1'b0;
        for (h2 = CORES-1; h2 >= 0; h2 = h2 - 1) begin
            if (!we2 && req_valid[h2] && req_write[h2] &&
                (req_addr[h2][31:8] == MBOX_ADDR_TAG) &&
                (req_addr[h2][7:6] == 2'd2)) begin
                wd2 = req_wdata[h2];
                ws2 = req_wstrb[h2];
                wa2 = req_addr[h2][5:2];
                we2 = 1'b1;
            end
        end
    end

    always @* begin
        wd3 = 32'd0; ws3 = 4'd0; wa3 = 4'd0; we3 = 1'b0;
        for (h3 = CORES-1; h3 >= 0; h3 = h3 - 1) begin
            if (!we3 && req_valid[h3] && req_write[h3] &&
                (req_addr[h3][31:8] == MBOX_ADDR_TAG) &&
                (req_addr[h3][7:6] == 2'd3)) begin
                wd3 = req_wdata[h3];
                ws3 = req_wstrb[h3];
                wa3 = req_addr[h3][5:2];
                we3 = 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // One write port per slot: clear walk muxed with the selected hart write.
    //-------------------------------------------------------------------------
    wire clear0 = init_busy && (init_slot == 2'd0);
    wire clear1 = init_busy && (init_slot == 2'd1);
    wire clear2 = init_busy && (init_slot == 2'd2);
    wire clear3 = init_busy && (init_slot == 2'd3);

    wire [3:0]  wstrb0 = clear0 ? 4'hF : ws0;
    wire [3:0]  wstrb1 = clear1 ? 4'hF : ws1;
    wire [3:0]  wstrb2 = clear2 ? 4'hF : ws2;
    wire [3:0]  wstrb3 = clear3 ? 4'hF : ws3;

    wire [3:0]  waddr0 = clear0 ? init_word : wa0;
    wire [3:0]  waddr1 = clear1 ? init_word : wa1;
    wire [3:0]  waddr2 = clear2 ? init_word : wa2;
    wire [3:0]  waddr3 = clear3 ? init_word : wa3;

    wire [31:0] wdata0 = clear0 ? 32'd0 : wd0;
    wire [31:0] wdata1 = clear1 ? 32'd0 : wd1;
    wire [31:0] wdata2 = clear2 ? 32'd0 : wd2;
    wire [31:0] wdata3 = clear3 ? 32'd0 : wd3;

    wire do0 = clear0 | we0;
    wire do1 = clear1 | we1;
    wire do2 = clear2 | we2;
    wire do3 = clear3 | we3;

    always @(posedge clk) begin
        if (do0) begin
            if (wstrb0[0]) slot0[waddr0][ 7: 0] <= wdata0[ 7: 0];
            if (wstrb0[1]) slot0[waddr0][15: 8] <= wdata0[15: 8];
            if (wstrb0[2]) slot0[waddr0][23:16] <= wdata0[23:16];
            if (wstrb0[3]) slot0[waddr0][31:24] <= wdata0[31:24];
        end
    end

    always @(posedge clk) begin
        if (do1) begin
            if (wstrb1[0]) slot1[waddr1][ 7: 0] <= wdata1[ 7: 0];
            if (wstrb1[1]) slot1[waddr1][15: 8] <= wdata1[15: 8];
            if (wstrb1[2]) slot1[waddr1][23:16] <= wdata1[23:16];
            if (wstrb1[3]) slot1[waddr1][31:24] <= wdata1[31:24];
        end
    end

    always @(posedge clk) begin
        if (do2) begin
            if (wstrb2[0]) slot2[waddr2][ 7: 0] <= wdata2[ 7: 0];
            if (wstrb2[1]) slot2[waddr2][15: 8] <= wdata2[15: 8];
            if (wstrb2[2]) slot2[waddr2][23:16] <= wdata2[23:16];
            if (wstrb2[3]) slot2[waddr2][31:24] <= wdata2[31:24];
        end
    end

    always @(posedge clk) begin
        if (do3) begin
            if (wstrb3[0]) slot3[waddr3][ 7: 0] <= wdata3[ 7: 0];
            if (wstrb3[1]) slot3[waddr3][15: 8] <= wdata3[15: 8];
            if (wstrb3[2]) slot3[waddr3][23:16] <= wdata3[23:16];
            if (wstrb3[3]) slot3[waddr3][31:24] <= wdata3[31:24];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            init_cnt <= {INIT_W{1'b0}};
        end else if (init_busy) begin
            init_cnt <= init_cnt + 1'b1;
        end
    end
endmodule
