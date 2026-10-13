`include "autoconf.vh"

module DCacheData_BRAM #(
  // The configured capacity is the total D-cache capacity.  The RTL creates
  // two instances selected by addr[2], so each behavioral bank owns half of
  // the 32-bit entries.
  parameter integer ENTRY_COUNT = `CONFIG_DCACHE_SIZE_KB * 128,
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
