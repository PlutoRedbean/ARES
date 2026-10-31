//=============================================================================
// pipeline SoC - div: unsigned 32-bit DIV/REM, iterative radix-4 datapath
//-----------------------------------------------------------------------------
// Purpose
//   AXIS-shaped divider behind Mundus/EXU/DIV.  The port list, the LATENCY
//   parameter and the cycle at which a result appears are unchanged; only the
//   datapath is different.  This used to be
//       wire [31:0] quotient  = dividend / divisor;
//       wire [31:0] remainder = dividend % divisor;
//   which PDS expanded into a single-cycle 32-stage restoring array: 291
//   logic levels, 215 CLMA and 257 carry cells on one path, 60.7 ns arrival
//   on pipeline_amp_board_top (PG2L200H-6, cpu_clk 100 MHz).  The LATENCY
//   shift register behind it only delayed that result; it never broke the
//   combinational cone, so the cone stayed the design WNS (-46.1 ns) and two
//   copies (one per hart) also sat in the most congested hart windows.
//
// Structure
//   * operands are latched on the fire edge (one outstanding request),
//   * 16 radix-4 iterations, one per clock: three parallel compare/subtract
//     chains select the quotient digit {0,1,2,3} and the next remainder,
//   * the remainder invariant rem < divisor makes r_shift = 4*rem + 2 bits
//     smaller than 4*divisor, so the selected digit is exact,
//   * the 64-bit result is held until the next request, so a fixed-latency
//     consumer (DIV in Mundus.sv counts 35 cycles) samples the same value it
//     used to,
//   * m_axis_dout_tvalid is still the fire pulse delayed by LATENCY.
//
// Timing contract
//   LATENCY must be >= 17 (16 iterations plus the launch edge).  At the
//   default 35 the result is stable from cycle fire+17 onward and is held, so
//   the existing 35-cycle consumer needs no change.  Lowering
//   CONFIG_DIV_LATENCY also requires lowering the DIV terminal count in
//   Mundus.sv (6'h23); that is a separate, deliberate step.
//
//   At most one request may be in flight.  DIV only re-arms once its counter
//   reaches div_terminal, i.e. at least 36 cycles after the previous start, so
//   a fire while busy is ignored and cannot corrupt an operation in progress.
//   Both tready outputs are tied high, so fire == both tvalids.
//
// Semantics (unchanged)
//   divisor == 0 : quotient = 32'hFFFF_FFFF, remainder = dividend.
//   This module is unsigned and is fed magnitudes; Mundus/EXU/DIV applies the
//   quotient and remainder signs when it captures the result.
//
// Verification
//   rtl/pipeline/test/tb_div.sv - directed boundaries plus random pairs
//   against a reference model, with result latency and hold checks.
//   Run it with 'make pipeline-div-test' (Icarus, ~2 s).
//=============================================================================
`include "common_para.vh"
module div #(
    parameter LATENCY = `CONFIG_DIV_LATENCY
)(
    input         aclk                  ,
    input  [31:0] s_axis_dividend_tdata ,
    output        s_axis_dividend_tready,
    input         s_axis_dividend_tvalid,
    input  [31:0] s_axis_divisor_tdata  ,
    output        s_axis_divisor_tready ,
    input         s_axis_divisor_tvalid ,
    output [63:0] m_axis_dout_tdata     ,
    output        m_axis_dout_tvalid
);

    localparam [3:0] ITER_LAST = 4'd15;   // 16 radix-4 iterations cover 32 bits

    wire fire = s_axis_dividend_tvalid && s_axis_divisor_tvalid;

    reg        busy;
    reg  [3:0] iter;
    reg [31:0] dend;      // remaining dividend bits, MSB first
    reg [31:0] divisor;   // divisor magnitude
    // rem never exceeds 2^32-1 and quo only reaches bit 29 before the final
    // digit is appended, so the wide bits are intentionally unused.
    /* verilator lint_off UNUSEDSIGNAL */
    reg [33:0] rem;       // running remainder, always < divisor
    reg [31:0] quo;       // accumulated quotient
    /* verilator lint_on UNUSEDSIGNAL */
    reg [63:0] dout;      // {quotient, remainder}, held between requests

    //-------------------------------------------------------------------------
    // Radix-4 iteration datapath: three parallel compare/subtract chains pick
    // the quotient digit {0,1,2,3}; rem < divisor guarantees r_shift =
    // 4*rem + 2 bits < 4*divisor, so the digit is exact.  Explicit unsigned
    // comparisons are used instead of a borrow bit because 3*divisor can
    // exceed 2^33 and wrap.
    //-------------------------------------------------------------------------
    wire [33:0] b1      = {2'b00, divisor};
    wire [33:0] b2      = b1 << 1;               // 2*divisor (< 2^33)
    wire [33:0] b3      = b1 + b2;               // 3*divisor (< 2^34)
    wire [33:0] r_shift = {rem[31:0], dend[31:30]};
    wire [33:0] d1      = r_shift - b1;
    wire [33:0] d2      = r_shift - b2;
    wire [33:0] d3      = r_shift - b3;
    wire [1:0] digit    = (r_shift >= b3) ? 2'd3 :
                          (r_shift >= b2) ? 2'd2 :
                          (r_shift >= b1) ? 2'd1 : 2'd0;
    wire [33:0] r_next  = (digit == 2'd3) ? d3 :
                          (digit == 2'd2) ? d2 :
                          (digit == 2'd1) ? d1 : r_shift;
    wire [31:0] quo_next  = {quo[29:0], digit};
    wire [31:0] dend_next = {dend[29:0], 2'b00};

    //-------------------------------------------------------------------------
    // Request bookkeeping and result register
    //-------------------------------------------------------------------------
    reg [LATENCY-1:0] valid_pipe;
    integer i;

    initial begin
        valid_pipe = {LATENCY{1'b0}};
        busy       = 1'b0;
        iter       = 4'd0;
        dend       = 32'd0;
        divisor    = 32'd0;
        rem        = 34'd0;
        quo        = 32'd0;
        dout       = 64'd0;
    end

    always @(posedge aclk) begin
        valid_pipe[0] <= fire && !busy;
        for (i = 1; i < LATENCY; i = i + 1) begin
            valid_pipe[i] <= valid_pipe[i - 1];
        end
    end

    always @(posedge aclk) begin
        if (fire && !busy) begin
            if (s_axis_divisor_tdata == 32'd0) begin
                // RV32M divide-by-zero: quotient = -1, remainder = dividend.
                dout <= {32'hFFFF_FFFF, s_axis_dividend_tdata};
            end else begin
                busy    <= 1'b1;
                iter    <= 4'd0;
                dend    <= s_axis_dividend_tdata;
                divisor <= s_axis_divisor_tdata;
                rem     <= 34'd0;
                quo     <= 32'd0;
            end
        end else if (busy) begin
            if (iter == ITER_LAST) begin
                busy <= 1'b0;
                dout <= {quo_next, r_next[31:0]};
            end else begin
                iter <= iter + 4'd1;
                dend <= dend_next;
                rem  <= r_next;
                quo  <= quo_next;
            end
        end
    end

    assign s_axis_dividend_tready = 1'b1;
    assign s_axis_divisor_tready  = 1'b1;
    assign m_axis_dout_tdata      = dout;
    assign m_axis_dout_tvalid     = valid_pipe[LATENCY - 1];

endmodule
