`timescale 1ns/1ps

// One signed INT8 multiply-accumulate processing element. A propagates to
// the right and B propagates downward on every enabled systolic step.
module tensor_pe (
  input  logic clk,
  input  logic rst,
  input  logic clear,
  input  logic step,
  input  logic signed [31:0] acc_init,
  input  logic signed [7:0] a_in,
  input  logic signed [7:0] b_in,
  output logic signed [7:0] a_out,
  output logic signed [7:0] b_out,
  output logic signed [31:0] acc_out
);
  logic signed [15:0] product_q;
  logic product_valid_q;

  // The product is consumed one clock after its systolic step.  Its valid
  // bit also drains the final product when step goes low.
  always_ff @(posedge clk) begin
    product_q <= a_in * b_in;
  end

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      a_out <= '0;
      b_out <= '0;
      acc_out <= acc_init;
      product_valid_q <= 1'b0;
    end else begin
      product_valid_q <= step;
      if (step) begin
        a_out <= a_in;
        b_out <= b_in;
      end
      if (product_valid_q)
        acc_out <= acc_out + {{16{product_q[15]}}, product_q};
    end
  end
endmodule
