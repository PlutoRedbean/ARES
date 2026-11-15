`timescale 1ns / 1ps
// RTOS owns its image slot; the CoreMark board defaults remain unchanged.
module pipeline_rtos_board_top (
    input wire clk_27m, input wire rst_n,
    output wire uart_tx, output wire [7:0] led
);
    pipeline_board_top #(
        .IROM_INIT_FILE("build/rtos/irom.hex"),
        .DRAM_INIT_FILE("build/rtos/dram.hex")
    ) u_board (.clk_27m(clk_27m), .rst_n(rst_n), .uart_tx(uart_tx), .led(led));
endmodule
