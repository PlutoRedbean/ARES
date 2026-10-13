module DRAM(
    input         clk ,
    input  [15:0] a   ,
    output [31:0] spo ,
    input         we  ,
    input  [31:0] d
);

import "DPI-C" function int vaddr_read(input int raddr);
import "DPI-C" function void vaddr_write(input int waddr, input int wdata, input byte len);

  wire [31:0] addr ;
  wire        wen   ;
  reg  [ 1:0] len   ;
  wire [31:0] wdata ;
  reg  [31:0] rdata ;

  wire in_dram = 'h80100000 <= addr && addr < 'h80140000;

  assign addr  = { 14'b1000_0000_0001_00, a, 2'b00  };
  assign wdata = d;
  assign spo   = rdata;

  always @(posedge clk) begin
    if (we) begin
      vaddr_write(addr, wdata, 8'd2);
    end
  end

  always @(*) begin
    if (!in_dram) begin
      rdata = 'd0;
    end
    else begin
      rdata = vaddr_read(addr);
    end
  end

endmodule
