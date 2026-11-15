//=============================================================================
// list9_engine unit test
//=============================================================================
`timescale 1ns / 1ps

module tb_list9_engine;

    localparam [31:0] LE_NODE   = 32'h0000_0000;
    localparam [31:0] LE_VAL    = 32'h0000_0100;
    localparam [31:0] LE_CTRL   = 32'h0000_0700;
    localparam [31:0] LE_N      = 32'h0000_0704;
    localparam [31:0] LE_FINDER = 32'h0000_0708;
    localparam [31:0] LE_SEED3  = 32'h0000_070C;
    localparam [31:0] LE_STATUS = 32'h0000_0710;
    localparam [31:0] LE_RETVAL = 32'h0000_0714;
    localparam [31:0] LE_FOUND  = 32'h0000_0718;
    localparam [31:0] LE_MISSED = 32'h0000_071C;

    reg clk;
    reg rst = 1;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    wire        host_req_ready;
    reg         host_req_valid = 0;
    reg         host_write = 0;
    reg  [31:0] host_addr = 0;
    reg  [31:0] host_wdata = 0;
    reg  [3:0]  host_wstrb = 4'hF;
    wire        host_rsp_valid;
    wire [31:0] host_rsp_data;

    list9_engine dut (
        .clk            (clk),
        .rst            (rst),
        .host_req_valid (host_req_valid),
        .host_req_ready (host_req_ready),
        .host_write     (host_write),
        .host_addr      (host_addr),
        .host_wdata     (host_wdata),
        .host_wstrb     (host_wstrb),
        .host_rsp_valid (host_rsp_valid),
        .host_rsp_data  (host_rsp_data)
    );

    reg [31:0] mem [0:131071];
    reg [31:0] node [0:63];
    reg [31:0] vals [0:63];
    reg [31:0] raw  [0:63];
    reg [31:0] want [0:63];

    integer errors = 0;
    integer ntests, t, i, ptr;
    integer n, finder, iters, exp_dir;
    reg [31:0] exp_ret, exp_found, exp_missed;
    reg [31:0] got, st, got_ret, got_found, got_missed;
    reg [1023:0] vpath;

    task automatic wr(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            host_req_valid = 1'b1;
            host_write     = 1'b1;
            host_addr      = a;
            host_wdata     = d;
            host_wstrb     = 4'hF;
            @(negedge clk);
            host_req_valid = 1'b0;
            host_write     = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic rd(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            host_req_valid = 1'b1;
            host_write     = 1'b0;
            host_addr      = a;
            @(negedge clk);
            host_req_valid = 1'b0;
            d = host_rsp_data;
            @(negedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("VECTORS=%s", vpath))
            vpath = "build/unit/list9_vectors.hex";
        $readmemh(vpath, mem);

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        ptr = 0;
        ntests = mem[ptr];
        ptr = ptr + 1;

        for (t = 0; t < ntests; t = t + 1) begin
            n      = mem[ptr]; ptr = ptr + 1;
            finder = mem[ptr]; ptr = ptr + 1;
            iters  = mem[ptr]; ptr = ptr + 1;

            for (i = 0; i < n; i = i + 1) begin
                node[i] = mem[ptr]; ptr = ptr + 1;
            end
            for (i = 0; i < n; i = i + 1) begin
                vals[i] = mem[ptr]; ptr = ptr + 1;
            end
            exp_ret   = mem[ptr]; ptr = ptr + 1;
            exp_found = mem[ptr]; ptr = ptr + 1;
            exp_missed= mem[ptr]; ptr = ptr + 1;
            exp_dir   = mem[ptr]; ptr = ptr + 1;
            for (i = 0; i < n; i = i + 1) begin
                want[i] = mem[ptr]; ptr = ptr + 1;
            end

            for (i = 0; i < n; i = i + 1) begin
                wr(LE_NODE + 4 * i, node[i]);
                wr(LE_VAL  + 4 * i, vals[i]);
            end
            wr(LE_N,      n);
            wr(LE_FINDER, finder);
            wr(LE_SEED3,  iters);
            wr(LE_CTRL,   32'd1);

            rd(LE_STATUS, st);
            while ((st & 32'd2) == 32'd0)
                rd(LE_STATUS, st);

            rd(LE_RETVAL, got_ret);
            rd(LE_FOUND,  got_found);
            rd(LE_MISSED, got_missed);

            for (i = 0; i < n; i = i + 1)
                rd(LE_NODE + 4 * i, raw[i]);

            if (got_ret !== exp_ret) begin
                $display("FAIL test %0d: retval %04x != %04x", t, got_ret, exp_ret);
                errors = errors + 1;
            end
            if (got_found !== exp_found) begin
                $display("FAIL test %0d: found %0d != %0d", t, got_found, exp_found);
                errors = errors + 1;
            end
            if (got_missed !== exp_missed) begin
                $display("FAIL test %0d: missed %0d != %0d", t, got_missed, exp_missed);
                errors = errors + 1;
            end
            if (((st >> 2) & 1) !== exp_dir) begin
                $display("FAIL test %0d: dir %0d != %0d", t, (st >> 2) & 1, exp_dir);
                errors = errors + 1;
            end
            for (i = 0; i < n; i = i + 1) begin
                got = exp_dir ? raw[n - 1 - i] : raw[i];
                if (got !== want[i]) begin
                    $display("FAIL test %0d: order[%0d] %08x != %08x", t, i, got, want[i]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("ALL %0d LIST9 VECTORS PASSED", ntests);
        else
            $fatal(1, "%0d LIST9 VECTOR ERRORS", errors);
        $finish;
    end

endmodule
