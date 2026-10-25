// Test-only reference at pre-C4 commit 8aa3bca; invalid request payloads are ignored.
//=============================================================================
// ARES backend - Issue Scheduler (B07)
//-----------------------------------------------------------------------------
// Strictly in-order, up to 4-wide issue from the four oldest CIQ candidates
// (backend.md section 8, plan section 5.6):
//
//   * grant is a contiguous prefix over issue_ptr+0..3; the first candidate
//     that cannot fire stops every younger candidate (no age matrix, no
//     oldest-ready search);
//   * each physical port is reserved at most once per cycle; the reservation
//     starts from the FU can_accept inputs and is consumed by the prefix walk;
//   * MUL that satisfies the SMUL independent-fit test is compatible with
//     SMUL | MUL and prefers SMUL (backend.md 9.3);
//   * a serializing instruction (CSR/ECALL/MRET) may issue only when it is the
//     commit head and lsu_mmio_order_idle is set, and it issues alone
//     (backend.md 8.3/16.3); no new issue is allowed on a recovery/flush cycle;
//   * guaranteed accept: issue_valid implies the FU latched the request, so
//     issue_fire = issue_valid and there is no second ready/retry.
//
// Port index encoding: the 3-bit index equals the ares_pkg::fu_type_t value
// (FU_ALU0=0 ... FU_LSU=7), so be_top can wire fu_issue_valid/fu_req straight
// to the matching FU instance.
//
// FREE items: FREE-04 (parallel port-preference decode + prefix chain).
//=============================================================================
module be_issue_sched_reference (
    //---- four oldest candidates and their resolved sources -----------------
    input ares_pkg::queue_entry_t        cand     [ares_pkg::ISSUE_WIDTH_MAX],
    input logic                   [31:0] src1     [ares_pkg::ISSUE_WIDTH_MAX],
    input logic                   [31:0] src2     [ares_pkg::ISSUE_WIDTH_MAX],
    input logic                          src_ready[ares_pkg::ISSUE_WIDTH_MAX],

    //---- ordering / global conditions --------------------------------------
    input ares_pkg::tag_t issue_ptr,
    input ares_pkg::tag_t commit_ptr,
    input logic           lsu_mmio_order_idle,
    input logic           lsu_fence_idle,
    input logic           recovery_valid,
    input logic           flush_active,

    //---- FU acceptance and LSU credits (indexed by ares_pkg::fu_type_t) -------------
    input logic [7:0] fu_can_accept,
    input logic [2:0] load_credit,    // ares_pkg::LQ_ENTRIES = 4 (3 bits = 0..4)
    input logic [3:0] store_credit,   // ares_pkg::SQ_ENTRIES = 8 (4 bits = 0..8)

    //---- grants (CIQ: WAIT -> EXEC, FU: latch the request) -----------------
    output logic [ares_pkg::ISSUE_WIDTH_MAX-1:0] issue_grant,
    output ares_pkg::tag_t issue_tag[ares_pkg::ISSUE_WIDTH_MAX],
    output logic [7:0] fu_issue_valid,
    output ares_pkg::fu_req_t fu_req[8]
);
    import ares_pkg::*;

    localparam logic [2:0] P_ALU0 = 3'd0;
    localparam logic [2:0] P_ALU1 = 3'd1;
    localparam logic [2:0] P_BRU  = 3'd2;
    localparam logic [2:0] P_SMUL = 3'd3;
    localparam logic [2:0] P_MUL  = 3'd4;
    localparam logic [2:0] P_DIV  = 3'd5;
    localparam logic [2:0] P_CSR  = 3'd6;
    localparam logic [2:0] P_LSU  = 3'd7;

    //-------------------------------------------------------------------------
    // SMUL eligibility on the real operands (backend.md 9.3)
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // only v[31:15] take part in the fit test
    function automatic logic fit16(input logic [31:0] v);
        begin
            fit16 = (v[31:16] == 16'h0000) || (v[31:16] == {16{v[15]}});
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic smul_ok[ISSUE_WIDTH_MAX];
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++)
        smul_ok[i] = (cand[i].op == OP_MUL) && fit16(src1[i]) && fit16(src2[i]);
    end

    //-------------------------------------------------------------------------
    // Port preference for one candidate against the remaining port set.
    // Returns 1 when a compatible free port was found.
    //-------------------------------------------------------------------------
    function automatic logic pick_port(input fu_type_t ft, input logic smul_eligible,
                                       input logic credit_ok, input logic [7:0] rem,
                                       output logic [2:0] port);
        begin
            pick_port = 1'b1;
            port      = P_ALU0;
            case (ft)
                FU_ALU0, FU_ALU1: begin
                    if (rem[P_ALU0]) port = P_ALU0;
                    else if (rem[P_ALU1]) port = P_ALU1;
                    else pick_port = 1'b0;
                end
                FU_MUL: begin
                    if (smul_eligible && rem[P_SMUL]) port = P_SMUL;
                    else if (rem[P_MUL]) port = P_MUL;
                    else pick_port = 1'b0;
                end
                FU_BRU: begin
                    if (rem[P_BRU]) port = P_BRU;
                    else pick_port = 1'b0;
                end
                FU_DIV: begin
                    if (rem[P_DIV]) port = P_DIV;
                    else pick_port = 1'b0;
                end
                FU_CSR: begin
                    if (rem[P_CSR]) port = P_CSR;
                    else pick_port = 1'b0;
                end
                FU_LSU: begin
                    if (rem[P_LSU] && credit_ok) port = P_LSU;
                    else pick_port = 1'b0;
                end
                default: begin
                    port = P_ALU0;
                    pick_port = 1'b0;
                end
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Contiguous-prefix arbitration
    //-------------------------------------------------------------------------
    logic [7:0] remaining;
    logic prefix_ok, block_all;
    logic c_ok, c_credit_ok, c_found;
    logic [2:0] c_port;
    logic [2:0] fu_sel      [ISSUE_WIDTH_MAX];
    logic       fu_sel_valid[ISSUE_WIDTH_MAX];

    always_comb begin
        remaining = fu_can_accept;
        prefix_ok = 1'b1;
        block_all = recovery_valid || flush_active;

        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            issue_grant[i]          = 1'b0;
            issue_tag[i].slot_index = issue_ptr.slot_index + 4'(i);
            fu_sel[i]               = P_ALU0;
            fu_sel_valid[i]         = 1'b0;
        end

        c_ok = 1'b0;
        c_credit_ok = 1'b0;
        c_found = 1'b0;
        c_port = P_ALU0;

        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            c_ok = cand[i].valid && (cand[i].state == ENTRY_WAIT) && src_ready[i];
            if (cand[i].is_serializing)
                c_ok = c_ok && (issue_tag[i].slot_index == commit_ptr.slot_index) && (cand[i].is_fence ? lsu_fence_idle : lsu_mmio_order_idle);

            c_credit_ok = cand[i].is_load  ? (load_credit  != 3'd0)
                        : cand[i].is_store ? (store_credit != 4'd0)
                        : 1'b1;

            c_found = pick_port(cand[i].fu_type, smul_ok[i], c_credit_ok, remaining, c_port);

            issue_grant[i] = prefix_ok && c_ok && c_found && !block_all;
            if (issue_grant[i]) begin
                remaining[c_port] = 1'b0;
                fu_sel[i]         = c_port;
                fu_sel_valid[i]   = 1'b1;
            end

            // A granted serializing instruction issues alone; any other grant
            // requires every older candidate to have been granted.
            prefix_ok = issue_grant[i] && !cand[i].is_serializing;
        end
    end

    //-------------------------------------------------------------------------
    // Request fan-out (guaranteed accept)
    //-------------------------------------------------------------------------
    always_comb begin
        fu_issue_valid = 8'd0;
        for (int unsigned p = 0; p < 8; p++) fu_req[p] = '0;

        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            if (issue_grant[i] && fu_sel_valid[i]) begin
                fu_issue_valid[fu_sel[i]]      = 1'b1;
                fu_req[fu_sel[i]].tag          = issue_tag[i];
                fu_req[fu_sel[i]].op           = cand[i].op;
                fu_req[fu_sel[i]].src1         = src1[i];
                fu_req[fu_sel[i]].src2         = src2[i];
                fu_req[fu_sel[i]].imm          = cand[i].imm;
                fu_req[fu_sel[i]].pc           = cand[i].pc;
                fu_req[fu_sel[i]].pred_npc     = cand[i].pred_npc;
                fu_req[fu_sel[i]].csr_addr     = cand[i].csr_addr;
                fu_req[fu_sel[i]].csr_write_en = cand[i].csr_write_en;
            end
        end
    end

`ifdef CONFIG_SIMULATION
    // issue_valid implies the port accepted (backend.md 10); the prefix rule is
    // asserted in the unit TB (a_guaranteed_accept is a pure combinational
    // invariant).
    always_comb begin
        for (int unsigned p = 0; p < 8; p++)
        a_guaranteed_accept : assert (!fu_issue_valid[p] || fu_can_accept[p]);
    end
`endif
endmodule
