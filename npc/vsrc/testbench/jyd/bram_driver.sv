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


module bram_driver(
    input  logic         clk,
    input  logic [23:0]  read_addr,
    input  logic         write_valid,
    input  logic [23:0]  write_addr,
    input  logic [31:0]  write_data,
    input  logic [3:0]   write_wea,
    output logic [31:0]  perip_rdata
);
    logic [31:0] bram_rdata_raw;

    BRAM Mem_BRAM (
        .clka       (clk),
`ifdef __VERILATOR__
        // The simulation model spans the full 0x8000_0000-0x80FF_FFFF window so
        // the firmware can keep weights and activations far beyond the on-chip
        // 256 KiB.
        .addra      (write_addr[23:2]),
        .wea        (write_valid ? write_wea : 4'b0000),
        .dina       (write_data),
        .clkb       (clk),
        .addrb      (read_addr[23:2]),
`else
        // The Vivado Block Memory Generator IP is only 65536 x 32, so the
        // hardware build keeps the original 256 KiB address width.
        .addra      (write_addr[17:2]),
        .wea        (write_valid ? write_wea : 4'b0000),
        .dina       (write_data),
        .clkb       (clk),
        .addrb      (read_addr[17:2]),
`endif
        .doutb      (bram_rdata_raw)
    );

    assign perip_rdata = bram_rdata_raw;
endmodule
