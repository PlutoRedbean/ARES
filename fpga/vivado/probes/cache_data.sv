// OOC resource probe matching the default cache data instance counts.
module cache_data_probe (
    input logic clk,rst,
    input logic [5:0] i_rd_a,i_rd_b,i_wr_addr,
    input logic [3:0] i_wr_en,
    input logic [255:0] i_wr_data,
    output logic [3:0][255:0] i_data_a,i_data_b,
    input logic [8:0] d_rd_addr,d_wr_addr,
    input logic [1:0] d_rd_en,d_wr_en,
    input logic [1:0][7:0] d_wr_be,
    input logic [63:0] d_wr_data,
    output logic [1:0][63:0] d_data
);
    for(genvar w=0;w<4;w++) begin : g_i
        icache_data_way u_way (
            .clk(clk),.rst(rst),.rd_addr_a(i_rd_a),.rd_addr_b(i_rd_b),
            .wr_addr(i_wr_addr),.wr_en(i_wr_en[w]),.wr_data(i_wr_data),
            .rd_data_a(i_data_a[w]),.rd_data_b(i_data_b[w])
        );
    end
    for(genvar w=0;w<2;w++) begin : g_d
        dcache_data_way u_way (
            .clk(clk),.rd_en(d_rd_en[w]),.rd_addr(d_rd_addr),.rd_data(d_data[w]),
            .wr_en(d_wr_en[w]),.wr_addr(d_wr_addr),.wr_data(d_wr_data),.wr_be(d_wr_be[w])
        );
    end
endmodule
