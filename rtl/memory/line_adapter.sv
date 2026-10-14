//=============================================================================
// ARES LSU - cache line <-> 16B beat adapter (L10)
//-----------------------------------------------------------------------------
// Splits one Refill / Writeback into ares_pkg::LINE_BEATS 16-byte beats on the custom
// 128-bit memory bus (memory.md 6.7) and reassembles a refill line from the
// individual beat responses.  It also exposes the single-beat read/write
// ports used by the M2a direct path (lsu_top without DCache; LSU_INTERFACES.md
// section 0 "staging").
//
// Protocol / properties (memory.md 6.7, LSU_INTERFACES.md section 6):
//   * Exactly one outstanding read on the shared bus: a read transaction spans
//     the request handshake of one beat until its response handshake.  Refill
//     and single-beat reads share that one owner slot; the next bus request is
//     only presented after the previous response was consumed.
//   * Beat b of a line lives at line_addr + 16*b and is bit slice
//     [128*b +: 128] of the line.  Refill beats are written into
//     refill_line_data and flagged in refill_beat_valid[b]; once all
//     ares_pkg::LINE_BEATS beats arrived refill_rsp_valid is raised and held until
//     refill_rsp_ready (assembled data is never overwritten while unconsumed).
//   * Writeback beats use be = 16'hFFFF; single-beat writes carry their own
//     byte enables.  wb_done / beat_wr_done are single-cycle pulses, raised on
//     the handshake of the last / only beat.
//   * Arbitration: refill > beat_rd and wb > beat_wr.  A losing request is not
//     accepted (its ready stays low) and must keep its fields stable; every
//     accepted request field is latched, so a client may change its inputs
//     immediately after the handshake.
//   * Backpressure: mem_rd_addr is stable while mem_rd_valid && !mem_rd_ready,
//     the write fields and the response payloads are stable while stalled.
//   * Same-cycle write/read ordering (write first) is a guarantee of the
//     downstream fabric (memory.md 6.7) and is not implemented here.
//
// Latency (no backpressure): a single beat read is accepted in cycle 0, its
// bus request is presented in cycle 1, the response is captured in cycle 2 and
// handed to the client in cycle 3.  A refill needs 2*ares_pkg::LINE_BEATS cycles for the
// bus beats plus the accept cycle and the client response cycle.
//
// Spec sources: docs/microarch/memory.md 6.7 (bus + read ownership), 6.4
//   (refill beats), 6.6 (dirty victim writeback); rtl/memory/LSU_INTERFACES.md
//   section 6 (frozen interface).
// FREE items: FREE-02 (file organisation), FREE-04 (parallel beat datapath -
//   the beat slice is selected by an indexed part-select, no shifter chains).
// Self-check bench: rtl/memory/test/unit/tb_line_adapter.sv
//
// Build / run (repository root; explicit file list; the bench is compiled once
// per line size - ares_pkg::LINE_BYTES = 16 / 32 / 64, ares_pkg::LINE_BEATS comes from ares_pkg):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//     -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module line_adapter \
//     rtl/common/ares_pkg.sv rtl/memory/line_adapter.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     --top-module tb_line_adapter --Mdir sim/build/unit/tb_line_adapter \
//     -o tb_line_adapter \
//     rtl/common/ares_pkg.sv rtl/memory/line_adapter.sv \
//     rtl/memory/test/unit/tb_line_adapter.sv
//   sim/build/unit/tb_line_adapter/tb_line_adapter
//   (-o is resolved against --Mdir by Verilator 5.x, so the binary lands in the
//    Mdir as sim/build/unit/<TB>/<TB>; passing the full path there fails.)
//=============================================================================
module line_adapter (
    input  logic                              clk,
    input  logic                              rst,

    //---- read channel: full line refill (MSHR) ----------------------------
    input  logic                              refill_req_valid,
    output logic                              refill_req_ready,
    input  logic [31:0]                       refill_line_addr,   // line aligned
    output logic                              refill_rsp_valid,
    input  logic                              refill_rsp_ready,
    output logic [8*ares_pkg::LINE_BYTES-1:0] refill_line_data,
    output logic [ares_pkg::LINE_BEATS-1:0]   refill_beat_valid,

    //---- read channel: single beat (M2a direct path) ----------------------
    input  logic                              beat_rd_req_valid,
    output logic                              beat_rd_req_ready,
    input  logic [31:0]                       beat_rd_req_addr,   // 16B aligned
    output logic                              beat_rd_rsp_valid,
    input  logic                              beat_rd_rsp_ready,
    output logic [127:0]                      beat_rd_rsp_data,

    //---- write channel: full line writeback (WB buffer) -------------------
    input  logic                              wb_req_valid,
    output logic                              wb_req_ready,
    input  logic [31:0]                       wb_line_addr,
    input  logic [8*ares_pkg::LINE_BYTES-1:0] wb_line_data,
    output logic                              wb_done,            // 1 cycle pulse

    //---- write channel: single beat (M2a direct path) ---------------------
    input  logic                              beat_wr_req_valid,
    output logic                              beat_wr_req_ready,
    input  logic [31:0]                       beat_wr_req_addr,   // 16B aligned
    input  logic [127:0]                      beat_wr_req_data,
    input  logic [15:0]                       beat_wr_req_be,
    output logic                              beat_wr_done,

    //---- 128-bit memory bus (memory.md 6.7) -------------------------------
    output logic                              mem_rd_valid,
    input  logic                              mem_rd_ready,
    output logic [31:0]                       mem_rd_addr,
    input  logic                              mem_rsp_valid,
    output logic                              mem_rsp_ready,
    input  logic [127:0]                      mem_rsp_data,
    output logic                              mem_wr_valid,
    input  logic                              mem_wr_ready,
    output logic [31:0]                       mem_wr_addr,
    output logic [127:0]                      mem_wr_data,
    output logic [15:0]                       mem_wr_be
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Derived geometry.  LINE_BYTES is the line size from the configuration
    // menu (16/32/64, default 32); LINE_BEATS = LINE_BYTES/16 is 1/2/4.
    //-------------------------------------------------------------------------
    localparam int unsigned NBEAT   = ares_pkg::LINE_BEATS;       // 1/2/4
    localparam int unsigned LDATA_W = 8 * ares_pkg::LINE_BYTES;   // line bits
    localparam int unsigned BIDX_W  = (NBEAT > 1) ? $clog2(NBEAT) : 1;
    localparam int unsigned SOFF_W  = $clog2(LDATA_W);            // line slice index
    // Beat selectors are pre-sized: no width mismatch, and the LINE_BEATS==1
    // configurations simply use the only legal value (0).
    localparam logic [BIDX_W-1:0] LAST_BEAT = BIDX_W'(NBEAT - 1);
    localparam logic [SOFF_W-1:0] BEAT_STEP = SOFF_W'(128);

    //=========================================================================
    // Read channel - one outstanding read, refill and single beat share it
    //=========================================================================
    // RD_IDLE : no bus beat to send (may still hold a client response)
    // RD_REQ  : mem_rd_valid is asserted, waiting for mem_rd_ready
    // RD_RSP  : request accepted, waiting for the beat response
    typedef enum logic [1:0] { RD_IDLE, RD_REQ, RD_RSP } rd_state_e;
    rd_state_e rd_state;

    logic              rd_busy_q;       // client transaction owned
    logic              rd_is_refill_q;  // owner kind of the current read
    logic [31:0]       rd_base_q;       // line address or beat address
    logic [BIDX_W-1:0] rd_beat_q;       // beat index requested / received
    logic [SOFF_W-1:0] rd_slice_q;      // 128 * rd_beat_q

    logic [LDATA_W-1:0] refill_data_q;  // assembled line
    logic [NBEAT-1:0]   refill_bv_q;    // per beat arrival flags
    logic               refill_rsp_q;   // assembled line ready to hand over

    logic         beat_rsp_q;           // single beat payload valid
    logic [127:0] beat_data_q;

    // A client response is consumed in the cycle its ready is high.
    wire refill_done_fire = refill_rsp_q && refill_rsp_ready;
    wire beat_done_fire   = beat_rsp_q   && beat_rd_rsp_ready;

    // Refill has priority over the single beat port.  A request is accepted
    // when the channel is idle or in the very cycle the previous transaction's
    // last response is consumed (its packet buffer is freed at that edge).
    assign refill_req_ready  = (!rd_busy_q) || refill_done_fire || beat_done_fire;
    assign beat_rd_req_ready = ((!rd_busy_q) || beat_done_fire || refill_done_fire)
                               && !(refill_req_valid && refill_req_ready);

    wire refill_accept  = refill_req_valid  && refill_req_ready;
    wire beat_rd_accept = beat_rd_req_valid && beat_rd_req_ready;

    // Bus read request / response handshake.
    assign mem_rd_valid  = (rd_state == RD_REQ);
    assign mem_rd_addr   = rd_base_q + (32'(rd_beat_q) << 4);
    assign mem_rsp_ready = (rd_state == RD_RSP);

    // Response payloads are registered and held until the client accepts them.
    assign refill_rsp_valid  = refill_rsp_q;
    assign refill_line_data  = refill_data_q;
    assign refill_beat_valid = refill_bv_q;
    assign beat_rd_rsp_valid = beat_rsp_q;
    assign beat_rd_rsp_data  = beat_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_state       <= RD_IDLE;
            rd_busy_q      <= 1'b0;
            rd_is_refill_q <= 1'b0;
            rd_base_q      <= 32'd0;
            rd_beat_q      <= '0;
            rd_slice_q     <= '0;
            refill_data_q  <= '0;
            refill_bv_q    <= '0;
            refill_rsp_q   <= 1'b0;
            beat_rsp_q     <= 1'b0;
            beat_data_q    <= '0;
        end else begin
            //---- client response consumption ------------------------------
            if (refill_done_fire) refill_rsp_q <= 1'b0;
            if (beat_done_fire)   beat_rsp_q   <= 1'b0;

            //---- new client read request (all fields latched here) -------
            if (refill_accept) begin
                rd_is_refill_q <= 1'b1;
                rd_base_q      <= refill_line_addr;
                rd_beat_q      <= '0;
                rd_slice_q     <= '0;
                rd_state       <= RD_REQ;
                refill_data_q  <= '0;
                refill_bv_q    <= '0;
            end else if (beat_rd_accept) begin
                rd_is_refill_q <= 1'b0;
                rd_base_q      <= beat_rd_req_addr;
                rd_beat_q      <= '0;
                rd_slice_q     <= '0;
                rd_state       <= RD_REQ;
            end

            //---- bus request handshake -----------------------------------
            if ((rd_state == RD_REQ) && mem_rd_ready) rd_state <= RD_RSP;

            //---- bus response handshake ----------------------------------
            if ((rd_state == RD_RSP) && mem_rsp_valid) begin
                if (rd_is_refill_q) begin
                    refill_data_q[rd_slice_q +: 128] <= mem_rsp_data;
                    refill_bv_q[rd_beat_q]           <= 1'b1;
                    if (rd_beat_q == LAST_BEAT) begin
                        refill_rsp_q <= 1'b1;   // whole line assembled
                        rd_state     <= RD_IDLE;
                    end else begin
                        rd_beat_q  <= rd_beat_q + 1'b1;
                        rd_slice_q <= rd_slice_q + BEAT_STEP;
                        rd_state   <= RD_REQ;
                    end
                end else begin
                    beat_data_q <= mem_rsp_data;
                    beat_rsp_q  <= 1'b1;
                    rd_state    <= RD_IDLE;
                end
            end

            //---- ownership: a request accepted in the completion cycle
            //     keeps the channel busy for the new transaction -----------
            if (refill_accept || beat_rd_accept)         rd_busy_q <= 1'b1;
            else if (refill_done_fire || beat_done_fire) rd_busy_q <= 1'b0;
        end
    end

    //=========================================================================
    // Write channel - whole line WB or a single beat, WB has priority
    //=========================================================================
    typedef enum logic [1:0] { WR_IDLE, WR_BEAT, WR_WB } wr_state_e;
    wr_state_e wr_state;

    // single beat write (latched on acceptance)
    logic [31:0]  bw_addr_q;
    logic [127:0] bw_data_q;
    logic [15:0]  bw_be_q;

    // whole line writeback (latched on acceptance)
    logic [31:0]        wb_addr_q;
    logic [LDATA_W-1:0] wb_data_q;
    logic [BIDX_W-1:0]  wb_beat_q;
    logic [SOFF_W-1:0]  wb_slice_q;

    wire wb_last_beat = (wr_state == WR_WB) && (wb_beat_q == LAST_BEAT);

    // WB owns the channel whenever it can start a transaction.  A WB request
    // may also be accepted in the cycle the previous WB's last beat fires, so
    // back-to-back writebacks have no bubble.
    assign wb_req_ready = (wr_state == WR_IDLE)
                          || (wb_last_beat && mem_wr_valid && mem_wr_ready);
    // Single beat writes: accepted while idle (but never when a WB request is
    // present - WB wins the same cycle) and again in the cycle the current
    // beat write fires, which keeps back-to-back single beats at II = 1.
    assign beat_wr_req_ready = ((wr_state == WR_IDLE) && !wb_req_valid)
                               || ((wr_state == WR_BEAT) && mem_wr_valid && mem_wr_ready);

    wire wb_accept      = wb_req_valid      && wb_req_ready;
    wire beat_wr_accept = beat_wr_req_valid && beat_wr_req_ready;

    assign mem_wr_valid = (wr_state == WR_BEAT) || (wr_state == WR_WB);
    assign mem_wr_addr  = (wr_state == WR_WB) ? (wb_addr_q + (32'(wb_beat_q) << 4))
                                              : bw_addr_q;
    assign mem_wr_data  = (wr_state == WR_WB) ? wb_data_q[wb_slice_q +: 128]
                                              : bw_data_q;
    assign mem_wr_be    = (wr_state == WR_WB) ? 16'hFFFF : bw_be_q;

    wire mem_wr_fire = mem_wr_valid && mem_wr_ready;

    assign wb_done      = wb_last_beat && mem_wr_fire;
    assign beat_wr_done = (wr_state == WR_BEAT) && mem_wr_fire;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_state   <= WR_IDLE;
            bw_addr_q  <= 32'd0;
            bw_data_q  <= '0;
            bw_be_q    <= '0;
            wb_addr_q  <= 32'd0;
            wb_data_q  <= '0;
            wb_beat_q  <= '0;
            wb_slice_q <= '0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    if (wb_accept) begin
                        wb_addr_q  <= wb_line_addr;
                        wb_data_q  <= wb_line_data;
                        wb_beat_q  <= '0;
                        wb_slice_q <= '0;
                        wr_state   <= WR_WB;
                    end else if (beat_wr_accept) begin
                        bw_addr_q <= beat_wr_req_addr;
                        bw_data_q <= beat_wr_req_data;
                        bw_be_q   <= beat_wr_req_be;
                        wr_state  <= WR_BEAT;
                    end
                end
                WR_BEAT: begin
                    if (mem_wr_fire) begin
                        if (beat_wr_accept) begin      // next beat, no bubble
                            bw_addr_q <= beat_wr_req_addr;
                            bw_data_q <= beat_wr_req_data;
                            bw_be_q   <= beat_wr_req_be;
                            wr_state  <= WR_BEAT;
                        end else begin
                            wr_state  <= WR_IDLE;
                        end
                    end
                end
                WR_WB: begin
                    if (mem_wr_fire) begin
                        if (wb_beat_q == LAST_BEAT) begin
                            if (wb_accept) begin       // next line, no bubble
                                wb_addr_q  <= wb_line_addr;
                                wb_data_q  <= wb_line_data;
                                wb_beat_q  <= '0;
                                wb_slice_q <= '0;
                                wr_state   <= WR_WB;
                            end else begin
                                wr_state   <= WR_IDLE;
                            end
                        end else begin
                            wb_beat_q  <= wb_beat_q + 1'b1;
                            wb_slice_q <= wb_slice_q + BEAT_STEP;
                        end
                    end
                end
                default: wr_state <= WR_IDLE;
            endcase
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol assertions (memory.md 6.7 / 6.8, LSU_INTERFACES.md section 8).
    //-------------------------------------------------------------------------
    logic       rd_outstanding_q;   // a bus read beat is in flight
    logic       client_rd_busy_q;   // a client read transaction is owned
    logic [1:0] client_rd_cnt_q;    // accepted but not yet completed reads

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_outstanding_q <= 1'b0;
            client_rd_busy_q <= 1'b0;
            client_rd_cnt_q  <= 2'd0;
        end else begin
            if (mem_rd_valid && mem_rd_ready) rd_outstanding_q <= 1'b1;
            if (mem_rsp_valid && mem_rsp_ready) rd_outstanding_q <= 1'b0;
            if (refill_accept || beat_rd_accept) client_rd_busy_q <= 1'b1;
            else if (refill_done_fire || beat_done_fire) client_rd_busy_q <= 1'b0;
            client_rd_cnt_q <= client_rd_cnt_q
                             + {1'b0, (refill_accept || beat_rd_accept)}
                             - {1'b0, (refill_done_fire || beat_done_fire)};
        end
    end

    // At most one outstanding read beat on the bus.
    a_no_read_while_outstanding: assert property (@(posedge clk) disable iff (rst)
        mem_rd_valid |-> !rd_outstanding_q);
    // At most one client read transaction, and no spurious completion.
    a_client_single_read: assert property (@(posedge clk) disable iff (rst)
        client_rd_cnt_q <= 2'd1);
    a_client_completion_without_request: assert property (@(posedge clk) disable iff (rst)
        (refill_done_fire || beat_done_fire) |-> client_rd_busy_q);
    // A refill response only exists once every beat arrived.
    a_refill_rsp_requires_all_beats: assert property (@(posedge clk) disable iff (rst)
        refill_rsp_q |-> (refill_bv_q == {NBEAT{1'b1}}));
    a_beat_rsp_never_with_refill: assert property (@(posedge clk) disable iff (rst)
        beat_rsp_q |-> !rd_is_refill_q);
    // 16B alignment of both bus directions.
    a_mem_rd_aligned: assert property (@(posedge clk) disable iff (rst)
        mem_rd_valid |-> (mem_rd_addr[3:0] == 4'h0));
    a_mem_wr_aligned: assert property (@(posedge clk) disable iff (rst)
        mem_wr_valid |-> (mem_wr_addr[3:0] == 4'h0));
    // Refill requests are line aligned; WB beats are full byte enabled.
    a_refill_line_aligned: assert property (@(posedge clk) disable iff (rst)
        refill_accept |-> (refill_line_addr[$clog2(ares_pkg::LINE_BYTES)-1:0] == '0));
    a_wb_full_be: assert property (@(posedge clk) disable iff (rst)
        (wr_state == WR_WB) |-> (mem_wr_be == 16'hFFFF));
    // Stalled bus fields and payloads must not move.
    a_mem_rd_stable: assert property (@(posedge clk) disable iff (rst)
        (mem_rd_valid && !mem_rd_ready) |=> (mem_rd_valid && $stable(mem_rd_addr)));
    a_mem_wr_stable: assert property (@(posedge clk) disable iff (rst)
        (mem_wr_valid && !mem_wr_ready) |=>
        (mem_wr_valid && $stable(mem_wr_addr) && $stable(mem_wr_data) && $stable(mem_wr_be)));
    a_refill_rsp_stable: assert property (@(posedge clk) disable iff (rst)
        (refill_rsp_q && !refill_rsp_ready) |=>
        (refill_rsp_q && $stable(refill_data_q) && $stable(refill_bv_q)));
    a_beat_rsp_stable: assert property (@(posedge clk) disable iff (rst)
        (beat_rsp_q && !beat_rd_rsp_ready) |=> (beat_rsp_q && $stable(beat_data_q)));
`endif

endmodule
