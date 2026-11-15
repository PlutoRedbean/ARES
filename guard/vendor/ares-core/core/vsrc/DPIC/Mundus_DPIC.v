`include "common_para.vh"
`include "inst_para.vh"

module Mundus_DPIC(
  input clk,
  input rst,
  input [31:0] pc_next_in,
  input cycle_done,
  input bpu_update_en,
  input [31:0] bpu_update_pc,
  input [31:0] predicted_pc,
  input predicted_taken,
  input [31:0] actual_pc,
  input actual_taken,
  input [`ENVIR_WIDTH-1:0] environment
);

`ifdef CONFIG_SIMULATION

  wire [31:0] pc;

  Mundus_PC u_Mundus_PC(
    .clk  	(clk        ),
    .rst  	(rst        ),
    .din  	(pc_next_in ),
    .dout 	(pc         ),
    .wen  	(cycle_done )
  );
  

`ifdef DPIC
import "DPI-C" function void get_npc_pc(input int pc);
import "DPI-C" function void get_npc_pc_next(input int pc_next);

  always @(pc, pc_next_in) begin
    get_npc_pc(pc);
    get_npc_pc_next(pc_next_in);
  end

import "DPI-C" function void inst_done(input bit done);
import "DPI-C" function void branch_difftest_queue_update(
  input int update_en,
  input int update_pc,
  input int predicted_pc,
  input int predicted_taken,
  input int actual_taken,
  input int actual_target
);

  always @(posedge clk) begin
    inst_done(cycle_done);
    branch_difftest_queue_update({31'b0, bpu_update_en}, bpu_update_pc, predicted_pc, {31'b0, predicted_taken}, {31'b0, actual_taken}, actual_pc);
  end

// ebreak
import "DPI-C" function void ebreak();

  always @(posedge clk) begin
    if (!rst && cycle_done && environment == `ENVIR_EBREAK) begin // ENVIR_EBREAK
      ebreak();
    end
  end

`else   // else DPIC

  always @(posedge clk) begin
    if (!rst && cycle_done && environment == `ENVIR_EBREAK) begin // ENVIR_EBREAK
      $finish(0);
    end
  end

`endif  // ifdef DPIC

`endif
endmodule
