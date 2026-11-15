`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/22/2025 11:42:01 AM
// Design Name: 
// Module Name: bram_driver
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module bram_driver #(
    // Per-hart DRAM geometry.  DRAM_AW is the word-address width of the
    // inferred BRAM (16 = 256 KiB single-hart, 13 = 32 KiB per-hart AMP
    // window); DRAM_INIT_FILE is the matching $readmemh image.  The address
    // slicing lives in soc/pango/pipeline_bram.v, so nothing below has to
    // change when the window shrinks.
    parameter integer DRAM_AW        = 16,
    parameter         DRAM_INIT_FILE = "build/pipeline/dram.hex"
)(
    input  wire         clk,
    input  wire [17:0]  read_addr,
    input  wire         write_valid,
    input  wire [17:0]  write_addr,
    input  wire [31:0]  write_data,
    input  wire [3:0]   write_wea,
    output wire [31:0]  perip_rdata
);
    wire [31:0] bram_rdata_raw;

    BRAM #(
        .DRAM_AW        (DRAM_AW),
        .DRAM_INIT_FILE (DRAM_INIT_FILE)
    ) Mem_BRAM (
        .clka       (clk),
        .addra      (write_addr[17:2]),
        .wea        (write_valid ? write_wea : 4'b0000),
        .dina       (write_data),
        .clkb       (clk),
        .addrb      (read_addr[17:2]),
        .doutb      (bram_rdata_raw)
    );

    assign perip_rdata = bram_rdata_raw;
endmodule
