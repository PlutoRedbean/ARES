`ifdef __VERILATOR__
`include "common_para.vh"
`endif

`ifdef DPIC
import "DPI-C" function void write_reg(input int data, input int addr);
import "DPI-C" function void init_reg(input int data, input int index);
`endif
module RegisterFile #(parameter ADDR_WIDTH = 4, parameter DATA_WIDTH = 32) (
  input                   clk   ,
  input                   wen   ,
  input  [ADDR_WIDTH-1:0] waddr ,
  input  [DATA_WIDTH-1:0] wdata ,
  input                   ren   ,
  input  [ADDR_WIDTH-1:0] raddr1,
  output [DATA_WIDTH-1:0] rdata1,
  input  [ADDR_WIDTH-1:0] raddr2,
  output [DATA_WIDTH-1:0] rdata2
);
  reg [DATA_WIDTH-1:0] rf [2**ADDR_WIDTH-1:1];
  always @(posedge clk) begin
    if (wen) begin
      rf[waddr] <= wdata;
`ifdef DPIC
`ifdef CONFIG_RVE
      write_reg(wdata, {28'd0, waddr});
`else
      write_reg(wdata, {27'd0, waddr});
`endif
`endif
    end
  end

`ifdef DPIC
  integer i;
  initial begin
    for (i = 1; i < 2**ADDR_WIDTH; i = i + 1) begin
      init_reg(rf[i], i);
    end
  end
`endif

  reg [DATA_WIDTH-1:0] rdata1_r;
  reg [DATA_WIDTH-1:0] rdata2_r;
  reg [ADDR_WIDTH-1:0] raddr1_r;
  reg [ADDR_WIDTH-1:0] raddr2_r;
  always @(posedge clk) begin
    if (ren) begin
      raddr1_r <= raddr1;
      if (raddr1 == 0) begin
        rdata1_r <= 0;
      end
      else if (raddr1 == waddr && wen) begin
        rdata1_r <= wdata;
      end
      else begin
        rdata1_r <= rf[raddr1];
      end
    end
    else if (wen && raddr1_r != 0 && waddr == raddr1_r) begin
      // Preserve write-through semantics while the synchronous read port is
      // held for an issue stall, without putting stall logic on the RAM address.
      rdata1_r <= wdata;
    end
  end
  always @(posedge clk) begin
    if (ren) begin
      raddr2_r <= raddr2;
      if (raddr2 == 0) begin
        rdata2_r <= 0;
      end
      else if (raddr2 == waddr && wen) begin
        rdata2_r <= wdata;
      end
      else begin
        rdata2_r <= rf[raddr2];
      end
    end
    else if (wen && raddr2_r != 0 && waddr == raddr2_r) begin
      rdata2_r <= wdata;
    end
  end

  assign rdata1[DATA_WIDTH-1:0] = rdata1_r;
  assign rdata2[DATA_WIDTH-1:0] = rdata2_r;

endmodule
