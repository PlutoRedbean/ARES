//=============================================================================
// ARES - unit testbench for mtx9_engine
//-----------------------------------------------------------------------------
// Drives the MMIO window and compares CRC / C / SUM0..3 / restored A against a
// bit-exact SystemVerilog model of CoreMark matrix_test().
//=============================================================================
`timescale 1ns/1ps
module tb_mtx9_engine;

    logic clk, rst;
    initial begin clk = 1'b0; rst = 1'b1; end
    always #5 clk = ~clk;

    logic        host_req_valid;
    logic        host_req_ready;
    logic        host_write;
    logic [31:0] host_addr;
    logic [31:0] host_wdata;
    logic [3:0]  host_wstrb;
    logic        host_rsp_valid;
    logic [31:0] host_rsp_data;

    mtx9_engine dut (
        .clk(clk), .rst(rst),
        .host_req_valid(host_req_valid), .host_req_ready(host_req_ready),
        .host_write(host_write), .host_addr(host_addr),
        .host_wdata(host_wdata), .host_wstrb(host_wstrb),
        .host_rsp_valid(host_rsp_valid), .host_rsp_data(host_rsp_data)
    );

    localparam logic [11:0] A_BASE = 12'h000;
    localparam logic [11:0] B_BASE = 12'h200;
    localparam logic [11:0] C_BASE = 12'h400;
    localparam logic [11:0] CTRL   = 12'h700;
    localparam logic [11:0] N_REG  = 12'h704;
    localparam logic [11:0] VAL    = 12'h708;
    localparam logic [11:0] STATUS = 12'h70C;
    localparam logic [11:0] CRC    = 12'h710;
    localparam logic [11:0] SUM0   = 12'h720;

    task automatic host_wr(input logic [11:0] a, input logic [31:0] d);
        while (host_rsp_valid) @(negedge clk);
        @(negedge clk);
        host_req_valid = 1'b1;
        host_write     = 1'b1;
        host_addr      = {20'h0, a};
        host_wdata     = d;
        host_wstrb     = 4'hF;
        @(negedge clk);
        host_req_valid = 1'b0;
        while (!host_rsp_valid) @(posedge clk);
        @(negedge clk);
    endtask

    task automatic host_rd(input logic [11:0] a, output logic [31:0] d);
        while (host_rsp_valid) @(negedge clk);
        @(negedge clk);
        host_req_valid = 1'b1;
        host_write     = 1'b0;
        host_addr      = {20'h0, a};
        host_wdata     = 32'h0;
        host_wstrb     = 4'h0;
        @(negedge clk);
        host_req_valid = 1'b0;
        while (!host_rsp_valid) @(posedge clk);
        d = host_rsp_data;
        @(negedge clk);
    endtask

    task automatic wait_done;
        logic [31:0] st;
        do begin
            host_rd(STATUS, st);
        end while (!st[1]);
    endtask

    function automatic logic [15:0] ref_crc8(
        input logic [7:0]  data,
        input logic [15:0] crc_in
    );
        logic [15:0] c;
        logic [7:0]  d;
        logic        x16, carry;
        c = crc_in;
        d = data;
        for (int i = 0; i < 8; i++) begin
            x16 = d[0] ^ c[0];
            d   = d >> 1;
            if (x16) begin c = c ^ 16'h4002; carry = 1'b1; end
            else       carry = 1'b0;
            c = c >> 1;
            if (carry) c[15] = 1'b1; else c[15] = 1'b0;
        end
        return c;
    endfunction

    function automatic logic [15:0] ref_crc16(
        input logic signed [15:0] val,
        input logic [15:0]        crc_in
    );
        logic [15:0] c;
        c = ref_crc8(val[7:0], crc_in);
        c = ref_crc8(val[15:8], c);
        return c;
    endfunction

    function automatic logic signed [15:0] ref_sum(
        input logic signed [31:0] cc [0:80],
        input logic signed [15:0] clipv
    );
        logic signed [31:0] tmp, prev, cur, clip32;
        logic signed [15:0] ret;
        tmp  = 32'sd0;
        prev = 32'sd0;
        ret  = 16'sd0;
        clip32 = {{16{clipv[15]}}, clipv};
        for (int i = 0; i < 81; i++) begin
            cur = cc[i];
            tmp = tmp + cur;
            if (tmp > clip32) begin
                ret = ret + 16'sd10;
                tmp = 32'sd0;
            end else begin
                ret = ret + ((cur > prev) ? 16'sd1 : 16'sd0);
            end
            prev = cur;
        end
        return ret;
    endfunction

    logic signed [15:0] A [0:80];
    logic signed [15:0] B [0:80];
    logic signed [31:0] C_ref [0:80];
    logic signed [15:0] sum_ref [0:3];
    logic [15:0]        crc_ref;

    task automatic ref_model(input logic signed [15:0] val);
        logic signed [15:0] a [0:80];
        logic signed [31:0] c [0:80];
        logic signed [15:0] clipv;
        logic signed [31:0] acc, tmp, ext;
        logic [15:0]        crc;

        for (int i = 0; i < 81; i++) a[i] = A[i];
        clipv = 16'hF000 | val;

        for (int i = 0; i < 81; i++) a[i] = a[i] + val;

        for (int i = 0; i < 81; i++)
            c[i] = $signed(a[i]) * $signed(val);
        sum_ref[0] = ref_sum(c, clipv);
        crc = ref_crc16(sum_ref[0], 16'h0);

        for (int i = 0; i < 9; i++) begin
            acc = 32'sd0;
            for (int j = 0; j < 9; j++)
                acc = acc + ($signed(a[i*9+j]) * $signed(B[j]));
            c[i] = acc;
        end
        sum_ref[1] = ref_sum(c, clipv);
        crc = ref_crc16(sum_ref[1], crc);

        for (int i = 0; i < 9; i++)
            for (int j = 0; j < 9; j++) begin
                acc = 32'sd0;
                for (int k = 0; k < 9; k++)
                    acc = acc + ($signed(a[i*9+k]) * $signed(B[k*9+j]));
                c[i*9+j] = acc;
            end
        sum_ref[2] = ref_sum(c, clipv);
        crc = ref_crc16(sum_ref[2], crc);

        for (int i = 0; i < 9; i++)
            for (int j = 0; j < 9; j++) begin
                acc = 32'sd0;
                for (int k = 0; k < 9; k++) begin
                    tmp = $signed(a[i*9+k]) * $signed(B[k*9+j]);
                    ext = (($signed(tmp) >>> 2) & 32'h0000_000F)
                        * (($signed(tmp) >>> 5) & 32'h0000_007F);
                    acc = acc + ext;
                end
                c[i*9+j] = acc;
            end
        sum_ref[3] = ref_sum(c, clipv);
        crc = ref_crc16(sum_ref[3], crc);

        for (int i = 0; i < 81; i++) a[i] = a[i] - val;

        for (int i = 0; i < 81; i++) C_ref[i] = c[i];
        crc_ref = crc;
    endtask

    int unsigned checks;
    int unsigned errors;

    task automatic check32(input string name, input logic [31:0] got,
                           input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("FAIL %s: got=%08x exp=%08x", name, got, exp);
        end
    endtask

    task automatic run_case(input int unsigned case_id,
                            input logic signed [15:0] val);
        logic [31:0] d;
        logic [31:0] cword;
        logic signed [31:0] expected;
        logic signed [15:0] rd_a;

        ref_model(val);

        for (int i = 0; i < 81; i++) begin
            host_wr(A_BASE + 4*i, {16'h0, A[i]});
            host_wr(B_BASE + 4*i, {16'h0, B[i]});
        end
        host_wr(N_REG, 32'd9);
        host_wr(VAL,   {16'h0, val});
        host_wr(CTRL,  32'd1);
        wait_done();

        host_rd(CRC, d);
        check32("crc", {16'h0, d[15:0]}, {16'h0, crc_ref});

        for (int i = 0; i < 81; i++) begin
            host_rd(C_BASE + 4*i, cword);
            expected = C_ref[i];
            check32($sformatf("C[%0d]", i), cword, expected);
        end

        for (int i = 0; i < 4; i++) begin
            host_rd(SUM0 + 4*i, d);
            check32($sformatf("SUM%0d", i), d, {{16{sum_ref[i][15]}}, sum_ref[i]});
        end

        for (int i = 0; i < 81; i++) begin
            host_rd(A_BASE + 4*i, d);
            rd_a = d[15:0];
            if (rd_a !== A[i]) begin
                errors++;
                $display("FAIL A[%0d] restore: got=%04x exp=%04x", i, rd_a, A[i]);
            end
            checks++;
        end

        $display("case %0d: val=%04x crc=%04x %s",
                 case_id, val, crc_ref, (errors == 0) ? "ok" : "ERROR");
    endtask

    logic [31:0] seed;
    integer i;

    initial begin
        host_req_valid = 1'b0;
        host_write     = 1'b0;
        host_addr      = 32'h0;
        host_wdata     = 32'h0;
        host_wstrb     = 4'h0;
        seed           = 32'h1234_5678;
        checks         = 0;
        errors         = 0;

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        for (int t = 0; t < 16; t++) begin
            for (i = 0; i < 81; i++) begin
                A[i] = $random(seed);
                B[i] = $random(seed);
            end
            run_case(t, $random(seed));
        end

        for (i = 0; i < 81; i++) begin A[i] = 16'sd0; B[i] = 16'sd0; end
        run_case(100, 16'sd0);

        for (i = 0; i < 81; i++) begin
            A[i] = (i & 1) ? 16'sh7fff : 16'sh8000;
            B[i] = (i & 2) ? 16'sh7fff : 16'sh8000;
        end
        run_case(101, 16'sh7fff);
        run_case(102, 16'sh8000);

        for (i = 0; i < 81; i++) begin
            A[i] = 16'sh1234 + i[15:0];
            B[i] = 16'shfedc - i[15:0];
        end
        run_case(103, 16'sh0d22);

        for (i = 0; i < 81; i++) begin
            A[i] = i * 17 - 500;
            B[i] = i * 13 + 7;
        end
        run_case(104, -16'sd8);

        $display("==============================================");
        if (errors == 0)
            $display("ALL TESTS PASSED: %0d checks - mtx9_engine", checks);
        else
            $display("FAILED: %0d errors / %0d checks", errors, checks);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT: mtx9_engine testbench");
        $finish;
    end

endmodule
