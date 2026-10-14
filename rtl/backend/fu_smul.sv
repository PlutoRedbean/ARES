//=============================================================================
// ARES backend - fu_smul: Short-MUL execution port (Independent Fit 17x17)
//-----------------------------------------------------------------------------
// Purpose
//   Single-cycle (latency = 1, II = 1, can_accept = 1) short multiplier port.
//   It is fed only OP_MUL instructions whose operands the issue scheduler has
//   proved smul_eligible (backend.md section 9.3); the unit then normalises
//   each operand independently to 17-bit signed, multiplies 17x17 -> 34 bit and
//   returns the low 32 bits, which is bit-identical to the low 32 bits of the
//   full RV32 MUL result.  MULH/MULHSU/MULHU never enter this unit.
//
//   Normalisation (independent per operand, backend.md section 9.3):
//     fit_u16 = (src[31:16] == 16'h0000)  ->  {1'b0,    src[15:0]}
//     otherwise (signed fit)              ->  {src[15], src[15:0]}
//   Ineligible operands are outside this unit's contract (the scheduler keeps
//   them on the full MUL port); the formula above is still applied so the
//   output is fully defined for any input.
//
// Spec sources
//   docs/microarch/backend.md section 9.3   Short MUL (SMUL) definition
//   docs/microarch/backend.md section 9     FU latency / II / can_accept table
//   docs/microarch/backend.md section 10    guaranteed-accept request + kill
//   docs/microarch/backend.md section 11    completion protocol invariants
//   docs/implementation_plan.md sections 5.6 / 5.7, module B12
//
// FREE items exercised
//   FREE-02  file organisation / internal partitioning
//   FREE-04  combinational structure
//   FREE-05  SMUL multiplier implementation
//   FREE-11  internal pipeline register placement and naming
//
// Verification
//   rtl/backend/test/unit/tb_fu_exec.sv (directed + randomised, fixed seed);
//   lint and run commands are recorded in that test bench header.
//=============================================================================
module fu_smul (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // BRU/LSU/CSR-only fu_req_t fields are not read by SMUL
    input  ares_pkg::fu_req_t                issue_req,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion
);

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // 17-bit signed normalisation of both operands.
    //-------------------------------------------------------------------------
    logic signed [16:0] smul_a;
    logic signed [16:0] smul_b;
    always_comb begin
        smul_a = (issue_req.src1[31:16] == 16'h0000)
                 ? {1'b0, issue_req.src1[15:0]} : {issue_req.src1[15], issue_req.src1[15:0]};
        smul_b = (issue_req.src2[31:16] == 16'h0000)
                 ? {1'b0, issue_req.src2[15:0]} : {issue_req.src2[15], issue_req.src2[15:0]};
    end

    //-------------------------------------------------------------------------
    // signed 17 x 17 -> 34 bit; the low 32 bits are the MUL result.
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // 17x17 product is 34 bit by spec; only [31:0] is the result
    logic signed [33:0] smul_prod;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb smul_prod = smul_a * smul_b;

    //-------------------------------------------------------------------------
    // Single in-flight operation register (latency 1).
    //-------------------------------------------------------------------------
    logic        op_valid;
    tag_t        op_tag;
    logic [31:0] op_result;

    wire op_kill = kill_mask[op_tag.slot_index];

    always_ff @(posedge clk) begin
        if (rst) begin
            op_valid  <= 1'b0;
            op_tag    <= '0;
            op_result <= 32'd0;
        end else begin
            // The operation is held for exactly one cycle, so the next value
            // of op_valid is simply issue_valid: a completed (or killed)
            // operation leaves the register.  The kill needs no separate
            // clear here - it suppresses the completion combinationally in the
            // same cycle and the operation is gone one cycle later.
            op_valid <= issue_valid;
            if (issue_valid) begin
                op_tag    <= issue_req.tag;
                op_result <= smul_prod[31:0];
            end
        end
    end

    assign completion_valid = op_valid && !op_kill;

    always_comb begin
        completion           = '0;
        completion.tag       = op_tag;
        completion.result    = op_result;
        completion.exception = 1'b0;
        completion.cause     = EXC_NONE;
        completion.tval      = 32'd0;
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol invariants (backend.md section 11)
    //-------------------------------------------------------------------------
    a_kill_wins: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> !kill_mask[completion.tag.slot_index]);

    a_no_completion_without_op: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> op_valid);
`endif

endmodule
