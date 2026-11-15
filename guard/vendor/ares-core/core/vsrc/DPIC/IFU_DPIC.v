`include "SRAM_para.vh"
`include "common_para.vh"
`include "AXI_para.vh"
module IFU_DPIC #(
  PC_WIDTH = 32
)
(
  input                     clk         ,

  input                     valid       ,
  input                     bpu_resp_valid,
  input  [PC_WIDTH-1:0]     bpu_resp_pc,
  input  [PC_WIDTH-1:0]     bpu_predicted_pc,
  input                     bpu_predicted_taken
/*-------------------------------------*/
);

`ifdef DPIC
/*-----------------DPI-C---------------*/

`ifdef CONFIG_IF_COUNTER

import "DPI-C" function void if_cnt_add();

  always @(posedge valid) begin
    if (valid) if_cnt_add();
  end

`endif  // ifdef CONFIG_IF_COUNTER

import "DPI-C" function void branch_difftest_on_bpu_response(
  input int resp_valid,
  input int resp_pc,
  input int predicted_pc,
  input int predicted_taken
);

  always @(negedge clk) begin
    branch_difftest_on_bpu_response({31'b0, bpu_resp_valid}, bpu_resp_pc,
      bpu_predicted_pc, {31'b0, bpu_predicted_taken});
  end

/*-------------------------------------*/
`endif  // ifdef DPIC

endmodule
