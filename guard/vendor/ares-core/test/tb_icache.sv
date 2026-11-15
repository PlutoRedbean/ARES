`timescale 1ns / 1ps
// Unit test for rtl/pipeline/core/vsrc/icache/pipeline_icache.v at the
// single-core geometry (32 sets x 4 ways x 32 B).
//
// A scoreboard checks every response against the address it was requested
// for.  The refill side models pipeline_irom_passthrough: one-cycle in-order
// responses, with pending beats dropped on flush.  Directed cases cover four
// resident lines in one set, LRU replacement and a flush or reset landing on
// the S_FILL cycle; a random phase then mixes back-pressure, flushes and resets.
module tb_icache;
    localparam integer SET_STRIDE = 32 * 32;   // NR_SETS * LINE_BYTES
    localparam [2:0]   S_FILL     = 3'd3;
    localparam [31:0]  BASE       = 32'h8000_0000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst = 1'b1;
    reg         flush = 1'b0;
    reg         req_valid = 1'b0;
    reg  [31:0] req_addr = 32'd0;
    wire        req_ready;
    wire        rsp_valid;
    wire [31:0] rsp_data;
    reg         rsp_ready = 1'b1;

    wire        refill_req_valid;
    wire [31:0] refill_req_addr;
    reg         refill_req_ready = 1'b1;
    wire        refill_rsp_valid;
    wire [31:0] refill_rsp_data;
    wire        refill_rsp_ready;

    pipeline_icache dut (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_addr(req_addr), .req_ready(req_ready),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_ready(rsp_ready),
        .flush(flush),
        .refill_req_valid(refill_req_valid), .refill_req_addr(refill_req_addr),
        .refill_req_ready(refill_req_ready),
        .refill_rsp_valid(refill_rsp_valid), .refill_rsp_data(refill_rsp_data),
        .refill_rsp_ready(refill_rsp_ready),
        .stats_dump(1'b0),
        .hit_count(), .miss_count(), .refill_count(), .request_count()
    );

    function [31:0] mem_word(input [31:0] a);
        mem_word = ({a[31:2], 2'b00} * 32'h9E37_79B1) ^ 32'h7F4A_7C15;
    endfunction

    // Refill memory: FIFO of accepted beat addresses, answered one per cycle.
    reg [31:0] rq [0:15];
    reg [3:0]  rq_head = 4'd0, rq_tail = 4'd0;
    reg [4:0]  rq_count = 5'd0;
    assign refill_rsp_valid = (rq_count != 5'd0);
    assign refill_rsp_data  = mem_word(rq[rq_head]);

    always @(posedge clk) begin
        if (rst || flush) begin
            rq_head  <= 4'd0;
            rq_tail  <= 4'd0;
            rq_count <= 5'd0;
        end else begin
            if (refill_req_valid && refill_req_ready) begin
                rq[rq_tail] <= refill_req_addr;
                rq_tail     <= rq_tail + 4'd1;
            end
            if (refill_rsp_valid && refill_rsp_ready)
                rq_head <= rq_head + 4'd1;
            rq_count <= rq_count
                      + ((refill_req_valid && refill_req_ready) ? 5'd1 : 5'd0)
                      - ((refill_rsp_valid && refill_rsp_ready) ? 5'd1 : 5'd0);
        end
    end

    // Scoreboard of accepted requests; a flush or reset drops them all.
    reg [31:0] sq [0:7];
    integer sq_head = 0, sq_tail = 0, sq_count = 0;
    integer checks = 0, errors = 0;

    always @(posedge clk) begin
        if (rst || flush) begin
            sq_head = 0; sq_tail = 0; sq_count = 0;
        end else begin
            if (rsp_valid && rsp_ready) begin
                if (sq_count == 0) begin
                    errors = errors + 1;
                    $display("ERROR t=%0t response with no outstanding request", $time);
                end else begin
                    if (rsp_data !== mem_word(sq[sq_head])) begin
                        errors = errors + 1;
                        $display("ERROR t=%0t addr=%08x got=%08x exp=%08x",
                                 $time, sq[sq_head], rsp_data, mem_word(sq[sq_head]));
                    end
                    checks   = checks + 1;
                    sq_head  = (sq_head + 1) % 8;
                    sq_count = sq_count - 1;
                end
            end
            if (req_valid && req_ready) begin
                sq[sq_tail] = req_addr;
                sq_tail     = (sq_tail + 1) % 8;
                sq_count    = sq_count + 1;
            end
        end
    end

    // Directed helpers; all stimulus changes on the falling edge.
    task automatic issue(input [31:0] a);
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_addr  = a;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic drain;
        integer guard;
        begin
            guard = 0;
            while (sq_count != 0 && guard < 200) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (sq_count != 0) begin
                errors = errors + 1;
                $display("ERROR t=%0t response timeout", $time);
            end
        end
    endtask

    task automatic fetch(input [31:0] a);
        begin
            issue(a);
            drain;
        end
    endtask

    task automatic reset_cycles(input integer n);
        begin
            @(negedge clk);
            rst = 1'b1;
            repeat (n) @(negedge clk);
            rst = 1'b0;
        end
    endtask

    // Fill one set with four lines, miss on a fifth so the LRU line (way of
    // BASE) is the victim, and hit the S_FILL cycle with flush or reset.  The
    // cache must stay consistent: every later fetch returns its own data.
    task automatic install_race(input use_reset);
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1)
                fetch(BASE + i * SET_STRIDE);
            issue(BASE + 4 * SET_STRIDE);
            while (dut.state !== S_FILL) @(negedge clk);
            if (use_reset) rst = 1'b1; else flush = 1'b1;
            @(negedge clk);
            rst = 1'b0;
            flush = 1'b0;
            for (i = 0; i < 5; i = i + 1)
                fetch(BASE + i * SET_STRIDE);
            for (i = 0; i < 5; i = i + 1)
                fetch(BASE + i * SET_STRIDE + 4 * i);
        end
    endtask

    integer cyc, seed;
    initial begin
        seed = 32'h1CAC_4E5D;
        // valid_mem has no reset by design (read-only IROM); start from an
        // empty directory so the directed cases see cold misses.
        dut.valid_mem = {32 * 4{1'b0}};
        reset_cycles(4);

        // Sequential fetch across lines, then hits on the same lines.
        for (cyc = 0; cyc < 64; cyc = cyc + 1) fetch(BASE + 32'h4000 + cyc * 4);
        for (cyc = 0; cyc < 64; cyc = cyc + 1) fetch(BASE + 32'h4000 + cyc * 4);

        install_race(1'b0);
        install_race(1'b1);

        // Random phase: pipelined requests, back-pressure on both sides,
        // random flushes, flushes and resets aimed at the install cycle.
        for (cyc = 0; cyc < 40000; cyc = cyc + 1) begin
            @(negedge clk);
            rst   = 1'b0;
            flush = 1'b0;
            if (dut.state == S_FILL && ($urandom(seed) % 4) == 0) begin
                if (($urandom(seed) % 4) == 0) rst = 1'b1; else flush = 1'b1;
            end else if (($urandom(seed) % 64) == 0) begin
                flush = 1'b1;
            end
            req_valid        = !flush && !rst && (($urandom(seed) % 4) != 0);
            req_addr         = BASE + ((($urandom(seed) % 3072)) << 2);
            rsp_ready        = (($urandom(seed) % 5) != 0);
            refill_req_ready = (($urandom(seed) % 5) != 0);
        end
        @(negedge clk);
        req_valid = 1'b0;
        rst = 1'b0;
        flush = 1'b0;
        rsp_ready = 1'b1;
        refill_req_ready = 1'b1;
        drain;

        if (errors == 0 && checks > 1000)
            $display("ICACHE UNIT TEST PASS (%0d checks)", checks);
        else
            $fatal(1, "ICACHE UNIT TEST FAILED: %0d errors over %0d checks", errors, checks);
        $finish;
    end
endmodule
