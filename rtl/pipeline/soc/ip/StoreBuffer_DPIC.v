module StoreBuffer_DPIC (
  input        clk,
  input        rst,
  input        store_enqueue,
  input        store_dequeue,
  input        read_accept,
  input        read_blocked,
  input        read_conflict,
  input        read_write_overlap,
  input        read_write_same_word,
  input [3:0]  read_forward_mask,
  input [3:0]  staged_forward_mask,
  input        read_blocked_staged_write,
  input        store_blocked,
  input        mmio_write_blocked,
  input [31:0] occupancy,
  input [31:0] depth
);

`ifdef __VERILATOR__

  import "DPI-C" function int sim_stats_enabled();

  reg [63:0] store_enqueue_cnt;
  reg [63:0] store_dequeue_cnt;
  reg [63:0] store_overlap_cnt;
  reg [63:0] read_accept_cnt;
  reg [63:0] read_blocked_cycle_cnt;
  reg [63:0] read_blocked_event_cnt;
  reg [63:0] read_blocked_conflict_cycle_cnt;
  reg [63:0] read_blocked_independent_cycle_cnt;
  reg [63:0] read_write_overlap_cnt;
  reg [63:0] read_write_same_word_cnt;
  reg [63:0] read_forwarded_cnt;
  reg [63:0] read_forwarded_byte_cnt;
  reg [63:0] staged_forwarded_cnt;
  reg [63:0] staged_forwarded_byte_cnt;
  reg [63:0] read_blocked_staged_write_cnt;
  reg [63:0] store_blocked_cycle_cnt;
  reg [63:0] mmio_write_blocked_cycle_cnt;
  reg [63:0] nonempty_cycle_cnt;
  reg [63:0] full_cycle_cnt;
  reg [63:0] occupancy_sum;
  reg [63:0] max_occupancy;
  reg        read_blocked_q;
  wire [63:0] occupancy_ext = {32'd0, occupancy};
  wire [2:0] forwarded_byte_count =
    {2'd0, read_forward_mask[0]} +
    {2'd0, read_forward_mask[1]} +
    {2'd0, read_forward_mask[2]} +
    {2'd0, read_forward_mask[3]};
  wire [2:0] staged_forwarded_byte_count =
    {2'd0, staged_forward_mask[0]} +
    {2'd0, staged_forward_mask[1]} +
    {2'd0, staged_forward_mask[2]} +
    {2'd0, staged_forward_mask[3]};

  initial begin
    store_enqueue_cnt = 0;
    store_dequeue_cnt = 0;
    store_overlap_cnt = 0;
    read_accept_cnt = 0;
    read_blocked_cycle_cnt = 0;
    read_blocked_event_cnt = 0;
    read_blocked_conflict_cycle_cnt = 0;
    read_blocked_independent_cycle_cnt = 0;
    read_write_overlap_cnt = 0;
    read_write_same_word_cnt = 0;
    read_forwarded_cnt = 0;
    read_forwarded_byte_cnt = 0;
    staged_forwarded_cnt = 0;
    staged_forwarded_byte_cnt = 0;
    read_blocked_staged_write_cnt = 0;
    store_blocked_cycle_cnt = 0;
    mmio_write_blocked_cycle_cnt = 0;
    nonempty_cycle_cnt = 0;
    full_cycle_cnt = 0;
    occupancy_sum = 0;
    max_occupancy = 0;
    read_blocked_q = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      store_enqueue_cnt <= 0;
      store_dequeue_cnt <= 0;
      store_overlap_cnt <= 0;
      read_accept_cnt <= 0;
      read_blocked_cycle_cnt <= 0;
      read_blocked_event_cnt <= 0;
      read_blocked_conflict_cycle_cnt <= 0;
      read_blocked_independent_cycle_cnt <= 0;
      read_write_overlap_cnt <= 0;
      read_write_same_word_cnt <= 0;
      read_forwarded_cnt <= 0;
      read_forwarded_byte_cnt <= 0;
      staged_forwarded_cnt <= 0;
      staged_forwarded_byte_cnt <= 0;
      read_blocked_staged_write_cnt <= 0;
      store_blocked_cycle_cnt <= 0;
      mmio_write_blocked_cycle_cnt <= 0;
      nonempty_cycle_cnt <= 0;
      full_cycle_cnt <= 0;
      occupancy_sum <= 0;
      max_occupancy <= 0;
      read_blocked_q <= 0;
    end else if (sim_stats_enabled() != 0) begin
      read_blocked_q <= read_blocked;

      if (store_enqueue) begin
        store_enqueue_cnt <= store_enqueue_cnt + 1;
      end
      if (store_dequeue) begin
        store_dequeue_cnt <= store_dequeue_cnt + 1;
      end
      if (store_enqueue && store_dequeue) begin
        store_overlap_cnt <= store_overlap_cnt + 1;
      end
      if (read_accept) begin
        read_accept_cnt <= read_accept_cnt + 1;
      end
      if (read_blocked) begin
        read_blocked_cycle_cnt <= read_blocked_cycle_cnt + 1;
        if (read_conflict) begin
          read_blocked_conflict_cycle_cnt <=
            read_blocked_conflict_cycle_cnt + 1;
        end else begin
          read_blocked_independent_cycle_cnt <=
            read_blocked_independent_cycle_cnt + 1;
        end
      end
      if (read_blocked && !read_blocked_q) begin
        read_blocked_event_cnt <= read_blocked_event_cnt + 1;
      end
      if (read_write_overlap) begin
        read_write_overlap_cnt <= read_write_overlap_cnt + 1;
      end
      if (read_write_same_word) begin
        read_write_same_word_cnt <= read_write_same_word_cnt + 1;
      end
      if (read_accept && (read_forward_mask != 0)) begin
        read_forwarded_cnt <= read_forwarded_cnt + 1;
        read_forwarded_byte_cnt <= read_forwarded_byte_cnt +
          {61'd0, forwarded_byte_count};
      end
      if (read_accept && (staged_forward_mask != 0)) begin
        staged_forwarded_cnt <= staged_forwarded_cnt + 1;
        staged_forwarded_byte_cnt <= staged_forwarded_byte_cnt +
          {61'd0, staged_forwarded_byte_count};
      end
      if (read_blocked_staged_write) begin
        read_blocked_staged_write_cnt <=
          read_blocked_staged_write_cnt + 1;
      end
      if (store_blocked) begin
        store_blocked_cycle_cnt <= store_blocked_cycle_cnt + 1;
      end
      if (mmio_write_blocked) begin
        mmio_write_blocked_cycle_cnt <= mmio_write_blocked_cycle_cnt + 1;
      end
      if (occupancy != 0) begin
        nonempty_cycle_cnt <= nonempty_cycle_cnt + 1;
      end
      if (occupancy == depth) begin
        full_cycle_cnt <= full_cycle_cnt + 1;
      end

      occupancy_sum <= occupancy_sum + occupancy_ext;
      if (occupancy_ext > max_occupancy) begin
        max_occupancy <= occupancy_ext;
      end
    end
  end

  import "DPI-C" function void get_store_buffer_counts(
    input longint unsigned depth,
    input longint unsigned store_enqueue_cnt,
    input longint unsigned store_dequeue_cnt,
    input longint unsigned store_overlap_cnt,
    input longint unsigned read_accept_cnt,
    input longint unsigned read_blocked_cycle_cnt,
    input longint unsigned read_blocked_event_cnt,
    input longint unsigned read_blocked_conflict_cycle_cnt,
    input longint unsigned read_blocked_independent_cycle_cnt,
    input longint unsigned read_write_overlap_cnt,
    input longint unsigned read_write_same_word_cnt,
    input longint unsigned read_forwarded_cnt,
    input longint unsigned read_forwarded_byte_cnt,
    input longint unsigned staged_forwarded_cnt,
    input longint unsigned staged_forwarded_byte_cnt,
    input longint unsigned read_blocked_staged_write_cnt,
    input longint unsigned store_blocked_cycle_cnt,
    input longint unsigned mmio_write_blocked_cycle_cnt,
    input longint unsigned nonempty_cycle_cnt,
    input longint unsigned full_cycle_cnt,
    input longint unsigned occupancy_sum,
    input longint unsigned max_occupancy
  );

  final begin
    get_store_buffer_counts(
      {32'd0, depth},
      store_enqueue_cnt,
      store_dequeue_cnt,
      store_overlap_cnt,
      read_accept_cnt,
      read_blocked_cycle_cnt,
      read_blocked_event_cnt,
      read_blocked_conflict_cycle_cnt,
      read_blocked_independent_cycle_cnt,
      read_write_overlap_cnt,
      read_write_same_word_cnt,
      read_forwarded_cnt,
      read_forwarded_byte_cnt,
      staged_forwarded_cnt,
      staged_forwarded_byte_cnt,
      read_blocked_staged_write_cnt,
      store_blocked_cycle_cnt,
      mmio_write_blocked_cycle_cnt,
      nonempty_cycle_cnt,
      full_cycle_cnt,
      occupancy_sum,
      max_occupancy
    );
  end

`endif // __VERILATOR__
endmodule
