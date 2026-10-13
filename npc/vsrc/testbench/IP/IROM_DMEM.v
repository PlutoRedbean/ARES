`include "autoconf.vh"
module IROM_DMEM(
  input      [`CONFIG_IROM_ADDR_WIDTH - 1:0] a  ,
  output reg [63:0] spo
);

  wire [31:0] word_index =
    {{(32 - `CONFIG_IROM_ADDR_WIDTH){1'b0}}, a};
  wire [31:0] addr = 32'h8000_0000 + (word_index << 3);

import "DPI-C" function int vaddr_read(input int raddr);

  always @(*) begin
    if (32'h8000_0000 <= addr &&
        addr < 32'h8000_0000 + `CONFIG_IROM_SIZE_BYTES) begin
      spo = {vaddr_read(addr + 4), vaddr_read(addr)};
    end
    else begin
      spo = 'd0;
    end
  end

endmodule
