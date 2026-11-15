`include "common_para.vh"

module PipelineStats_DPIC (
  input clk,
  input rst,
  input retire,
  input pipeline_active,
  input backend_stall,
  input long_stall,
  input issue_hazard,
  input control_redirect,
  input load_replay
);

`ifdef DPIC

  reg [63:0] cycle_cnt;
  reg [63:0] retire_cnt;
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
  reg backend_stall_q;
  reg long_stall_q;
  reg issue_hazard_q;

  initial begin
    cycle_cnt = 0;
    retire_cnt = 0;
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
    backend_stall_q = 0;
    long_stall_q = 0;
    issue_hazard_q = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      cycle_cnt <= 0;
      retire_cnt <= 0;
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
      backend_stall_q <= 0;
      long_stall_q <= 0;
      issue_hazard_q <= 0;
    end else begin
      cycle_cnt <= cycle_cnt + 1;
      backend_stall_q <= backend_stall;
      long_stall_q <= long_stall;
      issue_hazard_q <= issue_hazard;

      if (retire) begin
        retire_cnt <= retire_cnt + 1;
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
    end
  end

  import "DPI-C" function void get_pipeline_counts(
    input longint unsigned cycle_cnt,
    input longint unsigned retire_cnt,
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

  final begin
    get_pipeline_counts(
      cycle_cnt,
      retire_cnt,
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
  end

`endif // DPIC
endmodule
