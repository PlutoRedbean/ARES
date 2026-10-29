`timescale 1ns/1ps
module tb_benchmark_io;
    logic clk, rst;
    always #5 clk = ~clk;
    logic req_valid = 0, req_ready, write = 0;
    logic [31:0] addr = 0, wdata = 0, rdata;
    logic [3:0] strb = 0;
    logic rsp_valid, rsp_ready = 1, tx, busy;
    logic [31:0] value, first_count;
    time first_read, second_read;

    ares_benchmark_io dut (
        .clk(clk), .rst(rst), .host_req_valid(req_valid), .host_req_ready(req_ready),
        .host_write(write), .host_addr(addr), .host_wdata(wdata), .host_wstrb(strb),
        .host_rsp_valid(rsp_valid), .host_rsp_ready(rsp_ready), .host_rsp_data(rdata),
        .uart_tx(tx), .uart_busy(busy)
    );
    uart_console_monitor console (.rst(rst), .tx(tx));

    task automatic request(input bit wr, input logic [31:0] address,
                           input logic [31:0] data, input logic [3:0] mask);
        @(negedge clk);
        req_valid = 1; write = wr; addr = address; wdata = data; strb = mask;
        do @(posedge clk); while (!req_ready);
        #1; req_valid = 0;
        if (!rsp_valid) $fatal(1, "missing MMIO completion");
        value = rdata;
        @(posedge clk); #1;
    endtask

    initial begin
        clk = 0; rst = 1;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 0;
        request(0, 32'hA000_0050, 0, 0);
        first_count = value; first_read = $time;
        #1000;
        request(0, 32'hA000_0050, 0, 0);
        second_read = $time;
        if (64'(value - first_count) != (second_read-first_read)/10)
            $fatal(1, "100 MHz cycle count does not follow simulated time");

        // A response must survive a stalled consumer without accepting a new request.
        rsp_ready = 0;
        request(0, 32'hA000_0050, 0, 0);
        repeat (4) begin
            @(posedge clk); #1;
            if (!rsp_valid || req_ready || rdata != value)
                $fatal(1, "MMIO response changed under backpressure");
        end
        rsp_ready = 1;
        @(posedge clk); #1;

        request(1, 32'hA000_03F8, 32'h4F, 1);  // O
        if (!busy) $fatal(1, "UART did not start");
        request(0, 32'hA000_03FC, 0, 0);
        if (value != 1) $fatal(1, "UART busy status is incorrect");
        first_read = $time;
        request(1, 32'hA000_03F8, 32'h4B, 1);  // K: must wait for O
        if ($time-first_read < 80000) $fatal(1, "UART write was not backpressured");
        request(1, 32'hA000_03F8, 32'h0A, 1);
        wait (!busy);
        #1;
        if (console.byte_count != 3 || console.line != "")
            $fatal(1, "UART bytes were lost, duplicated, or not decoded from TX");
        request(1, 32'hA000_03F8, 32'h58, 0);
        if (busy || console.byte_count != 3) $fatal(1, "zero-strobe write transmitted");

        force dut.cycles = 64'h0000_0001_FFFF_FFF0;
        request(0, 32'hA000_0054, 0, 0);
        if (value != 1) $fatal(1, "cycle counter high word is incorrect");
        release dut.cycles;
        #400;
        request(0, 32'hA000_0054, 0, 0);
        if (value != 2) $fatal(1, "64-bit cycle counter did not carry");
        $display("ALL TESTS PASSED: benchmark RTL UART, backpressure, 100 MHz timer and rollover");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "benchmark IO test timeout");
    end
endmodule
