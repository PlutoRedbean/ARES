`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/16/2025 06:21:44 PM
// Design Name: 
// Module Name: top
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


module top #(
    // Set to 0 to restore the original digital-twin UART protocol.
    parameter bit P_UART_CONSOLE = 1'b1
) (
    input  wire i_sys_clk_p         ,
    input  wire i_sys_clk_n         ,
    input  wire i_uart_rx           ,
    output wire o_uart_tx           ,

    output wire [31:0] virtual_led  ,
    output wire [39:0] virtual_seg
);

    wire w_clk_50Mhz, cpu_clk;
    wire w_clk_rst;

    wire [7:0] virtual_key;
    wire [63:0] virtual_sw;

    wire [7:0] rx_data;
    wire rx_ready;
    wire tx_start;
    wire [7:0] tx_data;
    wire tx_busy;

    wire [7:0] cpu_tx_data;
    wire cpu_tx_start;
    wire cpu_rx_ready;
    wire cpu_tx_busy;

    pll pll_inst(
        .clk_in1_p(i_sys_clk_p),
        .clk_in1_n(i_sys_clk_n),
        .clk_out1(w_clk_50Mhz),
        .clk_out2(cpu_clk),
        .locked(w_clk_rst)
    );

    uart #(
        .CLK_FREQ(50000000),
        .BAUD_RATE(9600)
    ) uart_inst(
        .clk(w_clk_50Mhz),
        .rst_n(w_clk_rst),
        .rx(i_uart_rx),
        .rx_data(rx_data),
        .rx_ready(rx_ready),
        .tx(o_uart_tx),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_busy(tx_busy)
    );

    generate
        if (P_UART_CONSOLE) begin : g_uart_console
            assign tx_start     = cpu_tx_start;
            assign tx_data      = cpu_tx_data;
            assign cpu_rx_ready = rx_ready;
            assign cpu_tx_busy  = tx_busy;
            assign virtual_sw   = 64'd0;
            assign virtual_key  = 8'd0;
        end else begin : g_twin_controller
            assign cpu_rx_ready = 1'b0;
            assign cpu_tx_busy  = 1'b1;

            twin_controller twin_controller_inst(
                .clk(w_clk_50Mhz),
                .rst_n(w_clk_rst),
                .rx_ready(rx_ready),
                .rx_data(rx_data),
                .tx_start(tx_start),
                .tx_data(tx_data),
                .tx_busy(tx_busy),
                .sw(virtual_sw),
                .key(virtual_key),
                .seg(virtual_seg),
                .led(virtual_led)
            );
        end
    endgenerate

    student_top student_top_inst(
        .w_cpu_clk(cpu_clk),
        .w_clk_50Mhz(w_clk_50Mhz),
        .w_clk_rst(~w_clk_rst),
        .virtual_key(virtual_key),
        .virtual_sw(virtual_sw),
        .uart_rx_data(rx_data),
        .uart_rx_ready(cpu_rx_ready),
        .uart_tx_busy(cpu_tx_busy),
        .uart_tx_data(cpu_tx_data),
        .uart_tx_start(cpu_tx_start),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg)
    );

endmodule

