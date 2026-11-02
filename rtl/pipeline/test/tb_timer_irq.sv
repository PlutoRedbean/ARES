`timescale 1ns/1ps
module tb_timer_irq;
    reg clk=0, cnt_clk=0, rst=1, enable=0, ack=0;
    wire [31:0] ms;
    wire irq;
    always #5 clk=~clk;
    always #10 cnt_clk=~cnt_clk;
    counter dut(.cpu_clk(clk),.cnt_clk(cnt_clk),.rst(rst),
                .cnt_enable_cpu(enable),.timer_ack(ack),.perip_rdata(ms),.timer_irq(irq));
    initial begin
        #100; @(negedge clk); rst=0;
        repeat(10) @(negedge clk);
        if(irq) $fatal(1,"pending after reset");
        enable=1;
        wait(irq); repeat(100) @(negedge clk);
        if(!irq) $fatal(1,"pending not held");
        ack=1; @(negedge clk); ack=0;
        if(irq) $fatal(1,"ACK did not clear");
        // ACK at the same edge that consumes a new synchronized millisecond.
        wait(dut.cnt_ms_cpu != dut.cnt_ms_cpu_seen);
        @(negedge clk); ack=1;
        @(negedge clk); ack=0;
        if(!irq) $fatal(1,"new tick must win over ACK");
        enable=0; @(negedge clk);
        if(irq) $fatal(1,"stop did not clear");
        enable=1; wait(irq);
        @(negedge clk); rst=1; @(negedge clk);
        if(irq) $fatal(1,"reset did not clear");
        $display("TIMER IRQ PASS: reset, hold, ACK, simultaneous tick/ACK, stop, restart");
        $finish;
    end
    initial begin #1000000; $fatal(1,"timer test timeout"); end
endmodule
