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
  input                     bpu_predicted_taken,
  input                     bpu_predicted_slot,
  input                     bpu_predicted_hit,
  input                     frontend_external_redirect,
  input [31:0]              frontend_queue_count,
  input                     frontend_downstream_ready,
  input [31:0]              frontend_dequeue_count,
  input                     frontend_request_candidate,
  input                     frontend_reservation_available,
  input                     frontend_request_fire,
  input [31:0]              frontend_inflight_count,
  input                     frontend_response_usable,
  input [31:0]              frontend_enqueue_count,
  input                     frontend_iq_reservation_available,
  input                     frontend_ftq_reservation_available,
  input [31:0]              frontend_ftq_count,
  input [31:0]              frontend_ftq_alloc_count,
  input [31:0]              frontend_ftq_pop_count,
  input [31:0]              frontend_ftq_rollback_count
`ifdef CONFIG_BP_TAGE
  ,input                    tage_resp_valid
  ,input [PC_WIDTH-1:0]     tage_resp_pc
  ,input [PC_WIDTH-1:0]     tage_provisional_pc
  ,input [PC_WIDTH-1:0]     tage_final_pc
  ,input                    tage_final_taken
  ,input                    tage_override
  ,input                    tage_override_restart
  ,input                    tage_override_blocked
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  ,input                    tage_fast_loop_provisional
  ,input                    tage_override_replaced_loop
`endif
`endif
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
  input int predicted_taken,
  input int predicted_slot,
  input int predicted_hit
);

import "DPI-C" function void branch_difftest_on_frontend_cycle(
  input int external_redirect,
  input int queue_count,
  input int downstream_ready,
  input int dequeue_count,
  input int request_candidate,
  input int reservation_available,
  input int request_fire,
  input int inflight_count,
  input int response_usable,
  input int enqueue_count,
  input int iq_reservation_available,
  input int ftq_reservation_available,
  input int ftq_count,
  input int ftq_alloc_count,
  input int ftq_pop_count,
  input int ftq_rollback_count
);

  always @(negedge clk) begin
    branch_difftest_on_bpu_response({31'b0, bpu_resp_valid}, bpu_resp_pc,
      bpu_predicted_pc, {31'b0, bpu_predicted_taken},
      {31'b0, bpu_predicted_slot}, {31'b0, bpu_predicted_hit});
    branch_difftest_on_frontend_cycle(
      {31'b0, frontend_external_redirect}, frontend_queue_count,
      {31'b0, frontend_downstream_ready}, frontend_dequeue_count,
      {31'b0, frontend_request_candidate},
      {31'b0, frontend_reservation_available},
      {31'b0, frontend_request_fire}, frontend_inflight_count,
      {31'b0, frontend_response_usable}, frontend_enqueue_count,
      {31'b0, frontend_iq_reservation_available},
      {31'b0, frontend_ftq_reservation_available}, frontend_ftq_count,
      frontend_ftq_alloc_count, frontend_ftq_pop_count,
      frontend_ftq_rollback_count);
  end

`ifdef CONFIG_BP_TAGE
import "DPI-C" function void branch_difftest_on_tage_response(
  input int resp_valid,
  input int resp_pc,
  input int provisional_pc,
  input int final_pc,
  input int final_taken
);

import "DPI-C" function void branch_difftest_on_tage_frontend(
  input int override_valid,
  input int restarted,
  input int blocked,
  input int fast_loop_provisional,
  input int override_replaced_loop
);

  always @(negedge clk) begin
    branch_difftest_on_tage_response({31'b0, tage_resp_valid}, tage_resp_pc,
      tage_provisional_pc, tage_final_pc, {31'b0, tage_final_taken});
    branch_difftest_on_tage_frontend({31'b0, tage_override},
      {31'b0, tage_override_restart}, {31'b0, tage_override_blocked},
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
      {31'b0, tage_fast_loop_provisional},
      {31'b0, tage_override_replaced_loop});
`else
      32'b0, 32'b0);
`endif
  end
`endif

/*-------------------------------------*/
`endif  // ifdef DPIC

endmodule
