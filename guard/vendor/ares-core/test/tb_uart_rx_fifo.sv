`timescale 1ns/1ps
module tb_uart_rx_fifo;
    reg cpu_clk=0, clk=0, cpu_rst=1, rst=1, consumed=0;
    always #7 cpu_clk=~cpu_clk;
    always #10 clk=~clk;
    reg [7:0] raw_data=0;
    reg raw_ready=0;
    wire [7:0] data;
    wire ready, full, overflow;
    pipeline_uart_rx_fifo dut (.*);
    task send(input [7:0] value);
        @(negedge clk); raw_data=value; raw_ready=1;
        repeat(3) @(negedge clk); // A held ready level must enqueue only once.
        raw_ready=0;
        @(negedge clk);
    endtask
    task ack;
        @(negedge cpu_clk); consumed=1;
        @(negedge cpu_clk); consumed=0;
    endtask
    task expect_byte(input [7:0] expected);
        do begin @(posedge clk); #1; end while(!ready);
        if(data !== expected) $fatal(1,"RX order: got %0d expected %0d",data,expected);
    endtask
    initial begin
        #100000; $fatal(1,"FIFO timeout");
    end
    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        @(negedge cpu_clk); cpu_rst=0;
        send(0);
        // Byte 0 occupies the mailbox, independently of the 128-byte queue.
        if(data !== 0) $fatal(1,"first mailbox byte");
        for(integer i=1;i<=128;i=i+1) send(i[7:0]);
        if(!full || overflow) $fatal(1,"128-byte capacity");
        send(129);
        if(!overflow || data !== 0) $fatal(1,"overflow must latch and preserve mailbox");
        for(integer i=1;i<=128;i=i+1) begin
            ack();
            expect_byte(i[7:0]);
        end
        ack();
        repeat(10) begin
            @(posedge clk); #1;
            if(ready || full) $fatal(1,"duplicate byte after drain");
        end
        @(negedge clk); rst=1;
        @(negedge cpu_clk); cpu_rst=1;
        repeat(4) @(negedge clk);
        if(ready || full || overflow) $fatal(1,"reset must clear queue and overflow");
        $display("UART RX FIFO PASS: asynchronous ACK, held ready, ordering, capacity, overflow and reset");
        $finish;
    end
endmodule
