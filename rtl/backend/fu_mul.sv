//=============================================================================
// ARES backend - fu_mul: full MUL / MULH / MULHSU / MULHU pipeline
//-----------------------------------------------------------------------------
// Purpose
//   Fully pipelined multiplier, II = 1, can_accept = 1, fixed latency
//   ares_pkg::MUL_LATENCY (2 or 3 stages, docs/c0_decisions.md D-C0-03).
//   A new request is latched on every clock edge and a completion leaves the
//   last stage every cycle; every pipeline stage holds its own valid bit and
//   tag, so a kill (kill_mask[tag.slot_index]) only clears the matching stage
//   and can never leak a completion for a killed operation, whatever stage the
//   operation has reached.
//
//   Datapath: the unsigned 32x32 product is built from four 16x16 partial
//   products (DSP friendly) and the signed results are derived with high-word
//   corrections:
//     prod_u          = (unsigned)a * (unsigned)b            (exact, 64 bit)
//     MULHU           = prod_u[63:32]
//     MULH            = prod_u[63:32] - (a[31] ? b : 0) - (b[31] ? a : 0)
//     MULHSU          = prod_u[63:32] - (a[31] ? b : 0)      (a signed, b unsigned)
//     MUL             = prod_u[31:0]                         (signedness irrelevant)
//   These identities hold modulo 2^64, so the high word is correct for every
//   operand combination (see the 128-bit reference model in the unit TB).
//
//   Stage usage: stage 1 registers operands, and stage ares_pkg::MUL_LATENCY is the
//   output/completion register.  For ares_pkg::MUL_LATENCY = 3 the partial products are
//   registered in an extra middle stage; for ares_pkg::MUL_LATENCY = 2 the 16x16
//   products and the reduction share the single remaining stage.  Only the two
//   configurations offered by configs/Kconfig (range 2..3) are supported.
//
// Spec sources
//   docs/microarch/backend.md section 9.4   Full MUL definition (per-stage
//                                           pipe_valid + tag, kill semantics)
//   docs/microarch/backend.md section 9     FU latency / II / can_accept table
//   docs/microarch/backend.md section 10    guaranteed-accept request + kill
//   docs/microarch/backend.md section 11    completion protocol invariants
//   docs/implementation_plan.md sections 5.6 / 5.7, module B13
//   docs/c0_decisions.md D-C0-03            ares_pkg::MUL_LATENCY default 3
//
// FREE items exercised
//   FREE-02  file organisation / internal partitioning
//   FREE-04  combinational structure
//   FREE-05  MUL stage count (parameter) and multiplier structure
//   FREE-11  internal pipeline register placement and naming
//
// Verification
//   rtl/backend/test/unit/tb_fu_exec.sv runs both ares_pkg::MUL_LATENCY = 2 and 3;
//   lint and run commands are recorded in that test bench header.
//=============================================================================
module fu_mul (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // imm/pc and the BRU/LSU/CSR-only fields are not read by MUL
    input  ares_pkg::fu_req_t                issue_req,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion
);

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Reduction of the four 16x16 partial products + signed high-word fixup.
    //-------------------------------------------------------------------------
    function automatic logic [31:0] mul_result(input op_t         op,
                                               input logic [31:0] a,
                                               input logic [31:0] b,
                                               input logic [31:0] pp_ll,
                                               input logic [31:0] pp_lh,
                                               input logic [31:0] pp_hl,
                                               input logic [31:0] pp_hh);
        logic [63:0] prod_u;
        logic [31:0] hi;
        begin
            prod_u = {32'd0, pp_ll} + {16'd0, pp_lh, 16'd0}
                   + {16'd0, pp_hl, 16'd0} + {pp_hh, 32'd0};
            hi     = prod_u[63:32];
            case (op)
                OP_MULHU:  mul_result = hi;
                OP_MULH:   mul_result = hi - (a[31] ? b : 32'd0)
                                           - (b[31] ? a : 32'd0);
                OP_MULHSU: mul_result = hi - (a[31] ? b : 32'd0);
                default:   mul_result = prod_u[31:0];   // OP_MUL
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stage 1 - issue register (operands, op, tag)
    //-------------------------------------------------------------------------
    logic        s1_valid;
    tag_t        s1_tag;
    op_t         s1_op;
    logic [31:0] s1_a;
    logic [31:0] s1_b;

    wire s1_kill = s1_valid && kill_mask[s1_tag.slot_index];

    always_ff @(posedge clk) begin
        if (rst) begin
            s1_valid <= 1'b0;
            s1_tag   <= '0;
            s1_op    <= OP_MUL;
            s1_a     <= 32'd0;
            s1_b     <= 32'd0;
        end else begin
            s1_valid <= issue_valid;            // guaranteed accept, II = 1
            if (issue_valid) begin
                s1_tag <= issue_req.tag;
                s1_op  <= issue_req.op;
                s1_a   <= issue_req.src1;
                s1_b   <= issue_req.src2;
            end
        end
    end

    // 16x16 unsigned partial products of the stage-1 operands.
    wire [31:0] pp_ll = s1_a[15:0]  * s1_b[15:0];
    wire [31:0] pp_lh = s1_a[15:0]  * s1_b[31:16];
    wire [31:0] pp_hl = s1_a[31:16] * s1_b[15:0];
    wire [31:0] pp_hh = s1_a[31:16] * s1_b[31:16];

    //-------------------------------------------------------------------------
    // Completion-facing signals, driven by the elaborated pipeline depth.
    //-------------------------------------------------------------------------
    logic        out_valid;
    tag_t        out_tag;
    logic [31:0] out_result;

    wire out_kill = kill_mask[out_tag.slot_index];

    generate
        if (MUL_LATENCY >= 3) begin : g_stage3
            //-----------------------------------------------------------------
            // Stage 2 - registered partial products (timing stage of the 32x32
            // multiply), stage 3 - output/completion register.
            //-----------------------------------------------------------------
            logic        s2_valid;
            tag_t        s2_tag;
            op_t         s2_op;
            logic [31:0] s2_a, s2_b;
            logic [31:0] s2_ll, s2_lh, s2_hl, s2_hh;

            wire s2_kill = s2_valid && kill_mask[s2_tag.slot_index];

            always_ff @(posedge clk) begin
                if (rst) begin
                    s2_valid <= 1'b0;
                    s2_tag   <= '0;
                    s2_op    <= OP_MUL;
                    s2_a     <= 32'd0;
                    s2_b     <= 32'd0;
                    s2_ll    <= 32'd0;
                    s2_lh    <= 32'd0;
                    s2_hl    <= 32'd0;
                    s2_hh    <= 32'd0;
                end else begin
                    s2_valid <= s1_valid && !s1_kill;
                    s2_tag   <= s1_tag;
                    s2_op    <= s1_op;
                    s2_a     <= s1_a;
                    s2_b     <= s1_b;
                    s2_ll    <= pp_ll;
                    s2_lh    <= pp_lh;
                    s2_hl    <= pp_hl;
                    s2_hh    <= pp_hh;
                end
            end

            always_ff @(posedge clk) begin
                if (rst) begin
                    out_valid  <= 1'b0;
                    out_tag    <= '0;
                    out_result <= 32'd0;
                end else begin
                    out_valid  <= s2_valid && !s2_kill;
                    out_tag    <= s2_tag;
                    out_result <= mul_result(s2_op, s2_a, s2_b,
                                             s2_ll, s2_lh, s2_hl, s2_hh);
                end
            end
        end else begin : g_stage2
            //-----------------------------------------------------------------
            // Stage 2 - output/completion register (MUL_LATENCY = 2).
            //-----------------------------------------------------------------
            always_ff @(posedge clk) begin
                if (rst) begin
                    out_valid  <= 1'b0;
                    out_tag    <= '0;
                    out_result <= 32'd0;
                end else begin
                    out_valid  <= s1_valid && !s1_kill;
                    out_tag    <= s1_tag;
                    out_result <= mul_result(s1_op, s1_a, s1_b,
                                             pp_ll, pp_lh, pp_hl, pp_hh);
                end
            end
        end
    endgenerate

    assign completion_valid = out_valid && !out_kill;

    always_comb begin
        completion           = '0;
        completion.tag       = out_tag;
        completion.result    = out_result;
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
        completion_valid |-> out_valid);
`endif

endmodule
