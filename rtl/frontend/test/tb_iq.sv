/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
// Self-checking testbench for the instruction queue (iq.sv).
//
// Built with the explicit package/source ordering in make unit-frontend;
// scripts/test.mk retains the historical test entrypoint.
// Ported from ysyx-workbench/npc/vsrc/test/tb_iq.sv and adapted to the
// counting handshake of docs/microarch/frontend_backend_contract.md §2.
//
// The queue width follows fe_pkg::FETCH_WIDTH and the read port follows
// DECODE_WIDTH.  The tests are width-agnostic: a scoreboard keeps the expected
// FIFO order so the same stimulus checks the 2-wide and 4-wide configurations
// (and any future width).
//
// Read protocol modelled here (counting handshake)
// ------------------------------------------------
// The IQ tells the IDU which HEAD slots are valid through rvalid/rbits.  The
// IDU answers with raccept_cnt alone -- there is no rready -- where
// raccept_cnt is the number of entries it actually consumed this cycle.  Hence
// the invariants
//
//     raccept_cnt <= popcount(rvalid)     (and raccept_cnt != 3)
//
// always hold at the input, and on a Redirect/Reset cycle the back-end drives
// raccept_cnt = 0.  parse_head() below samples rvalid/rbits first and derives
// raccept_cnt from what was read, so this testbench never drives an illegal
// consume.
//
// wmask contract
// --------------
// The IQ counts write_num = popcount(wmask) and packs the *leading* slots
// wdata[0..write_num-1]; it does not support holes inside the mask.  The
// testbench therefore only drives low-contiguous masks (checked in press_block).
`timescale 1ns / 1ps


module tb_iq;
    import fe_pkg::*;

    // iq.sv hardcodes a 2-entry HEAD and a 2-bit consume, so DECODE_WIDTH must stay
    // 2 for now; the widths are still derived so the intent is explicit.
    localparam int unsigned ACC_W = (DECODE_WIDTH > 0) ? $clog2(DECODE_WIDTH + 1) : 1;

    // how many steady-state push/pop rounds walk the BODY ring pointers a few
    // full laps (push DECODE_WIDTH / pop DECODE_WIDTH per round)
    localparam int unsigned WRAP_ROUNDS = 2 * (IQ_DEPTH - DECODE_WIDTH) + 8;

    logic clk;
    logic rst;
    logic wvalid;
    iq_entry_t wdata[FETCH_WIDTH];
    logic [FETCH_WIDTH-1:0] wmask;
    logic wready;
    logic [DECODE_WIDTH-1:0] rvalid;
    logic [ACC_W-1:0] raccept_cnt;
    iq_entry_t rbits[DECODE_WIDTH];
    logic [$clog2(IQ_DEPTH+1)-1:0] occupancy;
    logic [$clog2(FETCH_WIDTH+1)-1:0] enq_count;
    logic [$clog2(DECODE_WIDTH+1)-1:0] deq_count;
    logic flush;

    int errors = 0;
    int checks = 0;
    int unsigned exp_q[$];  // expected instruction PCs, in FIFO order

    iq dut (.*);

    always #5 clk = ~clk;

    // ---------------------------------------------------------------- helpers
    // Every field gets a PC-dependent value so a field that is dropped, zeroed
    // or swapped while passing through HEAD / BODY is caught.
    function automatic iq_entry_t make_iq_entry(input int pc);
        iq_entry_t e;
        e = '0;
        e.pc = pc[31:0];
        e.inst = 32'hDEAD_0000 ^ (32'(pc) * 32'h0001_0001);
        e.valid = 1'b1; // visible valid is queue state, not an opaque payload bit
        e.pred_npc=32'h80000004 + 32'(pc*4);
        e.pred_meta.ghr_before=GHR_WIDTH'(pc ^ 123);
        e.pred_meta.pred_type=CFI_COND_BRANCH;
        e.pred_meta.pred_taken = pc[1];
        e.pred_meta.pred_target = 32'h8000_0000 + (32'(pc) << 2);
`ifdef TOURNAMENT_ON
        e.pred_meta.chooser_meta.update_gshare_taken = pc[2];
        e.pred_meta.chooser_meta.update_bimodal_taken = pc[3];
        e.pred_meta.chooser_meta.pred_ghr = GHR_WIDTH'(pc);
`endif
`ifdef LOOP_PRED_ON
        e.pred_meta.loop_override = pc[4];
`endif
        e.cfi_type = cfi_type_t'(pc % 6);
        e.is_cfi = pc[5];
        make_iq_entry = e;
    endfunction

    function automatic bit entry_eq(input iq_entry_t a, input iq_entry_t b);
        bit ok;
        ok = (a.pc == b.pc) &&
             (a.inst == b.inst) &&
             (a.valid == b.valid) &&
             (a.cfi_type == b.cfi_type) &&
             (a.is_cfi == b.is_cfi) &&
             (a.pred_npc == b.pred_npc) && (a.pred_meta.ghr_before == b.pred_meta.ghr_before) &&
             (a.pred_meta.pred_type == b.pred_meta.pred_type) && (a.pred_meta.pred_taken == b.pred_meta.pred_taken) &&
             (a.pred_meta.pred_target == b.pred_meta.pred_target);
`ifdef TOURNAMENT_ON
        ok = ok &&
             (a.pred_meta.chooser_meta.update_gshare_taken ==
              b.pred_meta.chooser_meta.update_gshare_taken) &&
             (a.pred_meta.chooser_meta.update_bimodal_taken ==
              b.pred_meta.chooser_meta.update_bimodal_taken) &&
             (a.pred_meta.chooser_meta.pred_ghr == b.pred_meta.chooser_meta.pred_ghr);
`endif
`ifdef LOOP_PRED_ON
        ok = ok && (a.pred_meta.loop_override == b.pred_meta.loop_override);
`endif
        return ok;
    endfunction

    function automatic bit is_zero_entry(input iq_entry_t e);
        iq_entry_t z;
        z = '0;
        return entry_eq(e, z);
    endfunction

    // wmask must be a contiguous run of ones in the low slots
    function automatic bit is_contig(input logic [FETCH_WIDTH-1:0] m);
        int n;
        bit ok;
        n  = $countones(m);
        ok = 1'b1;
        for (int i = 0; i < FETCH_WIDTH; i++) ok &= (i < n) ? m[i] : ~m[i];
        return ok;
    endfunction

    task automatic tick();
        @(posedge clk);
        #1;
    endtask

    task automatic check(input string name, input logic cond, input bit quiet = 1'b0);
        checks++;
        if (!cond) begin
            $display("FAIL: %s", name);
            errors++;
        end else if (!quiet) begin
            $display("PASS: %s", name);
        end
    endtask

    // compare a read-out entry against the value make_iq_entry would produce
    task automatic check_entry(input string name, input iq_entry_t got, input int pc,
                               input bit quiet = 1'b1);
        iq_entry_t exp;
        exp = make_iq_entry(pc);
        checks++;
        if (entry_eq(got, exp)) begin
            if (!quiet) $display("PASS: %s", name);
        end else begin
            errors++;
            $display("FAIL: %s field mismatch (expected pc=%0d)", name, pc);
            $display("  exp pc=%0d inst=%h valid=%b taken=%b tgt=%h cfi=%0d is_cfi=%b", exp.pc,
                     exp.inst, exp.valid, exp.pred_meta.pred_taken, exp.pred_meta.pred_target,
                     exp.cfi_type, exp.is_cfi);
            $display("  got pc=%0d inst=%h valid=%b taken=%b tgt=%h cfi=%0d is_cfi=%b", got.pc,
                     got.inst, got.valid, got.pred_meta.pred_taken, got.pred_meta.pred_target,
                     got.cfi_type, got.is_cfi);
`ifdef TOURNAMENT_ON
            $display("  exp chooser g=%b b=%b ghr=%h",
                     exp.pred_meta.chooser_meta.update_gshare_taken,
                     exp.pred_meta.chooser_meta.update_bimodal_taken,
                     exp.pred_meta.chooser_meta.pred_ghr);
            $display("  got chooser g=%b b=%b ghr=%h",
                     got.pred_meta.chooser_meta.update_gshare_taken,
                     got.pred_meta.chooser_meta.update_bimodal_taken,
                     got.pred_meta.chooser_meta.pred_ghr);
`endif
`ifdef LOOP_PRED_ON
            $display("  exp loop_override=%b got loop_override=%b",
                     exp.pred_meta.loop_override, got.pred_meta.loop_override);
`endif
        end
    endtask

    // verify the current read port against the scoreboard (and the structural
    // invariant that the valid slots are always a low-contiguous prefix)
    task automatic check_head(input string name, input bit quiet = 1'b1);
        int avail;
        avail = $countones(rvalid);
        check({name, " rvalid != 2'b10"}, (DECODE_WIDTH != 2) || (rvalid != 2'b10), quiet);
        check({name, " head <= model"}, avail <= exp_q.size(), quiet);
        check({name, " occupancy == model"}, int'(occupancy) == exp_q.size(), quiet);
        for (int i = 0; i < DECODE_WIDTH; i++) begin
            if ((i < avail) && (i < exp_q.size()))
                check_entry($sformatf("%s h%0d", name, i), rbits[i], exp_q[i], quiet);
        end
    endtask

    // Drive one write block.  `accepted` reports whether the IQ took it; the
    // scoreboard is only updated on acceptance.
    task automatic press_block(input int base, input logic [FETCH_WIDTH-1:0] mask,
                               output bit accepted);
        int n;
        if (!is_contig(mask)) begin
            $display("FAIL: press_block drove non-contiguous wmask=%b", mask);
            errors++;
        end
        n = $countones(mask);
        for (int s = 0; s < FETCH_WIDTH; s++) wdata[s] = make_iq_entry(base + s);
        wmask  = mask;
        wvalid = 1;
        #1;  // let the combinational accept logic observe the new inputs
        accepted = wready && (n != 0);
        check("enq_count matches write", int'(enq_count) == (accepted ? n : 0), 1'b1);
        if (accepted) for (int s = 0; s < n; s++) exp_q.push_back(base + s);
        tick();
        wvalid = 0;
        wmask  = 0;
        tick();
    endtask

    // Read the head out, decide how many to consume from what was read, then
    // assert raccept_cnt.  `want` is a request and is clamped to the observed
    // rvalid, mimicking a real IDU.  raccept_cnt is the only consume condition
    // (counting handshake: no rready).
    task automatic read_and_consume(input string name, input int want);
        int avail;
        int take;
        avail = $countones(rvalid);
        check_head(name);  // scoreboard + rvalid shape
        take = (want < avail) ? want : avail;
        check({name, " accept <= read"}, int'(take) <= avail, 1'b1);
        raccept_cnt = ACC_W'(take);
        #1;
        check("deq_count matches accept", int'(deq_count) == take, 1'b1);
        repeat (take) if (exp_q.size() > 0) void'(exp_q.pop_front());
        tick();
        raccept_cnt = 0;
        tick();
    endtask

    // consume and write in the same cycle (exercises free_slots + body_r_dec)
    task automatic read_write(input string name, input int want, input int base,
                              input logic [FETCH_WIDTH-1:0] mask, output bit accepted);
        int avail;
        int take;
        int wnum;
        avail = $countones(rvalid);
        check_head(name);
        take = (want < avail) ? want : avail;
        wnum = $countones(mask);
        for (int s = 0; s < FETCH_WIDTH; s++) wdata[s] = make_iq_entry(base + s);
        wmask       = mask;
        wvalid      = 1;
        raccept_cnt = ACC_W'(take);
        #1;
        accepted = wready && (wnum != 0);
        repeat (take) if (exp_q.size() > 0) void'(exp_q.pop_front());
        if (accepted) for (int s = 0; s < wnum; s++) exp_q.push_back(base + s);
        tick();
        wvalid      = 0;
        wmask       = 0;
        raccept_cnt = 0;
        tick();
    endtask

    task automatic drain_all(input string name);
        while (exp_q.size() > 0) begin
            if ($countones(rvalid) == 0) begin
                $display("FAIL: %s queue non-empty (%0d left) but rvalid=0", name, exp_q.size());
                errors++;
                break;
            end
            read_and_consume(name, DECODE_WIDTH);
        end
        check({name, " empty"}, rvalid == 0, 1'b1);
    endtask

    // ------------------------------------------------------------------ tests
    // all entry fields survive both the HEAD path and the BODY->HEAD promotion
    task automatic run_struct_tests();
        bit acc;
        press_block(100, {FETCH_WIDTH{1'b1}}, acc);
        check("struct full accepted", acc == 1);
        check_entry("struct h0 fields", rbits[0], 100, 1'b0);
        check_entry("struct h1 fields", rbits[1], 101, 1'b0);
        drain_all("struct full");

        // two blocks: the first block's tail sits in BODY and is promoted later
        // (needs room for two full blocks, i.e. 2*FETCH_WIDTH entries)
        if (IQ_DEPTH >= 2 * FETCH_WIDTH) begin
            press_block(200, {FETCH_WIDTH{1'b1}}, acc);
            check("struct blk1 accepted", acc == 1);
            press_block(300, {FETCH_WIDTH{1'b1}}, acc);
            check("struct blk2 accepted", acc == 1);
            drain_all("struct two blocks");
        end
    endtask

    // how a fetch block is split between HEAD and BODY for this width
    task automatic run_width_tests();
        bit acc;
        press_block(400, {FETCH_WIDTH{1'b1}}, acc);
        check("width full accepted", acc == 1);
        check("width head count", $countones(rvalid) == ((FETCH_WIDTH < 2) ? FETCH_WIDTH : 2));
        check_entry("width h0", rbits[0], 400, 1'b0);
        if ($countones(rvalid) > 1) check_entry("width h1", rbits[1], 401, 1'b0);
        drain_all("width full");

        if (FETCH_WIDTH == 4) begin
            press_block(500, 4'b0111, acc);
            check("w4 3-wide accepted", acc == 1);
            check("w4 3-wide head=2", $countones(rvalid) == 2);
            check_entry("w4 3-wide h0", rbits[0], 500, 1'b0);
            check_entry("w4 3-wide h1", rbits[1], 501, 1'b0);
            drain_all("w4 3-wide");

            press_block(600, 4'b0011, acc);
            check("w4 2-wide head=2", $countones(rvalid) == 2);
            drain_all("w4 2-wide");

            press_block(700, 4'b0001, acc);
            check("w4 1-wide head=1", $countones(rvalid) == 1);
            check("w4 1-wide rbits1 zero", is_zero_entry(rbits[1]));
            drain_all("w4 1-wide");
        end

        if (FETCH_WIDTH == 2) begin
            press_block(800, FETCH_WIDTH'(2'b01), acc);
            check("w2 1-wide head=1", $countones(rvalid) == 1);
            check("w2 1-wide rbits1 zero", is_zero_entry(rbits[1]));
            drain_all("w2 1-wide");
        end
    endtask

    task automatic run_boundary_tests();
        bit acc;
        int avail;

        // (a) IDU bubble: raccept_cnt=0 must consume nothing and keep the head
        //     stable (frontend_backend_contract.md §2)
        press_block(1000, {FETCH_WIDTH{1'b1}}, acc);
        read_and_consume("bubble", 0);
        check("bubble model intact", exp_q.size() == FETCH_WIDTH);
        check_entry("bubble h0 unchanged", rbits[0], 1000, 1'b1);
        drain_all("bubble");

        // (b) IDU wants more than the head exposes -> raccept_cnt clamps to the
        //     entries that were actually read this cycle
        press_block(1100, {FETCH_WIDTH{1'b1}}, acc);
        avail = $countones(rvalid);
        check("clamp has a valid prefix", avail > 0);
        read_and_consume("clamp", avail + 1);
        drain_all("clamp");

        // (c) backpressure: fill until a block is refused, then drain in order
        press_block(1200, {FETCH_WIDTH{1'b1}}, acc);
        check("cap first accepted", acc == 1);
        begin
            bit a2;
            int it;
            int bound;
            a2 = 1;
            it = 0;
            bound = IQ_DEPTH / FETCH_WIDTH + 2;
            while (a2 && (it < bound)) begin
                press_block(1300 + it * 10, {FETCH_WIDTH{1'b1}}, a2);
                it++;
            end
            check("cap refused when full", a2 == 0);
        end
        drain_all("cap full");

        // (d) partial capacity: leave exactly 2 BODY slots free (with the HEAD
        //     full) so a full block is refused, a 2-wide block fits exactly and a
        //     1-wide one no longer does.  The fill count is derived from the
        //     configured IQ depth so the test tracks BODY_DEPTH.
        if ((FETCH_WIDTH == 4) && ((IQ_DEPTH - DECODE_WIDTH) >= 5)) begin
            int body_depth;
            int extra;
            body_depth = IQ_DEPTH - DECODE_WIDTH;
            press_block(2000, 4'b0001, acc);  // HEAD=1
            press_block(2010, 4'b1111, acc);  // HEAD=2, BODY=3
            // top the BODY up to body_depth - 2 (i.e. 2 free slots)
            extra = body_depth - 5;
            for (int k = 0; k < extra; k++) press_block(2020 + k, 4'b0001, acc);
            press_block(3000, 4'b1111, acc);
            check("partial full refused", acc == 0);
            press_block(3010, 4'b0011, acc);
            check("partial 2 accepted", acc == 1);
            press_block(3020, 4'b0001, acc);
            check("partial 1 refused", acc == 0);
            drain_all("partial");
        end

        // (e) contract §2 stability: with raccept_cnt=0 a concurrent write is
        //     appended behind the head entry; the oldest entry must not move
        begin
            logic [FETCH_WIDTH-1:0] one = '0;
            one[0] = 1'b1;
            press_block(1400, one, acc);
            read_write("stable", 0, 1410, one, acc);
            check("stable write accepted", acc == 1);
            check_entry("stable h0 not moved", rbits[0], 1400, 1'b1);
            if (DECODE_WIDTH > 1) check_entry("stable h1 appended", rbits[1], 1410, 1'b1);
            drain_all("stable");
        end
    endtask

    task automatic run_concurrency_tests();
        bit acc;
        press_block(3000, {FETCH_WIDTH{1'b1}}, acc);
        read_write("conc rw1", 1, 3100, {FETCH_WIDTH{1'b1}}, acc);
        drain_all("conc rw");

        press_block(3200, {FETCH_WIDTH{1'b1}}, acc);
        read_write("conc rw2", DECODE_WIDTH, 3300, {FETCH_WIDTH{1'b1}}, acc);
        drain_all("conc rw2");

        if (FETCH_WIDTH == 4) begin
            // HEAD full + BODY full: a full block alone is refused, but a 2-wide
            // block paired with a 2-entry consume fits because the consume frees
            // two BODY slots in the same cycle.  Fill depth-agnostic first.
            bit a2;
            int it;
            int bound;
            a2 = 1;
            it = 0;
            bound = IQ_DEPTH / FETCH_WIDTH + 2;
            while (a2 && (it < bound)) begin
                press_block(3400 + it * 10, 4'b1111, a2);
                it++;
            end
            check("conc queue full", a2 == 0);
            read_write("conc free", 2, 3420, 4'b0011, acc);
            check("conc free accepted", acc == 1);
            drain_all("conc free");
        end
    endtask

    // long interleaved push/drain at steady state that walks the BODY ring
    // pointers past the wrap point several times, verified entry-by-entry
    // through the scoreboard
    task automatic run_wrap_tests();
        bit acc;
        logic [FETCH_WIDTH-1:0] low2;
        low2 = '0;
        for (int s = 0; s < DECODE_WIDTH; s++) low2[s] = 1'b1;
        drain_all("wrap pre");
        // backlog so the BODY never empties and every write lands in the BODY
        press_block(7000, {FETCH_WIDTH{1'b1}}, acc);
        press_block(7010, {FETCH_WIDTH{1'b1}}, acc);
        for (int i = 0; i < WRAP_ROUNDS; i++) begin
            read_write("wrap", DECODE_WIDTH, 7100 + i * DECODE_WIDTH, low2, acc);
        end
        drain_all("wrap stress");
        $display("wrap stress done (%0d checks)", checks);
    endtask

    task automatic run_flush_tests();
        bit acc;

        // flush when idle
        press_block(5000, {FETCH_WIDTH{1'b1}}, acc);
        flush = 1;
        tick();
        flush = 0;
        exp_q.delete();
        tick();
        check("flush idle empty", rvalid == 0);

        // flush concurrent with a write -> flush wins, the write is dropped
        for (int s = 0; s < FETCH_WIDTH; s++) wdata[s] = make_iq_entry(5100 + s);
        wmask  = {FETCH_WIDTH{1'b1}};
        wvalid = 1;
        flush  = 1;
        tick();
        exp_q.delete();
        wvalid = 0;
        wmask  = 0;
        flush  = 0;
        tick();
        check("flush+write empty", rvalid == 0);

        // flush with a non-empty head.  The contract requires the back-end to
        // drive raccept_cnt=0 on a Redirect cycle, so accept is held at 0 here.
        press_block(5200, {FETCH_WIDTH{1'b1}}, acc);
        raccept_cnt = 0;
        flush       = 1;
        tick();
        exp_q.delete();
        flush = 0;
        tick();
        check("flush+accept0 empty", rvalid == 0);

        // flush a full queue
        press_block(5300, {FETCH_WIDTH{1'b1}}, acc);
        press_block(5310, {FETCH_WIDTH{1'b1}}, acc);
        flush = 1;
        tick();
        flush = 0;
        exp_q.delete();
        tick();
        check("flush full empty", rvalid == 0);
    endtask

    task automatic run_reset_tests();
        bit acc;

        // reset with a non-empty queue
        press_block(6000, {FETCH_WIDTH{1'b1}}, acc);
        press_block(6010, {FETCH_WIDTH{1'b1}}, acc);
        rst = 1;
        tick();
        tick();
        exp_q.delete();
        check("rst non-empty cleared", rvalid == 0);
        rst = 0;
        tick();
        check("post-rst empty", rvalid == 0);

        // the queue must be usable again with a clean pointer state
        press_block(6100, {FETCH_WIDTH{1'b1}}, acc);
        check("post-rst accepted", acc == 1);
        check_entry("post-rst h0", rbits[0], 6100, 1'b0);
        drain_all("post-rst");

        // reset while a write is offered
        press_block(6200, {FETCH_WIDTH{1'b1}}, acc);
        rst = 1;
        for (int s = 0; s < FETCH_WIDTH; s++) wdata[s] = make_iq_entry(6300 + s);
        wmask  = {FETCH_WIDTH{1'b1}};
        wvalid = 1;
        tick();
        tick();
        exp_q.delete();
        wvalid = 0;
        wmask = 0;
        rst = 0;
        tick();
        check("rst during write empty", rvalid == 0);
    endtask

    // --------------------------------------------------------------- monitors
`ifndef SYNTHESIS
    bit inv_bad = 0;
    always @(posedge clk) begin
        // rvalid is always a low-contiguous prefix (slot0 valid => not "10")
        if (!rst && !flush && (DECODE_WIDTH == 2) && (rvalid == 2'b10)) begin
            if (!inv_bad) begin
                $display("FAIL: rvalid=2'b10 (slot0 invalid, slot1 valid)");
                errors++;
                inv_bad = 1;
            end
        end
        // counting-handshake invariants: never accept more than was read, and
        // the legal encodings are 0/1/2 only
        if (!rst && !flush && (int'(raccept_cnt) > $countones(rvalid))) begin
            if (!inv_bad) begin
                $display("FAIL: raccept_cnt=%0d exceeds rvalid popcount=%0d", raccept_cnt,
                         $countones(rvalid));
                errors++;
                inv_bad = 1;
            end
        end
        if (!rst && (raccept_cnt == 2'd3)) begin
            if (!inv_bad) begin
                $display("FAIL: raccept_cnt=3 is not a legal consume count");
                errors++;
                inv_bad = 1;
            end
        end
    end
`endif

    initial begin
        clk = 0;
        rst = 1;
        wvalid = 0;
        wmask = 0;
        raccept_cnt = 0;
        flush = 0;
        for (int s = 0; s < FETCH_WIDTH; s++) wdata[s] = '0;
        tick();
        tick();
        rst = 0;
        tick();

        run_struct_tests();
        run_width_tests();
        run_boundary_tests();
        run_concurrency_tests();
        run_wrap_tests();
        run_flush_tests();
        run_reset_tests();

        if (errors == 0) begin
            $display("ALL TESTS PASSED (FETCH_WIDTH=%0d, %0d checks)", FETCH_WIDTH, checks);
            $finish;
        end else begin
            // $fatal makes the process exit with a non-zero status so the
            // regression Makefile can report FAIL
            $fatal(1, "%0d TESTS FAILED", errors);
        end
    end
endmodule

/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
