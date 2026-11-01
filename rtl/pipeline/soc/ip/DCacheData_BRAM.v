`include "autoconf.vh"

// One way of the set-associative L1 D-cache data array.
// The DCache keeps CONFIG_DCACHE_WAYS independent copies of this RAM, so the
// depth is the number of *sets* (DCACHE_SIZE_KB*256/DCACHE_WAYS).
module DCacheData_BRAM #(
  parameter integer ENTRY_COUNT = `CONFIG_DCACHE_SIZE_KB * 256 / `CONFIG_DCACHE_WAYS,
  parameter integer INDEX_WIDTH = $clog2(ENTRY_COUNT)
) (
  input         clka,
  input         wea,
  input  [INDEX_WIDTH-1:0] addra,
  input  [31:0] dina,
  input         clkb,
  input  [INDEX_WIDTH-1:0] addrb,
  output [31:0] doutb
);

  (* ram_style = "block" *)
  reg [31:0] mem [0:ENTRY_COUNT-1];
  reg [31:0] rdata_r;

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
