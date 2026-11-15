`include "common_para.vh"
module WBU_DPIC (
  input        clk  ,
  input        read ,
  input        write,
  input [31:0] addr 
);

`ifdef DPIC

// Skip the reference only for MMIO locations implemented by the JYD
// peripheral bridge.  Using "!in_mem" here also classified an invalid DRAM
// address as MMIO; an AGU bug could then copy the bad DUT state into NEMU and
// permanently hide the first architectural mismatch.
wire is_jyd_mmio = addr == 32'h8020_0000 ||
                   addr == 32'h8020_0004 ||
                   addr == 32'h8020_0010 ||
                   addr == 32'h8020_0020 ||
                   addr == 32'h8020_0040 ||
                   addr == 32'h8020_0050;

import "DPI-C" function void difftest_skip_ref();

  always @(posedge clk) begin
    if (read || write) begin
      if (is_jyd_mmio) begin
        difftest_skip_ref();
      end
    end
  end

`endif  // ifdef DPIC
endmodule
