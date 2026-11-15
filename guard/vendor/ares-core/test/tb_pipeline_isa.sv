// M1.5 ISA regression harness for the pipeline SoC.
module tb_pipeline_isa #(
    parameter USE_ICACHE       = 1,
    parameter ICACHE_PIPE_HITS = 1
) (
    input  logic        clk,
    input  logic        rst,
    output logic        ebreak_seen,
    output logic [31:0] a0,
    output logic [31:0] retire_count
);
    logic [7:0]  uart_tx_data;
    logic        uart_tx_start;
    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;

    logic        retire_valid;
    logic [31:0] retire_pc;
    logic [31:0] retire_pc_next;
    logic        retire_rd_wen;
    logic [ 4:0] retire_rd;
    logic [31:0] retire_wdata;
    logic        retire_is_ebreak;

    student_top #(
        .USE_ICACHE       (USE_ICACHE),
        .ICACHE_PIPE_HITS (ICACHE_PIPE_HITS)
    ) dut (
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

    logic [31:0] a0_q = 32'd0;
    logic [31:0] count_q = 32'd0;
    logic        ebreak_q = 1'b0;

    assign a0 = a0_q;
    assign retire_count = count_q;
    assign ebreak_seen = ebreak_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            a0_q     <= 32'd0;
            count_q  <= 32'd0;
            ebreak_q <= 1'b0;
        end else if (retire_valid) begin
            count_q <= count_q + 1'b1;
            if (retire_rd_wen && (retire_rd == 5'd10))
                a0_q <= retire_wdata;
            if (retire_is_ebreak)
                ebreak_q <= 1'b1;
        end
    end
endmodule
