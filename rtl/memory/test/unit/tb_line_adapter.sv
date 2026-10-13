//=============================================================================
// ARES LSU - self-checking unit bench for the L10 line adapter
//-----------------------------------------------------------------------------
// DUT : rtl/memory/line_adapter.sv (cache line <-> 16B beat, memory.md 6.7)
// Spec: docs/microarch/memory.md 6.7 (128-bit bus, 16B beats, single
//       outstanding read, write acceptance), 6.4 (refill beats), 6.6 (WB);
//       rtl/memory/LSU_INTERFACES.md section 6 (frozen interface) and
//       section 8 (verification requirements).
// FREE items: FREE-10 (verification environment internal structure).
//
// Structure (independent top, no DPI, no harness, own clock + reset):
//   * behavioural byte level 128-bit memory slave with programmable read
//     latency / read-ready / write-ready stalls and write-before-read
//     ordering for same cycle conflicts (memory.md 6.7),
//   * a golden checker engine that runs once per cycle and compares every DUT
//     output against an independent reference: the accepted request fields,
//     the expected beat address sequence, the memory array content and the
//     exactly-once completion pulses,
//   * directed tests for reset, refill assembly, single beat read/write,
//     writeback, partial byte enables, backpressure and arbitration,
//   * a fixed seed randomised phase (RAND_CYCLES cycles) with random
//     valid/ready patterns that covers all four client ports at once.
//
// The bench is compiled once per line size (LINE_BEATS is derived inside
// ares_pkg): -DCONFIG_LINE_BYTES=16 / 32 / 64.
//
// Build / run (repository root, LINE_BYTES = 16 | 32 | 64):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//       --top-module tb_line_adapter --Mdir sim/build/unit/tb_line_adapter \
//       -o tb_line_adapter \
//       rtl/common/ares_pkg.sv rtl/memory/line_adapter.sv \
//       rtl/memory/test/unit/tb_line_adapter.sv
//   sim/build/unit/tb_line_adapter/tb_line_adapter
//   (-o is resolved against --Mdir by Verilator 5.x, so the output name must be
//    given relative to the Mdir.)
//=============================================================================
`timescale 1ns/1ps

module tb_line_adapter;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Configuration / geometry
    //-------------------------------------------------------------------------
    localparam int unsigned LINE_BYTES_L = ares_pkg::LINE_BYTES;
    localparam int unsigned LINE_BEATS_L = ares_pkg::LINE_BEATS;
    localparam int unsigned LDATA_W      = 8 * LINE_BYTES_L;
    localparam int unsigned MEM_BYTES    = 64 * 1024;              // 64 KiB
    localparam int unsigned N_LINES      = MEM_BYTES / LINE_BYTES_L;
    localparam int unsigned RD_LINES     = N_LINES / 2;            // read window
    localparam int unsigned RAND_CYCLES  = 12000;

    //-------------------------------------------------------------------------
    // Clock and reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Watchdog: the bench must finish well inside this budget; a stalled
    // handshake is reported as a failure instead of hanging the run.
    localparam int unsigned WATCHDOG_CYCLES = 300000;
    initial begin
        repeat (WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1, "TB FAILED: watchdog timeout after %0d cycles", WATCHDOG_CYCLES);
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic                     refill_req_valid;
    logic                     refill_req_ready;
    logic [31:0]              refill_line_addr;
    logic                     refill_rsp_valid;
    logic                     refill_rsp_ready;
    logic [LDATA_W-1:0]       refill_line_data;
    logic [LINE_BEATS_L-1:0]  refill_beat_valid;

    logic                     beat_rd_req_valid;
    logic                     beat_rd_req_ready;
    logic [31:0]              beat_rd_req_addr;
    logic                     beat_rd_rsp_valid;
    logic                     beat_rd_rsp_ready;
    logic [127:0]             beat_rd_rsp_data;

    logic                     wb_req_valid;
    logic                     wb_req_ready;
    logic [31:0]              wb_line_addr;
    logic [LDATA_W-1:0]       wb_line_data;
    logic                     wb_done;

    logic                     beat_wr_req_valid;
    logic                     beat_wr_req_ready;
    logic [31:0]              beat_wr_req_addr;
    logic [127:0]             beat_wr_req_data;
    logic [15:0]              beat_wr_req_be;
    logic                     beat_wr_done;

    logic                     mem_rd_valid;
    logic                     mem_rd_ready;
    logic [31:0]              mem_rd_addr;
    logic                     mem_rsp_valid;
    logic                     mem_rsp_ready;
    logic [127:0]             mem_rsp_data;
    logic                     mem_wr_valid;
    logic                     mem_wr_ready;
    logic [31:0]              mem_wr_addr;
    logic [127:0]             mem_wr_data;
    logic [15:0]              mem_wr_be;

    line_adapter dut (.*);

    //=========================================================================
    // Behavioural 128-bit memory slave
    //=========================================================================
    logic [7:0] mem [MEM_BYTES];
    logic       mem_init_done;

    function automatic logic [7:0] mem_pattern(input logic [31:0] byte_addr);
        logic [31:0] x;
        begin
            x = byte_addr * 32'h9E37_79B1;
            mem_pattern = x[31:24] ^ x[23:16] ^ x[15:8] ^ x[7:0];
        end
    endfunction

    typedef enum logic [1:0] { MR_IDLE, MR_DELAY, MR_RSP } mr_state_e;
    mr_state_e    mr_state;
    logic [127:0] mr_data;
    logic [7:0]   mr_cnt;
    int unsigned  rd_lat_mode;      // 0 = 1 cycle, 1 = random 1..4 cycles
    int unsigned  mdl_prot_err;

    assign mem_rsp_data  = mr_data;
    assign mem_rsp_valid = (mr_state == MR_RSP);

    function automatic logic [127:0] mem_read_beat(input logic [15:0] base);
        logic [127:0] d;
        begin
            for (int unsigned b = 0; b < 16; b++) begin
                d[8*b +: 8] = mem[base + 16'(b)];
                if (mem_wr_valid && mem_wr_ready && mem_wr_be[b]
                    && (mem_wr_addr[15:4] == base[15:4]))
                    d[8*b +: 8] = mem_wr_data[8*b +: 8];
            end
            mem_read_beat = d;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!mem_init_done) begin
            mem_init_done <= 1'b1;
            for (int unsigned a = 0; a < MEM_BYTES; a++) mem[a] <= mem_pattern(32'(a));
        end else if (mem_wr_valid && mem_wr_ready) begin
            for (int unsigned b = 0; b < 16; b++)
                if (mem_wr_be[b]) mem[mem_wr_addr[15:0] + 16'(b)] <= mem_wr_data[8*b +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mr_state <= MR_IDLE;
            mr_data  <= '0;
            mr_cnt   <= 8'd0;
        end else begin
            case (mr_state)
                MR_IDLE: begin
                    if (mem_rd_valid && mem_rd_ready) begin
                        mr_data  <= mem_read_beat(mem_rd_addr[15:0]);
                        mr_cnt   <= (rd_lat_mode == 0) ? 8'd0 : 8'($urandom_range(0, 3));
                        mr_state <= MR_DELAY;
                    end
                end
                MR_DELAY: begin
                    if (mr_cnt == 8'd0) mr_state <= MR_RSP;
                    else                mr_cnt   <= mr_cnt - 8'd1;
                end
                MR_RSP: begin
                    if (mem_rsp_ready) mr_state <= MR_IDLE;
                end
                default: mr_state <= MR_IDLE;
            endcase
        end
    end

    // The slave must never see a second read while one is outstanding.
    always_ff @(posedge clk) begin
        if (!rst && mem_rd_valid && mem_rd_ready && (mr_state != MR_IDLE)) begin
            mdl_prot_err <= mdl_prot_err + 1;
            $display("[%0t] FAIL: memory slave got a read request while busy", $time);
        end
    end

    //=========================================================================
    // Golden checker engine (one pass per clock, mid-cycle)
    //=========================================================================
    int unsigned checks;
    int unsigned errors;

    task automatic chk(input logic cond, input string msg);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            if (errors <= 40) $display("[%0t] FAIL: %s", $time, msg);
        end
    endtask

    // Read channel golden state (owned by the engine only).
    logic        g_rd_busy;
    logic        g_rd_refill;
    logic [31:0] g_rd_base;
    int unsigned g_rd_req_n;      // beats already requested on the bus
    int unsigned g_rd_rsp_n;      // beats already answered
    int unsigned g_refill_acc, g_refill_cmp;
    int unsigned g_bread_acc,  g_bread_cmp;

    // Write channel golden state.
    logic        g_wr_busy;
    logic        g_wr_wb;
    logic [31:0] g_wr_base;
    int unsigned g_wr_beat_n;
    logic [LDATA_W-1:0] g_wb_line;
    logic [127:0]       g_bw_data;
    logic [15:0]        g_bw_be;
    int unsigned g_wb_acc,  g_wb_cmp;
    int unsigned g_bwr_acc, g_bwr_cmp;

    // Deferred memory content check (the slave applies the write on the edge).
    logic               g_memchk_pend;
    logic               g_memchk_wb;
    logic [15:0]        g_memchk_addr;
    logic [LDATA_W-1:0] g_memchk_line;
    logic [127:0]       g_memchk_data;
    logic [15:0]        g_memchk_be;

    task automatic engine_cycle();
        logic [15:0] beat_addr;
        begin
            if (rst) begin
                g_rd_busy  = 1'b0;
                g_rd_refill = 1'b0;
                g_rd_base  = 32'd0;
                g_rd_req_n = 0;
                g_rd_rsp_n = 0;
                g_wr_busy  = 1'b0;
                g_wr_wb    = 1'b0;
                g_wr_base  = 32'd0;
                g_wr_beat_n = 0;
                g_wb_line  = '0;
                g_bw_data  = '0;
                g_bw_be    = 16'd0;
                g_memchk_pend = 1'b0;
            end else begin
                //---- (0) deferred memory content checks ----------------------
                if (g_memchk_pend) begin
                    g_memchk_pend = 1'b0;
                    if (g_memchk_wb) begin
                        for (int unsigned b = 0; b < LINE_BYTES_L; b++)
                            chk(mem[g_memchk_addr + 16'(b)] == g_memchk_line[8*b +: 8],
                                "writeback bytes landed in memory");
                    end else begin
                        for (int unsigned b = 0; b < 16; b++)
                            if (g_memchk_be[b])
                                chk(mem[g_memchk_addr + 16'(b)] == g_memchk_data[8*b +: 8],
                                    "single beat write bytes landed in memory");
                    end
                end

                //---- (1) bus read response -----------------------------------
                if (mem_rsp_valid && mem_rsp_ready) begin
                    chk(g_rd_busy, "bus read response without an owned read");
                    beat_addr = g_rd_base[15:0] + (16'(g_rd_rsp_n) << 4);
                    for (int unsigned b = 0; b < 16; b++)
                        chk(mem_rsp_data[8*b +: 8] == mem[beat_addr + 16'(b)],
                            "beat response data differs from memory");
                    if (g_rd_refill) begin
                        chk(g_rd_rsp_n < LINE_BEATS_L, "too many refill beat responses");
                    end else begin
                        chk(g_rd_rsp_n == 0, "single beat read got more than one response");
                    end
                    g_rd_rsp_n = g_rd_rsp_n + 1;
                end

                //---- (2) bus read request ------------------------------------
                if (mem_rd_valid) begin
                    chk(g_rd_busy, "bus read request without an owned read");
                    chk(mem_rd_addr == (g_rd_base + (32'(g_rd_req_n) << 4)),
                        "read beat address is not line_base + 16*beat");
                    chk(mem_rd_addr[3:0] == 4'h0, "read address not 16B aligned");
                    if (g_rd_refill) chk(g_rd_req_n < LINE_BEATS_L, "too many refill beat requests");
                    else             chk(g_rd_req_n == 0, "single beat read issued more than one request");
                    if (mem_rd_ready) g_rd_req_n = g_rd_req_n + 1;
                end

                //---- (3) client read responses -------------------------------
                if (refill_rsp_valid) begin
                    chk(g_rd_refill && g_rd_busy, "refill_rsp_valid without an owned refill");
                    chk(g_rd_rsp_n == LINE_BEATS_L, "refill_rsp_valid before all beats arrived");
                    chk(refill_beat_valid == {LINE_BEATS_L{1'b1}}, "refill_beat_valid not complete");
                    for (int unsigned b = 0; b < LINE_BYTES_L; b++)
                        chk(refill_line_data[8*b +: 8] == mem[g_rd_base[15:0] + 16'(b)],
                            "refill line byte differs from memory");
                end
                if (beat_rd_rsp_valid) begin
                    chk(!g_rd_refill && g_rd_busy, "beat_rd_rsp_valid without an owned beat read");
                    chk(g_rd_rsp_n == 1, "beat read response without exactly one beat");
                    for (int unsigned b = 0; b < 16; b++)
                        chk(beat_rd_rsp_data[8*b +: 8] == mem[g_rd_base[15:0] + 16'(b)],
                            "single beat read data differs from memory");
                end

                //---- (4) client read completions -----------------------------
                if (refill_rsp_valid && refill_rsp_ready) begin
                    g_refill_cmp = g_refill_cmp + 1;
                    g_rd_busy = 1'b0;
                end
                if (beat_rd_rsp_valid && beat_rd_rsp_ready) begin
                    g_bread_cmp = g_bread_cmp + 1;
                    g_rd_busy = 1'b0;
                end

                //---- (5) client read requests (accepted fields are golden) ---
                if (refill_req_valid && refill_req_ready) begin
                    g_refill_acc = g_refill_acc + 1;
                    chk(!g_rd_busy, "refill accepted while a read transaction is outstanding");
                    chk(refill_line_addr[$clog2(LINE_BYTES_L)-1:0] == '0,
                        "refill line address is not line aligned");
                    g_rd_busy   = 1'b1;
                    g_rd_refill = 1'b1;
                    g_rd_base   = refill_line_addr;
                    g_rd_req_n  = 0;
                    g_rd_rsp_n  = 0;
                end
                if (beat_rd_req_valid && beat_rd_req_ready) begin
                    g_bread_acc = g_bread_acc + 1;
                    chk(!g_rd_busy, "beat read accepted while a read transaction is outstanding");
                    g_rd_busy   = 1'b1;
                    g_rd_refill = 1'b0;
                    g_rd_base   = beat_rd_req_addr;
                    g_rd_req_n  = 0;
                    g_rd_rsp_n  = 0;
                end

                //---- (6) bus write beats -------------------------------------
                if (mem_wr_valid) begin
                    chk(g_wr_busy, "bus write without an accepted client write");
                    chk(mem_wr_addr[3:0] == 4'h0, "write address not 16B aligned");
                    if (g_wr_wb) begin
                        chk(g_wr_beat_n < LINE_BEATS_L, "writeback issued too many beats");
                        chk(mem_wr_addr == (g_wr_base + (32'(g_wr_beat_n) << 4)),
                            "writeback beat address is not line_base + 16*beat");
                        chk(mem_wr_data == g_wb_line[128*g_wr_beat_n +: 128],
                            "writeback beat data slice is wrong");
                        chk(mem_wr_be == 16'hFFFF, "writeback beat must be full byte enabled");
                    end else begin
                        chk(g_wr_beat_n == 0, "single beat write issued more than one beat");
                        chk(mem_wr_addr == g_wr_base, "single beat write address is wrong");
                        chk(mem_wr_data == g_bw_data, "single beat write data is wrong");
                        chk(mem_wr_be == g_bw_be, "single beat write byte enables are wrong");
                    end
                    if (mem_wr_ready) g_wr_beat_n = g_wr_beat_n + 1;
                end

                //---- (7) write completions -----------------------------------
                if (wb_done) begin
                    g_wb_cmp = g_wb_cmp + 1;
                    chk(g_wr_wb && (g_wr_beat_n == LINE_BEATS_L), "wb_done without all beats");
                    g_wr_busy = 1'b0;
                    g_memchk_pend = 1'b1;
                    g_memchk_wb   = 1'b1;
                    g_memchk_addr = g_wr_base[15:0];
                    g_memchk_line = g_wb_line;
                end
                if (beat_wr_done) begin
                    g_bwr_cmp = g_bwr_cmp + 1;
                    chk(!g_wr_wb && (g_wr_beat_n == 1), "beat_wr_done without exactly one beat");
                    g_wr_busy = 1'b0;
                    g_memchk_pend = 1'b1;
                    g_memchk_wb   = 1'b0;
                    g_memchk_addr = g_wr_base[15:0];
                    g_memchk_data = g_bw_data;
                    g_memchk_be   = g_bw_be;
                end

                //---- (8) client write requests -------------------------------
                if (wb_req_valid && wb_req_ready) begin
                    g_wb_acc = g_wb_acc + 1;
                    chk(!g_wr_busy, "writeback accepted while the write channel is busy");
                    g_wr_busy   = 1'b1;
                    g_wr_wb     = 1'b1;
                    g_wr_base   = wb_line_addr;
                    g_wr_beat_n = 0;
                    g_wb_line   = wb_line_data;
                end
                if (beat_wr_req_valid && beat_wr_req_ready) begin
                    g_bwr_acc = g_bwr_acc + 1;
                    chk(!g_wr_busy, "beat write accepted while the write channel is busy");
                    g_wr_busy   = 1'b1;
                    g_wr_wb     = 1'b0;
                    g_wr_base   = beat_wr_req_addr;
                    g_wr_beat_n = 0;
                    g_bw_data   = beat_wr_req_data;
                    g_bw_be     = beat_wr_req_be;
                end
            end
        end
    endtask

    always @(negedge clk) begin
        #2;
        engine_cycle();
    end

    //=========================================================================
    // Stimulus helpers - one clock cycle granularity
    //   drv(): runs just after a rising edge, applies new stimulus
    //   smp(): runs mid-cycle, reads the values the next rising edge samples
    //=========================================================================
    task automatic drv(); @(posedge clk); #1; endtask
    task automatic smp(); @(negedge clk); #2; endtask

    task automatic idle_inputs();
        refill_req_valid   = 1'b0;
        beat_rd_req_valid  = 1'b0;
        wb_req_valid       = 1'b0;
        beat_wr_req_valid  = 1'b0;
        refill_rsp_ready   = 1'b0;
        beat_rd_rsp_ready  = 1'b0;
        mem_rd_ready       = 1'b0;
        mem_wr_ready       = 1'b0;
    endtask

    task automatic do_reset();
        idle_inputs();
        rst = 1'b1;
        repeat (3) drv();
        rst = 1'b0;
        drv();
        chk(!refill_rsp_valid,  "reset: refill_rsp_valid must be 0");
        chk(!beat_rd_rsp_valid, "reset: beat_rd_rsp_valid must be 0");
        chk(!mem_rd_valid,      "reset: mem_rd_valid must be 0");
        chk(!mem_wr_valid,      "reset: mem_wr_valid must be 0");
        chk(!wb_done,           "reset: wb_done must be 0");
        chk(!beat_wr_done,      "reset: beat_wr_done must be 0");
        chk(refill_req_ready && beat_rd_req_ready, "reset: read request ports must be ready");
        chk(wb_req_ready && beat_wr_req_ready,     "reset: write request ports must be ready");
    endtask

    //---- one full line refill ------------------------------------------------
    task automatic refill_op(input logic [31:0] addr, input int unsigned hold);
        logic [LDATA_W-1:0]      d0;
        logic [LINE_BEATS_L-1:0] bv0;
        begin
            refill_line_addr = addr;
            refill_req_valid = 1'b1;
            while (!refill_req_ready) begin smp(); drv(); end
            smp();
            chk(refill_req_valid && refill_req_ready, "refill request did not handshake");
            drv();
            refill_req_valid = 1'b0;
            refill_line_addr = 32'hDEAD_0000;          // must be latched inside
            refill_rsp_ready = 1'b0;
            while (!refill_rsp_valid) begin smp(); drv(); end
            d0  = refill_line_data;
            bv0 = refill_beat_valid;
            for (int unsigned i = 0; i < hold; i++) begin
                drv();
                chk(refill_rsp_valid && (refill_line_data == d0) && (refill_beat_valid == bv0),
                    "refill response changed while refill_rsp_ready was low");
            end
            refill_rsp_ready = 1'b1;
            smp();
            chk(refill_rsp_valid, "refill response lost when ready went high");
            drv();
            refill_rsp_ready = 1'b0;
            chk(!refill_rsp_valid, "refill_rsp_valid not cleared after handshake");
        end
    endtask

    //---- one single beat read ------------------------------------------------
    task automatic beat_rd_op(input logic [31:0] addr, input int unsigned hold);
        logic [127:0] d0;
        begin
            beat_rd_req_addr  = addr;
            beat_rd_req_valid = 1'b1;
            while (!beat_rd_req_ready) begin smp(); drv(); end
            smp();
            chk(beat_rd_req_ready, "beat read request did not handshake");
            drv();
            beat_rd_req_valid = 1'b0;
            beat_rd_req_addr  = 32'hDEAD_0000;
            beat_rd_rsp_ready = 1'b0;
            while (!beat_rd_rsp_valid) begin smp(); drv(); end
            d0 = beat_rd_rsp_data;
            for (int unsigned i = 0; i < hold; i++) begin
                drv();
                chk(beat_rd_rsp_valid && (beat_rd_rsp_data == d0),
                    "beat read response changed while beat_rd_rsp_ready was low");
            end
            beat_rd_rsp_ready = 1'b1;
            smp();
            chk(beat_rd_rsp_valid, "beat read response lost when ready went high");
            drv();
            beat_rd_rsp_ready = 1'b0;
            chk(!beat_rd_rsp_valid, "beat_rd_rsp_valid not cleared after handshake");
        end
    endtask

    //---- one whole line writeback -------------------------------------------
    task automatic wb_op(input logic [31:0] addr, input logic [LDATA_W-1:0] data,
                         input int unsigned hold);
        logic [31:0]  a0;
        logic [127:0] d0;
        logic [15:0]  e0;
        logic         seen;
        begin
            wb_line_addr  = addr;
            wb_line_data  = data;
            wb_req_valid  = 1'b1;
            while (!wb_req_ready) begin smp(); drv(); end
            smp();
            chk(wb_req_ready, "writeback request did not handshake");
            drv();
            wb_req_valid = 1'b0;
            wb_line_addr = 32'hDEAD_0000;
            wb_line_data = '1;                           // must be latched
            mem_wr_ready = 1'b0;
            a0 = 32'd0; d0 = '0; e0 = 16'd0; seen = 1'b0;
            for (int unsigned i = 0; i < hold; i++) begin
                drv();
                if (mem_wr_valid) begin
                    if (!seen) begin a0 = mem_wr_addr; d0 = mem_wr_data; e0 = mem_wr_be; seen = 1'b1; end
                    chk(mem_wr_addr == a0, "writeback address moved while mem_wr_ready was low");
                    chk(mem_wr_data == d0, "writeback data moved while mem_wr_ready was low");
                    chk(mem_wr_be == e0,   "writeback byte enables moved while mem_wr_ready was low");
                end
            end
            if (hold != 0) chk(seen, "writeback did not present a beat while stalled");
            mem_wr_ready = 1'b1;
            smp();                       // let the combinational path settle
            while (!wb_done) begin drv(); smp(); end
            drv();                       // cross the last beat's handshake edge
            chk(!wb_done, "wb_done must be a single cycle pulse");
            mem_wr_ready = 1'b0;
        end
    endtask

    //---- one single beat write ----------------------------------------------
    task automatic beat_wr_op(input logic [31:0] addr, input logic [127:0] data,
                              input logic [15:0] be, input int unsigned hold);
        logic [31:0]  a0;
        logic [127:0] d0;
        logic [15:0]  e0;
        logic         seen;
        begin
            beat_wr_req_addr  = addr;
            beat_wr_req_data  = data;
            beat_wr_req_be    = be;
            beat_wr_req_valid = 1'b1;
            while (!beat_wr_req_ready) begin smp(); drv(); end
            smp();
            chk(beat_wr_req_ready, "beat write request did not handshake");
            drv();
            beat_wr_req_valid = 1'b0;
            beat_wr_req_addr  = 32'hDEAD_0000;
            beat_wr_req_data  = '1;
            beat_wr_req_be    = 16'hFFFF;
            mem_wr_ready      = 1'b0;
            a0 = 32'd0; d0 = '0; e0 = 16'd0; seen = 1'b0;
            for (int unsigned i = 0; i < hold; i++) begin
                drv();
                if (mem_wr_valid) begin
                    if (!seen) begin a0 = mem_wr_addr; d0 = mem_wr_data; e0 = mem_wr_be; seen = 1'b1; end
                    chk(mem_wr_addr == a0, "beat write address moved while mem_wr_ready was low");
                    chk(mem_wr_data == d0, "beat write data moved while mem_wr_ready was low");
                    chk(mem_wr_be == e0,   "beat write byte enables moved while mem_wr_ready was low");
                end
            end
            if (hold != 0) chk(seen, "beat write did not present a beat while stalled");
            mem_wr_ready = 1'b1;
            smp();                       // let the combinational path settle
            while (!beat_wr_done) begin drv(); smp(); end
            drv();                       // cross the beat's handshake edge
            chk(!beat_wr_done, "beat_wr_done must be a single cycle pulse");
            mem_wr_ready = 1'b0;
        end
    endtask

    //---- directed data pattern helpers --------------------------------------
    task automatic line_data_from_pattern(input logic [31:0] line_addr,
                                          output logic [LDATA_W-1:0] data);
        for (int unsigned b = 0; b < LINE_BYTES_L; b++)
            data[8*b +: 8] = mem_pattern(line_addr + 32'(b));
    endtask

    task automatic check_mem_line(input logic [15:0] line_addr, input logic [LDATA_W-1:0] data);
        for (int unsigned b = 0; b < LINE_BYTES_L; b++)
            chk(mem[line_addr + 16'(b)] == data[8*b +: 8],
                "writeback memory content mismatch");
    endtask

    task automatic check_mem_beat(input logic [15:0] addr, input logic [127:0] data,
                                  input logic [15:0] be);
        for (int unsigned b = 0; b < 16; b++)
            if (be[b]) chk(mem[addr + 16'(b)] == data[8*b +: 8],
                           "single beat write memory content mismatch");
    endtask

    //=========================================================================
    // Randomised phase state
    //=========================================================================
    int unsigned rand_cycles;
    logic [31:0] rd_a, wr_a;
    logic        rd_is_refill, wr_is_wb;
    logic        rd_wait, wr_wait, rd_wait_next, wr_wait_next;
    logic        rd_new, rd_drop, wr_new, wr_drop;
    logic [127:0] wr_d;
    logic [15:0]  wr_be;
    logic [LDATA_W-1:0] wr_line;
    logic [LDATA_W-1:0] line_pat, line_pat2;

    //=========================================================================
    // Test program
    //=========================================================================
    initial begin
        idle_inputs();
        rd_lat_mode  = 0;
        rand_cycles  = 0;
        checks       = 0;
        errors       = 0;
        mdl_prot_err = 0;

        $display("== tb_line_adapter: LINE_BYTES=%0d LINE_BEATS=%0d ==",
                 LINE_BYTES_L, LINE_BEATS_L);

        //---- 0. geometry + reset --------------------------------------------
        chk(LINE_BYTES_L == 16 || LINE_BYTES_L == 32 || LINE_BYTES_L == 64,
            "LINE_BYTES must be 16/32/64");
        chk(LINE_BEATS_L == LINE_BYTES_L/16, "LINE_BEATS must be LINE_BYTES/16");
        do_reset();
        mem_rd_ready = 1'b1;      // directed phase: slave always accepts reads
        $display("[%0t] marker: reset ok", $time);

        //---- 1. refill: beat count, addresses, assembly, byte order ---------
        line_data_from_pattern(32'h0000_0100, line_pat);
        refill_op(32'h0000_0100, 0);
        line_data_from_pattern(32'h0000_0200, line_pat2);
        refill_op(32'h0000_0200, 4);                 // response held 4 cycles
        refill_op(32'h0000_0F00 - LINE_BYTES_L, 2);  // line across a 4 KiB seam

        $display("[%0t] marker: refills ok", $time);
        //---- 2. single beat reads -------------------------------------------
        rd_lat_mode = 0;
        beat_rd_op(32'h0000_0110, 0);
        beat_rd_op(32'h0000_01F0, 3);                // held response
        rd_lat_mode = 1;                             // random slave latency
        for (int unsigned i = 0; i < 6; i++)
            beat_rd_op(32'(i)*32'd16, 1);
        rd_lat_mode = 0;

        $display("[%0t] marker: single beat reads ok", $time);
        //---- 3. writeback ----------------------------------------------------
        line_data_from_pattern(32'h0000_4100, line_pat);
        wb_op(32'h0000_4100, line_pat, 0);
        check_mem_line(16'h4100, line_pat);
        line_data_from_pattern(32'h0000_4200, line_pat2);
        wb_op(32'h0000_4200, line_pat2, 5);          // beats stalled 5 cycles
        check_mem_line(16'h4200, line_pat2);

        $display("[%0t] marker: writebacks ok", $time);
        //---- 4. single beat writes with full and partial byte enables -------
        beat_wr_op(32'h0000_5100, 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210, 16'hFFFF, 0);
        check_mem_beat(16'h5100, 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210, 16'hFFFF);
        beat_wr_op(32'h0000_5110, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFA5, 16'h0001, 2);
        beat_wr_op(32'h0000_5120, 128'h5A00_0000_0000_0000_0000_0000_0000_0000, 16'h8000, 3);
        beat_wr_op(32'h0000_5130, 128'h1111_2222_3333_4444_5555_6666_7777_8888, 16'h0005, 2);
        beat_wr_op(32'h0000_5140, 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1234, 16'h00F0, 4);
        beat_wr_op(32'h0000_5150, 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0, 16'hF0F0, 0);
        beat_wr_op(32'h0000_5160, 128'h0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F, 16'hFFFF, 0);
        beat_wr_op(32'h0000_5170, 128'hF0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0, 16'hFFFF, 0);
        check_mem_beat(16'h5110, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFA5, 16'h0001);
        check_mem_beat(16'h5120, 128'h5A00_0000_0000_0000_0000_0000_0000_0000, 16'h8000);
        check_mem_beat(16'h5130, 128'h1111_2222_3333_4444_5555_6666_7777_8888, 16'h0005);
        check_mem_beat(16'h5140, 128'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1234, 16'h00F0);
        check_mem_beat(16'h5150, 128'hDEAD_BEEF_CAFE_BABE_1234_5678_9ABC_DEF0, 16'hF0F0);
        check_mem_beat(16'h5160, 128'h0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F, 16'hFFFF);
        check_mem_beat(16'h5170, 128'hF0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0_F0F0, 16'hFFFF);

        $display("[%0t] marker: single beat writes ok", $time);
        //---- 5. arbitration: refill beats beat_rd, wb beats beat_wr ---------
        refill_line_addr  = 32'h0000_0300;
        beat_rd_req_addr  = 32'h0000_0310;
        refill_req_valid  = 1'b1;
        beat_rd_req_valid = 1'b1;
        smp();
        chk(refill_req_ready,   "arb: refill port must be ready");
        chk(!beat_rd_req_ready, "arb: beat_rd must lose against refill");
        drv();                                   // refill accepted, beat_rd kept
        refill_req_valid = 1'b0;
        chk(beat_rd_req_valid && !beat_rd_req_ready,
            "arb: losing beat_rd request must not be accepted");
        for (int unsigned i = 0; i < 2; i++) begin
            smp();
            chk(!beat_rd_req_ready, "single outstanding: beat_rd ready during a refill");
            drv();
        end
        while (!refill_rsp_valid) begin smp(); drv(); end
        smp();
        chk(!beat_rd_req_ready, "single outstanding: beat_rd ready while refill rsp pending");
        chk(beat_rd_req_valid,  "arb: held beat_rd request disappeared");
        drv();                                   // ready is driven from a clean edge
        refill_rsp_ready = 1'b1;
        smp();                                   // the refill completion cycle
        chk(refill_rsp_valid, "arb: refill response lost");
        chk(beat_rd_req_valid && beat_rd_req_ready,
            "arb: held beat_rd must be taken with the refill completion");
        drv();                                   // refill consumed, beat_rd accepted
        refill_rsp_ready  = 1'b0;
        beat_rd_req_valid = 1'b0;
        beat_rd_rsp_ready = 1'b1;
        smp();
        while (!beat_rd_rsp_valid) begin drv(); smp(); end
        drv();
        beat_rd_rsp_ready = 1'b0;
        smp();
        chk(!beat_rd_rsp_valid, "arb: beat read response not cleared after handshake");
        drv();

        line_data_from_pattern(32'h0000_4300, line_pat);
        wb_line_addr      = 32'h0000_4300;
        wb_line_data      = line_pat;
        beat_wr_req_addr  = 32'h0000_5200;
        beat_wr_req_data  = 128'hCAFE_F00D_0BAD_F00D_1234_5678_9ABC_DEF0;
        beat_wr_req_be    = 16'hFFFF;
        wb_req_valid      = 1'b1;
        beat_wr_req_valid = 1'b1;
        smp();
        chk(wb_req_ready,       "arb: wb port must be ready");
        chk(!beat_wr_req_ready, "arb: beat_wr must lose against wb");
        drv();                                   // wb accepted, beat_wr kept
        wb_req_valid = 1'b0;
        chk(beat_wr_req_valid && !beat_wr_req_ready,
            "arb: losing beat_wr request must not be accepted");
        mem_wr_ready = 1'b1;
        smp();
        while (!wb_done) begin drv(); smp(); end
        drv();
        mem_wr_ready = 1'b0;
        check_mem_line(16'h4300, line_pat);
        while (!beat_wr_req_ready) begin smp(); drv(); end
        smp();
        chk(beat_wr_req_valid && beat_wr_req_ready,
            "arb: held beat_wr must be accepted after the wb released the channel");
        drv();
        beat_wr_req_valid = 1'b0;
        mem_wr_ready = 1'b1;
        smp();
        while (!beat_wr_done) begin drv(); smp(); end
        drv();
        mem_wr_ready = 1'b0;
        check_mem_beat(16'h5200, 128'hCAFE_F00D_0BAD_F00D_1234_5678_9ABC_DEF0, 16'hFFFF);

        $display("[%0t] marker: arbitration ok", $time);
        //---- 6. randomised phase --------------------------------------------
        rand_cycles = 0;
        rd_wait = 1'b0;
        wr_wait = 1'b0;
        $display("-- randomised phase: %0d cycles --", RAND_CYCLES);
        // One cooperative scheduler instead of concurrent processes: every
        // iteration is exactly one clock, and the three stimulus sources
        // (ready randomisation, read client, write client) are evaluated in
        // order.  All signal changes are applied right after a rising edge.
        while (rand_cycles < RAND_CYCLES) begin
            smp();                                   // sample the running cycle
            //---- read client --------------------------------------------
            rd_new  = 1'b0;
            rd_drop = 1'b0;
            if (!rd_wait) begin
                rd_a         = 32'($urandom_range(0, RD_LINES - 1)) * 32'(LINE_BYTES_L);
                rd_is_refill = ($urandom_range(0, 3) == 0);
                rd_new       = 1'b1;
                rd_wait_next = 1'b1;
            end else if ((refill_req_valid && refill_req_ready)
                      || (beat_rd_req_valid && beat_rd_req_ready)) begin
                rd_drop      = 1'b1;                 // accepted on the next edge
                rd_wait_next = 1'b0;
            end else begin
                rd_wait_next = 1'b1;                 // keep the request stable
            end
            //---- write client -------------------------------------------
            wr_new  = 1'b0;
            wr_drop = 1'b0;
            if (!wr_wait) begin
                wr_a = (32'(RD_LINES) + 32'($urandom_range(0, N_LINES - RD_LINES - 1)))
                       * 32'(LINE_BYTES_L);
                wr_is_wb = ($urandom_range(0, 1) == 0);
                if (wr_is_wb) begin
                    for (int unsigned k = 0; k < LINE_BYTES_L; k++)
                        wr_line[8*k +: 8] = mem_pattern(wr_a + 32'(k));
                end else begin
                    for (int unsigned k = 0; k < 16; k++)
                        wr_d[8*k +: 8] = mem_pattern(wr_a + (32'(k) ^ 32'h5A5A));
                    wr_be = 16'($urandom);
                    if (wr_be == 16'd0) wr_be = 16'hFFFF;
                end
                wr_new       = 1'b1;
                wr_wait_next = 1'b1;
            end else if ((wb_req_valid && wb_req_ready)
                      || (beat_wr_req_valid && beat_wr_req_ready)) begin
                wr_drop      = 1'b1;
                wr_wait_next = 1'b0;
            end else begin
                wr_wait_next = 1'b1;
            end

            drv();                                   // cross the clock edge

            //---- apply the stimulus for the next cycle -------------------
            refill_rsp_ready  = ($urandom_range(0, 3) != 0);
            beat_rd_rsp_ready = ($urandom_range(0, 3) != 0);
            mem_rd_ready      = ($urandom_range(0, 3) != 0);
            mem_wr_ready      = ($urandom_range(0, 3) != 0);
            rd_lat_mode       = $urandom_range(0, 1);
            if (rd_new) begin
                if (rd_is_refill) begin
                    refill_line_addr  = rd_a;
                    refill_req_valid  = 1'b1;
                    beat_rd_req_valid = 1'b0;
                end else begin
                    beat_rd_req_addr  = rd_a;
                    beat_rd_req_valid = 1'b1;
                    refill_req_valid  = 1'b0;
                end
            end else if (rd_drop) begin
                refill_req_valid  = 1'b0;
                beat_rd_req_valid = 1'b0;
            end
            if (wr_new) begin
                if (wr_is_wb) begin
                    wb_line_addr      = wr_a;
                    wb_line_data      = wr_line;
                    wb_req_valid      = 1'b1;
                    beat_wr_req_valid = 1'b0;
                end else begin
                    beat_wr_req_addr  = wr_a;
                    beat_wr_req_data  = wr_d;
                    beat_wr_req_be    = wr_be;
                    beat_wr_req_valid = 1'b1;
                    wb_req_valid      = 1'b0;
                end
            end else if (wr_drop) begin
                wb_req_valid      = 1'b0;
                beat_wr_req_valid = 1'b0;
            end
            rd_wait     = rd_wait_next;
            wr_wait     = wr_wait_next;
            rand_cycles = rand_cycles + 1;
        end

        //---- 7. drain and final invariants -----------------------------------
        refill_req_valid  = 1'b0;
        beat_rd_req_valid = 1'b0;
        wb_req_valid      = 1'b0;
        beat_wr_req_valid = 1'b0;
        refill_rsp_ready  = 1'b1;
        beat_rd_rsp_ready = 1'b1;
        mem_rd_ready      = 1'b1;
        mem_wr_ready      = 1'b1;
        repeat (200) drv();
        repeat (50) begin smp(); drv(); end

        chk(!refill_rsp_valid,  "drain: refill_rsp_valid still set");
        chk(!beat_rd_rsp_valid, "drain: beat_rd_rsp_valid still set");
        chk(!mem_rd_valid,      "drain: mem_rd_valid still set");
        chk(!mem_wr_valid,      "drain: mem_wr_valid still set");
        chk(g_refill_acc == g_refill_cmp, "every refill must complete exactly once");
        chk(g_bread_acc  == g_bread_cmp,  "every beat read must complete exactly once");
        chk(g_wb_acc     == g_wb_cmp,     "every writeback must complete exactly once");
        chk(g_bwr_acc    == g_bwr_cmp,    "every beat write must complete exactly once");
        chk(mdl_prot_err == 0, "memory slave saw a protocol violation");
        chk(g_refill_acc > 50,  "coverage: at least 50 refills");
        chk(g_bread_acc  > 100, "coverage: at least 100 single beat reads");
        chk(g_wb_acc     > 50,  "coverage: at least 50 writebacks");
        chk(g_bwr_acc    > 50,  "coverage: at least 50 single beat writes");
        chk(rand_cycles >= 10000, "coverage: at least 10k randomised cycles");

        $display("-- refills=%0d/%0d beat_rd=%0d/%0d wb=%0d/%0d beat_wr=%0d/%0d checks=%0d --",
                 g_refill_acc, g_refill_cmp, g_bread_acc, g_bread_cmp,
                 g_wb_acc, g_wb_cmp, g_bwr_acc, g_bwr_cmp, checks);
        if (errors != 0)
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        $display("ALL TESTS PASSED: %0d checks - LINE_BYTES=%0d LINE_BEATS=%0d: reset clean, refill beat addr/order/assembly/byte order, single beat rd, WB be=FFFF + one wb_done pulse, single beat wr with partial be, rsp/wr backpressure stability, refill>beat_rd and wb>beat_wr arbitration, single outstanding read, %0d randomised cycles with all four ports active",
                 checks, LINE_BYTES_L, LINE_BEATS_L, rand_cycles);
        $finish;
    end

endmodule
