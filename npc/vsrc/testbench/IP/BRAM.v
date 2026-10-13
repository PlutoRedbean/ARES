module BRAM(
    input         clka  ,
    input  [21:0] addra ,
    input  [ 3:0] wea   ,
    input  [31:0] dina  ,
    input         clkb  ,
    input  [21:0] addrb ,
    output [31:0] doutb
);

import "DPI-C" function int vaddr_read(input int raddr);
import "DPI-C" function void vaddr_write(input int waddr, input int wdata, input byte len);

  wire [31:0] raddr ;
  wire [31:0] waddr ;
  wire        wen   ;
  reg  [ 1:0] offset;
  reg  [ 1:0] len   ;
  reg  [31:0] wdata ;
  reg  [31:0] rdata ;
  reg  [31:0] rdata_q;

  // Word addresses span the whole 0x8000_0000-0x80FF_FFFF DRAM window, so the
  // reconstructed byte address is 0x8000_0000 | (word << 2).  perip_bridge
  // normalises the uncached mirror (0x8030_0000-0x8033_FFFF) before it gets here.
  assign raddr = { 8'b1000_0000, addrb, 2'b00  };
  assign waddr = { 8'b1000_0000, addra, offset };
  assign wen   = wea != 4'b0000;
  // Match the FPGA Block Memory Generator with its core output register
  // enabled: one cycle for the memory array and one cycle for doutb.
  assign doutb = rdata_q;

  always @(*) begin
    case (wea)
      4'b0001 : offset = 2'b00;
      4'b0010 : offset = 2'b01;
      4'b0100 : offset = 2'b10;
      4'b1000 : offset = 2'b11;
      4'b0011 : offset = 2'b00;
      4'b1100 : offset = 2'b10;
      4'b1111 : offset = 2'b00;
      default : offset = 2'b00;
    endcase
  end

  always @(*) begin
    case (wea)
      4'b0001 : len = 2'b00;
      4'b0010 : len = 2'b00;
      4'b0100 : len = 2'b00;
      4'b1000 : len = 2'b00;
      4'b0011 : len = 2'b01;
      4'b1100 : len = 2'b01;
      4'b1111 : len = 2'b10;
      default : len = 2'b11;
    endcase
  end

  always @(*) begin
    case (wea)
      4'b0001 : wdata = { 24'd0, dina[ 7: 0] };
      4'b0010 : wdata = { 24'd0, dina[15: 8] };
      4'b0100 : wdata = { 24'd0, dina[23:16] };
      4'b1000 : wdata = { 24'd0, dina[31:24] };
      4'b0011 : wdata = { 16'd0, dina[15: 0] };
      4'b1100 : wdata = { 16'd0, dina[31:16] };
      4'b1111 : wdata = dina ;
      default : wdata = 32'b0;
    endcase
  end

  always @(posedge clkb) begin
    rdata <= vaddr_read(raddr);
    rdata_q <= rdata;
  end

  always @(posedge clka) begin
    if (wen) begin
      vaddr_write(waddr, wdata, {6'h0, len});
    end
  end

endmodule
