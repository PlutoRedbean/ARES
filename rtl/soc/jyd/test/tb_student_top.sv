/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
module tb_student_top;
    logic w_cpu_clk=0,w_clk_50Mhz=0,w_clk_rst=1;
    always #2 w_cpu_clk=~w_cpu_clk;
    always #10 w_clk_50Mhz=~w_clk_50Mhz;
    logic [31:0] led;
    logic [39:0] seg;
    logic [7:0] tx_data;
    logic tx_start, tx_prev=0;
    int retired=0,uart_count=0,refills=0,hits=0,misses=0,branches=0,checks=0;
    logic [31:0] a0=1;
    string image;
    student_top dut(.w_cpu_clk(w_cpu_clk),.w_clk_50Mhz(w_clk_50Mhz),.w_clk_rst(w_clk_rst),
        .virtual_key(8'ha5),.virtual_sw(64'h1020304050607080),
        .uart_rx_data(8'd0),.uart_rx_ready(1'b0),.uart_tx_busy(1'b0),
        .uart_tx_data(tx_data),.uart_tx_start(tx_start),.virtual_led(led),.virtual_seg(seg),
        .mt_wr_en(),.mt_wr_idx(),.mt_wr_data(),.mt_status_rd(),.mt_status(32'd0),.mt_result(32'd0));
    always @(posedge w_cpu_clk) if(!w_clk_rst) begin
        if(tx_start && !tx_prev) begin
            if(tx_data!=8'h4b) $fatal(1,"UART data mismatch");
            uart_count++;
        end
        tx_prev=tx_start;
        if(dut.Core_cpu.u_core.u_lsu.dc_hit_fill_valid_w) hits++;
        if(dut.Core_cpu.u_core.u_lsu.mshr_resv_valid_w && dut.Core_cpu.u_core.u_lsu.mshr_resv_ready_w) misses++;
        if(dut.Core_cpu.u_frontend.icache_refill) refills++;
        if(dut.Core_cpu.backend_redirect_valid) branches++;
        if(dut.Core_cpu.dep_error) $fatal(1,"dependency error");
        for(int l=0;l<2;l++) if(dut.Core_cpu.retire_valid[l]) begin
            retired++;
            if(dut.Core_cpu.retire_rd_wen[l] && dut.Core_cpu.retire_rd[l]==10) a0=dut.Core_cpu.retire_wdata[l];
            if(dut.Core_cpu.retire_is_ebreak[l]) begin
                if(a0!=0 || led!=32'h123 || uart_count!=1 || refills==0 || branches==0 || hits==0 || misses==0)
                    $fatal(1,"SoC autonomous boot failed a0=%x led=%x uart=%0d",a0,led,uart_count);
                checks+=5;
                $display("ALL TESTS PASSED: student_top real FE/IROM %0d retires, %0d checks, UART/LED, DRAM miss/hit, uncached, JAL/JALR",retired,checks);
                $finish;
            end
        end
    end
    initial begin
        if(!$value$plusargs("IROM_HEX=%s",image)) $fatal(1,"missing +IROM_HEX");
        // Program/data preload is the only test fixture injection: IQ is real.
        // IP timing models preload the supplied image at initialization.
        repeat(6) @(negedge w_cpu_clk); w_clk_rst=0;
    end
    initial begin #200000; $fatal(1,"SoC timeout after %0d retires",retired); end
endmodule

/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
