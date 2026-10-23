/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns/1ps
module tb_board;
    bit sys_clk = 0, rx = 1;
    always #2.5 sys_clk = ~sys_clk;
    wire tx;
    wire [31:0] led;
    wire [39:0] seg;
    int frames = 0, traps = 0, mrets = 0, retires = 0;
    logic [31:0] last_pc;
    top #(.UART_BAUD(5_000_000)) dut (
        .i_sys_clk_p(sys_clk), .i_sys_clk_n(!sys_clk), .i_uart_rx(rx),
        .o_uart_tx(tx), .virtual_led(led), .virtual_seg(seg)
    );
    // 50MHz / 5Mbaud = 200ns/bit. Sample the actual physical TX pin.
    task automatic receive(input byte expected);
        byte value;
        @(negedge tx);
        #100;
        if (tx !== 0) $fatal(1,"bad TX start");
        for (int i=0;i<8;i++) begin #200; value[i]=tx; end
        #200;
        if (tx !== 1 || value != expected)
            $fatal(1,"serial frame %0d: got %02x expected %02x",frames,value,expected);
        frames++;
    endtask
    task automatic hello;
        string message = "ARES C4 OK\r\n";
        for (int i=0;i<message.len();i++) receive(message[i]);
    endtask
    task automatic send(input byte value);
        @(negedge dut.peripheral_clk); rx=0;
        #200;
        for (int i=0;i<8;i++) begin rx=value[i]; #200; end
        rx=1; #200;
    endtask
    always @(posedge dut.cpu_clk) if (!dut.cpu_rst) begin
        for (int l=0;l<2;l++) if(dut.u_platform.Core_cpu.retire_valid[l]) begin
            retires++;
            last_pc=dut.u_platform.Core_cpu.retire_pc[l];
        end
        if (dut.u_platform.Core_cpu.u_core.u_backend.u_trap.trap_we) traps++;
        if (dut.u_platform.Core_cpu.u_core.u_backend.u_trap.mret_we) mrets++;
        if (dut.u_platform.Core_cpu.dep_error) $fatal(1,"dependency error");
    end
    initial begin
        hello();
        wait (led == 32'h123);
        fork send(8'ha5); receive(8'ha5); join
        fork send(8'h3c); receive(8'h3c); join
        // Lose PLL lock in flight, then require the complete boot again.
        @(negedge dut.peripheral_clk);
        dut.u_pll.fault=1;
        #1;
        if (!dut.cpu_rst || !dut.peripheral_rst) $fatal(1,"lock loss did not assert reset");
        #219;
        dut.u_pll.fault=0;
        wait (dut.pll_locked);
        if (!dut.cpu_rst || !dut.peripheral_rst) $fatal(1,"reset released before sync edges");
        hello();
        wait (led == 32'h123);
        if (traps != 2 || mrets != 2) $fatal(1,"ECALL/MRET counts %0d/%0d",traps,mrets);
        $display("ALL TESTS PASSED: board %0d serial frames, 2 boots, ECALL/MRET, data image, RX echo, PLL loss/reset",frames);
        $finish;
    end
    initial begin #300000; $fatal(1,"board timeout led=%x frames=%0d retires=%0d pc=%x trap=%0d mret=%0d reset=%b",led,frames,retires,last_pc,traps,mrets,dut.cpu_rst); end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
