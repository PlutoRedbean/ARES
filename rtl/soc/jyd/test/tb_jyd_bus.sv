// Integration test: real migrated perip_bridge + width converter + IP models.
// Test counters/stimulus deliberately use blocking assignments; unused model
// outputs (timer/UART/SEG) are outside this memory/CDC integration test.
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_jyd_bus;
    logic clk=0, cnt_clk=0, rst=1;
    always #2 clk=~clk;
    always #10 cnt_clk=~cnt_clk;
    logic mem_rd_valid=0, mem_rd_ready, mem_rsp_valid, mem_rsp_ready=0;
    logic [31:0] mem_rd_addr=0;
    logic [127:0] mem_rsp_data;
    logic mem_wr_valid=0, mem_wr_ready;
    logic [31:0] mem_wr_addr=0;
    logic [127:0] mem_wr_data=0;
    logic [15:0] mem_wr_be=0;
    logic mmio_req_valid=0, mmio_req_ready, mmio_write=0;
    logic [31:0] mmio_addr=0, mmio_wdata=0, mmio_rsp_data;
    logic [3:0] mmio_wstrb=0;
    logic mmio_rsp_valid, mmio_rsp_ready=0;
    logic perip_valid, perip_ready, perip_rvalid, perip_order_idle, perip_wen;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic [3:0] perip_wstrb;
    logic allow=1, random_stalls=0, real_ready;
    logic [31:0] led;
    logic [39:0] seg;
    logic timer_irq, uart_tx_start;
    logic [7:0] uart_tx_data;
    logic mt_wr_en, mt_status_rd;
    logic [2:0] mt_wr_idx;
    logic [31:0] mt_wr_data;
    byte unsigned mirror [4096];
    int checks=0, push_pop=0, stalls=0;
    ares_jyd_bus_bridge dut (.*);
    assign perip_ready = allow && real_ready;
    perip_bridge platform (
        .clk(clk), .cnt_clk(cnt_clk), .rst(rst),
        .perip_valid(perip_valid && allow), .perip_ready(real_ready),
        .perip_rvalid(perip_rvalid), .perip_order_idle(perip_order_idle),
        .perip_addr(perip_addr), .perip_wdata(perip_wdata),
        .perip_wen(perip_wen), .perip_wstrb(perip_wstrb), .perip_rdata(perip_rdata),
        .timer_irq(timer_irq), .virtual_sw_input(64'h1020304050607080),
        .virtual_key_input(8'hA5), .virtual_led_output(led), .virtual_seg_output(seg),
        .uart_rx_data(8'd0), .uart_rx_ready(1'b0), .uart_tx_busy(1'b0),
        .uart_tx_data(uart_tx_data), .uart_tx_start(uart_tx_start),
        .mt_wr_en(mt_wr_en), .mt_wr_idx(mt_wr_idx), .mt_wr_data(mt_wr_data),
        .mt_status_rd(mt_status_rd), .mt_status(32'hA55A0102), .mt_result(32'h34567890)
    );
    always @(negedge clk) if (random_stalls) allow = $urandom_range(0,3) != 0;
    always @(posedge clk) if (!rst) begin
        if (dut.push && dut.pop) push_pop++;
        if (perip_valid && !perip_ready) stalls++;
    end
    task automatic check(input bit ok, input string reason);
        checks++;
        if (!ok) $fatal(1,"%s",reason);
    endtask
    task automatic write_beat(input int offset, input logic [127:0] data, input logic [15:0] be);
        @(negedge clk);
        mem_wr_valid=1; mem_wr_addr=32'h80100000+32'(offset);
        mem_wr_data=data; mem_wr_be=be;
        @(posedge clk);
        while (!mem_wr_ready) @(posedge clk);
        for (int b=0;b<16;b++) if (be[b]) mirror[offset+b]=data[b*8 +:8];
        @(negedge clk); mem_wr_valid=0;
    endtask
    task automatic read_beat(input int offset);
        logic [127:0] expected;
        expected=0;
        for (int b=0;b<16;b++) expected[b*8 +:8]=mirror[offset+b];
        @(negedge clk); mem_rd_valid=1; mem_rd_addr=32'h80100000+32'(offset);
        @(posedge clk); while (!mem_rd_ready) @(posedge clk);
        @(negedge clk); mem_rd_valid=0;
        wait(mem_rsp_valid);
        repeat(5) begin
            @(negedge clk); check(mem_rsp_valid && mem_rsp_data===expected,"beat data / response backpressure");
        end
        mem_rsp_ready=1;
        @(negedge clk); mem_rsp_ready=0;
    endtask
    task automatic device(input bit write, input logic [31:0] addr, data,
                          input logic [3:0] be, input logic [31:0] expected);
        @(negedge clk);
        mmio_req_valid=1; mmio_write=write; mmio_addr=addr; mmio_wdata=data; mmio_wstrb=be;
        @(posedge clk); while (!mmio_req_ready) @(posedge clk);
        @(negedge clk); mmio_req_valid=0;
        wait(mmio_rsp_valid);
        repeat(4) begin
            @(negedge clk);
            check(mmio_rsp_valid && mmio_rsp_data===expected,"MMIO data / response backpressure");
            if (write) check(perip_order_idle,"write ack before memory side effect complete");
        end
        mmio_rsp_ready=1;
        @(negedge clk); mmio_rsp_ready=0;
    endtask
    initial begin
        int seed;
        logic [127:0] data;
        logic [15:0] be;
        int offset;
        seed=32'h18A7C0DE; seed=$urandom(seed);
        foreach(mirror[i]) mirror[i]=0;
        repeat(5) @(negedge clk); rst=0;
        allow=0;
        for (int n=0;n<4;n++) write_beat(n*16,128'(n+1),16'hFFFF);
        check(!mem_wr_ready,"write queue must hold four complete beats under downstream stall");
        repeat(10) @(negedge clk);
        allow=1;
        for (int n=0;n<4;n++) read_beat(n*16);
        // Arbitrary sparse byte lanes and all-zero writes.
        write_beat(0,128'hFFEEDDCCBBAA99887766554433221100,16'hA5A5);
        write_beat(0,'1,16'h0000);
        read_beat(0);
        random_stalls=1;
        for (int n=0;n<1200;n++) begin
            offset=int'($urandom_range(0,255))*16;
            data={$urandom,$urandom,$urandom,$urandom}; be=16'($urandom);
            write_beat(offset,data,be);
            if (n%4==0) read_beat(offset);
        end
        for (int n=0;n<256;n++) read_beat(n*16);
        // Uncached alias returns the same physical bytes; partial store stays uncached.
        device(0,32'h80300000,0,0,{mirror[3],mirror[2],mirror[1],mirror[0]});
        device(1,32'h80300001,32'h00007B00,4'b0010,0); mirror[1]=8'h7B;
        read_beat(0);
        device(0,32'h80400000,0,0,{mirror[3],mirror[2],mirror[1],mirror[0]});
        device(0,32'h80200000,0,0,32'h50607080);
        device(0,32'h80200004,0,0,32'h10203040);
        device(0,32'h80200010,0,0,32'hA5);
        device(1,32'h80200040,32'hABCDEF12,4'hF,0);
        repeat(100) @(negedge clk);
        check(led==32'hABCDEF12,"LED coherent CDC snapshot");
        device(0,32'h80201010,0,0,32'hA55A0102);
        device(0,32'h80201014,0,0,32'h34567890);
        // Reset during a backpressured read response drops the response/owner.
        @(negedge clk); mem_rd_valid=1; mem_rd_addr=32'h80100000;
        @(posedge clk); while(!mem_rd_ready) @(posedge clk);
        @(negedge clk); mem_rd_valid=0; wait(mem_rsp_valid);
        @(negedge clk); rst=1;
        repeat(5) @(negedge clk);
        check(!mem_rsp_valid && !mmio_rsp_valid,"reset must discard pending response");
        rst=0; read_beat(0);
        check(stalls>0,"downstream stalls not covered");
        check(push_pop>0,"simultaneous enqueue/dequeue not covered");
        $display("ALL TESTS PASSED: %0d checks; %0d downstream stalls; %0d simultaneous push/pop; 1200 randomized partial writes",checks,stalls,push_pop);
        $finish;
    end
    initial begin #1000000; $fatal(1,"test timed out"); end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on PROCASSINIT */
/* verilator lint_on BLKSEQ */
