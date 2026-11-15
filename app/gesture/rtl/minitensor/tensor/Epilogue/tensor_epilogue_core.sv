`timescale 1ns/1ps

// INT32 bias + fixed-point requantization + optional ReLU for one 4x4 tile.
// Config row format: [15:0] signed multiplier, [20:16] right shift,
// [28:21] signed zero point, [29] ReLU enable.
//
// Two stages.  The bias add and the scale multiply land in scaled_q; the
// shift, zero point, ReLU and saturation run combinationally from it.  The
// 33x16 multiply is built from two cascaded APMs (PO -> PI -> P) and that
// cascade alone is 3.5 ns, so keeping the multiply in the same cycle as the
// rest of the datapath cannot close above ~96 MHz on this device.
//
// The saturation test looks at the sign extension of the shifted value
// instead of comparing two 48-bit magnitudes: the result fits in int8 iff
// bits [47:8] all equal bit 7, which is one XOR/OR reduction per lane
// instead of a 48-bit compare against +127 and -128.
/* verilator lint_off UNUSEDSIGNAL */
module tensor_epilogue_core (
  input  logic         clk,
  input  logic [511:0] c_data,
  input  logic [511:0] bias_data,
  input  logic [127:0] config_data,
  output logic [127:0] output_data
);
  localparam int unsigned LANES = 16;

  logic signed [15:0] multiplier;
  logic        [4:0]  shift_amount;
  logic signed [7:0]  zero_point;
  logic               relu_enable;
  logic signed [47:0] zero_point_value;
  logic signed [47:0] scaled_q [0:LANES-1];
  logic signed [47:0] quantized_value;
  logic               saturated;
  integer mul_i, pack_i;

  always_comb begin
    multiplier = $signed(config_data[15:0]);
    shift_amount = config_data[20:16];
    zero_point = $signed(config_data[28:21]);
    zero_point_value = {{40{zero_point[7]}}, zero_point};
    relu_enable = config_data[29];
  end

  // Stage 1: bias add and scale multiply, registered.  The product needs 49
  // bits; dropping the top bit matches the single-expression form this
  // replaced, which also truncated when a 48-bit variable took the product.
  /* verilator lint_off WIDTHEXPAND */
  // The 48-bit assignment context widens the bias add; c + bias always fits in
  // 33 bits, so the widened add and the 33-bit add are the same value, and the
  // truncated 96-bit product equals the truncated 49-bit product.
  always_ff @(posedge clk) begin
    for (mul_i = 0; mul_i < LANES; mul_i = mul_i + 1)
      scaled_q[mul_i] <= ($signed(c_data[32*mul_i +: 32]) +
                          $signed(bias_data[32*mul_i +: 32])) * $signed(multiplier);
  end
  /* verilator lint_on WIDTHEXPAND */

  // Stage 2: shift, zero point, ReLU, saturation and pack.
  always_comb begin
    output_data = '0;
    for (pack_i = 0; pack_i < LANES; pack_i = pack_i + 1) begin
      quantized_value = (scaled_q[pack_i] >>> shift_amount) + zero_point_value;
      saturated = |(quantized_value[47:8] ^ {40{quantized_value[7]}});
      if (relu_enable && quantized_value[47])
        output_data[8*pack_i +: 8] = 8'h00;
      else if (saturated)
        output_data[8*pack_i +: 8] = quantized_value[47] ? 8'h80 : 8'h7f;
      else
        output_data[8*pack_i +: 8] = quantized_value[7:0];
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
