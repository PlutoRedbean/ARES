`include "autoconf.vh"

module TageTable_BRAM #(
  parameter ADDR_WIDTH = `CONFIG_BRANCH_TAGE_INDEX_BITS,
  parameter DATA_WIDTH = `CONFIG_BRANCH_TAGE_TAG_BITS + 6
) (
  input         clka,
  input         wea,
  input  [ADDR_WIDTH-1:0] addra,
  input  [DATA_WIDTH-1:0] dina,
  input         clkb,
  input  [ADDR_WIDTH-1:0] addrb,
  output [DATA_WIDTH-1:0] doutb
);

  localparam DEPTH = 1 << ADDR_WIDTH;

  reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  reg [DATA_WIDTH-1:0] rdata_r;

  always @(posedge clka) begin
    if (wea) begin
      mem[addra] <= dina;
    end
  end

  // Match the one-cycle, read-first Simple Dual Port RAM IP behavior.
  always @(posedge clkb) begin
    rdata_r <= mem[addrb];
  end

  assign doutb = rdata_r;
endmodule
