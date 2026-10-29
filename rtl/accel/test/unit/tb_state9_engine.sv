//=============================================================================
// ARES - unit testbench for state9_engine
//-----------------------------------------------------------------------------
// Drives the MMIO window and compares CRC / final counts / track counts /
// post-undo data against a bit-exact model of CoreMark core_bench_state().
//=============================================================================
`timescale 1ns/1ps
module tb_state9_engine;

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

    state9_engine dut (
        .clk(clk), .rst(rst),
        .host_req_valid(host_req_valid), .host_req_ready(host_req_ready),
        .host_write(host_write), .host_addr(host_addr),
        .host_wdata(host_wdata), .host_wstrb(host_wstrb),
        .host_rsp_valid(host_rsp_valid), .host_rsp_data(host_rsp_data)
    );

    localparam logic [11:0] DATA   = 12'h000;
    localparam logic [11:0] CTRL   = 12'h700;
    localparam logic [11:0] BLKSZ  = 12'h704;
    localparam logic [11:0] SEED1  = 12'h708;
    localparam logic [11:0] SEED2  = 12'h70C;
    localparam logic [11:0] STEP   = 12'h710;
    localparam logic [11:0] CRCIN  = 12'h714;
    localparam logic [11:0] STATUS = 12'h718;
    localparam logic [11:0] CRCOUT = 12'h71C;
    localparam logic [11:0] FINAL0 = 12'h720;
    localparam logic [11:0] TRACK0 = 12'h740;

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

    //-------------------------------------------------------------------------
    // Reference model
    //-------------------------------------------------------------------------
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
        input logic [15:0] v,
        input logic [15:0] crc_in
    );
        logic [15:0] c;
        c = ref_crc8(v[7:0], crc_in);
        c = ref_crc8(v[15:8], c);
        return c;
    endfunction

    function automatic logic [15:0] ref_crcu32(
        input logic [31:0] v,
        input logic [15:0] crc_in
    );
        logic [15:0] c;
        c = ref_crc16(v[15:0], crc_in);
        c = ref_crc16(v[31:16], c);
        return c;
    endfunction

    logic [7:0]  data [0:1023];
    logic [7:0]  ref_mem [0:1023];
    logic [31:0] ref_final [0:7];
    logic [31:0] ref_track [0:7];
    logic [15:0] ref_crc;

    task automatic ref_transition(inout integer p, output logic [2:0] state);
        logic [7:0] c;
        logic is_digit, is_pm, is_dot, is_e;
        state = 3'd0;
        while (ref_mem[p] != 8'h00 && state != 3'd1) begin
            c = ref_mem[p];
            if (c == 8'h2C) begin
                p = p + 1;
                break;
            end
            is_digit = (c >= 8'h30) && (c <= 8'h39);
            is_pm    = (c == 8'h2B) || (c == 8'h2D);
            is_dot   = (c == 8'h2E);
            is_e     = (c == 8'h45) || (c == 8'h65);

            unique case (state)
                3'd0: begin // START
                    if (is_digit)      state = 3'd4;
                    else if (is_pm)    state = 3'd2;
                    else if (is_dot)   state = 3'd5;
                    else begin
                        state = 3'd1;
                        ref_track[1] = ref_track[1] + 32'd1;
                    end
                    ref_track[0] = ref_track[0] + 32'd1;
                end
                3'd2: begin // S1
                    ref_track[2] = ref_track[2] + 32'd1;
                    if (is_digit)      state = 3'd4;
                    else if (is_dot)   state = 3'd5;
                    else               state = 3'd1;
                end
                3'd4: begin // INT
                    if (is_dot) begin
                        state = 3'd5;
                        ref_track[4] = ref_track[4] + 32'd1;
                    end else if (!is_digit) begin
                        state = 3'd1;
                        ref_track[4] = ref_track[4] + 32'd1;
                    end
                end
                3'd5: begin // FLOAT
                    if (is_e) begin
                        state = 3'd3;
                        ref_track[5] = ref_track[5] + 32'd1;
                    end else if (!is_digit) begin
                        state = 3'd1;
                        ref_track[5] = ref_track[5] + 32'd1;
                    end
                end
                3'd3: begin // S2
                    ref_track[3] = ref_track[3] + 32'd1;
                    if (is_pm) state = 3'd6;
                    else       state = 3'd1;
                end
                3'd6: begin // EXPONENT
                    ref_track[6] = ref_track[6] + 32'd1;
                    if (is_digit) state = 3'd7;
                    else          state = 3'd1;
                end
                3'd7: begin // SCIENTIFIC
                    if (!is_digit) begin
                        state = 3'd1;
                        ref_track[1] = ref_track[1] + 32'd1;
                    end
                end
                default: state = 3'd1;
            endcase
            p = p + 1;
        end
    endtask

    task automatic ref_bench(input integer blksize,
                             input logic signed [15:0] seed1,
                             input logic signed [15:0] seed2,
                             input logic signed [15:0] step,
                             input logic [15:0] crcin);
        integer p;
        logic [2:0] st;
        for (int i = 0; i < 1024; i++) ref_mem[i] = data[i];
        for (int i = 0; i < 8; i++) begin
            ref_final[i] = 32'h0;
            ref_track[i] = 32'h0;
        end
        p = 0;
        while (ref_mem[p] != 8'h00) begin
            ref_transition(p, st);
            ref_final[st] = ref_final[st] + 32'd1;
        end
        for (p = 0; p < blksize; p = p + step)
            if (ref_mem[p] != 8'h2C)
                ref_mem[p] = ref_mem[p] ^ seed1[7:0];
        p = 0;
        while (ref_mem[p] != 8'h00) begin
            ref_transition(p, st);
            ref_final[st] = ref_final[st] + 32'd1;
        end
        for (p = 0; p < blksize; p = p + step)
            if (ref_mem[p] != 8'h2C)
                ref_mem[p] = ref_mem[p] ^ seed2[7:0];
        ref_crc = crcin;
        for (int i = 0; i < 8; i++) begin
            ref_crc = ref_crcu32(ref_final[i], ref_crc);
            ref_crc = ref_crcu32(ref_track[i], ref_crc);
        end
    endtask

    //-------------------------------------------------------------------------
    // Checks
    //-------------------------------------------------------------------------
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
                            input integer blksize,
                            input logic signed [15:0] seed1,
                            input logic signed [15:0] seed2,
                            input logic signed [15:0] step,
                            input logic [15:0] crcin);
        logic [31:0] d;
        logic [31:0] w;
        logic [31:0] rdword;

        for (int i = blksize; i < 1024; i++) data[i] = 8'h00;
        ref_bench(blksize, seed1, seed2, step, crcin);

        for (int i = 0; i < blksize; i += 4) begin
            w = 32'h0;
            for (int j = 0; j < 4; j++)
                if ((i + j) < blksize)
                    w[8*j +: 8] = data[i + j];
            host_wr(DATA + 12'(i), w);
        end
        host_wr(BLKSZ, blksize);
        host_wr(SEED1, {16'h0, seed1});
        host_wr(SEED2, {16'h0, seed2});
        host_wr(STEP, {16'h0, step});
        host_wr(CRCIN, {16'h0, crcin});
        host_wr(CTRL, 32'd1);
        wait_done();

        host_rd(CRCOUT, d);
        check32("crc", {16'h0, d[15:0]}, {16'h0, ref_crc});

        for (int i = 0; i < 8; i++) begin
            host_rd(FINAL0 + 12'(4*i), d);
            check32($sformatf("FINAL%0d", i), d, ref_final[i]);
            host_rd(TRACK0 + 12'(4*i), d);
            check32($sformatf("TRACK%0d", i), d, ref_track[i]);
        end

        for (int i = 0; i < blksize; i += 4) begin
            host_rd(DATA + 12'(i), rdword);
            for (int j = 0; j < 4; j++) begin
                if ((i + j) < blksize) begin
                    checks++;
                    if (rdword[8*j +: 8] !== ref_mem[i + j]) begin
                        errors++;
                        $display("FAIL data[%0d]: got=%02x exp=%02x",
                                 i + j, rdword[8*j +: 8], ref_mem[i + j]);
                    end
                end
            end
        end

        $display("case %0d: step=%0d crc=%04x %s",
                 case_id, step, ref_crc, (errors == 0) ? "ok" : "ERROR");
    endtask


    function automatic logic [15:0] rand_step(input logic [31:0] s);
        logic [31:0] r;
        logic [15:0] v;
        r = $random(s);
        v = r[15:0] & 16'h00FF;
        if (v == 16'd0) v = 16'd1;
        return v;
    endfunction

    //-------------------------------------------------------------------------
    // Stimulus
    //-------------------------------------------------------------------------
    logic [31:0] seed;
    integer i, j;
    string patterns;

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

        // Random blocks, NUL-terminated at 665; random NUL/commas inside.
        for (int t = 0; t < 12; t++) begin
            for (i = 0; i < 1024; i++) data[i] = $random(seed);
            for (i = 0; i < 666; i++)
                if (data[i] == 8'h00) data[i] = 8'h20;
            data[665] = 8'h00;
            run_case(t, 666, 16'sh3415, 16'sh3415,
                     (t == 0) ? 16'sh22 : (t == 1) ? 16'sh01 : rand_step(seed),
                     $random(seed));
        end

        // Directed token stream with all state-machine paths.
        patterns = "5012,1234,-874,+122,35.54400,.1234500,-110.700,+0.64400,5.500e+3,-.123e-2,-87e+832,+0.6e-12,T0.3e-1F,-T.T++Tq,1T3.4e4z,34.0e-T^,";
        for (i = 0; i < 1024; i++) data[i] = 8'h20;
        for (i = 0; i < patterns.len(); i++) data[i] = patterns[i];
        data[patterns.len()] = 8'h00;
        run_case(100, 666, 16'sh3415, 16'sh3415, 16'sh22, 16'h0);
        run_case(101, 666, 16'sh3415, 16'sh3415, 16'sh01, 16'hbeef);
        run_case(102, 666, 16'sh3415, 16'sh3415, 16'shff, 16'h1234);

        // Leading/trailing commas and an early NUL.
        for (i = 0; i < 1024; i++) data[i] = 8'h20;
        data[0] = 8'h2C; data[1] = 8'h2C; data[2] = 8'h31;
        data[3] = 8'h2C; data[4] = 8'h00;
        run_case(103, 666, 16'sh3415, 16'sh3415, 16'sh22, 16'h0);

        $display("==============================================");
        if (errors == 0)
            $display("ALL TESTS PASSED: %0d checks - state9_engine", checks);
        else
            $display("FAILED: %0d errors / %0d checks", errors, checks);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "TIMEOUT: state9_engine testbench");
    end

endmodule
