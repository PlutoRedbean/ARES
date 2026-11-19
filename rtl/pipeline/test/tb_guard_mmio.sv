`timescale 1ns/1ps
module tb_guard_mmio;
    bit clk, guard_clk;
    always #5 clk = ~clk;
    always #20 guard_clk = ~guard_clk;
    bit rst = 1, valid, write, uart_overflow;
    logic [3:0] addr;
    logic [31:0] data;
    wire ready;
    wire [31:0] result;

    pipeline_amp_guard #(.USE_NER(0)) dut (
        .clk, .rst, .guard_clk, .uart_overflow, .valid, .write, .addr,
        .wstrb(4'b1111), .wdata(data), .ready, .rdata(result)
    );

    task automatic access(input bit wr, input logic [3:0] offset,
                          input int payload, output int value);
        @(negedge clk);
        valid = 1;
        write = wr;
        addr = offset;
        data = payload;
        do @(posedge clk); while (!ready);
        @(negedge clk);
        valid = 0;
        @(negedge clk);
        value = result;
    endtask

    byte unsigned bytes_in[2048], expected[2400];
    int fd, frames, fault, count, expected_count, value, status, pos_in, pos_out, polls;
    bit closed;
    initial begin
        fd = $fopen("build/rtos_amp/guard_mmio_cases.txt", "r");
        if (!fd) $fatal(1, "Missing golden vectors");
        #200 rst = 0;
        while ($fscanf(fd, "%d %d %d", count, expected_count, fault) == 3) begin
            for (int i = 0; i < count; i++)
                if ($fscanf(fd, "%x", bytes_in[i]) != 1) $fatal;
            for (int i = 0; i < expected_count; i++)
                if ($fscanf(fd, "%x", expected[i]) != 1) $fatal;
            uart_overflow = fault != 0;
            pos_in = 0; pos_out = 0; closed = 0; polls = 0;
            forever begin
                access(0, 0, 0, status);
                if (status[0] && !closed) begin
                    if (pos_in < count) begin
                        access(1, 4, bytes_in[pos_in], value);
                        pos_in++;
                    end else begin
                        access(1, 8, 1, value);
                        closed = 1;
                    end
                end
                // Withhold reads until both FIFOs and the body credit limit
                // have had time to fill, then consume in short bursts.
                if (status[1] && polls % 256 >= 240) begin
                    access(0, 12, 0, value);
                    if (value[8]) begin
                        if (value != (256 | (fault << 9)) || pos_out != expected_count || !closed)
                            $fatal(1, "bad frame end in case %d at %d", frames, pos_out);
                        break;
                    end
                    if (pos_out >= expected_count || value != expected[pos_out])
                        $fatal(1, "case %d byte %d got %x expected %x", frames, pos_out, value, expected[pos_out]);
                    pos_out++;
                end
                if (polls++ > 40000) $fatal(1, "stalled case %d", frames);
            end
            access(0, 0, 0, status);
            if (status != (1 | (fault << 3))) $fatal(1, "unexpected final status %x", status);
            frames++;
        end
        if (!frames) $fatal(1, "empty vector file");
        $display("Guard MMIO PASS: %0d frames compared byte for byte", frames);
        $finish;
    end
endmodule
