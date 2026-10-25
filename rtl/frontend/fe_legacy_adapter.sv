//=============================================================================
// ARES - legacy frontend -> new backend contract adapter (C5 step 1)
//-----------------------------------------------------------------------------
// The existing rtl/frontend is kept intact.  This adapter only translates:
//
//   legacy IQ read port          -> contract iq_valid/iq_inst/iq_accept_count
//   legacy redirect              -> contract redirect (ghr/actual_taken are
//                                   observation-only here; the legacy BPU uses
//                                   redirect_kind)
//   contract BPU update (2/cycle)-> legacy single update/cycle
//
// IQ and redirect are combinational (zero added cycles).  BPU updates go
// through a 4-entry FIFO so a 2-wide commit cannot lose a training event; the
// legacy BPU still consumes one update per cycle.  The FIFO adds at most a
// one-cycle training delay, not a fetch-pipeline delay.
//=============================================================================
module fe_legacy_adapter (
    input  logic clk,
    input  logic rst,

    //---- legacy frontend side ----------------------------------------------
    input  logic [1:0]                 fe_iq_rvalid,
    input  fe_pkg::iq_entry_t          fe_iq_rbits [2],
    output logic [1:0]                 fe_iq_raccept_cnt,
    output logic                       fe_redirect_valid,
    output logic [31:0]                fe_redirect_pc,
    output fe_pkg::fe_redirect_kind_t  fe_redirect_kind,
    output logic                       fe_bpu_update_en,
    output fe_pkg::bpu_update_t        fe_bpu_update_meta,

    //---- new backend contract ----------------------------------------------
    output logic [1:0]                 be_iq_valid,
    output fe_pkg::iq_entry_t          be_iq_inst [2],
    input  logic [1:0]                 be_iq_accept_count,
    input  logic                       be_redirect_valid,
    input  logic [31:0]                be_redirect_pc,
    input  fe_pkg::fe_redirect_kind_t  be_redirect_kind,
    input  logic [fe_pkg::GHR_WIDTH-1:0] be_redirect_ghr_before,
    input  logic                       be_redirect_actual_taken,
    output logic [1:0]                 be_bpu_update_credit,
    input  logic [1:0]                 be_bpu_update_valid,
    input  fe_pkg::bpu_update_t        be_bpu_update [2]
);
    import fe_pkg::*;

    //-------------------------------------------------------------------------
    // IQ: the legacy IQ already exposes a contiguous valid prefix and a
    // counting consume handshake, so this is a pure rename.
    //-------------------------------------------------------------------------
    assign be_iq_valid        = fe_iq_rvalid;
    assign be_iq_inst[0]      = fe_iq_rbits[0];
    assign be_iq_inst[1]      = fe_iq_rbits[1];
    assign fe_iq_raccept_cnt  = be_iq_accept_count;

    //-------------------------------------------------------------------------
    // Redirect: combinational pass-through.  ghr_before/actual_taken are part
    // of the new contract but the legacy BPU recovers history from kind, so
    // they are not consumed here.
    //-------------------------------------------------------------------------
    assign fe_redirect_valid = be_redirect_valid;
    assign fe_redirect_pc    = be_redirect_pc;
    assign fe_redirect_kind  = be_redirect_kind;

    //-------------------------------------------------------------------------
    // BPU update: 2 pushes/cycle, 1 pop/cycle.
    //-------------------------------------------------------------------------
    localparam int unsigned DEPTH = 4;
    localparam int unsigned PTR_W = 2;

    bpu_update_t q [DEPTH];
    logic [2:0]  count;
    logic [PTR_W-1:0] head, tail;

    wire [2:0] free = 3'(DEPTH) - count;
    wire [2:0] push_count =
        (be_bpu_update_valid == 2'b11 && free >= 3'd2) ? 3'd2 :
        (be_bpu_update_valid != 2'b00 && free >= 3'd1) ? 3'd1 : 3'd0;
    wire pop = (count != 3'd0);

    assign be_bpu_update_credit =
        (free >= 3'd2) ? 2'd2 : (free == 3'd1) ? 2'd1 : 2'd0;

    assign fe_bpu_update_en   = pop;
    assign fe_bpu_update_meta = q[head];

    always_ff @(posedge clk) begin
        if (rst) begin
            count <= 3'd0;
            head  <= '0;
            tail  <= '0;
        end else begin
            // Pop first (oldest event).
            if (pop) head <= head + 1'b1;

            // Push up to the available space.  Lane 0 has priority.
            if (be_bpu_update_valid[0] && (free >= 3'd1)) begin
                q[tail] <= be_bpu_update[0];
                tail    <= tail + 1'b1;
            end
            if (be_bpu_update_valid[1] && (free >= ((be_bpu_update_valid[0]) ? 3'd2 : 3'd1))) begin
                q[(be_bpu_update_valid[0] ? tail + 1'b1 : tail)] <= be_bpu_update[1];
                tail <= tail + ((be_bpu_update_valid[0] && (free >= 3'd2)) ? 2'd2 : 2'd1);
            end

            count <= count + push_count - (pop ? 3'd1 : 3'd0);
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */  // part of the new contract, observed by the SoC
    logic unused_redirect_meta;
    assign unused_redirect_meta = ^{be_redirect_ghr_before, be_redirect_actual_taken};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
