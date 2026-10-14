//=============================================================================
// ARES LSU - 2-entry dirty victim Writeback Buffer (L09)
//-----------------------------------------------------------------------------
// Responsibilities (memory.md 6.6; LSU_INTERFACES.md section 11): hold a dirty
// victim line while it is captured out of the DCache and until every 16B beat
// of its writeback was accepted by the memory bus.  Each entry saves
// {state, line_addr, line_data, capture_row_valid, beat progress} and runs the
// FSM FREE -> CAPTURING -> READY -> DRAINING -> FREE:
//
//   FREE       entry available; free_mask / busy expose the cycle-start state.
//   CAPTURING  allocated by the MSHR (alloc_valid/alloc_idx/alloc_line_addr);
//              cap_wr_valid writes one 64-bit Row (cap_wr_row) into
//              line_data and sets capture_row_valid[row]; cap_wr_last closes
//              the capture and moves the entry to READY.
//   READY      complete line available; the lowest-index READY entry drives
//              wb_req_valid/wb_line_addr/wb_line_data and is handed to the
//              Line Adapter on wb_req_valid && wb_req_ready.
//   DRAINING   the Line Adapter owns the line and is emitting the
//              ares_pkg::LINE_BEATS x 16B full-byte-enable beats; wb_done (last beat
//              accepted, D-M2b-03 - never waiting for the physical write to
//              finish) returns the entry to FREE.
//
// FSM / arbitration notes (FREE-11 pipeline position):
//   * free_mask and busy are pure functions of the registered state, so they
//     report the *cycle-start* occupancy and never borrow an entry that
//     wb_done releases in the same cycle (LSU_INTERFACES.md section 11.1).
//   * Only one entry may be DRAINING at a time: wb_done carries no index, so a
//     second READY entry is held back until the draining entry returned to
//     FREE.  This also matches the Line Adapter's single writeback channel.
//   * The READY arbiter picks the lowest index with a fully parallel
//     "no lower READY index" comparison (no priority chain, FREE-04).
//   * vis_query_block is a combinational CAM over all non-FREE entries: any
//     line still owned by the WB buffer (CAPTURING and DRAINING included)
//     blocks a read hit on that line (memory.md 6.6).
//
// Spec sources: docs/microarch/memory.md 6.6 (WB buffer state, dirty victim
//   handoff, release after the last beat) and 6.7 (16B beats, be = 16'hFFFF,
//   write acceptance); docs/m2b_decisions.md D-M2b-03 (release point);
//   rtl/memory/LSU_INTERFACES.md section 11 (frozen interface) and section 8
//   (verification requirements).
// FREE items: FREE-02 (file organisation), FREE-04 (parallel arbiter / mux
//   structure), FREE-11 (pipeline position: READY arbitration is combinational,
//   all entry state is updated on the clock edge).
// Self-check bench: rtl/memory/test/unit/tb_wb_buffer.sv
//
// Build / run (repository root; explicit file list; ares_pkg::LINE_BYTES = 16 / 32 / 64,
// default 32):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//     -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module wb_buffer \
//     rtl/common/ares_pkg.sv rtl/memory/wb_buffer.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     --top-module tb_wb_buffer --Mdir sim/build/unit/tb_wb_buffer \
//     -o tb_wb_buffer rtl/common/ares_pkg.sv rtl/memory/wb_buffer.sv \
//     rtl/memory/test/unit/tb_wb_buffer.sv
//   sim/build/unit/tb_wb_buffer/tb_wb_buffer
//   (-o is resolved against --Mdir by Verilator 5.x, so the binary lands in the
//    Mdir as sim/build/unit/<TB>/<TB>; passing the full path there fails.)
//=============================================================================
module wb_buffer (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      alloc_valid,
    input  logic [1:0]                                alloc_idx,
    input  logic [31:0]                               alloc_line_addr,
    output logic [ares_pkg::WB_ENTRIES-1:0]           free_mask,
    input  logic                                      cap_wr_valid,
    input  logic [1:0]                                cap_wr_idx,
    input  logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_wr_row,
    input  logic [63:0]                               cap_wr_data,
    input  logic                                      cap_wr_last,
    output logic                                      wb_req_valid,
    input  logic                                      wb_req_ready,
    output logic [31:0]                               wb_line_addr,
    output logic [8*ares_pkg::LINE_BYTES-1:0]         wb_line_data,
    input  logic                                      wb_done,
    input  logic [31:0]                               vis_query_line_addr,
    output logic                                      vis_query_block,
    output logic [ares_pkg::WB_ENTRIES-1:0]           busy
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Parameters / FSM encoding
    //-------------------------------------------------------------------------
    localparam int unsigned ENTRIES  = WB_ENTRIES;
    localparam int unsigned ROWS     = ROWS_PER_LINE;
    localparam int unsigned LDATA_W  = 8 * LINE_BYTES;

    localparam logic [1:0] WB_FREE      = 2'd0;
    localparam logic [1:0] WB_CAPTURING = 2'd1;
    localparam logic [1:0] WB_READY     = 2'd2;
    localparam logic [1:0] WB_DRAINING  = 2'd3;

    //-------------------------------------------------------------------------
    // Entry state
    //-------------------------------------------------------------------------
    logic [ENTRIES-1:0][1:0]      state_q;
    logic [31:0]                  line_addr_q [ENTRIES];
    logic [LDATA_W-1:0]           line_data_q [ENTRIES];
    logic [ENTRIES-1:0][ROWS-1:0] capture_row_valid;

    //-------------------------------------------------------------------------
    // Cycle-start state decode (free_mask / busy never borrow this cycle's
    // wb_done release - LSU_INTERFACES.md section 11.1)
    //-------------------------------------------------------------------------
    logic [ENTRIES-1:0] free_v;
    logic [ENTRIES-1:0] ready_v;
    logic [ENTRIES-1:0] capturing_v;
    logic [ENTRIES-1:0] draining_v;

    always_comb begin
        for (int unsigned w = 0; w < ENTRIES; w++) begin
            free_v[w]      = (state_q[w] == WB_FREE);
            ready_v[w]     = (state_q[w] == WB_READY);
            capturing_v[w] = (state_q[w] == WB_CAPTURING);
            draining_v[w]  = (state_q[w] == WB_DRAINING);
        end
    end

    assign free_mask = free_v;
    assign busy      = ~free_v;

    //-------------------------------------------------------------------------
    // Request selectors (one-hot, fully parallel)
    //-------------------------------------------------------------------------
    logic [ENTRIES-1:0] alloc_sel;
    logic [ENTRIES-1:0] cap_sel;

    always_comb begin
        alloc_sel = '0;
        cap_sel   = '0;
        for (int unsigned w = 0; w < ENTRIES; w++) begin
            alloc_sel[w] = alloc_valid && (alloc_idx == 2'(w));
            cap_sel[w]   = cap_wr_valid && (cap_wr_idx == 2'(w));
        end
    end

    // Lowest-index READY arbiter: "ready and no lower index is ready".
    logic [ENTRIES-1:0] ready_sel;
    logic               any_ready;
    logic               any_draining;

    always_comb begin
        ready_sel    = '0;
        any_ready    = |ready_v;
        any_draining = |draining_v;
        for (int unsigned w = 0; w < ENTRIES; w++) begin
            logic [ENTRIES-1:0] lower_mask;
            lower_mask   = (ENTRIES'(1'b1) << w) - ENTRIES'(1'b1);
            ready_sel[w] = ready_v[w] && ((ready_v & lower_mask) == '0);
        end
    end

    // A single writeback channel: a READY entry is only presented while no
    // entry is DRAINING (wb_done carries no index).
    logic grant_fire;
    assign wb_req_valid = any_ready && !any_draining;
    assign grant_fire   = wb_req_valid && wb_req_ready;

    // Parallel AND-OR mux of the selected entry payload.
    always_comb begin
        wb_line_addr = 32'd0;
        wb_line_data = '0;
        for (int unsigned w = 0; w < ENTRIES; w++) begin
            wb_line_addr |= {32{ready_sel[w]}} & line_addr_q[w];
            wb_line_data |= {LDATA_W{ready_sel[w]}} & line_data_q[w];
        end
    end

    //-------------------------------------------------------------------------
    // Visibility query: combinational CAM over every owned (non-FREE) line.
    //-------------------------------------------------------------------------
    logic [ENTRIES-1:0] vis_hit;

    always_comb begin
        vis_hit = '0;
        for (int unsigned w = 0; w < ENTRIES; w++)
            vis_hit[w] = (!free_v[w]) && (line_addr_q[w] == vis_query_line_addr);
    end

    assign vis_query_block = |vis_hit;

    //-------------------------------------------------------------------------
    // Entry state update (one clock edge, per-entry FSM)
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q           <= {ENTRIES{WB_FREE}};
            capture_row_valid <= '0;
            for (int unsigned w = 0; w < ENTRIES; w++) begin
                line_addr_q[w] <= 32'd0;
                line_data_q[w] <= '0;
            end
        end else begin
            for (int unsigned w = 0; w < ENTRIES; w++) begin
                case (state_q[w])
                    WB_FREE: begin
                        if (alloc_sel[w]) begin
                            state_q[w]           <= WB_CAPTURING;
                            line_addr_q[w]       <= alloc_line_addr;
                            line_data_q[w]       <= '0;
                            capture_row_valid[w] <= '0;
                        end
                    end
                    WB_CAPTURING: begin
                        if (cap_sel[w]) begin
                            line_data_q[w][64*cap_wr_row +: 64] <= cap_wr_data;
                            capture_row_valid[w][cap_wr_row]    <= 1'b1;
                            if (cap_wr_last) state_q[w] <= WB_READY;
                        end
                    end
                    WB_READY: begin
                        if (ready_sel[w] && grant_fire) state_q[w] <= WB_DRAINING;
                    end
                    WB_DRAINING: begin
                        if (wb_done) state_q[w] <= WB_FREE;
                    end
                    default: state_q[w] <= WB_FREE;
                endcase
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Simulation assertions (LSU_INTERFACES.md section 11.5)
    //-------------------------------------------------------------------------
    logic rst_q;
    always_ff @(posedge clk) rst_q <= rst;

    function automatic logic legal_trans(input logic [1:0] from, input logic [1:0] to);
        legal_trans = (from == to)
                   || ((from == WB_FREE)      && (to == WB_CAPTURING))
                   || ((from == WB_CAPTURING) && (to == WB_READY))
                   || ((from == WB_READY)     && (to == WB_DRAINING))
                   || ((from == WB_DRAINING)  && (to == WB_FREE));
    endfunction

    // Allocation only ever hits a cycle-start FREE entry with a legal index.
    a_alloc_known: assert property (@(posedge clk) disable iff (rst)
        alloc_valid |-> (|alloc_sel));
    a_alloc_free: assert property (@(posedge clk) disable iff (rst)
        |(alloc_sel & ~free_v) == 1'b0);

    // Capture writes only a CAPTURING entry and only for a legal index.
    a_cap_known: assert property (@(posedge clk) disable iff (rst)
        cap_wr_valid |-> (|cap_sel));
    a_cap_capturing: assert property (@(posedge clk) disable iff (rst)
        |(cap_sel & ~capturing_v) == 1'b0);

    // wb_req_* is only ever driven by the lowest-index READY entry.
    a_wb_req_from_ready: assert property (@(posedge clk) disable iff (rst)
        wb_req_valid |-> (|(ready_sel & ready_v)));

    // wb_done belongs to exactly one DRAINING entry (never duplicated).
    a_wb_done_draining: assert property (@(posedge clk) disable iff (rst)
        wb_done |-> $onehot(draining_v));
    a_one_draining: assert property (@(posedge clk) disable iff (rst)
        $onehot0(draining_v));

    // Visibility blocking is produced by owned (non-FREE) entries only.
    a_vis_from_busy: assert property (@(posedge clk) disable iff (rst)
        vis_query_block |-> (|busy));

    // Reset returns every entry to FREE.
    a_rst_free: assert property (@(posedge clk) disable iff (rst)
        rst_q |-> (state_q == '0));

    for (genvar w = 0; w < ENTRIES; w++) begin : g_asrt
        // cap_wr_last may only be raised once every Row of the entry has been
        // written, including the Row written in this very cycle.
        a_cap_last_all_rows: assert property (@(posedge clk) disable iff (rst)
            (cap_sel[w] && cap_wr_last) |->
                ((capture_row_valid[w] | (ROWS'(1'b1) << cap_wr_row)) == {ROWS{1'b1}}));

        // FSM legality: only the four documented edges exist.
        a_fsm_legal: assert property (@(posedge clk) disable iff (rst || rst_q)
            (state_q[w] != $past(state_q[w])) |-> legal_trans($past(state_q[w]), state_q[w]));
    end
`endif

endmodule
