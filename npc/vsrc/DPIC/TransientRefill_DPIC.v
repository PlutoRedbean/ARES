module TransientRefill_DPIC (
  input clk,
  input rst,
  input candidate,
  input transient_candidate,
  input direct_fire,
  input direct_transient_fire,
  input pending_enqueue,
  input pending_transient_enqueue,
  input pending_fire,
  input pending_transient_fire,
  input pending_wait,
  input candidate_drop,
  input startup_suppressed,
  input pending_flush
);

`ifdef DPIC

  import "DPI-C" function int sim_stats_enabled();

  reg [63:0] candidate_cnt;
  reg [63:0] transient_candidate_cnt;
  reg [63:0] direct_fire_cnt;
  reg [63:0] direct_transient_fire_cnt;
  reg [63:0] pending_enqueue_cnt;
  reg [63:0] pending_transient_enqueue_cnt;
  reg [63:0] pending_fire_cnt;
  reg [63:0] pending_transient_fire_cnt;
  reg [63:0] pending_wait_cnt;
  reg [63:0] candidate_drop_cnt;
  reg [63:0] startup_suppressed_cnt;
  reg [63:0] pending_flush_cnt;

  initial begin
    candidate_cnt = 0;
    transient_candidate_cnt = 0;
    direct_fire_cnt = 0;
    direct_transient_fire_cnt = 0;
    pending_enqueue_cnt = 0;
    pending_transient_enqueue_cnt = 0;
    pending_fire_cnt = 0;
    pending_transient_fire_cnt = 0;
    pending_wait_cnt = 0;
    candidate_drop_cnt = 0;
    startup_suppressed_cnt = 0;
    pending_flush_cnt = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      candidate_cnt <= 0;
      transient_candidate_cnt <= 0;
      direct_fire_cnt <= 0;
      direct_transient_fire_cnt <= 0;
      pending_enqueue_cnt <= 0;
      pending_transient_enqueue_cnt <= 0;
      pending_fire_cnt <= 0;
      pending_transient_fire_cnt <= 0;
      pending_wait_cnt <= 0;
      candidate_drop_cnt <= 0;
      startup_suppressed_cnt <= 0;
      pending_flush_cnt <= 0;
    end else if (sim_stats_enabled() != 0) begin
      if (candidate)
        candidate_cnt <= candidate_cnt + 1;
      if (transient_candidate)
        transient_candidate_cnt <= transient_candidate_cnt + 1;
      if (direct_fire)
        direct_fire_cnt <= direct_fire_cnt + 1;
      if (direct_transient_fire)
        direct_transient_fire_cnt <= direct_transient_fire_cnt + 1;
      if (pending_enqueue)
        pending_enqueue_cnt <= pending_enqueue_cnt + 1;
      if (pending_transient_enqueue)
        pending_transient_enqueue_cnt <= pending_transient_enqueue_cnt + 1;
      if (pending_fire)
        pending_fire_cnt <= pending_fire_cnt + 1;
      if (pending_transient_fire)
        pending_transient_fire_cnt <= pending_transient_fire_cnt + 1;
      if (pending_wait)
        pending_wait_cnt <= pending_wait_cnt + 1;
      if (candidate_drop)
        candidate_drop_cnt <= candidate_drop_cnt + 1;
      if (startup_suppressed)
        startup_suppressed_cnt <= startup_suppressed_cnt + 1;
      if (pending_flush)
        pending_flush_cnt <= pending_flush_cnt + 1;
    end
  end

  import "DPI-C" function void get_transient_refill_counts(
    input longint unsigned candidate_cnt,
    input longint unsigned transient_candidate_cnt,
    input longint unsigned direct_fire_cnt,
    input longint unsigned direct_transient_fire_cnt,
    input longint unsigned pending_enqueue_cnt,
    input longint unsigned pending_transient_enqueue_cnt,
    input longint unsigned pending_fire_cnt,
    input longint unsigned pending_transient_fire_cnt,
    input longint unsigned pending_wait_cnt,
    input longint unsigned candidate_drop_cnt,
    input longint unsigned startup_suppressed_cnt,
    input longint unsigned pending_flush_cnt
  );

  final begin
    get_transient_refill_counts(
      candidate_cnt,
      transient_candidate_cnt,
      direct_fire_cnt,
      direct_transient_fire_cnt,
      pending_enqueue_cnt,
      pending_transient_enqueue_cnt,
      pending_fire_cnt,
      pending_transient_fire_cnt,
      pending_wait_cnt,
      candidate_drop_cnt,
      startup_suppressed_cnt,
      pending_flush_cnt
    );
  end

`endif
endmodule
