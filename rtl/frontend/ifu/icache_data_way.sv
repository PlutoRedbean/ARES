// One cache way: two synchronous reads and one refill, with read-first A
// and held B output on a refill. FPGA storage uses two copies of an SDP
// Block Memory Generator IP: each copy has one read and the shared write.
// This preserves A's old-data collision behavior without a third RAM port.
module icache_data_way #(
    parameter int INDEX_BITS=6,
    parameter int LINE_BITS=256
) (
    input logic clk,rst,
    input logic [INDEX_BITS-1:0] rd_addr_a,rd_addr_b,wr_addr,
    input logic wr_en,
    input logic [LINE_BITS-1:0] wr_data,
    output logic [LINE_BITS-1:0] rd_data_a,rd_data_b
);
`ifdef CONFIG_SIMULATION
`ifndef ARES_CACHE_IP_SIM
`define ARES_ICACHE_BEHAVIORAL
`endif
`endif
`ifdef ARES_ICACHE_BEHAVIORAL
    logic [LINE_BITS-1:0] ram[1<<INDEX_BITS];
    always_ff @(posedge clk) begin
        if(rst) rd_data_a<='0;
        else    rd_data_a<=ram[rd_addr_a];
    end
    always_ff @(posedge clk) begin
        if(!rst && wr_en) ram[wr_addr]<=wr_data;
        if(rst) rd_data_b<='0;
        else if(!wr_en) rd_data_b<=ram[rd_addr_b];
    end
`undef ARES_ICACHE_BEHAVIORAL
`else
    // The IP recipe is generated from the same frozen configuration as RTL.
    initial begin
        if (LINE_BITS != fe_pkg::ICACHE_LINE_BYTES*8 ||
            (1<<INDEX_BITS) != fe_pkg::ICACHE_NR_SETS)
            $error("ICache BRAM IP geometry differs from the generated configuration");
    end
    ares_icache_data_bram u_read_a (
        .clka(clk), .ena(1'b1), .wea(wr_en && !rst), .addra(wr_addr), .dina(wr_data),
        .clkb(clk), .enb(1'b1), .rstb(rst), .addrb(rd_addr_a), .doutb(rd_data_a)
    );
    ares_icache_data_bram u_read_b (
        .clka(clk), .ena(1'b1), .wea(wr_en && !rst), .addra(wr_addr), .dina(wr_data),
        .clkb(clk), .enb(rst || !wr_en), .rstb(rst), .addrb(rd_addr_b), .doutb(rd_data_b)
    );
`endif
endmodule
