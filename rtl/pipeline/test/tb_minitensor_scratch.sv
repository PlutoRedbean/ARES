`timescale 1ns/1ps
module tb_minitensor_scratch;
    bit clk, rst = 1;
    always #5 clk = !clk;
    logic cpu_valid, cpu_write, cpu_ready;
    logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
    logic [3:0] cpu_wstrb;
    pipeline_amp_minitensor dut (.*);

    // Drive the cluster's DMA master port independently of its instruction stream.
    initial begin
        force dut.dma_valid = 0;
        force dut.dma_rsp_ready = 0;
        force dut.dma_addr = 32'h1000;
        force dut.dma_write = 0;
        force dut.perf_mma = 32'h1234;
        @(negedge clk);
        rst = 0;
        cpu_addr = 32'h100c;
        cpu_wdata = 32'h11223344;
        cpu_wstrb = 4'hf;
        cpu_valid = 1;
        cpu_write = 1;
        force dut.dma_valid = 1;
        #1;
        if (!cpu_ready || dut.dma_ready) $fatal(1, "CPU lost the unreserved port");
        @(negedge clk);
        if (cpu_ready || !dut.dma_ready) $fatal(1, "DMA did not reserve the next port cycle");
        cpu_addr = 32'he000001c;
        cpu_write = 0;
        #1;
        if (!cpu_ready) $fatal(1, "DMA grant blocked a register read");
        @(negedge clk);
        force dut.dma_valid = 0;
        cpu_addr = 32'h100c;
        @(negedge clk);
        if (cpu_rdata !== 32'h1234) $fatal(1, "CPU register response misaligned");
        if (!dut.dma_rsp_valid || dut.dma_rdata[127:96] !== 32'h11223344)
            $fatal(1, "DMA did not see the preceding CPU store");

        // Hold a new masked write behind an unconsumed read response.
        force dut.dma_valid = 1;
        force dut.dma_write = 1;
        force dut.dma_wdata = {32'haabbccdd, 96'd0};
        force dut.dma_wstrb = 16'ha000;
        repeat (3) begin
            @(negedge clk);
            if (!cpu_ready || cpu_rdata !== 32'h11223344 ||
                dut.dma_ready || !dut.dma_rsp_valid || dut.dma_rdata[127:96] !== 32'h11223344)
                $fatal(1, "Stalled DMA response or CPU scratch read corrupted");
        end
        force dut.dma_rsp_ready = 1;
        @(negedge clk);
        @(negedge clk);
        if (cpu_ready || !dut.dma_ready) $fatal(1, "Queued DMA write missed its grant");
        @(negedge clk);
        force dut.dma_valid = 0;
        if (!cpu_ready) $fatal(1, "CPU read could not retry after the DMA write");
        @(negedge clk);
        if (!dut.dma_rsp_valid) $fatal(1, "Missing DMA write response");
        @(negedge clk);
        if (cpu_rdata !== 32'haa22cc44) $fatal(1, "Wrong byte lanes or read latency");

        force dut.dma_valid = 1;
        @(negedge clk);
        if (!dut.dma_ready) $fatal(1, "Missing grant before reset");
        rst = 1;
        force dut.dma_valid = 0;
        #1;
        if (cpu_ready || dut.dma_ready) $fatal(1, "Accepted a transfer during reset");
        @(negedge clk);
        rst = 0;
        #1;
        if (!cpu_ready || dut.dma_ready || dut.dma_rsp_valid) $fatal(1, "Stale grant after reset");
        $display("miniTensor scratch arbitration PASS");
        $finish;
    end
endmodule
