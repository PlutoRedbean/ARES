//=============================================================================
// ARES pipeline SoC - 32-bit IROM wrapper (direct jyd SoC modification)
//-----------------------------------------------------------------------------
// The jyd SoC originally exposed a 64-bit IROM pair to myCPU.  The 5-stage
// Mundus core fetches one 32-bit instruction per cycle, so the pipeline SoC
// uses this 32-bit wrapper and removes the 64-bit pair path entirely.
//
// CONFIG_IROM_ADDR_WIDTH is kept as the jyd 64-bit-pair index width (12 for
// 32 KiB).  One extra bit indexes the 8192 32-bit words.
//=============================================================================
`include "autoconf.vh"

module IROM_BMEM32 (
    input  [`CONFIG_IROM_ADDR_WIDTH:0] addra,
    input                              clka,
    output reg [31:0]                  douta
);
    localparam integer DEPTH = 1 << (`CONFIG_IROM_ADDR_WIDTH + 1);

    wire [31:0] word_index = {{(31-`CONFIG_IROM_ADDR_WIDTH){1'b0}}, addra};
    wire [31:0] byte_addr  = 32'h8000_0000 + (word_index << 2);

`ifdef __VERILATOR__
    // Simulation model used by the jyd testbench (DPI vaddr_read).
    import "DPI-C" function int vaddr_read(input int raddr);

    always @(posedge clka) begin
        if (byte_addr >= 32'h8000_0000 &&
            byte_addr < 32'h8000_0000 + `CONFIG_IROM_SIZE_BYTES) begin
            douta <= vaddr_read(byte_addr);
        end else begin
            douta <= 32'd0;
        end
    end
`else
    // Synthesis placeholder.  The Pango BRAM wrapper (with image
    // initialization) is added in the board-integration milestone; this
    // inferred array keeps the 1-cycle read contract.
    reg [31:0] mem [0:DEPTH-1];

    always @(posedge clka) begin
        douta <= mem[addra];
    end
`endif
endmodule
