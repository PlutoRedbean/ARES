module Mundus_PC(
  input clk,
  input rst,
  input [31:0] din,
  output reg [31:0] dout,
  input wen
);
// ARES application entry.  The application boot ROM sits at 0x0000_0000 and
// either trampolines to the image loaded at 0x8000_0000 (simulation) or runs
// the UART loader and jumps there (board).  The ARES mainline SoC enters at
// 0x8000_0000; both application projects override that here so the same core
// RTL boots identically in simulation and on the board.  Define CORE_ENTRY to
// take the address from autoconf.vh instead.
`ifdef CORE_ENTRY
  localparam PC_BASE = `CORE_ENTRY;
`else
  localparam PC_BASE = 32'h00000000;
`endif
  always @(posedge clk) begin
    if (rst) dout <= PC_BASE;
    else if (wen) dout <= din;
  end
endmodule
