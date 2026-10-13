module DCache_DPIC (
  input clk,
  input rst,
  input request,
  input write,
  input hit
);

`ifdef DPIC

  import "DPI-C" function int sim_stats_enabled();

  reg [63:0] load_request_cnt;
  reg [63:0] load_hit_cnt;
  reg [63:0] store_request_cnt;
  reg [63:0] store_hit_cnt;

  initial begin
    load_request_cnt = 0;
    load_hit_cnt = 0;
    store_request_cnt = 0;
    store_hit_cnt = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      load_request_cnt <= 0;
      load_hit_cnt <= 0;
      store_request_cnt <= 0;
      store_hit_cnt <= 0;
    end else if ((sim_stats_enabled() != 0) && request) begin
      if (write) begin
        store_request_cnt <= store_request_cnt + 1;
        if (hit) begin
          store_hit_cnt <= store_hit_cnt + 1;
        end
      end else begin
        load_request_cnt <= load_request_cnt + 1;
        if (hit) begin
          load_hit_cnt <= load_hit_cnt + 1;
        end
      end
    end
  end

  import "DPI-C" function void get_dcache_counts(
    input longint unsigned load_request_cnt,
    input longint unsigned load_hit_cnt,
    input longint unsigned store_request_cnt,
    input longint unsigned store_hit_cnt
  );

  final begin
    get_dcache_counts(
      load_request_cnt,
      load_hit_cnt,
      store_request_cnt,
      store_hit_cnt
    );
  end

`endif // DPIC
endmodule
