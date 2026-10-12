//=============================================================================
// ARES backend - fu_div: radix-4 iterative DIV / DIVU / REM / REMU
//-----------------------------------------------------------------------------
// Purpose
//   One outstanding operation, variable latency, II variable.  The radix-4
//   restoring core consumes two dividend bits per iteration (16 iterations for
//   RV32); the request is latched on the issue edge, the completion is a
//   single-cycle pulse and never waits for a ready.
//
//   Handover: can_accept = !busy || completing_this_cycle, so a new request
//   may be latched on the very clock edge that carries the final completion of
//   the previous operation (backend.md section 9.5).  can_accept is a function
//   of state only and never depends on issue_valid.
//
//   Kill: a kill_mask hit aborts the operation immediately (busy is cleared on
//   that clock edge), suppresses a completion in the same cycle (kill wins) and
//   makes can_accept 1 again on the following cycle.
//
//   RV32M result semantics (no arithmetic exception is ever raised):
//     divisor == 0        : DIV/DIVU = 32'hFFFF_FFFF, REM/REMU = dividend
//     INT_MIN / -1        : DIV = INT_MIN (32'h8000_0000), REM = 0
//   Sign handling uses magnitudes: |a| / |b|, quotient sign = a[31] ^ b[31],
//   remainder sign = a[31]; the INT_MIN/-1 case then falls out of the unsigned
//   datapath with quotient 0x8000_0000 and remainder 0 without special casing.
//   No data fast path is implemented; every operation (including the divisor
//   = 0 cases) takes the full 16-iteration pipeline, so the completion is
//   always at least one cycle after issue.
//
// Spec sources
//   docs/microarch/backend.md section 9.5   DIV definition / can_accept
//   docs/microarch/backend.md section 9     FU latency / II / can_accept table
//   docs/microarch/backend.md section 10    guaranteed-accept request + kill
//   docs/microarch/backend.md section 11    completion protocol invariants
//   docs/implementation_plan.md sections 5.6 / 5.7, module B14
//
// FREE items exercised
//   FREE-02  file organisation / internal partitioning
//   FREE-04  combinational structure (parallel compare/subtract digit select)
//   FREE-05  DIV iteration radix / state encoding
//   FREE-11  internal pipeline register placement and naming
//
// Verification
//   rtl/backend/test/unit/tb_fu_exec.sv (directed edge cases: 0, +-1,
//   INT_MIN/-1, divisor 0; >= 20000 random pairs against a reference model;
//   handover and kill tests).  Lint and run commands are in that TB header.
//=============================================================================
module fu_div (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // imm/pc and the BRU/LSU/CSR-only fields are not read by DIV
    input  ares_pkg::fu_req_t                issue_req,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion,
    output logic                             can_accept
);

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Operation state
    //-------------------------------------------------------------------------
    localparam logic [3:0] ITER_LAST = 4'd15;   // 16 radix-4 iterations = 32 bits

    logic        busy;
    tag_t        op_tag;
    logic        op_rem;       // REM / REMU
    logic        div_zero;     // divisor == 0 at issue
    logic        q_neg;        // signed op with a[31] ^ b[31]
    logic        r_neg;        // signed op with a[31]
    logic [31:0] dend_orig;    // dividend as issued (divisor = 0 remainder)
    logic [31:0] dend_shift;   // remaining dividend bits (MSB first)
    logic [31:0] divisor;      // |divisor|
    /* verilator lint_off UNUSEDSIGNAL */  // rem stays < divisor (< 2^32) and the top quotient
    logic [33:0] rem;          // running remainder, always < divisor   bits are consumed by the
    logic [31:0] quo;          // accumulated quotient                  16 radix-4 shifts
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]  iter;

    //-------------------------------------------------------------------------
    // Radix-4 iteration datapath: three parallel compare/subtract chains pick
    // the quotient digit {0,1,2,3}; the remainder invariant rem < divisor
    // guarantees r_shift = 4*rem + 2 bits < 4*divisor, so the digit is exact.
    // The comparisons are explicit unsigned >= (a borrow-bit test is not valid
    // here: 3*divisor can exceed 2^33, so a negative difference can wrap into a
    // 34-bit value whose top bit is 0).
    //-------------------------------------------------------------------------
    wire [33:0] b_ext   = {2'b00, divisor};
    wire [33:0] b2      = b_ext << 1;               // 2*divisor (< 2^33)
    wire [33:0] b3      = b_ext + b2;               // 3*divisor (< 2^34)
    wire [33:0] r_shift = {rem[31:0], dend_shift[31:30]};
    wire [33:0] d1      = r_shift - b_ext;
    wire [33:0] d2      = r_shift - b2;
    wire [33:0] d3      = r_shift - b3;
    wire [1:0]  digit   = (r_shift >= b3) ? 2'd3 :
                          (r_shift >= b2) ? 2'd2 :
                          (r_shift >= b_ext) ? 2'd1 : 2'd0;
    wire [33:0] r_next  = (digit == 2'd3) ? d3 :
                          (digit == 2'd2) ? d2 :
                          (digit == 2'd1) ? d1 : r_shift;
    wire [31:0] quo_next  = {quo[29:0], digit};
    wire [31:0] dend_next = {dend_shift[29:0], 2'b00};

    wire last_iter = (iter == ITER_LAST);
    wire killed    = busy && kill_mask[op_tag.slot_index];
    wire finishing = busy && last_iter;

    //-------------------------------------------------------------------------
    // Final result selection (backend.md section 9.5 / RV32M semantics)
    //-------------------------------------------------------------------------
    wire [31:0] q_signed  = q_neg ? -quo_next : quo_next;
    wire [31:0] r_signed  = r_neg ? -r_next[31:0] : r_next[31:0];
    wire [31:0] div_result = op_rem ? (div_zero ? dend_orig : r_signed)
                                    : (div_zero ? 32'hFFFF_FFFF : q_signed);

    assign can_accept       = !busy || finishing;
    assign completion_valid = finishing && !killed;

    always_comb begin
        completion           = '0;
        completion.tag       = op_tag;
        completion.result    = div_result;
        completion.exception = 1'b0;
        completion.cause     = EXC_NONE;
        completion.tval      = 32'd0;
    end

    //-------------------------------------------------------------------------
    // Issue operands: magnitudes for the signed forms, identity otherwise.
    //-------------------------------------------------------------------------
    wire in_signed = (issue_req.op == OP_DIV) || (issue_req.op == OP_REM);
    wire [31:0] in_mag_a = (in_signed && issue_req.src1[31]) ? -issue_req.src1
                                                             : issue_req.src1;
    wire [31:0] in_mag_b = (in_signed && issue_req.src2[31]) ? -issue_req.src2
                                                             : issue_req.src2;

    //-------------------------------------------------------------------------
    // State update: issue (guaranteed accept) > kill abort > iteration advance.
    // Issue has priority so that a request latched on the same edge as the
    // final completion performs the can_accept handover.
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            op_tag     <= '0;
            op_rem     <= 1'b0;
            div_zero   <= 1'b0;
            q_neg      <= 1'b0;
            r_neg      <= 1'b0;
            dend_orig  <= 32'd0;
            dend_shift <= 32'd0;
            divisor    <= 32'd0;
            rem        <= 34'd0;
            quo        <= 32'd0;
            iter       <= 4'd0;
        end else if (issue_valid) begin
            busy       <= 1'b1;
            op_tag     <= issue_req.tag;
            op_rem     <= (issue_req.op == OP_REM) || (issue_req.op == OP_REMU);
            div_zero   <= (issue_req.src2 == 32'd0);
            q_neg      <= in_signed & (issue_req.src1[31] ^ issue_req.src2[31]);
            r_neg      <= in_signed & issue_req.src1[31];
            dend_orig  <= issue_req.src1;
            dend_shift <= in_mag_a;
            divisor    <= in_mag_b;
            rem        <= 34'd0;
            quo        <= 32'd0;
            iter       <= 4'd0;
        end else if (killed) begin
            // Flush abort: no completion for this operation, port free again.
            busy <= 1'b0;
            iter <= 4'd0;
        end else if (busy) begin
            if (last_iter) begin
                busy <= 1'b0;
            end else begin
                rem        <= r_next;
                quo        <= quo_next;
                dend_shift <= dend_next;
                iter       <= iter + 4'd1;
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol invariants (backend.md sections 9.5 / 11)
    //-------------------------------------------------------------------------
    a_issue_when_can_accept: assert property (@(posedge clk) disable iff (rst)
        issue_valid |-> can_accept);

    a_kill_wins: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> !kill_mask[completion.tag.slot_index]);

    a_no_completion_without_op: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> busy);
`endif

endmodule
