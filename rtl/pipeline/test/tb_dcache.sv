`timescale 1ns/1ps
//=============================================================================
// Directed + random unit testbench for the 2-way set-associative L1 D-cache.
//-----------------------------------------------------------------------------
// The ISA regression cannot see associativity (a cache is functionally
// transparent), so this bench drives the generated DCache directly and checks
// the properties that only a 2-way cache has:
//
//   * two aliases of one Set stay resident at the same time,
//   * the Victim of a request is the LRU Way (invalid Way first),
//   * a store updates the Way it hit, with byte/half merging,
//   * a store miss stays write-through (memory updated, line not allocated),
//   * an invalidate clears every Way of the Set,
//   * a refill with a stale epoch is dropped,
//   * a stalled Ls1 request keeps its own lookup result (held path),
//   * a refill that collides with the Iss lookup of the same Set is forwarded
//     as a hit on the written Way and does not disturb the other Way,
//   * a long random request stream over aliased addresses always returns the
//     value the memory was left with (hits included).
//
// Geometry is fixed by CONFIG_DCACHE_WAYS=2, CONFIG_DCACHE_SIZE_KB=8:
//   1024 Sets x 2 Ways x 4 B, index addr[11:2], tag addr[17:12].
//
// Run: make pipeline-dcache-test
//=============================================================================
module tb_dcache;
    localparam integer WAY_W = 1;                    // log2(CONFIG_DCACHE_WAYS)
    localparam [31:0]  DRAM_BASE = 32'h8010_0000;
    // One word of every 4 KiB page aliases into the same Set.
    localparam [31:0]  A = 32'h8010_2000;            // Set 0, tag 2
    localparam [31:0]  B = 32'h8010_3000;            // Set 0, tag 3
    localparam [31:0]  C = 32'h8010_4000;            // Set 0, tag 4
    localparam [31:0]  D = 32'h8010_5000;            // Set 0, tag 5
    localparam [31:0]  E = 32'h8010_2004;            // Set 1, tag 2
    localparam [31:0]  F = 32'h8010_3004;            // Set 1, tag 3

    localparam [1:0]   BYTE = 2'b00;
    localparam [1:0]   HALF = 2'b01;
    localparam [1:0]   WORD = 2'b10;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    reg              lookup_valid = 1'b0;
    reg  [31:0]      lookup_addr  = 32'd0;

    reg              req_present = 1'b0;
    reg              req_valid   = 1'b0;
    reg  [31:0]      req_addr    = 32'd0;
    reg              req_write   = 1'b0;
    reg  [31:0]      req_wdata   = 32'd0;
    reg  [1:0]       req_bytes   = WORD;
    wire [WAY_W-1:0] req_way;

    reg              resp_fire = 1'b0;
    wire             resp_hit;
    wire [31:0]      resp_data;

    reg              refill_valid = 1'b0;
    reg  [31:0]      refill_addr  = 32'd0;
    reg  [31:0]      refill_data  = 32'd0;
    reg  [WAY_W-1:0] refill_way   = {WAY_W{1'b0}};
    reg  [7:0]       refill_epoch = 8'd0;

    reg              inv_valid = 1'b0;
    reg  [31:0]      inv_addr  = 32'd0;
    reg  [7:0]       epoch     = 8'd0;

    DCache dut (
        .clock            (clk),
        .reset            (rst),
        .io_lookup_valid  (lookup_valid),
        .io_lookup_addr   (lookup_addr),
        .io_req_present   (req_present),
        .io_req_valid     (req_valid),
        .io_req_addr      (req_addr),
        .io_req_write     (req_write),
        .io_req_wdata     (req_wdata),
        .io_req_bytes     (req_bytes),
        .io_req_way       (req_way),
        .io_resp_fire     (resp_fire),
        .io_resp_hit      (resp_hit),
        .io_resp_data     (resp_data),
        .io_refill_valid  (refill_valid),
        .io_refill_addr   (refill_addr),
        .io_refill_data   (refill_data),
        .io_refill_way    (refill_way),
        .io_coh_inv_valid (inv_valid),
        .io_coh_inv_addr  (inv_addr),
        .io_coh_epoch     (epoch),
        .io_refill_epoch  (refill_epoch)
    );

    //-------------------------------------------------------------------------
    // Backing memory.  Only the low 18 address bits are meaningful (the DRAM
    // window is 0x8010_0000-0x8013_ffff and every access is word aligned).
    //-------------------------------------------------------------------------
    reg [31:0] mem [0:65535];
    integer    i;
    initial begin
        for (i = 0; i < 65536; i = i + 1)
            mem[i] = 32'h5A5A_0000 ^ (i * 32'h0001_0101);
    end

    function automatic [31:0] mem_word(input [31:0] addr);
        mem_word = mem[addr[17:2]];
    endfunction

    // Write-through store as the peripheral would see it.
    task automatic mem_store(input [31:0] addr, input [31:0] data, input [1:0] bytes);
        begin
            case (bytes)
                BYTE: mem[addr[17:2]][{addr[1:0], 3'b000} +: 8] = data[7:0];
                HALF: if (addr[1]) mem[addr[17:2]][31:16] = data[15:0];
                      else         mem[addr[17:2]][15:0]  = data[15:0];
                default: mem[addr[17:2]] = data;
            endcase
        end
    endtask

    //-------------------------------------------------------------------------
    // Checking helpers
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    task automatic step; begin @(negedge clk); end endtask

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            $display("[%0t] FAIL: %s", $time, msg);
        end
    endtask

    task automatic expect_bit(input bit got, input bit want, input string msg);
        begin
            checks = checks + 1;
            if (got !== want) fail($sformatf("%s (got %0b, want %0b)", msg, got, want));
        end
    endtask

    task automatic expect_word(input [31:0] got, input [31:0] want, input string msg);
        begin
            checks = checks + 1;
            if (got !== want) fail($sformatf("%s (got %08h, want %08h)", msg, got, want));
        end
    endtask

    task automatic expect_way(input [WAY_W-1:0] got, input integer want, input string msg);
        begin
            checks = checks + 1;
            if (got !== want[WAY_W-1:0]) fail($sformatf("%s (got %0d, want %0d)", msg, got, want));
        end
    endtask

    //-------------------------------------------------------------------------
    // One request: Iss lookup in T, Ls1 accept in T+1, Ls2 response in T+2.
    // req_way is the Victim the LSU would capture for this request.
    //-------------------------------------------------------------------------
    task automatic cache_req(input [31:0] addr, input bit we, input [31:0] wdata,
                             input [1:0] bytes, output bit hit, output [31:0] rdata,
                             output [WAY_W-1:0] way);
        begin
            lookup_valid = 1'b1; lookup_addr = addr;
            step();
            req_present = 1'b1; req_valid = 1'b1; req_addr = addr;
            req_write = we; req_wdata = wdata; req_bytes = bytes;
            way = req_way;
            step();
            req_present = 1'b0; req_valid = 1'b0;
            hit = resp_hit; rdata = resp_data;
            resp_fire = 1'b1;
            step();
            resp_fire = 1'b0;
            lookup_valid = 1'b0; lookup_addr = 32'd0;
            step();
        end
    endtask

    // Install the word the peripheral would return for a miss.
    task automatic do_refill(input [31:0] addr, input [31:0] data,
                             input [WAY_W-1:0] way, input [7:0] ep);
        begin
            refill_valid = 1'b1; refill_addr = addr; refill_data = data;
            refill_way = way; refill_epoch = ep;
            step();
            refill_valid = 1'b0;
        end
    endtask

    //-------------------------------------------------------------------------
    // Directed tests
    //-------------------------------------------------------------------------
    task automatic directed_tests;
        bit         hit;
        reg  [31:0] rdata;
        reg  [WAY_W-1:0] way;

        begin
            $display("== directed tests ==");

            // --- two aliases of one Set are both resident -------------------
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "A first read misses");
            expect_way(way, 0, "A misses a cold Set and takes no particular Way");
            do_refill(A, mem_word(A), way, epoch);

            cache_req(B, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "B first read misses");
            expect_way(way, 1, "B fills the empty Way of the Set");
            do_refill(B, mem_word(B), way, epoch);

            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "A is still resident (2-way)");
            expect_word(rdata, mem_word(A), "A hit data");

            cache_req(B, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "B is still resident (2-way)");
            expect_word(rdata, mem_word(B), "B hit data");

            // --- LRU victim: the least recently used Way goes first ---------
            cache_req(C, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "C misses a full Set");
            expect_way(way, 0, "C evicts A, the LRU Way (B was used last)");
            do_refill(C, mem_word(C), way, epoch);

            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "A was evicted by C");
            do_refill(A, mem_word(A), way, epoch);

            cache_req(C, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "C survived A's refill");
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "A resident after its refill");
            expect_word(rdata, mem_word(A), "A refilled data");

            // --- a store updates the Way it hit, with byte/half merging -----
            cache_req(A, 1'b1, 32'hDEAD_BEEF, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "store to resident A hits");
            mem_store(A, 32'hDEAD_BEEF, WORD);
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "A resident after the store");
            expect_word(rdata, 32'hDEAD_BEEF, "word store visible in the cache");

            cache_req(A + 2, 1'b1, 32'h0000_1234, HALF, hit, rdata, way);
            expect_bit(hit, 1'b1, "halfword store to A+2 hits");
            mem_store(A + 2, 32'h0000_1234, HALF);
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_word(rdata, 32'h1234_BEEF, "halfword store merged into the word");

            cache_req(A + 1, 1'b1, 32'h0000_005A, BYTE, hit, rdata, way);
            expect_bit(hit, 1'b1, "byte store to A+1 hits");
            mem_store(A + 1, 32'h0000_005A, BYTE);
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_word(rdata, 32'h1234_5AEF, "byte store merged into the word");

            // --- a store miss is write-through, no allocate ------------------
            cache_req(D, 1'b1, 32'hCAFE_F00D, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "store to a non-resident D misses");
            mem_store(D, 32'hCAFE_F00D, WORD);
            cache_req(D, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "D is not allocated by the store miss");
            do_refill(D, mem_word(D), way, epoch);
            cache_req(D, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "D cached by the refill");
            expect_word(rdata, 32'hCAFE_F00D, "D refill picked up the stored word");

            // --- a remote invalidate clears both Ways of the Set ------------
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "A resident before the invalidate");
            inv_valid = 1'b1; inv_addr = A;
            step();
            inv_valid = 1'b0;
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "invalidate removed A");
            cache_req(D, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "invalidate cleared the other Way too");

            // --- stale-epoch refill is dropped ------------------------------
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "A misses after the invalidate");
            epoch = epoch + 8'd1;
            do_refill(A, mem_word(A), way, epoch - 8'd1);
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "refill with a stale epoch is not installed");
            do_refill(A, mem_word(A), way, epoch);
            cache_req(A, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "refill with the matching epoch is installed");

            // --- held Ls1 request keeps its own lookup result ---------------
            cache_req(E, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "E misses");
            do_refill(E, mem_word(E), way, epoch);
            cache_req(E, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "E resident for the held test");

            lookup_valid = 1'b1; lookup_addr = E;
            step();                                   // lookup E
            req_present = 1'b1; req_valid = 1'b0;     // Ls1 freezes
            lookup_addr = F;                          // Iss runs ahead
            step();                                   // held captures E
            step();                                   // still frozen
            req_addr = E; req_valid = 1'b1;           // the frozen request retires
            step();
            req_valid = 1'b0; req_present = 1'b0;
            expect_bit(resp_hit, 1'b1, "held request still sees its own hit");
            expect_word(resp_data, mem_word(E), "held request returns its own word");
            resp_fire = 1'b1; step(); resp_fire = 1'b0;
            lookup_valid = 1'b0; lookup_addr = 32'd0;
            step();

            // --- refill collision: Iss looks up the Set being filled --------
            // E's Way holds E and was just read; evict it by refilling C's Set?
            // Simpler: use Set 1 again. Fill E and F, then refill C while the
            // lookup of C is in flight: the request must hit the new word and
            // must not disturb the other Way.
            cache_req(F, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "F misses");
            expect_way(way, 1, "F fills the other Way of Set 1");
            do_refill(F, mem_word(F), way, epoch);
            cache_req(F, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "F resident before the collision test");

            // Make the victim of Set 1 known: read F last, so E is the Victim.
            cache_req(F, 1'b0, 32'd0, WORD, hit, rdata, way);
            cache_req(E, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "E resident before the collision test");

            // Refill a *new* word into Set 1 while Iss looks it up.
            cache_req(32'h8010_4004, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "new Set 1 alias misses");
            lookup_valid = 1'b1; lookup_addr = 32'h8010_4004;
            refill_valid = 1'b1; refill_addr = 32'h8010_4004;
            refill_data = mem_word(32'h8010_4004); refill_way = way; refill_epoch = epoch;
            step();
            refill_valid = 1'b0;
            req_present = 1'b1; req_valid = 1'b1; req_addr = 32'h8010_4004;
            step();
            req_present = 1'b0; req_valid = 1'b0;
            expect_bit(resp_hit, 1'b1, "lookup colliding with a refill is forwarded as a hit");
            expect_word(resp_data, mem_word(32'h8010_4004), "collided lookup returns the filled word");
            resp_fire = 1'b1; step(); resp_fire = 1'b0;
            lookup_valid = 1'b0; lookup_addr = 32'd0;
            step();

            // The refill took the Victim Way (F's), so F is gone and E, the
            // Way that was not written, must still match.
            cache_req(F, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b0, "the refilled Way replaced the Victim (F)");
            cache_req(E, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "the other Way of the Set survived the refill");
            expect_word(rdata, mem_word(E), "other Way data intact");
            cache_req(32'h8010_4004, 1'b0, 32'd0, WORD, hit, rdata, way);
            expect_bit(hit, 1'b1, "filled word readable after the collision");
        end
    endtask

    //-------------------------------------------------------------------------
    // Random stream: one request per cycle, like the LSU in steady state.
    // Every hit must return the value the memory model holds for that word.
    //-------------------------------------------------------------------------
    localparam integer N_OPS = 4000;
    localparam integer N_ALIAS = 8;

    reg  [31:0] op_addr [0:N_OPS-1];
    reg         op_we   [0:N_OPS-1];
    reg  [31:0] op_data [0:N_OPS-1];
    reg  [1:0]  op_bytes[0:N_OPS-1];
    reg  [31:0] exp_data[0:N_OPS-1];
    reg  [WAY_W-1:0] way_i[0:N_OPS-1];

    function automatic [31:0] alias_addr(input integer k);
        begin
            case (k)
                0: alias_addr = A;
                1: alias_addr = B;
                2: alias_addr = C;
                3: alias_addr = D;
                4: alias_addr = E;
                5: alias_addr = F;
                6: alias_addr = 32'h8010_4004;
                default: alias_addr = 32'h8010_5004;
            endcase
        end
    endfunction

    task automatic random_tests;
        integer      n;
        integer      hits;
        integer      misses;
        integer      dropped;
        integer      k;
        reg [31:0]   addr;
        bit          store_ahead;
        reg          refill_pend;
        reg [31:0]   refill_pend_addr;
        reg [31:0]   refill_pend_data;
        reg [WAY_W-1:0] refill_pend_way;

        begin
            $display("== random stream ==");
            for (n = 0; n < N_OPS; n = n + 1) begin
                k = $unsigned($random) % N_ALIAS;
                addr = alias_addr(k);
                op_we[n] = ($unsigned($random) % 4) == 0;
                k = $unsigned($random) % 3;
                op_bytes[n] = (k == 0) ? BYTE : (k == 1 && addr[0] == 1'b0) ? HALF : WORD;
                addr = addr + ((op_bytes[n] == BYTE) ? ($unsigned($random) % 4) :
                               (op_bytes[n] == HALF) ? (($unsigned($random) % 2) << 1) : 0);
                op_addr[n] = addr;
                op_data[n] = $random;
            end

            hits = 0; misses = 0; dropped = 0;
            refill_pend = 1'b0;
            req_present = 1'b0;
            lookup_valid = 1'b1;
            // The LSU always has the Iss lookup one cycle ahead of Ls1; prime
            // the lookup port with the first request before starting.  Ls1 must
            // stay empty here, otherwise the cache correctly latches this
            // still-undefined read as a held Ls1 result.
            lookup_addr = op_addr[0];
            step();
            req_present = 1'b1;

            for (n = 0; n < N_OPS; n = n + 1) begin
                // Drive the refill scheduled in the previous cycle: this puts
                // the install at the load's Ls3, like the LSU does.
                if (refill_pend) begin
                    refill_valid = 1'b1;
                    refill_addr  = refill_pend_addr;
                    refill_data  = refill_pend_data;
                    refill_way   = refill_pend_way;
                    refill_epoch = epoch;
                    refill_pend  = 1'b0;
                end else begin
                    refill_valid = 1'b0;
                end

                // Response of request n-1 is in resp_valid/resp_* this cycle.
                if (n > 0) begin
                    if (resp_hit) begin
                        hits = hits + 1;
                        if (!op_we[n-1])
                            expect_word(resp_data, exp_data[n-1],
                                $sformatf("random load #%0d @%08h hit data", n-1, op_addr[n-1]));
                    end else begin
                        misses = misses + 1;
                        // The LSU installs load misses only, and drops a refill
                        // when a younger store already overwrote the word.
                        store_ahead = 1'b0;
                        if (n < N_OPS && op_we[n] &&
                            op_addr[n][31:2] === op_addr[n-1][31:2]) store_ahead = 1'b1;
                        if (n + 1 < N_OPS && op_we[n+1] &&
                            op_addr[n+1][31:2] === op_addr[n-1][31:2]) store_ahead = 1'b1;
                        if (!op_we[n-1] && !store_ahead && !refill_pend) begin
                            refill_pend = 1'b1;
                            refill_pend_addr = op_addr[n-1];
                            refill_pend_data = exp_data[n-1];
                            refill_pend_way  = way_i[n-1];
                        end else if (!op_we[n-1]) begin
                            dropped = dropped + 1;
                        end
                    end
                end
                resp_fire = (n > 0);

                // Issue request n and the lookup that belongs to it next cycle.
                req_valid = 1'b1;
                req_addr  = op_addr[n];
                req_write = op_we[n];
                req_wdata = op_data[n];
                req_bytes = op_bytes[n];
                way_i[n]  = req_way;
                lookup_addr = op_addr[n+1 < N_OPS ? n+1 : n];
                exp_data[n] = mem_word(op_addr[n]);   // value before this op's store
                if (op_we[n]) mem_store(op_addr[n], op_data[n], op_bytes[n]);

                step();
            end

            // Drain the last response.
            resp_fire = 1'b1; req_valid = 1'b0; lookup_valid = 1'b0;
            refill_valid = 1'b0;
            step();
            if (resp_hit) begin
                hits = hits + 1;
                if (!op_we[N_OPS-1])
                    expect_word(resp_data, exp_data[N_OPS-1], "final random load hit data");
            end else begin
                misses = misses + 1;
            end
            resp_fire = 1'b0;
            step();

            $display("random stream: %0d accesses, %0d hits, %0d misses, %0d refills dropped",
                     N_OPS, hits, misses, dropped);
            checks = checks + 1;
            if (hits < N_OPS / 10) fail("random stream hit rate is implausibly low");
        end
    endtask

    //-------------------------------------------------------------------------
    initial begin
        rst = 1'b1;
        repeat (4) step();
        rst = 1'b0;
        // The directory is cleared one Set per cycle at reset (1024 Sets).
        repeat (1100) step();

        directed_tests();
        random_tests();

        $display("");
        if (errors == 0)
            $display("DCACHE UNIT TEST PASS (%0d checks)", checks);
        else
            $display("DCACHE UNIT TEST FAIL (%0d errors / %0d checks)", errors, checks);
        if (errors != 0) $fatal(1, "dcache unit test failed");
        $finish;
    end
endmodule