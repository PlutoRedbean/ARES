`ifdef __VERILATOR__
`include "common_para.vh"
`endif

module RegisterFile_BRAM (
  input  [ 4:0] addra ,
  input         clka  ,
  input  [31:0] dina  ,
  input         wea   ,
  input  [ 4:0] addrb ,
  input         clkb  ,
  output [31:0] doutb
);

  (* ram_style = "block" *)
  reg [31:0] mem [0:31];

  reg [31:0] rdata_r;

  always @(posedge clka) begin
    if (wea) begin
      mem[addra] <= dina;
    end
  end

  // READ_FIRST: on a same-cycle same-address collision, doutb receives the
  // previous memory contents.  The RegisterFile wrapper implements forwarding.
  always @(posedge clkb) begin
    rdata_r <= mem[addrb];
  end

  assign doutb = rdata_r;

endmodule
