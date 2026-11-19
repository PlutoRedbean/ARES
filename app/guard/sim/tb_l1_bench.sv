// guard/sim/tb_l1_bench.sv
//
// 吞吐基准：把一段语料按 1 字节/拍灌进 l1_engine，统计
//   chars / cycles / chars_per_cycle / ns_per_char（按 150 MHz 折算）
// 以及各类型的命中数。用来把 plan 里"1 字符/拍、亚微秒"这两条量出来。
//
// 用法：+file=build/vectors/bench.txt

`timescale 1ns/1ps

module tb_l1_bench;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n    = 1'b0;
    logic       in_valid = 1'b0;
    logic       in_last  = 1'b0;
    logic [7:0] in_char  = 8'h00;

    wire        digit_valid, email_valid, ipv4_valid, uscc_valid, plate_valid;
    wire [31:0] digit_start, email_start, ipv4_start, uscc_start, plate_start;
    wire [7:0]  digit_len, email_len, ipv4_len, uscc_len, plate_len;
    wire [2:0]  digit_type;

    l1_engine dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .digit_valid(digit_valid), .digit_start(digit_start), .digit_len(digit_len), .digit_type(digit_type),
        .email_valid(email_valid), .email_start(email_start), .email_len(email_len),
        .ipv4_valid(ipv4_valid),   .ipv4_start(ipv4_start),   .ipv4_len(ipv4_len),
        .uscc_valid(uscc_valid),   .uscc_start(uscc_start),   .uscc_len(uscc_len),
        .plate_valid(plate_valid), .plate_start(plate_start), .plate_len(plate_len)
    );

    int hits [0:8];
    int chars  = 0;
    int cycles = 0;

    always @(posedge clk) begin
        if (digit_valid) hits[int'(digit_type)]++;
        if (email_valid) hits[5]++;
        if (ipv4_valid)  hits[6]++;
        if (uscc_valid)  hits[7]++;
        if (plate_valid) hits[8]++;
    end

    string path;
    int    fd, c;

    initial begin
        for (int t = 0; t <= 8; t++) hits[t] = 0;
        if (!$value$plusargs("file=%s", path)) path = "build/vectors/bench.txt";
        fd = $fopen(path, "rb");
        if (fd == 0) begin
            $display("FAIL: cannot open %s", path);
            $fatal(1);
        end

        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        @(negedge clk);
        while ((c = $fgetc(fd)) != -1) begin
            in_valid = 1'b1;
            in_char  = c[7:0];
            chars    = chars + 1;
            @(negedge clk);
            cycles   = cycles + 1;
        end
        in_valid = 1'b0;
        @(negedge clk);
        in_last = 1'b1;
        @(negedge clk);
        in_last = 1'b0;
        repeat (4) @(negedge clk);
        $fclose(fd);

        $display("bench: chars=%0d cycles=%0d hits=%0d", chars, cycles,
                 hits[1] + hits[2] + hits[3] + hits[4] + hits[5] + hits[6] + hits[7] + hits[8]);
        $display("  chars/cycle   = %0.3f", real'(chars) / real'(cycles));
        $display("  ns/char@150MHz= %0.3f", 6.667 * real'(cycles) / real'(chars));
        $display("  MB/s@150MHz   = %0.1f", real'(chars) / (real'(cycles) * 6.667e-9) / 1.0e6);
        $display("  hits: id18=%0d id15=%0d mobile=%0d bank=%0d email=%0d ipv4=%0d uscc=%0d plate=%0d",
                 hits[1], hits[2], hits[3], hits[4], hits[5], hits[6], hits[7], hits[8]);

        // 命中时延探针：身份证 + ';' 终止符（';' 是非分隔符，会关闭游程），
        // 数"终止字符被采样"到"out_valid 可见"的拍数（寄存器输出 => 1 拍）。
        begin
            string probe = "11010519491231002X;";
            int lat = 0;
            in_valid = 1'b0;
            in_last  = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
            for (int i = 0; i < probe.len(); i++) begin
                in_valid = 1'b1;
                in_char  = probe.getc(i);
                @(negedge clk);
            end
            in_valid = 1'b0;
            while (!digit_valid && lat < 32) begin
                @(negedge clk);
                lat++;
            end
            $display("  hit latency   = %0d cycle(s) terminator->visible (%0.2f ns @150MHz)",
                     lat + 1, real'(lat + 1) * 6.667);
        end
        $finish;
    end

endmodule
