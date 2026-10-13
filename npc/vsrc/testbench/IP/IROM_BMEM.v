`include "autoconf.vh"
module IROM_BMEM(
  input      [`CONFIG_IROM_ADDR_WIDTH - 1:0] addra ,
  input             clka  ,
  output reg [63:0] douta
);

  wire [31:0] word_index =
    {{(32 - `CONFIG_IROM_ADDR_WIDTH){1'b0}}, addra};
  wire [31:0] addr = 32'h8000_0000 + (word_index << 3);

import "DPI-C" function int vaddr_read(input int raddr);

`ifdef CONFIG_IROM_CORE_OUTPUT_REGISTER
  reg [63:0] memory_output;
`endif

  always @(posedge clka) begin
`ifdef CONFIG_IROM_CORE_OUTPUT_REGISTER
    if (32'h8000_0000 <= addr &&
        addr < 32'h8000_0000 + `CONFIG_IROM_SIZE_BYTES) begin
      memory_output <= {vaddr_read(addr + 4), vaddr_read(addr)};
    end
    else begin
      memory_output <= 'd0;
    end
    douta <= memory_output;
`else
    if (32'h8000_0000 <= addr &&
        addr < 32'h8000_0000 + `CONFIG_IROM_SIZE_BYTES) begin
      douta <= {vaddr_read(addr + 4), vaddr_read(addr)};
    end
    else begin
      douta <= 'd0;
    end
`endif
  end

endmodule
