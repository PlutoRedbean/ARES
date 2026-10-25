// First physical board baseline: real CPU + ROM/RAM + UART console.
// The board has no defined reset pin. PLL loss/reacquisition cold-resets both
// domains; each release is synchronized locally. C6 XIF/DMA is not instantiated.
/* verilator lint_off PINCONNECTEMPTY */
module top #(
    parameter int UART_BAUD = 115_200
) (
    input logic i_sys_clk_p, i_sys_clk_n, i_uart_rx,
    output logic o_uart_tx,
    output logic [31:0] virtual_led,
    output logic [39:0] virtual_seg
);
    logic cpu_clk, peripheral_clk, pll_locked;
    /* verilator lint_off SYNCASYNCNET */ // synchronous consumers + reset-chain async assertion
    logic cpu_rst, peripheral_rst;
    /* verilator lint_on SYNCASYNCNET */
    logic [7:0] rx_data, tx_data;
    logic rx_ready, tx_start, tx_busy;
    pll u_pll (
        .clk_in1_p(i_sys_clk_p), .clk_in1_n(i_sys_clk_n),
        .clk_out1(peripheral_clk), .clk_out2(cpu_clk), .locked(pll_locked)
    );
    ares_reset_sync u_cpu_reset (.clk(cpu_clk), .async_rst(!pll_locked), .rst(cpu_rst));
    ares_reset_sync u_peripheral_reset (.clk(peripheral_clk), .async_rst(cpu_rst), .rst(peripheral_rst));
    ares_uart #(.BAUD(UART_BAUD)) u_uart (
        .clk(peripheral_clk), .rst(peripheral_rst), .rx(i_uart_rx), .tx(o_uart_tx),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy),
        .rx_data(rx_data), .rx_ready(rx_ready)
    );
    student_top #(.RESET_MTVEC(32'h8000_0100)) u_platform (
        .w_cpu_clk(cpu_clk), .w_clk_50Mhz(peripheral_clk), .w_clk_rst(cpu_rst),
        .virtual_key(8'd0), .virtual_sw(64'd0),
        .uart_rx_data(rx_data), .uart_rx_ready(rx_ready), .uart_tx_busy(tx_busy),
        .uart_tx_data(tx_data), .uart_tx_start(tx_start),
        .virtual_led(virtual_led), .virtual_seg(virtual_seg),
        .mt_wr_en(), .mt_wr_idx(), .mt_wr_data(), .mt_status_rd(),
        .mt_status(32'd0), .mt_result(32'd0), .mt_irq(1'b0)
    );
endmodule
/* verilator lint_on PINCONNECTEMPTY */
