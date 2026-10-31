// Minimal pipeline SoC smoke test: clock/reset only; DPI memory model is in
// sim_main.cpp.  The program stores 0x55 to 0x80100000, then loops.
module tb_pipeline_smoke(
    input logic clk,
    input logic rst,
    output logic ebreak_seen
);
    logic [7:0] uart_tx_data;
    logic       uart_tx_start;
    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;
    logic        retire_valid;
    logic [31:0] retire_pc;
    logic [31:0] retire_pc_next;
    logic        retire_rd_wen;
    logic [ 4:0] retire_rd;
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
        .retire_valid(retire_valid),
        .retire_pc(retire_pc),
        .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen),
        .retire_rd(retire_rd),
        .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .irom_addr(),
        .irom_pc(),
        .irom_data(32'd0),
        .irom_ready(1'b1),
        .shared_rdata(32'd0),
        .shared_req_valid(),
        .shared_req_write(),
        .shared_req_addr(),
        .shared_req_wdata(),
        .shared_req_wstrb()
    );

    logic ebreak_seen_q = 1'b0;
    assign ebreak_seen = ebreak_seen_q;

    always @(posedge clk) begin
        if (!rst && retire_valid && retire_is_ebreak)
            ebreak_seen_q <= 1'b1;
    end

    integer trace_cycles = 0;
    always @(posedge clk) begin
        if (!rst && trace_cycles < 40) begin
            $display("TRACE pc=%08x inst=%08x fence=%b lsu_idle=%b perip_idle=%b idstall=%b", dut.pc, dut.instruction, dut.Core_cpu.Mundus.fence_wait, dut.Core_cpu.Mundus._EXU_io_lsu_idle, dut.perip_idle, dut.Core_cpu.Mundus.id_iss_stall);
            trace_cycles = trace_cycles + 1;
        end
        if (!rst && retire_valid && retire_is_ebreak)
            $display("RETIRE ebreak pc=%08x next=%08x", retire_pc, retire_pc_next);
    end
endmodule
