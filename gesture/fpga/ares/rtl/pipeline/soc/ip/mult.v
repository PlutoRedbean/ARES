`include "common_para.vh"
//=============================================================================
// mult - 33 x 33 signed multiplier, 4-stage partial-product pipeline
//-----------------------------------------------------------------------------
// A and B carry a 32-bit value plus an explicit sign bit (bit 32), i.e. they
// are 33-bit two's complement numbers.  P is the low 64 bits of the product,
// which is what RV32M needs: WBU selects P[31:0] (MUL) or P[63:32] (MULH*).
//
// Why this shape
// --------------
// WBU sits four pipeline stages behind EX1, so the multiplier must deliver a
// result 4 clocks after the operands are presented -- no stall, no scoreboard.
// The previous body built the whole 33x33 product combinationally and then
// shifted it through PIPELINE_STAGES registers: it paid the 4-cycle latency
// without buying any timing, because the product was still one long
// carry-propagate cone (measured 5-6 ns on PG2L200H-6, the slowest logic in
// the core after the accelerators).
//
// Here the product is built from four 18x18 partial products and the adder
// tree is spread over the four stages, so the latency stays 4 while every
// stage keeps one arithmetic operator:
//
//   A = a_hi * 2^17 + a_lo        (a_lo: 17-bit unsigned, a_hi: 16-bit signed)
//   B = b_hi * 2^17 + b_lo
//
//   A*B = a_hi*b_hi * 2^34 + (a_lo*b_hi + a_hi*b_lo) * 2^17 + a_lo*b_lo
//
//   edge n+1: p_ll/p_lh/p_hl/p_hh <- four 18x18 multiplies
//   edge n+2: lo = (p_lh << 17) + p_ll          (low half of the tree)
//             hi = (p_hl << 17) + (p_hh << 34)  (high half, independent adder)
//   edge n+3: sum = lo + hi
//   edge n+4: P   = sum
//
// The two halves are summed in parallel so all four partial products travel
// through the same number of registers; chaining them (lo -> +hi -> +hh) would
// let the high terms arrive one or two cycles early and mix two different
// multiplies into one result.
//
// The sums are truncated to 64 bits on purpose: bits above 63 cannot influence
// the low 64 bits, and the carry chains stay 64 bits instead of 66.  Every
// partial product is sign-extended before it is shifted, because zero
// extension would be wrong for negative a_hi/b_hi.
//
// PIPELINE_STAGES must stay >= 4.  Extra stages are appended as plain pipeline
// registers so the module keeps working if CONFIG_MUL_LATENCY is ever raised;
// that constant is shared with the core, which relies on the latency matching
// the EX1 -> WBU distance.
//=============================================================================
module mult #(
    parameter PIPELINE_STAGES = `CONFIG_MUL_LATENCY
)(
    input         CLK   ,
    input         CE    ,
    input  [32:0] A     ,
    input  [32:0] B     ,
    output [63:0] P
);

    // Partial-product container.  17x17 unsigned needs 34 bits; the extra bits
    // keep all four terms in one signed shape and let synthesis trim the top.
    localparam integer PW = 36;

    // a_lo/b_lo: 17-bit unsigned fields widened to 18-bit signed (always
    // non-negative, so the extra bit is a clean sign bit).
    wire signed [17:0] a_lo = { 1'b0, A[16:0] };
    wire signed [17:0] b_lo = { 1'b0, B[16:0] };
    // a_hi/b_hi: 16-bit signed fields; A[32] is the sign of the 33-bit value.
    wire signed [17:0] a_hi = { {2{A[32]}}, A[32:17] };
    wire signed [17:0] b_hi = { {2{B[32]}}, B[32:17] };

    wire signed [PW-1:0] p_ll = a_lo * b_lo;
    wire signed [PW-1:0] p_lh = a_lo * b_hi;
    wire signed [PW-1:0] p_hl = a_hi * b_lo;
    wire signed [PW-1:0] p_hh = a_hi * b_hi;

    //---- stage 0 -------------------------------------------------------------
    reg signed [PW-1:0] p_ll_q;
    reg signed [PW-1:0] p_lh_q;
    reg signed [PW-1:0] p_hl_q;
    reg signed [PW-1:0] p_hh_q;

    //---- stages 1..3 ---------------------------------------------------------
    reg signed [63:0] lo_q;
    reg signed [63:0] hi_q;
    reg signed [63:0] sum_q;
    reg signed [63:0] acc_q;

    wire signed [63:0] ll_x = { {64-PW{p_ll_q[PW-1]}}, p_ll_q };
    wire signed [63:0] lh_x = { {64-PW{p_lh_q[PW-1]}}, p_lh_q };
    wire signed [63:0] hl_x = { {64-PW{p_hl_q[PW-1]}}, p_hl_q };
    wire signed [63:0] hh_x = { {64-PW{p_hh_q[PW-1]}}, p_hh_q };

    always @(posedge CLK) begin
        if (CE) begin
            p_ll_q <= p_ll;
            p_lh_q <= p_lh;
            p_hl_q <= p_hl;
            p_hh_q <= p_hh;

            lo_q  <= (lh_x << 17) + ll_x;
            hi_q  <= (hl_x << 17) + (hh_x << 34);
            sum_q <= lo_q + hi_q;
            acc_q <= sum_q;
        end
    end

    // Simulation-only initial state.  Like the previous version there is no
    // reset: the multiplier is gated by CE and its output is only consumed
    // after a real fire.
    initial begin
        p_ll_q = {PW{1'b0}};
        p_lh_q = {PW{1'b0}};
        p_hl_q = {PW{1'b0}};
        p_hh_q = {PW{1'b0}};
        lo_q   = 64'b0;
        hi_q   = 64'b0;
        sum_q  = 64'b0;
        acc_q  = 64'b0;
    end

    //---- latency ------------------------------------------------------------
    generate
        if (PIPELINE_STAGES < 4) begin : g_latency_error
            // The partial-product tree needs four stages; a shorter latency
            // would silently drop the adder stages.
            MUL_PIPELINE_STAGES_must_be_at_least_4 u_latency_error ();
        end else if (PIPELINE_STAGES == 4) begin : g_latency_4
            assign P = acc_q;
        end else begin : g_latency_gt4
            reg [63:0] tail_q [0:PIPELINE_STAGES-5];
            integer t;

            initial begin
                for (t = 0; t < PIPELINE_STAGES - 4; t = t + 1)
                    tail_q[t] = 64'b0;
            end

            always @(posedge CLK) begin
                if (CE) begin
                    tail_q[0] <= acc_q;
                    for (t = 1; t < PIPELINE_STAGES - 4; t = t + 1)
                        tail_q[t] <= tail_q[t - 1];
                end
            end

            assign P = tail_q[PIPELINE_STAGES - 5];
        end
    endgenerate

endmodule
