`include "common_para.vh"

module PipelineStats_DPIC #(
  parameter IQ_COUNT_WIDTH = 4
) (
  input clk,
  input rst,
  input [1:0] retire_count,
  input [1:0] issue_count,
  input [IQ_COUNT_WIDTH-1:0] iq_count,
  input pair_opportunity,
  input pair_success,
  input reject_slot0_serial,
  input reject_slot1_unsupported,
  input reject_shared_resource,
  input reject_waw,
  input reject_raw,
  input reject_slot1_late,
  input waw_only,
  input waw_flat_raw,
  input waw_load_raw,
  input waw_mul_raw,
  input flat_bypass,
  input load_pair_hit,
  input load_pair_replay,
  input pipeline_active,
  input backend_stall,
  input long_stall,
  input issue_hazard,
  input [3:0] stall_primary,
  input [8:0] stall_raw,
  input issue_operand_stall,
  input [3:0] operand_stall_mask,
  input [11:0] operand_producer_stage,
  input [7:0] operand_producer_type,
  input [7:0] operand_consumer_type,
  input [31:0] operand_pc_0,
  input [31:0] operand_pc_1,
  input control_redirect,
  input load_replay,
  input store_overlap_ex1,
  input store_overlap_ex2,
  input store_overlap_ready,
  input store_overlap_not_ready,
  input transient_forward,
  input [2:0] transient_forward_bytes,
  input transient_unknown_addr_stall,
  input transient_data_stall,
  input transient_multi_store,
  input transient_shadowed_not_ready
);

`ifdef DPIC

  import "DPI-C" function int sim_stats_enabled();

  reg [63:0] cycle_cnt;
  reg [63:0] retire_cnt;
  reg [63:0] retire_width_1_cnt;
  reg [63:0] retire_width_2_cnt;
  reg [63:0] issue_width_0_cnt;
  reg [63:0] issue_width_1_cnt;
  reg [63:0] issue_width_2_cnt;
  reg [63:0] iq_empty_cnt;
  reg [63:0] iq_one_cnt;
  reg [63:0] iq_two_plus_cnt;
  reg [63:0] pair_opportunity_cnt;
  reg [63:0] pair_success_cnt;
  reg [63:0] reject_slot0_serial_cnt;
  reg [63:0] reject_slot1_unsupported_cnt;
  reg [63:0] reject_shared_resource_cnt;
  reg [63:0] reject_waw_cnt;
  reg [63:0] reject_raw_cnt;
  reg [63:0] reject_slot1_late_cnt;
  reg [63:0] waw_only_cnt;
  reg [63:0] waw_flat_raw_cnt;
  reg [63:0] waw_load_raw_cnt;
  reg [63:0] waw_mul_raw_cnt;
  reg [63:0] flat_bypass_cnt;
  reg [63:0] load_pair_hit_cnt;
  reg [63:0] load_pair_replay_cnt;
  reg [63:0] no_retire_cnt;
  reg [63:0] active_no_retire_cnt;
  reg [63:0] empty_no_retire_cnt;
  reg [63:0] backend_stall_cycle_cnt;
  reg [63:0] backend_stall_event_cnt;
  reg [63:0] long_stall_cycle_cnt;
  reg [63:0] long_stall_event_cnt;
  reg [63:0] issue_hazard_cycle_cnt;
  reg [63:0] issue_hazard_event_cnt;
  reg [63:0] control_redirect_cnt;
  reg [63:0] load_replay_cnt;
  reg [63:0] store_overlap_ex1_cnt;
  reg [63:0] store_overlap_ex2_cnt;
  reg [63:0] store_overlap_ready_cnt;
  reg [63:0] store_overlap_not_ready_cnt;
  reg [63:0] transient_forward_cnt;
  reg [63:0] transient_forward_byte_cnt;
  reg [63:0] transient_unknown_addr_stall_cnt;
  reg [63:0] transient_data_stall_cnt;
  reg [63:0] transient_multi_store_cnt;
  reg [63:0] transient_shadowed_not_ready_cnt;
  reg [63:0] primary_stall_cycle_cnt;
  reg [63:0] primary_cause_cycle_cnt [0:8];
  reg [63:0] primary_cause_event_cnt [0:8];
  reg [63:0] raw_cause_cycle_cnt [0:8];
  reg backend_stall_q;
  reg long_stall_q;
  reg issue_hazard_q;
  reg [3:0] stall_primary_q;
  integer stall_idx;

  initial begin
    cycle_cnt = 0;
    retire_cnt = 0;
    retire_width_1_cnt = 0;
    retire_width_2_cnt = 0;
    issue_width_0_cnt = 0;
    issue_width_1_cnt = 0;
    issue_width_2_cnt = 0;
    iq_empty_cnt = 0;
    iq_one_cnt = 0;
    iq_two_plus_cnt = 0;
    pair_opportunity_cnt = 0;
    pair_success_cnt = 0;
    reject_slot0_serial_cnt = 0;
    reject_slot1_unsupported_cnt = 0;
    reject_shared_resource_cnt = 0;
    reject_waw_cnt = 0;
    reject_raw_cnt = 0;
    reject_slot1_late_cnt = 0;
    waw_only_cnt = 0;
    waw_flat_raw_cnt = 0;
    waw_load_raw_cnt = 0;
    waw_mul_raw_cnt = 0;
    flat_bypass_cnt = 0;
    load_pair_hit_cnt = 0;
    load_pair_replay_cnt = 0;
    no_retire_cnt = 0;
    active_no_retire_cnt = 0;
    empty_no_retire_cnt = 0;
    backend_stall_cycle_cnt = 0;
    backend_stall_event_cnt = 0;
    long_stall_cycle_cnt = 0;
    long_stall_event_cnt = 0;
    issue_hazard_cycle_cnt = 0;
    issue_hazard_event_cnt = 0;
    control_redirect_cnt = 0;
    load_replay_cnt = 0;
    store_overlap_ex1_cnt = 0;
    store_overlap_ex2_cnt = 0;
    store_overlap_ready_cnt = 0;
    store_overlap_not_ready_cnt = 0;
    transient_forward_cnt = 0;
    transient_forward_byte_cnt = 0;
    transient_unknown_addr_stall_cnt = 0;
    transient_data_stall_cnt = 0;
    transient_multi_store_cnt = 0;
    transient_shadowed_not_ready_cnt = 0;
    primary_stall_cycle_cnt = 0;
    for (stall_idx = 0; stall_idx < 9; stall_idx = stall_idx + 1) begin
      primary_cause_cycle_cnt[stall_idx] = 0;
      primary_cause_event_cnt[stall_idx] = 0;
      raw_cause_cycle_cnt[stall_idx] = 0;
    end
    backend_stall_q = 0;
    long_stall_q = 0;
    issue_hazard_q = 0;
    stall_primary_q = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      cycle_cnt <= 0;
      retire_cnt <= 0;
      retire_width_1_cnt <= 0;
      retire_width_2_cnt <= 0;
      issue_width_0_cnt <= 0;
      issue_width_1_cnt <= 0;
      issue_width_2_cnt <= 0;
      iq_empty_cnt <= 0;
      iq_one_cnt <= 0;
      iq_two_plus_cnt <= 0;
      pair_opportunity_cnt <= 0;
      pair_success_cnt <= 0;
      reject_slot0_serial_cnt <= 0;
      reject_slot1_unsupported_cnt <= 0;
      reject_shared_resource_cnt <= 0;
      reject_waw_cnt <= 0;
      reject_raw_cnt <= 0;
      reject_slot1_late_cnt <= 0;
      waw_only_cnt <= 0;
      waw_flat_raw_cnt <= 0;
      waw_load_raw_cnt <= 0;
      waw_mul_raw_cnt <= 0;
      flat_bypass_cnt <= 0;
      load_pair_hit_cnt <= 0;
      load_pair_replay_cnt <= 0;
      no_retire_cnt <= 0;
      active_no_retire_cnt <= 0;
      empty_no_retire_cnt <= 0;
      backend_stall_cycle_cnt <= 0;
      backend_stall_event_cnt <= 0;
      long_stall_cycle_cnt <= 0;
      long_stall_event_cnt <= 0;
      issue_hazard_cycle_cnt <= 0;
      issue_hazard_event_cnt <= 0;
      control_redirect_cnt <= 0;
      load_replay_cnt <= 0;
      store_overlap_ex1_cnt <= 0;
      store_overlap_ex2_cnt <= 0;
      store_overlap_ready_cnt <= 0;
      store_overlap_not_ready_cnt <= 0;
      transient_forward_cnt <= 0;
      transient_forward_byte_cnt <= 0;
      transient_unknown_addr_stall_cnt <= 0;
      transient_data_stall_cnt <= 0;
      transient_multi_store_cnt <= 0;
      transient_shadowed_not_ready_cnt <= 0;
      primary_stall_cycle_cnt <= 0;
      for (stall_idx = 0; stall_idx < 9; stall_idx = stall_idx + 1) begin
        primary_cause_cycle_cnt[stall_idx] <= 0;
        primary_cause_event_cnt[stall_idx] <= 0;
        raw_cause_cycle_cnt[stall_idx] <= 0;
      end
      backend_stall_q <= 0;
      long_stall_q <= 0;
      issue_hazard_q <= 0;
      stall_primary_q <= 0;
    end else if (sim_stats_enabled() != 0) begin
      cycle_cnt <= cycle_cnt + 1;
      backend_stall_q <= backend_stall;
      long_stall_q <= long_stall;
      issue_hazard_q <= issue_hazard;
      stall_primary_q <= stall_primary;

      case (issue_count)
        2'd0: issue_width_0_cnt <= issue_width_0_cnt + 1;
        2'd1: issue_width_1_cnt <= issue_width_1_cnt + 1;
        2'd2: issue_width_2_cnt <= issue_width_2_cnt + 1;
        default: begin end
      endcase

      if (iq_count == 0) begin
        iq_empty_cnt <= iq_empty_cnt + 1;
      end else if (iq_count == 1) begin
        iq_one_cnt <= iq_one_cnt + 1;
      end else begin
        iq_two_plus_cnt <= iq_two_plus_cnt + 1;
      end

      if (pair_opportunity) pair_opportunity_cnt <= pair_opportunity_cnt + 1;
      if (pair_success) pair_success_cnt <= pair_success_cnt + 1;
      if (reject_slot0_serial)
        reject_slot0_serial_cnt <= reject_slot0_serial_cnt + 1;
      if (reject_slot1_unsupported)
        reject_slot1_unsupported_cnt <= reject_slot1_unsupported_cnt + 1;
      if (reject_shared_resource)
        reject_shared_resource_cnt <= reject_shared_resource_cnt + 1;
      if (reject_waw) reject_waw_cnt <= reject_waw_cnt + 1;
      if (reject_raw) reject_raw_cnt <= reject_raw_cnt + 1;
      if (reject_slot1_late)
        reject_slot1_late_cnt <= reject_slot1_late_cnt + 1;
      if (waw_only) waw_only_cnt <= waw_only_cnt + 1;
      if (waw_flat_raw) waw_flat_raw_cnt <= waw_flat_raw_cnt + 1;
      if (waw_load_raw) waw_load_raw_cnt <= waw_load_raw_cnt + 1;
      if (waw_mul_raw)
        waw_mul_raw_cnt <= waw_mul_raw_cnt + 1;
      if (flat_bypass) flat_bypass_cnt <= flat_bypass_cnt + 1;
      if (load_pair_hit) load_pair_hit_cnt <= load_pair_hit_cnt + 1;
      if (load_pair_replay)
        load_pair_replay_cnt <= load_pair_replay_cnt + 1;

      if (retire_count != 0) begin
        retire_cnt <= retire_cnt + {{62{1'b0}}, retire_count};
        case (retire_count)
          2'd1: retire_width_1_cnt <= retire_width_1_cnt + 1;
          2'd2: retire_width_2_cnt <= retire_width_2_cnt + 1;
          default: begin end
        endcase
      end else begin
        no_retire_cnt <= no_retire_cnt + 1;
        if (pipeline_active) begin
          active_no_retire_cnt <= active_no_retire_cnt + 1;
        end else begin
          empty_no_retire_cnt <= empty_no_retire_cnt + 1;
        end
      end

      if (backend_stall) begin
        backend_stall_cycle_cnt <= backend_stall_cycle_cnt + 1;
      end
      if (backend_stall && !backend_stall_q) begin
        backend_stall_event_cnt <= backend_stall_event_cnt + 1;
      end
      if (long_stall) begin
        long_stall_cycle_cnt <= long_stall_cycle_cnt + 1;
      end
      if (long_stall && !long_stall_q) begin
        long_stall_event_cnt <= long_stall_event_cnt + 1;
      end
      if (issue_hazard) begin
        issue_hazard_cycle_cnt <= issue_hazard_cycle_cnt + 1;
      end
      if (issue_hazard && !issue_hazard_q) begin
        issue_hazard_event_cnt <= issue_hazard_event_cnt + 1;
      end
      if (control_redirect) begin
        control_redirect_cnt <= control_redirect_cnt + 1;
      end
      if (load_replay) begin
        load_replay_cnt <= load_replay_cnt + 1;
      end
      if (store_overlap_ex1) begin
        store_overlap_ex1_cnt <= store_overlap_ex1_cnt + 1;
      end
      if (store_overlap_ex2) begin
        store_overlap_ex2_cnt <= store_overlap_ex2_cnt + 1;
      end
      if (store_overlap_ready) begin
        store_overlap_ready_cnt <= store_overlap_ready_cnt + 1;
      end
      if (store_overlap_not_ready) begin
        store_overlap_not_ready_cnt <= store_overlap_not_ready_cnt + 1;
      end
      if (transient_forward) begin
        transient_forward_cnt <= transient_forward_cnt + 1;
        transient_forward_byte_cnt <= transient_forward_byte_cnt +
          {61'd0, transient_forward_bytes};
      end
      if (transient_unknown_addr_stall) begin
        transient_unknown_addr_stall_cnt <=
          transient_unknown_addr_stall_cnt + 1;
      end
      if (transient_data_stall) begin
        transient_data_stall_cnt <= transient_data_stall_cnt + 1;
      end
      if (transient_multi_store) begin
        transient_multi_store_cnt <= transient_multi_store_cnt + 1;
      end
      if (transient_shadowed_not_ready) begin
        transient_shadowed_not_ready_cnt <=
          transient_shadowed_not_ready_cnt + 1;
      end

      if (stall_primary != 0 && stall_primary <= 9) begin
        primary_stall_cycle_cnt <= primary_stall_cycle_cnt + 1;
        primary_cause_cycle_cnt[stall_primary - 1] <=
          primary_cause_cycle_cnt[stall_primary - 1] + 1;
        if (stall_primary_q != stall_primary) begin
          primary_cause_event_cnt[stall_primary - 1] <=
            primary_cause_event_cnt[stall_primary - 1] + 1;
        end
      end
      for (stall_idx = 0; stall_idx < 9; stall_idx = stall_idx + 1) begin
        if (stall_raw[stall_idx]) begin
          raw_cause_cycle_cnt[stall_idx] <=
            raw_cause_cycle_cnt[stall_idx] + 1;
        end
      end
    end
  end

  import "DPI-C" function void get_pipeline_counts(
    input longint unsigned cycle_cnt,
    input longint unsigned retire_cnt,
    input longint unsigned retire_width_1_cnt,
    input longint unsigned retire_width_2_cnt,
    input longint unsigned issue_width_0_cnt,
    input longint unsigned issue_width_1_cnt,
    input longint unsigned issue_width_2_cnt,
    input longint unsigned iq_empty_cnt,
    input longint unsigned iq_one_cnt,
    input longint unsigned iq_two_plus_cnt,
    input longint unsigned pair_opportunity_cnt,
    input longint unsigned pair_success_cnt,
    input longint unsigned reject_slot0_serial_cnt,
    input longint unsigned reject_slot1_unsupported_cnt,
    input longint unsigned reject_shared_resource_cnt,
    input longint unsigned reject_waw_cnt,
    input longint unsigned reject_raw_cnt,
    input longint unsigned reject_slot1_late_cnt,
    input longint unsigned waw_only_cnt,
    input longint unsigned waw_flat_raw_cnt,
    input longint unsigned waw_load_raw_cnt,
    input longint unsigned waw_mul_raw_cnt,
    input longint unsigned flat_bypass_cnt,
    input longint unsigned load_pair_hit_cnt,
    input longint unsigned load_pair_replay_cnt,
    input longint unsigned no_retire_cnt,
    input longint unsigned active_no_retire_cnt,
    input longint unsigned empty_no_retire_cnt,
    input longint unsigned backend_stall_cycle_cnt,
    input longint unsigned backend_stall_event_cnt,
    input longint unsigned long_stall_cycle_cnt,
    input longint unsigned long_stall_event_cnt,
    input longint unsigned issue_hazard_cycle_cnt,
    input longint unsigned issue_hazard_event_cnt,
    input longint unsigned control_redirect_cnt,
    input longint unsigned load_replay_cnt
  );

  import "DPI-C" function void get_transient_store_forward_counts(
    input longint unsigned store_overlap_ex1_cnt,
    input longint unsigned store_overlap_ex2_cnt,
    input longint unsigned store_overlap_ready_cnt,
    input longint unsigned store_overlap_not_ready_cnt,
    input longint unsigned transient_forward_cnt,
    input longint unsigned transient_forward_byte_cnt,
    input longint unsigned transient_unknown_addr_stall_cnt,
    input longint unsigned transient_data_stall_cnt,
    input longint unsigned transient_multi_store_cnt,
    input longint unsigned transient_shadowed_not_ready_cnt
  );

  // Cause order:
  // 0 WB DIV, 1 backend store, 2 backend load, 3 issue system,
  // 4 issue long, 5 issue store overlap, 6 issue MMIO order,
  // 7 issue load port, 8 issue operand.
  import "DPI-C" function void get_pipeline_stall_counts(
    input longint unsigned primary_stall_cycle_cnt,
    input longint unsigned primary_wb_div_cycle_cnt,
    input longint unsigned primary_backend_store_cycle_cnt,
    input longint unsigned primary_backend_load_cycle_cnt,
    input longint unsigned primary_issue_system_cycle_cnt,
    input longint unsigned primary_issue_long_cycle_cnt,
    input longint unsigned primary_issue_store_overlap_cycle_cnt,
    input longint unsigned primary_issue_mmio_order_cycle_cnt,
    input longint unsigned primary_issue_load_port_cycle_cnt,
    input longint unsigned primary_issue_operand_cycle_cnt,
    input longint unsigned primary_wb_div_event_cnt,
    input longint unsigned primary_backend_store_event_cnt,
    input longint unsigned primary_backend_load_event_cnt,
    input longint unsigned primary_issue_system_event_cnt,
    input longint unsigned primary_issue_long_event_cnt,
    input longint unsigned primary_issue_store_overlap_event_cnt,
    input longint unsigned primary_issue_mmio_order_event_cnt,
    input longint unsigned primary_issue_load_port_event_cnt,
    input longint unsigned primary_issue_operand_event_cnt,
    input longint unsigned raw_wb_div_cycle_cnt,
    input longint unsigned raw_backend_store_cycle_cnt,
    input longint unsigned raw_backend_load_cycle_cnt,
    input longint unsigned raw_issue_system_cycle_cnt,
    input longint unsigned raw_issue_long_cycle_cnt,
    input longint unsigned raw_issue_store_overlap_cycle_cnt,
    input longint unsigned raw_issue_mmio_order_cycle_cnt,
    input longint unsigned raw_issue_load_port_cycle_cnt,
    input longint unsigned raw_issue_operand_cycle_cnt
  );

  import "DPI-C" function void record_issue_operand_stall(
    input int unsigned stall_mask,
    input int unsigned pc0,
    input int unsigned pc1,
    input int unsigned producer_stage,
    input int unsigned producer_type,
    input int unsigned consumer_type
  );

  always @(posedge clk) begin
    if (!rst && (sim_stats_enabled() != 0) && issue_operand_stall) begin
      record_issue_operand_stall(
        {28'b0, operand_stall_mask},
        operand_pc_0,
        operand_pc_1,
        {20'b0, operand_producer_stage},
        {24'b0, operand_producer_type},
        {24'b0, operand_consumer_type}
      );
    end
  end

  final begin
    get_pipeline_counts(
      cycle_cnt,
      retire_cnt,
      retire_width_1_cnt,
      retire_width_2_cnt,
      issue_width_0_cnt,
      issue_width_1_cnt,
      issue_width_2_cnt,
      iq_empty_cnt,
      iq_one_cnt,
      iq_two_plus_cnt,
      pair_opportunity_cnt,
      pair_success_cnt,
      reject_slot0_serial_cnt,
      reject_slot1_unsupported_cnt,
      reject_shared_resource_cnt,
      reject_waw_cnt,
      reject_raw_cnt,
      reject_slot1_late_cnt,
      waw_only_cnt,
      waw_flat_raw_cnt,
      waw_load_raw_cnt,
      waw_mul_raw_cnt,
      flat_bypass_cnt,
      load_pair_hit_cnt,
      load_pair_replay_cnt,
      no_retire_cnt,
      active_no_retire_cnt,
      empty_no_retire_cnt,
      backend_stall_cycle_cnt,
      backend_stall_event_cnt,
      long_stall_cycle_cnt,
      long_stall_event_cnt,
      issue_hazard_cycle_cnt,
      issue_hazard_event_cnt,
      control_redirect_cnt,
      load_replay_cnt
    );
    get_pipeline_stall_counts(
      primary_stall_cycle_cnt,
      primary_cause_cycle_cnt[0],
      primary_cause_cycle_cnt[1],
      primary_cause_cycle_cnt[2],
      primary_cause_cycle_cnt[3],
      primary_cause_cycle_cnt[4],
      primary_cause_cycle_cnt[5],
      primary_cause_cycle_cnt[6],
      primary_cause_cycle_cnt[7],
      primary_cause_cycle_cnt[8],
      primary_cause_event_cnt[0],
      primary_cause_event_cnt[1],
      primary_cause_event_cnt[2],
      primary_cause_event_cnt[3],
      primary_cause_event_cnt[4],
      primary_cause_event_cnt[5],
      primary_cause_event_cnt[6],
      primary_cause_event_cnt[7],
      primary_cause_event_cnt[8],
      raw_cause_cycle_cnt[0],
      raw_cause_cycle_cnt[1],
      raw_cause_cycle_cnt[2],
      raw_cause_cycle_cnt[3],
      raw_cause_cycle_cnt[4],
      raw_cause_cycle_cnt[5],
      raw_cause_cycle_cnt[6],
      raw_cause_cycle_cnt[7],
      raw_cause_cycle_cnt[8]
    );
    get_transient_store_forward_counts(
      store_overlap_ex1_cnt,
      store_overlap_ex2_cnt,
      store_overlap_ready_cnt,
      store_overlap_not_ready_cnt,
      transient_forward_cnt,
      transient_forward_byte_cnt,
      transient_unknown_addr_stall_cnt,
      transient_data_stall_cnt,
      transient_multi_store_cnt,
      transient_shadowed_not_ready_cnt
    );
  end

`endif // DPIC
endmodule
