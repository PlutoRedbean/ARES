module Mundus_PC(
  input clk,
  input rst,
  input [31:0] din,
  output reg [31:0] dout,
  input wen
);
`ifdef __VERILATOR__
  localparam PC_BASE = `CORE_ENTRY;
`else
  localparam PC_BASE = 32'h80000000;
`endif
  always @(posedge clk) begin
    if (rst) dout <= PC_BASE;
    else if (wen) dout <= din;
  end
endmodule
