// One DCache way: 512 x 64-bit rows, independent 1R1W ports and byte writes.
// Data is never reset; rd_en gates the one-cycle read and holds its output.
module dcache_data_way #(
    parameter int ADDR_BITS=9
) (
    input logic clk,
    input logic rd_en,
    input logic [ADDR_BITS-1:0] rd_addr,
    output logic [63:0] rd_data,
    input logic wr_en,
    input logic [ADDR_BITS-1:0] wr_addr,
    input logic [63:0] wr_data,
    input logic [7:0] wr_be
);
`ifdef CONFIG_SIMULATION
`ifndef ARES_CACHE_IP_SIM
`define ARES_DCACHE_BEHAVIORAL
`endif
`endif
`ifdef ARES_DCACHE_BEHAVIORAL
    logic [63:0] ram[1<<ADDR_BITS];
    always_ff @(posedge clk) begin
        if (rd_en) rd_data <= ram[rd_addr];
        if (wr_en)
            for (int b=0; b<8; b++)
                if (wr_be[b]) ram[wr_addr][8*b+:8] <= wr_data[8*b+:8];
    end
`undef ARES_DCACHE_BEHAVIORAL
`else
    initial begin
        if (ADDR_BITS != 9)
            $error("DCache BRAM IP requires 512 rows per way");
    end
    ares_dcache_data_bram u_rows (
        .clka(clk), .ena(1'b1), .wea(wr_be & {8{wr_en}}), .addra(wr_addr), .dina(wr_data),
        .clkb(clk), .enb(rd_en), .addrb(rd_addr), .doutb(rd_data)
    );
`endif
endmodule
