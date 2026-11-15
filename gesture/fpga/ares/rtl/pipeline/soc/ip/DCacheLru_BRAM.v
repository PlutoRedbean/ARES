`include "autoconf.vh"

// Per-set replacement state of the set-associative L1 D-cache: one entry per
// set holding the Way that was most recently filled or hit.  It is read in
// parallel with the tag/data arrays (same registered read latency) so the
// Victim Way of a request is known one cycle later, together with its tag
// comparison, and is carried to the refill by the LSU pipeline.
module DCacheLru_BRAM #(
  parameter integer ENTRY_COUNT = `CONFIG_DCACHE_SIZE_KB * 256 / `CONFIG_DCACHE_WAYS,
  parameter integer INDEX_WIDTH = $clog2(ENTRY_COUNT),
  parameter integer DATA_WIDTH  = (`CONFIG_DCACHE_WAYS > 1) ? $clog2(`CONFIG_DCACHE_WAYS) : 1
) (
  input         clka,
  input         wea,
  input  [INDEX_WIDTH-1:0] addra,
  input  [DATA_WIDTH-1:0]  dina,
  input         clkb,
  input  [INDEX_WIDTH-1:0] addrb,
  output [DATA_WIDTH-1:0]  doutb
);

  (* ram_style = "block" *)
  reg [DATA_WIDTH-1:0] mem [0:ENTRY_COUNT-1];
  reg [DATA_WIDTH-1:0] rdata_r;

  always @(posedge clka) begin
    if (wea) begin
      mem[addra] <= dina;
    end
  end

  always @(posedge clkb) begin
    rdata_r <= mem[addrb];
  end

  assign doutb = rdata_r;
endmodule
