`include "autoconf.vh"

// One way of the set-associative L1 D-cache directory.  The word is
// {valid, tag}; the tag is addr[17:12] for the 8 KiB / 2-way geometry
// (0x8010_0000-0x8013_ffff is the only cacheable window).
module DCacheTag_BRAM #(
  parameter integer ENTRY_COUNT = `CONFIG_DCACHE_SIZE_KB * 256 / `CONFIG_DCACHE_WAYS,
  parameter integer INDEX_WIDTH = $clog2(ENTRY_COUNT),
  parameter integer TAG_WIDTH = 18 - INDEX_WIDTH - 2
) (
  input         clka,
  input         wea,
  input  [INDEX_WIDTH-1:0] addra,
  input  [TAG_WIDTH:0] dina,
  input         clkb,
  input  [INDEX_WIDTH-1:0] addrb,
  output [TAG_WIDTH:0] doutb
);

  (* ram_style = "block" *)
  reg [TAG_WIDTH:0] mem [0:ENTRY_COUNT-1];
  reg [TAG_WIDTH:0] rdata_r;

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
