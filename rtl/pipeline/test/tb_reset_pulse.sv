// Short-reset regression: exposes retire activity of student_top so that
// sim_reset_pulse_main.cpp can pulse reset mid-run and check that nothing
// from before the pulse retires or reaches memory afterwards.
module tb_reset_pulse(
    input  logic        clk,
    input  logic        rst,
    output logic        retire_valid,
    output logic [31:0] retire_pc
);
    logic [7:0]  uart_tx_data;
    logic        uart_tx_start;
    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;
    logic [31:0] retire_pc_next;
    logic        retire_rd_wen;
    logic [4:0]  retire_rd;
    logic [31:0] retire_wdata;
    logic        retire_is_ebreak;

    student_top dut (
        .w_cpu_clk    (clk),
        .w_clk_50Mhz  (clk),
        .w_clk_rst    (rst),
        .virtual_key  (8'd0),
        .virtual_sw   (64'd0),
        .uart_rx_data (8'd0),
        .uart_rx_ready(1'b0),
        .uart_tx_busy (1'b0),
        .uart_tx_data (uart_tx_data),
        .uart_tx_start(uart_tx_start),
        .virtual_led  (virtual_led),
        .virtual_seg  (virtual_seg),
        .retire_valid (retire_valid),
        .retire_pc    (retire_pc),
        .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen),
        .retire_rd    (retire_rd),
        .retire_wdata (retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .irom_req_valid(),
        .irom_req_addr (),
        .irom_req_ready(1'b0),
        .irom_rsp_valid(1'b0),
        .irom_rsp_data (32'd0),
        .irom_rsp_ready(),
        .irom_flush    (),
        .shared_rdata(32'd0),
        .shared_req_valid(),
        .shared_req_write(),
        .shared_req_addr(),
        .shared_req_wdata(),
        .shared_req_wstrb()
    );
endmodule
