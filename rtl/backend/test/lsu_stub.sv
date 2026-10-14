//=============================================================================
// ARES core verification - ideal LSU stub (simulation only)
//-----------------------------------------------------------------------------
// Behavioural stand-in for the memory subsystem (C2) so the backend can be
// verified on its own (docs/core_verification_flow.md section 2, plan 5.10).
//
// It implements exactly the backend-visible contract of backend.md 9.6:
//   * guaranteed accept (can_accept = 1, the input register is always free);
//   * load_credit / store_credit from registered LQ/SQ occupancy, computed from
//     the start-of-cycle state and never borrowing this cycle's releases
//     (D-C0-05: 4 LQ entries, 8 SQ entries -> store_credit is 4 bits wide so
//     the empty-queue value 8 is representable);
//   * one completion per accepted, non-killed operation, COMPL_LATENCY cycles
//     later (load result = src1+imm address, store result = 0);
//   * kill cancels an uncommitted operation and suppresses its completion;
//   * store_commit_ok inspects registered state only (never commit_fire); the
//     authorization is consumed on store_commit_valid[i] && commit_fire[i];
//   * lsu_mmio_order_idle is constantly 1 (no device model in this stub).
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module lsu_stub #(
    parameter int unsigned COMPL_LATENCY = 1
) (
    input  logic                        clk,
    input  logic                        rst,

    //---- issue port ---------------------------------------------------------
    output logic                        can_accept,
    output logic [2:0]                  load_credit,   // LQ_ENTRIES = 4
    output logic [3:0]                  store_credit,  // SQ_ENTRIES = 8
    input  logic                        issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // only op / tag / src1 / imm are inspected
    input  ares_pkg::fu_req_t           issue_req,
    /* verilator lint_on UNUSEDSIGNAL */

    //---- completion port ----------------------------------------------------
    output logic                        completion_valid,
    output ares_pkg::fu_completion_t    completion,
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- commit handshake ---------------------------------------------------
    input  logic [1:0]                  store_commit_valid,
    input  ares_pkg::tag_t              store_commit_tag [2],
    output logic [1:0]                  store_commit_ok,
    input  logic [1:0]                  commit_fire,
    /* verilator lint_off UNUSEDSIGNAL */  // no MMIO / cache model in this stub
    input  logic                        load_head_valid,
    input  ares_pkg::tag_t              load_head_tag,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic                        mmio_order_idle,

    //---- scoreboard hooks ---------------------------------------------------
    output logic [4:0]                  lq_used,
    output logic [4:0]                  sq_used
);
    import ares_pkg::*;

    localparam int unsigned DEPTH = COMPL_LATENCY;

    //-------------------------------------------------------------------------
    // Outstanding-operation bookkeeping, indexed by CIQ tag (valid-only)
    //-------------------------------------------------------------------------
    logic [CIQ_ENTRIES-1:0] lq_busy, sq_busy;

    logic issue_is_load, issue_is_store;
    assign issue_is_load  = issue_valid
                         && issue_req.op inside {OP_LB, OP_LH, OP_LW, OP_LBU, OP_LHU};
    assign issue_is_store = issue_valid
                         && issue_req.op inside {OP_SB, OP_SH, OP_SW};

    logic issue_killed;
    assign issue_killed = issue_valid && kill_mask[issue_req.tag.slot_index];

    always_comb begin
        lq_used = 5'd0;
        sq_used = 5'd0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            lq_used = lq_used + {4'd0, lq_busy[i]};
            sq_used = sq_used + {4'd0, sq_busy[i]};
        end
    end

    assign load_credit     = 3'd4 - {1'b0, lq_used[1:0]};
    assign store_credit    = 4'd8 - sq_used[3:0];
    assign can_accept      = 1'b1;
    assign mmio_order_idle = 1'b1;

    //-------------------------------------------------------------------------
    // Completion pipeline (fixed latency, one result per accepted operation)
    //-------------------------------------------------------------------------
    logic [DEPTH-1:0] p_valid;
    tag_t             p_tag [DEPTH];
    logic             p_is_load [DEPTH];
    logic [31:0]      p_addr [DEPTH];

    always_comb begin
        completion_valid     = p_valid[DEPTH-1] && !kill_mask[p_tag[DEPTH-1].slot_index];
        completion           = '0;
        completion.tag       = p_tag[DEPTH-1];
        completion.result    = p_is_load[DEPTH-1] ? p_addr[DEPTH-1] : 32'd0;
        completion.exception = 1'b0;
        completion.cause     = EXC_NONE;
        completion.tval      = 32'd0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned d = 0; d < DEPTH; d++) begin
                p_valid[d]   <= 1'b0;
                p_tag[d]     <= '0;
                p_is_load[d] <= 1'b0;
                p_addr[d]    <= 32'd0;
            end
        end else begin
            for (int unsigned d = DEPTH - 1; d > 0; d--) begin
                p_valid[d]   <= p_valid[d-1];
                p_tag[d]     <= p_tag[d-1];
                p_is_load[d] <= p_is_load[d-1];
                p_addr[d]    <= p_addr[d-1];
            end
            p_valid[0]   <= issue_valid && !issue_killed;
            p_tag[0]     <= issue_req.tag;
            p_is_load[0] <= issue_is_load;
            p_addr[0]    <= issue_req.src1 + issue_req.imm;
        end
    end

    //-------------------------------------------------------------------------
    // LQ / SQ occupancy
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            lq_busy <= '0;
            sq_busy <= '0;
        end else begin
            if (issue_is_load && !issue_killed)
                lq_busy[issue_req.tag.slot_index] <= 1'b1;
            if (issue_is_store && !issue_killed)
                sq_busy[issue_req.tag.slot_index] <= 1'b1;

            // a load is released when its completion actually leaves the port
            if (completion_valid)
                lq_busy[p_tag[DEPTH-1].slot_index] <= 1'b0;

            // a store is released by the commit authorization, or by a kill
            // before it (already-authorized stores are never killed)
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++)
                if (kill_mask[i]) sq_busy[i] <= 1'b0;
            for (int unsigned l = 0; l < 2; l++)
                if (store_commit_valid[l] && commit_fire[l])
                    sq_busy[store_commit_tag[l].slot_index] <= 1'b0;
        end
    end

    // store_commit_ok only looks at registered state (backend.md 14.6)
    always_comb begin
        for (int unsigned l = 0; l < 2; l++)
            store_commit_ok[l] = store_commit_valid[l]
                              && sq_busy[store_commit_tag[l].slot_index];
    end

`ifdef CONFIG_SIMULATION
    // A completion leaving the port always belongs to an outstanding
    // operation (load: still in lq_busy, store: still in sq_busy).
    always_ff @(posedge clk) begin
        if (!rst && p_valid[DEPTH-1] && !kill_mask[p_tag[DEPTH-1].slot_index])
            a_compl_outstanding : assert (lq_busy[p_tag[DEPTH-1].slot_index]
                                       || sq_busy[p_tag[DEPTH-1].slot_index]);
    end
`endif
endmodule
