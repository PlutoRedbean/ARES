`include "common_para.vh"
`include "inst_para.vh"

module Mundus_DPIC(
  input clk,
  input rst,
  input [31:0] pc_next_in,
  input cycle_done,
  input interrupt_take,
  input [31:0] interrupt_target,
  input [1:0] retire_mask,
  input [31:0] pc0,
  input [31:0] pc1,
  input [31:0] pc_next0,
  input [31:0] pc_next1,
  input rd_wen0,
  input [4:0] rd_addr0,
  input [31:0] rd_data0,
  input rd_wen1,
  input [4:0] rd_addr1,
  input [31:0] rd_data1,
  input bpu_update_en,
  input [31:0] bpu_update_pc,
  input [31:0] predicted_pc,
  input predicted_taken,
  input [31:0] actual_pc,
  input actual_taken,
`ifdef CONFIG_BRANCH_FAST_RECURRENCE
  input frp_owned,
  input frp_candidate,
  input frp_active,
  input frp_boundary,
  input [1:0] frp_token_created,
  input [1:0] frp_token_consumed,
  input frp_blocked_by_issued,
`endif
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  input loop_meta_valid,
  input loop_candidate,
  input loop_prediction,
  input loop_base_prediction,
`ifdef CONFIG_BP_TAGE
  input tage_meta_valid,
  input tage_prediction,
`endif
`endif
  input [`ENVIR_WIDTH-1:0] environment0,
  input [`ENVIR_WIDTH-1:0] environment1
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

import "DPI-C" function void retire_event_enqueue(
  input int valid,
  input int pc,
  input int pc_next,
  input int rd_wen,
  input int rd_addr,
  input int rd_data,
  input int environment
);
import "DPI-C" function void interrupt_redirect(input int target);
import "DPI-C" function void branch_difftest_queue_update(
  input int update_en,
  input int update_pc,
  input int predicted_pc,
  input int predicted_taken,
  input int actual_taken,
  input int actual_target
);
`ifdef CONFIG_BRANCH_FAST_RECURRENCE
import "DPI-C" function void branch_difftest_frp_update(
  input int valid,
  input int candidate,
  input int active,
  input int boundary,
  input int pc,
  input int predicted_taken,
  input int actual_taken
);
import "DPI-C" function void branch_difftest_frp_activity(
  input int token_created,
  input int token_consumed,
  input int blocked_by_issued
);
`endif
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
import "DPI-C" function void branch_difftest_loop_update(
  input int valid,
  input int pc,
  input int loop_candidate,
  input int loop_prediction,
  input int reference_valid,
  input int reference_prediction,
  input int final_prediction,
  input int actual_taken
);
`endif

  always @(posedge clk) begin
    if (!rst && interrupt_take) begin
      interrupt_redirect(interrupt_target);
    end
    retire_event_enqueue({31'b0, retire_mask[0]}, pc0, pc_next0,
      {31'b0, rd_wen0}, {{(32-5){1'b0}}, rd_addr0}, rd_data0,
      {{(32-`ENVIR_WIDTH){1'b0}}, environment0});
    retire_event_enqueue({31'b0, retire_mask[1]}, pc1, pc_next1,
      {31'b0, rd_wen1}, {{(32-5){1'b0}}, rd_addr1}, rd_data1,
      {{(32-`ENVIR_WIDTH){1'b0}}, environment1});
    branch_difftest_queue_update({31'b0, bpu_update_en}, bpu_update_pc, predicted_pc, {31'b0, predicted_taken}, {31'b0, actual_taken}, actual_pc);
`ifdef CONFIG_BRANCH_FAST_RECURRENCE
    branch_difftest_frp_update({31'b0, bpu_update_en && frp_owned},
      {31'b0, bpu_update_en && frp_candidate},
      {31'b0, bpu_update_en && frp_active},
      {31'b0, bpu_update_en && frp_boundary}, bpu_update_pc,
      {31'b0, predicted_taken}, {31'b0, actual_taken});
    branch_difftest_frp_activity({30'b0, frp_token_created},
      {30'b0, frp_token_consumed}, {31'b0, frp_blocked_by_issued});
`endif
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    branch_difftest_loop_update(
      {31'b0, bpu_update_en && loop_meta_valid}, bpu_update_pc,
      {31'b0, loop_candidate}, {31'b0, loop_prediction},
`ifdef CONFIG_BP_TAGE
      {31'b0, tage_meta_valid}, {31'b0, tage_prediction},
`else
      32'b1, {31'b0, loop_base_prediction},
`endif
      {31'b0, predicted_taken},
      {31'b0, actual_taken});
`endif
  end

// ebreak
import "DPI-C" function void ebreak();

  always @(posedge clk) begin
    if (!rst && retire_mask[0] && environment0 == `ENVIR_EBREAK) begin
      ebreak();
    end
  end

`else   // else DPIC

  always @(posedge clk) begin
    if (!rst && retire_mask[0] && environment0 == `ENVIR_EBREAK) begin
      $finish(0);
    end
  end

`endif  // ifdef DPIC

`endif
endmodule
