// guard/sim/tb_guard_report.sv
//
// guard_report 的穷举测试：对 0..255 每个值检查 "n=" 三位十进制格式化，
// 再检查整行长度/结尾，以及 ovf 位。板级端到端用例里的计数都很小，
// 覆盖不到 100+，BCD 转换要靠这个 TB 兜住。

`timescale 1ns/1ps

module tb_guard_report;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n = 1'b0;
    logic       start = 1'b0;
    logic       at_ls = 1'b1;
    logic [7:0] v_n = 8'd0, v_id18 = 8'd0, v_id15 = 8'd0, v_mobile = 8'd0;
    logic [7:0] v_bank = 8'd0, v_email = 8'd0, v_ipv4 = 8'd0, v_uscc = 8'd0;
    logic [7:0] v_plate = 8'd0;
    logic       v_err = 1'b0;

    wire        byte_valid;
    wire [7:0]  byte_out;
    logic       fifo_full = 1'b0;

    wire        busy, finished;

    guard_report dut (
        .clk(clk), .rst_n(rst_n), .start(start), .at_line_start(at_ls),
        .v_n(v_n), .v_id18(v_id18), .v_id15(v_id15), .v_mobile(v_mobile),
        .v_bank(v_bank), .v_email(v_email), .v_ipv4(v_ipv4), .v_uscc(v_uscc),
        .v_plate(v_plate), .v_err(v_err),
        .byte_out(byte_out), .byte_valid(byte_valid), .fifo_full(fifo_full),
        .busy(busy), .finished(finished)
    );

    localparam int MAXL = 256;
    logic [7:0] line [0:MAXL-1];
    int         n;

    always @(posedge clk) begin
        if (byte_valid) begin
            if (n < MAXL) line[n] = byte_out;
            n = n + 1;
        end
    end

    int errors = 0;

    task automatic run_case(input int v, input logic err);
        int i, h, t, u;
        begin
            rst_n = 1'b1;
            at_ls = 1'b1;
            v_n   = v[7:0];
            v_err = err;
            repeat (2) @(negedge clk);
            n = 0;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            // 收集到 finished
            begin
                int guard_cnt = 0;
                while (!finished && guard_cnt < 1000) begin
                    @(negedge clk);
                    guard_cnt = guard_cnt + 1;
                end
            end

            // 整行 97 字节 + 行尾 LF = 98
            if (n != 98) begin
                errors = errors + 1;
                $display("FAIL v=%0d: line length %0d (exp 98)", v, n);
            end else begin
                // "[guard] n=HHH" → 下标 10..12
                h = v / 100;
                t = (v % 100) / 10;
                u = v % 10;
                if (line[10] !== (8'h30 + h[7:0]) ||
                    line[11] !== (8'h30 + t[7:0]) ||
                    line[12] !== (8'h30 + u[7:0])) begin
                    errors = errors + 1;
                    $display("FAIL v=%0d: n digits got %c%c%c", v,
                             line[10], line[11], line[12]);
                end
                // 结尾 " ovf=00X" → 下标 89..96，行尾 LF 在 97
                if (line[89] !== 8'h20 || line[90] !== 8'h6F || line[91] !== 8'h76 ||
                    line[92] !== 8'h66 || line[93] !== 8'h3D ||
                    line[94] !== 8'h30 || line[95] !== 8'h30 ||
                    line[96] !== (8'h30 + {7'd0, err}) || line[97] !== 8'h0A) begin
                    errors = errors + 1;
                    $display("FAIL v=%0d err=%0d: ovf field wrong (%c%c%c%c%c%c%c%c)",
                             v, err, line[89], line[90], line[91], line[92],
                             line[93], line[94], line[95], line[96]);
                end
                if (line[0] !== 8'h5B) begin      // '['
                    errors = errors + 1;
                    $display("FAIL v=%0d: line does not start with '['", v);
                end
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        repeat (3) @(negedge clk);

        // 0..255 的 n 字段（err=0），再抽查几个 err=1
        for (int v = 0; v < 256; v++) run_case(v, 1'b0);
        run_case(7, 1'b1);
        run_case(255, 1'b1);

        $display("report cases=257 errors=%0d", errors);
        if (errors != 0) $fatal(1, "guard_report mismatch");
        $display("PASS: guard_report formats 0..255");
        $finish;
    end

endmodule
