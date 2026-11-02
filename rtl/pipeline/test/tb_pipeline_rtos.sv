`timescale 1ns/1ps
// Both profiles read exactly the HEX memories used for PDS (no DPI RAM model).
module tb_pipeline_rtos #(parameter integer BOARD = 0, parameter integer IRQ_TEST = 0,
    parameter IROM_INIT_FILE = "build/rtos/irom.hex",
    parameter DRAM_INIT_FILE = "build/rtos/dram.hex");
    reg clk = 0, cnt_clk = 0, rst = 1, clk_27m = 0;
    always #5 clk = ~clk;
    always #10 cnt_clk = ~cnt_clk;
    always begin #18 clk_27m = 1; #19 clk_27m = 0; end
    initial begin #200000; rst = 0; end
    string line = "";
    bit passed = 0;
    task automatic receive_byte(input reg [7:0] ch);
        begin
            $write("%c", ch);
            if (ch == 10) begin
                if (line == "ARES RTOS PASS") passed = 1;
                if (line.substr(0,13) == "ARES RTOS FAIL") $fatal(1, "RTOS reported failure");
                line = "";
            end else if (ch != 13) line = {line, ch};
        end
    endtask
    generate if (BOARD) begin : g_board
        wire tx;
        wire [7:0] led;
        pipeline_rtos_board_top dut(.clk_27m(clk_27m), .rst_n(!rst), .uart_tx(tx), .led(led));
        reg [7:0] ch;
        initial forever begin
            @(negedge tx);
            #4340;
            if (tx !== 0) $fatal(1, "UART start bit");
            #8680;
            for (integer b=0; b<8; b=b+1) begin ch[b] = tx; #8680; end
            if (tx !== 1) $fatal(1, "UART stop bit");
            receive_byte(ch);
        end
    end else begin : g_soc
        student_top #(.IROM_INIT_FILE(IROM_INIT_FILE),
                      .DRAM_INIT_FILE(DRAM_INIT_FILE)) dut (
            .w_cpu_clk(clk), .w_clk_50Mhz(cnt_clk), .w_clk_rst(rst),
            .virtual_key(8'd0), .virtual_sw(64'd0), .uart_rx_data(8'd0),
            .uart_rx_ready(1'b0), .uart_tx_busy(1'b0),
            .irom_req_ready(1'b0), .irom_rsp_valid(1'b0), .irom_rsp_data(32'd0),
            .shared_rdata(32'd0));
        if (IRQ_TEST) begin : g_inject
            reg injected = 0;
            integer phase = 0, stores = 0;
            reg [5:0] coverage = 0;
            // Test-only forcing; the real pending register remains independently driven.
            initial force dut.Core_cpu.timer_irq = injected | dut.bridge_inst.counter_inst.timer_irq_r;
            always @(posedge clk) begin
                if (!rst) begin
                    if (dut.bridge_inst.mmio_write_accept && dut.perip_addr == 32'h80200020)
                        phase <= dut.perip_wdata;
                    if (phase >= 1 && phase <= 5 && !coverage[phase] && (
                        (phase == 1 && dut.Core_cpu.Mundus.EXU.io_bpu_update_en) ||
                        (phase == 2 && (dut.Core_cpu.Mundus.EXU.exu_ex2.io_in_valid && dut.Core_cpu.Mundus.EXU.exu_ex2.io_in_bits_is_load && !dut.Core_cpu.Mundus.EXU.exu_ex2.io_cache_hit)) ||
                        (phase == 3 && dut.bridge_inst.store_count_q != 0) ||
                        (phase == 4 && dut.Core_cpu.Mundus.EXU.exu_ex1.DIV.div_running) ||
                        (phase == 5 && dut.perip_valid && !dut.perip_ready))) begin
                        injected <= 1;
                        coverage[phase] <= 1;
                        $display("IRQ inject phase=%0d", phase);
                    end
                    if (dut.bridge_inst.mmio_write_accept && dut.perip_addr == 32'h80200054)
                        injected <= 0;
                    if (dut.bridge_inst.mmio_write_accept && dut.perip_addr == 32'h80200040) begin
                        stores <= stores + 1;
                        if (dut.perip_wdata !== stores + 1) $fatal(1, "duplicate/missing store");
                    end
                    if (passed && (coverage != 6'b111110 || stores != 640))
                        $fatal(1, "IRQ coverage=%b stores=%d", coverage, stores);
                end
            end
        end
        always @(posedge clk) begin
            if (!rst && dut.bridge_inst.mmio_write_accept &&
                dut.bridge_inst.perip_addr_eff == 32'h80200060)
                receive_byte(dut.bridge_inst.perip_wdata[7:0]);
            if (!rst && dut.retire_valid && dut.retire_is_ebreak)
                $fatal(1, "RTOS halted before success");
        end
    end endgenerate
    initial begin
        wait(passed);
        #1000;
        $display("RTOS simulation BOARD=%0d PASS", BOARD);
        $finish;
    end
    initial begin #250000000; $fatal(1, "RTOS timeout; last line=%s", line); end
endmodule
