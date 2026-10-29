`include "common_para.vh"
module LSU_DPIC (
  input        clk  ,
  input        rst  ,
  input        read ,
  input        write,
  input [31:0] addr ,
  input [31:0] rdata,
  input [31:0] wdata,
  input [ 2:0] bytes
);

`ifdef CONFIG_MTRACE

import "DPI-C" function void mread_trace(input int raddr, input int rdata, input byte mem_bytes);
import "DPI-C" function void mwrite_trace(input int waddr, input int wdata, input byte mem_bytes);

  always @(posedge clk) begin
    if (~rst) begin
      if (read) begin
        mread_trace(addr, rdata, { 5'd0, bytes });
      end
      else if (write) begin
        mwrite_trace(addr, wdata, { 5'd0, bytes });
      end
    end
  end

`endif  // ifdef CONFIG_MTRACE
endmodule
