/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
`timescale 1ns/1ps
module tb_board_io;
    bit clk=0, raw_rst=1;
    always #10 clk=~clk;
    wire rst;
    bit rx=1, start=0;
    byte data=0;
    wire tx, busy, ready;
    wire [7:0] received;
    int count=0;
    ares_reset_sync reset_dut (.clk(clk), .async_rst(raw_rst), .rst(rst));
    ares_uart #(.BAUD(5_000_000)) dut (.clk(clk),.rst(rst),.rx(rx),.tx(tx),
        .tx_data(data),.tx_start(start),.tx_busy(busy),.rx_data(received),.rx_ready(ready));
    always @(posedge clk) if (!rst && ready) begin
        if (received != 8'h96) $fatal(1,"RX data %x",received);
        count++;
    end
    task automatic frame(input bit stop_bit);
        byte value=8'h96;
        @(negedge clk); rx=0; #200;
        for (int i=0;i<8;i++) begin rx=value[i]; #200; end
        rx=stop_bit; #200; rx=1; #400;
    endtask
    initial begin
        #35; raw_rst=0;
        repeat(3) begin @(negedge clk); if(!rst) $fatal(1,"early reset release"); end
        @(negedge clk); if(rst) $fatal(1,"late reset release");
        frame(1);
        frame(0); // Invalid stop bit must not publish data.
        @(negedge clk); rx=0; #20; rx=1; #500; // Reject false start.
        if(count != 1) $fatal(1,"RX frame validation failed count=%0d",count);
        @(negedge clk); data=8'ha6; start=1;
        @(negedge clk); start=0;
        if(!busy || tx) $fatal(1,"TX did not reserve/start frame");
        #51; raw_rst=1;
        #1; if(!rst) $fatal(1,"async reset assertion failed");
        @(posedge clk); @(negedge clk);
        if(busy || !tx) $fatal(1,"UART did not reset in flight");
        $display("ALL TESTS PASSED: UART framing/false-start/stop rejection, reset synchronization and in-flight reset");
        $finish;
    end
    initial begin #20000; $fatal(1,"UART timeout"); end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
