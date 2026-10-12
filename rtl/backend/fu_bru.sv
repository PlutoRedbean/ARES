//=============================================================================
// ARES - Backend: BRU (branch resolution unit), B11
//-----------------------------------------------------------------------------
// Purpose
//   Resolve the eight control-transfer operations of the RV32IM backend
//   (BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR) one cycle after issue and hand the
//   result to the Completion Network, together with the low-latency recovery
//   sideband the frontend needs to restart fetch.
//
// Spec sources (authoritative)
//   backend.md section 9.2  - BRU: latency 1 / II 1, actual_npc / actual_taken
//                             / actual_target registration, mispredict =
//                             need_redirect || (actual_npc != pred_npc),
//                             need_redirect forces recovery even when the
//                             numeric target matches.
//   backend.md section 10   - guaranteed-accept request, in-flight operation
//                             valid + tag, kill_mask cancellation.
//   backend.md section 11   - completion protocol: one completion per accepted
//                             non-killed operation, >= 1 cycle after issue,
//                             single-cycle pulse, kill wins in the same cycle;
//                             BRU recovery is the only extra sideband (11.7).
//   backend.md section 15.1 - recovery_valid / recovery_branch_tag / redirect_pc
//                             are only produced by a live operation; after a
//                             kill the operation valid bit is cleared, so no
//                             recovery follows ("thereafter", section 11.2).
//   frontend_backend_contract.md section 4 - actual_target is the branch/jump
//                             immediate target even for a NOT-taken conditional
//                             branch (BTB training); it is never actual_npc.
//
// Structure (FREE-04): one request register pair (the operation is consumed in
// the cycle after issue, so no queue is needed), a parallel compare for the six
// branch directions and one add/XOR-target datapath shared by the immediate
// forms.
//
// Contract choices worth noting
//   * completion_valid is strictly kill-gated: kill_mask is applied
//     combinationally to the registered operation (kill wins in the completion
//     cycle, backend.md section 11.5) and again at the accept edge, so an
//     operation whose tag is killed in its issue cycle can never produce a
//     stale completion later.
//   * recovery_valid is deliberately NOT gated by kill_mask (C1 integration
//     fix): be_flush derives the kill mask from this very recovery event, so a
//     kill-gated recovery_valid would close the combinational loop
//         recovery_valid -> kill_mask -> recovery_valid.
//     This stays safe because
//       - the recovering branch is never in its own kill set: kill[i] requires
//         age(i) > age(recovery_branch_tag.slot_index), and age(b) > age(b) is
//         false (backend.md section 15.1),
//       - a killed operation always has op_valid cleared on the kill edge, so no
//         recovery can follow in any later cycle (backend.md section 11.2
//         "thereafter" - this is the guarantee the unit still provides),
//       - a full-queue flush (ECALL/MRET/IRQ trap) can never coincide with an
//         in-flight BRU operation (serializing issue / empty-CIQ requirement of
//         backend.md sections 16.3 and 17.2), and the redirect arbiter of
//         section 17.3 would give a higher-priority trap redirect precedence
//         anyway.
//   * In the completion cycle of a killed (impossible in legal operation)
//     recovering branch, recovery_valid may therefore be high without
//     completion_valid; a_kill_priority and a_recovery_needs_completion below
//     encode the exact post-fix contract.
//   * completion.result is pc + 4 for every supported operation.
//
// FREE items exercised: FREE-01 (op_t encodings), FREE-02 (file layout),
// FREE-04 (combinational structure), FREE-10 (verification environment).
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */  // BRU reads only the CFI fields of the shared fu_req_t
module fu_bru (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    input  ares_pkg::fu_req_t                issue_req,
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion,
    output logic [31:0]                      actual_npc,
    output logic                             actual_taken,
    output logic [31:0]                      actual_target,
    output logic                             recovery_valid,
    output ares_pkg::tag_t                   recovery_branch_tag,
    output logic [31:0]                      redirect_pc
);
/* verilator lint_on UNUSEDSIGNAL */
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // In-flight operation (latency = 1, II = 1): exactly one request is held
    // between the accept edge and the completion cycle.
    //-------------------------------------------------------------------------
    logic        op_valid;
    tag_t        op_tag;
    op_t         op_code;
    logic [31:0] op_pc;
    logic [31:0] op_src1;
    logic [31:0] op_src2;
    logic [31:0] op_imm;
    logic [31:0] op_pred_npc;
    logic        op_need_redirect;

    // Kill of the operation currently held (backend.md section 10/11.5): the
    // mask is indexed by the operation tag and wins over the completion.
    wire op_killed = op_valid && kill_mask[op_tag.slot_index];

    always_ff @(posedge clk) begin
        if (rst) begin
            op_valid <= 1'b0;
        end else begin
            // Guaranteed accept: every request is latched.  A request whose tag
            // is killed in the very cycle it is accepted is dropped here so it
            // can never emit a completion for a killed CIQ entry.
            op_valid <= issue_valid && !kill_mask[issue_req.tag.slot_index];
        end
    end

    always_ff @(posedge clk) begin
        if (issue_valid) begin
            op_tag           <= issue_req.tag;
            op_code          <= issue_req.op;
            op_pc            <= issue_req.pc;
            op_src1          <= issue_req.src1;
            op_src2          <= issue_req.src2;
            op_imm           <= issue_req.imm;
            op_pred_npc      <= issue_req.pred_npc;
            op_need_redirect <= issue_req.need_redirect;
        end
    end

    //-------------------------------------------------------------------------
    // Resolution (combinational, registered inputs)
    //-------------------------------------------------------------------------
    logic        is_jal;
    logic        is_jalr;
    logic        is_branch;
    logic        cond_taken;
    logic [31:0] jump_target;   // pc + imm for JAL / conditional branches
    logic [31:0] link_target;   // (src1 + imm) & ~1 for JALR
    logic [31:0] resolved_npc;
    logic        resolved_taken;

    always_comb begin
        is_jal    = (op_code == OP_JAL);
        is_jalr   = (op_code == OP_JALR);
        is_branch = (op_code == OP_BEQ) || (op_code == OP_BNE) || (op_code == OP_BLT)
                 || (op_code == OP_BGE) || (op_code == OP_BLTU) || (op_code == OP_BGEU);

        // Parallel direction evaluation; only the selected compare is used.
        case (op_code)
            OP_BEQ:  cond_taken = (op_src1 == op_src2);
            OP_BNE:  cond_taken = (op_src1 != op_src2);
            OP_BLT:  cond_taken = ($signed(op_src1) <  $signed(op_src2));
            OP_BGE:  cond_taken = ($signed(op_src1) >= $signed(op_src2));
            OP_BLTU: cond_taken = (op_src1 <  op_src2);
            OP_BGEU: cond_taken = (op_src1 >= op_src2);
            default: cond_taken = 1'b0;
        endcase

        // Branch/JAL immediate target.  JALR clears bit 0 of the computed
        // address (RV32I JALR: target = (rs1 + imm) & ~1).
        jump_target = op_pc + op_imm;
        link_target = (op_src1 + op_imm) & 32'hFFFF_FFFE;

        // actual_target is always the CFI target, taken or not (contract
        // section 4); actual_npc is pc+4 for a not-taken conditional branch.
        resolved_taken = is_jal || is_jalr || (is_branch && cond_taken);
        resolved_npc   = is_jalr ? link_target
                                 : ((is_branch && !cond_taken) ? (op_pc + 32'd4)
                                                               : jump_target);
    end

    wire [31:0] resolved_target = is_jalr ? link_target : jump_target;

    //-------------------------------------------------------------------------
    // Completion + recovery sideband
    //-------------------------------------------------------------------------
    wire op_completing = op_valid && !op_killed;

    always_comb begin
        completion_valid     = op_completing;
        completion           = '0;
        completion.tag       = op_tag;
        completion.result    = op_pc + 32'd4;
        completion.exception = 1'b0;
        completion.cause     = EXC_NONE;
        completion.tval      = 32'h0;

        actual_npc           = resolved_npc;
        actual_taken         = resolved_taken;
        actual_target        = resolved_target;

        // The recovery is deliberately NOT kill-gated: the kill mask is derived
        // from this very event (be_flush), so gating it here would close a
        // combinational loop.  It is safe because the recovering branch is
        // never in its own kill set (age(branch) > age(branch) is false), a
        // killed operation has op_valid cleared on the kill edge, and a full
        // flush (ECALL/MRET/IRQ) cannot coincide with an in-flight BRU
        // operation (serializing issue / empty-CIQ requirement).  The
        // a_kill_priority assertion below still pins the invariant.
        recovery_valid       = op_valid && (op_need_redirect
                                            || (resolved_npc != op_pred_npc));
        recovery_branch_tag  = op_tag;
        redirect_pc          = resolved_npc;
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol assertions (backend.md sections 9.2 / 10 / 11; plan section 6)
    //-------------------------------------------------------------------------
    // A recovery is produced by a live operation and, except for the
    // same-cycle kill that creates the loop-break case documented in the
    // header, always travels with the completion.
    a_recovery_needs_completion: assert property (@(posedge clk) disable iff (rst)
        recovery_valid |-> (completion_valid || kill_mask[op_tag.slot_index]));

    a_recovery_tag: assert property (@(posedge clk) disable iff (rst)
        recovery_valid |-> (recovery_branch_tag == completion.tag));

    a_recovery_pc: assert property (@(posedge clk) disable iff (rst)
        recovery_valid |-> (redirect_pc == actual_npc));

    a_kill_priority: assert property (@(posedge clk) disable iff (rst)
        (op_valid && kill_mask[op_tag.slot_index])
        |-> !completion_valid && !recovery_valid);

    a_result_is_pc4: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> (completion.result == op_pc + 32'd4));

    a_bru_no_exception: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> (!completion.exception && (completion.cause == EXC_NONE)));

    a_issue_completes: assert property (@(posedge clk) disable iff (rst)
        (issue_valid && !kill_mask[issue_req.tag.slot_index])
        |=> (completion_valid || kill_mask[$past(issue_req.tag.slot_index)]));
`endif

endmodule
