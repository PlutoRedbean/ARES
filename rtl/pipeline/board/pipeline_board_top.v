//=============================================================================
// ARES pipeline SoC - Pango PG2L200H board top
//-----------------------------------------------------------------------------
// Board profile: clk_27m D18, rst_n C22, uart_tx C24, led[7:0].
//
// Clocks: 100 MHz CPU (CoreMark time base), 50 MHz peripheral/UART.
// The UART RX pin is not defined by the existing Pango board profile, so RX
// is tied idle; CoreMark scoring only needs TX.  Add a pin to pipeline_board.fdc
// and replace the tie when the RX pin is confirmed.
//
// Verilog-2001.
//=============================================================================
`timescale 1ns / 1ps

module pipeline_board_top #(
    parameter UART_BAUD = 115200
) (
    input  wire       clk_27m,
    input  wire       rst_n,
    output wire       uart_tx,
    output wire [7:0] led
);
    wire cpu_clk;
    wire periph_clk;
    wire pll_lock;
    wire cpu_rst;
    wire periph_rst;

    pipeline_clk_reset u_clk_reset (
        .clk_27m   (clk_27m),
        .rst_n     (rst_n),
        .cpu_clk   (cpu_clk),
        .periph_clk(periph_clk),
        .pll_lock  (pll_lock),
        .cpu_rst   (cpu_rst),
        .periph_rst(periph_rst)
    );

    wire [7:0] uart_rx_data;
    wire       uart_rx_ready;
    wire [7:0] uart_tx_data;
    wire       uart_tx_start;
    wire       uart_tx_busy;

    uart #(
        .CLK_FREQ (50_000_000),
        .BAUD_RATE(UART_BAUD)
    ) u_uart (
        .clk      (periph_clk),
        .rst_n    (~periph_rst),
        .rx       (1'b1),
        .rx_data  (uart_rx_data),
        .rx_ready (uart_rx_ready),
        .tx       (uart_tx),
        .tx_data  (uart_tx_data),
        .tx_start (uart_tx_start),
        .tx_busy  (uart_tx_busy)
    );

    wire [31:0] virtual_led;

    student_top u_soc (
        .w_cpu_clk      (cpu_clk),
        .w_clk_50Mhz    (periph_clk),
        .w_clk_rst      (cpu_rst),
        .virtual_key    (8'd0),
        .virtual_sw     (64'd0),
        .uart_rx_data   (uart_rx_data),
        .uart_rx_ready  (uart_rx_ready),
        .uart_tx_busy   (uart_tx_busy),
        .uart_tx_data   (uart_tx_data),
        .uart_tx_start  (uart_tx_start),
        .virtual_led    (virtual_led),
        .virtual_seg    (),
        .retire_valid   (),
        .retire_pc      (),
        .retire_pc_next (),
        .retire_rd_wen  (),
        .retire_rd      (),
        .retire_wdata   (),
        .retire_is_ebreak()
    );

    assign led = virtual_led[7:0];
endmodule
