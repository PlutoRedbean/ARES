`timescale 1ns / 1ps

//=============================================================================
// ARES LSU - self-checking unit test for lsu_completion.sv (L12)
//-----------------------------------------------------------------------------
// Standalone top: own clock/reset, no DPI, no harness.  Covers
// LSU_INTERFACES.md section 5 ("要点" 1-6) and section 8 (reset, boundaries,
// same-cycle conflicts, kill priority, fixed-seed random reference model):
//
//   1. reset: fifo_empty=1, fifo_count=0, completion_valid=0, fast_take=0
//   2. fast path: FIFO empty and tag not killed -> same-cycle fast_take and
//      completion_valid with tag/result correct and exception=0 /
//      cause=EXC_NONE / tval=0; the pulse lasts exactly one cycle
//   3. fast path blocked while the FIFO is non-empty; the source holds
//      fast_valid/tag/result and is served later without loss
//   4. push_ready semantics (fifo_count < DEPTH or same-cycle dequeue) and the
//      occupancy boundary: a push is accepted while the head leaves the port
//      in the same cycle and the FIFO head pointer wraps around
//   5. strict FIFO order, at most one completion per cycle, fast path and FIFO
//      dequeue mutually exclusive
//   6. kill: FIFO head killed -> discarded without completion_valid and the
//      stream continues; fast path killed -> fast_take=0; a result whose tag is
//      killed in its push cycle is stored dead and never emitted; a killed
//      result never appears on completion_valid (TB monitor + model)
//   7. 20 back-to-back pushes emitted in order exactly once; fast/push
//      interleaving
//   8. fixed-seed random stress (20000 cycles) against an independent 2-entry
//      FIFO queue model: completion order/fields, completion_valid, fifo_count,
//      fifo_empty, push_ready, fast_take plus a per-result scoreboard that
//      rejects duplicate and post-kill emissions
//
// Harness: standalone top, own clock, no DPI.  Build/run (repository root):
//   tb: verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu_completion --Mdir sim/build/unit/tb_lsu_completion -o sim/build/unit/tb_lsu_completion/tb_lsu_completion rtl/common/ares_pkg.sv rtl/memory/lsu_completion.sv rtl/memory/test/unit/tb_lsu_completion.sv
//   run: sim/build/unit/tb_lsu_completion/tb_lsu_completion
//
// FREE items exercised: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_lsu_completion;
    import ares_pkg::*;

    localparam int unsigned DEPTH       = 2;          // memory.md section 2
    localparam int unsigned RAND_CYCLES = 20000;      // fixed-seed stress
    localparam logic [31:0] SEED        = 32'h5EED_0001;
    localparam int unsigned MAX_ITEMS   = 65536;

    localparam logic [1:0] ST_PEND   = 2'd1;          // generated, in flight
    localparam logic [1:0] ST_DONE   = 2'd2;          // emitted exactly once
    localparam logic [1:0] ST_CANCEL = 2'd3;          // killed, must never emit

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    logic                   clk;
    logic                   rst;
    logic                   fast_valid;
    tag_t                   fast_tag;
    logic [31:0]            fast_result;
    logic                   fast_take;
    logic                   push_valid;
    tag_t                   push_tag;
    logic [31:0]            push_result;
    logic                   push_ready;
    logic                   completion_valid;
    fu_completion_t         completion;
    logic [CIQ_ENTRIES-1:0] kill_mask;
    logic [1:0]             fifo_count;
    logic                   fifo_empty;

    lsu_completion #(.FIFO_DEPTH(DEPTH)) dut (
        .clk              (clk),
        .rst              (rst),
        .fast_valid       (fast_valid),
        .fast_tag         (fast_tag),
        .fast_result      (fast_result),
        .fast_take        (fast_take),
        .push_valid       (push_valid),
        .push_tag         (push_tag),
        .push_result      (push_result),
        .push_ready       (push_ready),
        .completion_valid (completion_valid),
        .completion       (completion),
        .kill_mask        (kill_mask),
        .fifo_count       (fifo_count),
        .fifo_empty       (fifo_empty)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;                       // 10 ns period

    //-------------------------------------------------------------------------
    // Checker
    //-------------------------------------------------------------------------
    int unsigned checks;
    int unsigned errors;

    task automatic chk(input logic cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[%0t] ERROR: %s", $time, msg);
        end
    endtask

    function automatic tag_t mktag(input logic [3:0] idx);
        tag_t t;
        t.slot_index = idx;
        mktag = t;
    endfunction

    function automatic logic [CIQ_ENTRIES-1:0] kill_of(input logic [3:0] idx);
        kill_of = 16'd1 << idx;
    endfunction

    function automatic logic [31:0] payload(input logic [15:0] id);
        payload = 32'hA5A5_0000 | {16'd0, id};
    endfunction

    // Drive one cycle: inputs change on the falling edge (after the previous
    // rising edge, before the next one) and are sampled by the DUT on the next
    // rising edge.  Outputs are sampled #1 after the drive, i.e. they reflect
    // the registered state entering this cycle - the same convention the
    // reference model uses.
    task automatic apply(input logic fv, input tag_t ft, input logic [31:0] fr,
                         input logic pv, input tag_t pt, input logic [31:0] pr,
                         input logic [CIQ_ENTRIES-1:0] km);
        @(negedge clk);
        fast_valid  = fv;  fast_tag = ft;  fast_result = fr;
        push_valid  = pv;  push_tag = pt;  push_result = pr;
        kill_mask   = km;
        #1;
    endtask

    task automatic idle();
        apply(1'b0, mktag(4'd0), 32'd0, 1'b0, mktag(4'd0), 32'd0, '0);
    endtask

    task automatic chk_completion(input tag_t etag, input logic [31:0] eresult,
                                  input string msg);
        chk(completion_valid,             $sformatf("%s: completion_valid", msg));
        chk(completion.tag == etag,       $sformatf("%s: tag", msg));
        chk(completion.result == eresult, $sformatf("%s: result", msg));
        chk(completion.exception == 1'b0, $sformatf("%s: exception=0", msg));
        chk(completion.cause == EXC_NONE, $sformatf("%s: cause=EXC_NONE", msg));
        chk(completion.tval == 32'd0,     $sformatf("%s: tval=0", msg));
    endtask

    //-------------------------------------------------------------------------
    // TB-side monitor (independent of the DUT assertions): a tag killed in a
    // cycle must never be emitted on the port in that same cycle.
    //-------------------------------------------------------------------------
    logic mon_kill_violation;

    always @(posedge clk) begin
        if (!rst && completion_valid && kill_mask[completion.tag.slot_index]) begin
            mon_kill_violation <= 1'b1;
            $display("[%0t] ERROR: monitor: killed tag emitted on completion_valid", $time);
        end
    end

    //=========================================================================
    // Directed tests
    //=========================================================================

    // 2. fast path: granted combinationally, correct fields, one-cycle pulse.
    task automatic test_fast_path();
        apply(1'b1, mktag(4'd5), 32'hDEAD_BEEF, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fast_take == 1'b1, "fast: same-cycle grant");
        chk_completion(mktag(4'd5), 32'hDEAD_BEEF, "fast");
        chk(fifo_empty == 1'b1 && fifo_count == 2'd0, "fast: FIFO untouched");
        idle();
        chk(fast_take == 1'b0, "fast: grant is a single cycle");
        chk(completion_valid == 1'b0, "fast: completion is a single cycle");
    endtask

    // 3. FIFO non-empty -> fast path blocked; the source holds and is served.
    task automatic test_fifo_blocks_fast();
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd1), 32'h1111_0001, '0);
        chk(push_ready == 1'b1, "block: push accepted");
        chk(completion_valid == 1'b0, "block: nothing emitted in the push cycle");
        chk(fifo_count == 2'd0 && fifo_empty == 1'b1, "block: FIFO empty before the edge");
        apply(1'b1, mktag(4'd2), 32'h2222_0002, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fast_take == 1'b0, "block: fast_take=0 while the FIFO is non-empty");
        chk(fifo_count == 2'd1 && fifo_empty == 1'b0, "block: FIFO holds one entry");
        chk_completion(mktag(4'd1), 32'h1111_0001, "block: FIFO head owns the port");
        apply(1'b1, mktag(4'd2), 32'h2222_0002, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fast_take == 1'b1, "block: held fast result granted once the FIFO drains");
        chk_completion(mktag(4'd2), 32'h2222_0002, "block: held tag/result intact");
        idle();
        chk(completion_valid == 1'b0, "block: pulse");
        chk(fifo_empty == 1'b1, "block: FIFO empty at the end");
    endtask

    // 4. push_ready / occupancy boundary: push accepted while the head leaves
    //    in the same cycle; the freed slot is re-used and order is preserved.
    task automatic test_capacity_boundary();
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd7), 32'h7777_0007, '0);
        chk(fifo_empty == 1'b1, "cap: FIFO empty before the first push");
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd8), 32'h8888_0008, '0);
        chk(fifo_count == 2'd1, "cap: occupancy 1 (maximum reachable at DEPTH=2)");
        chk(fifo_empty == 1'b0, "cap: FIFO not empty");
        chk(push_ready == 1'b1, "cap: push_ready with a same-cycle dequeue");
        chk_completion(mktag(4'd7), 32'h7777_0007, "cap: head leaves in the same cycle");
        idle();
        chk(fifo_count == 2'd1 && fifo_empty == 1'b0, "cap: pushed entry took the freed slot");
        chk_completion(mktag(4'd8), 32'h8888_0008, "cap: pushed entry emitted next");
        idle();
        chk(fifo_count == 2'd0 && fifo_empty == 1'b1, "cap: drained");
        chk(completion_valid == 1'b0, "cap: no extra completion");
    endtask

    // 5./7. strict order, one dequeue per cycle, 20 back-to-back pushes
    //       (head pointer wraps ten times at DEPTH=2).
    task automatic test_back_to_back_20();
        for (int unsigned i = 0; i < 20; i++) begin
            logic [3:0] itag;
            itag = i[3:0];
            apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(itag), payload(i[15:0]), '0);
            chk(push_ready == 1'b1, $sformatf("b2b: push %0d accepted", i));
            if (i == 0) begin
                chk(completion_valid == 1'b0, "b2b: first push cycle emits nothing");
                chk(fifo_empty == 1'b1, "b2b: FIFO empty at the first push");
            end else begin
                chk_completion(mktag(itag - 4'd1), payload(i[15:0] - 16'd1),
                               $sformatf("b2b: item %0d", i - 1));
            end
        end
        idle();
        chk_completion(mktag(4'd3), payload(16'd19), "b2b: item 19");   // tag = 19 % 16
        chk(fifo_count == 2'd1, "b2b: last item buffered before the edge");
        idle();
        chk(completion_valid == 1'b0, "b2b: exactly 20 completions, one per cycle");
        chk(fifo_empty == 1'b1 && fifo_count == 2'd0, "b2b: drained");
    endtask

    // 7. fast and push interleaved; only one source owns the port per cycle.
    task automatic test_fast_push_interleave();
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd1), 32'h0000_1000, '0);
        apply(1'b1, mktag(4'd2), 32'h0000_2000, 1'b1, mktag(4'd3), 32'h0000_3000, '0);
        chk(fast_take == 1'b0, "mix: fast waits behind a non-empty FIFO");
        chk_completion(mktag(4'd1), 32'h0000_1000, "mix: A0");
        apply(1'b1, mktag(4'd2), 32'h0000_2000, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fast_take == 1'b0, "mix: fast still waits");
        chk_completion(mktag(4'd3), 32'h0000_3000, "mix: A1");
        apply(1'b1, mktag(4'd2), 32'h0000_2000, 1'b1, mktag(4'd4), 32'h0000_4000, '0);
        chk(fast_take == 1'b1, "mix: fast granted on the empty FIFO");
        chk_completion(mktag(4'd2), 32'h0000_2000, "mix: F0");
        chk(fifo_empty == 1'b1, "mix: FIFO was empty when F0 was granted");
        idle();
        chk_completion(mktag(4'd4), 32'h0000_4000, "mix: A2");
        chk(fifo_count == 2'd1, "mix: A2 was buffered");
        idle();
        chk(completion_valid == 1'b0, "mix: exactly four completions");
        chk(fifo_empty == 1'b1, "mix: drained");
    endtask

    // 6. kill priority: FIFO head, fast path and same-cycle push.
    task automatic test_kill();
        // (a) FIFO head killed -> discarded silently, stream continues.
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd9), 32'h9999_0009, '0);
        chk(fifo_count == 2'd0, "kill: FIFO empty before the push edge");
        apply(1'b0, mktag(4'd0), 32'd0, 1'b0, mktag(4'd0), 32'd0, kill_of(4'd9));
        chk(completion_valid == 1'b0, "kill: killed FIFO head produces no completion");
        chk(fifo_count == 2'd1, "kill: head still buffered before the edge");
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd10), 32'hAAAA_0010, '0);
        chk(fifo_empty == 1'b1, "kill: killed head discarded");
        chk(completion_valid == 1'b0, "kill: discard is silent");
        apply(1'b0, mktag(4'd0), 32'd0, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fifo_count == 2'd1, "kill: following entry buffered");
        chk_completion(mktag(4'd10), 32'hAAAA_0010, "kill: stream continues after the kill");
        idle();
        chk(fifo_empty == 1'b1, "kill: drained");
        // (b) fast path killed -> no grant, no completion.
        apply(1'b1, mktag(4'd11), 32'hBBBB_0011, 1'b0, mktag(4'd0), 32'd0, kill_of(4'd11));
        chk(fast_take == 1'b0, "kill: killed fast result is not granted");
        chk(completion_valid == 1'b0, "kill: killed fast result emits nothing");
        idle();
        chk(completion_valid == 1'b0, "kill: killed fast result never appears");
        // (c) the fast path is healthy again right after the kill.
        apply(1'b1, mktag(4'd12), 32'hCCCC_0012, 1'b0, mktag(4'd0), 32'd0, '0);
        chk(fast_take == 1'b1, "kill: fast path healthy after a kill");
        chk_completion(mktag(4'd12), 32'hCCCC_0012, "kill: post-kill fast result");
        idle();
        // (d) push whose tag is killed in the same cycle: accepted but stored
        //     dead, never emitted.
        apply(1'b0, mktag(4'd0), 32'd0, 1'b1, mktag(4'd13), 32'hDDDD_0013, kill_of(4'd13));
        chk(push_ready == 1'b1, "kill: push accepted while its tag is killed");
        chk(completion_valid == 1'b0, "kill: killed push not emitted in the push cycle");
        idle();
        chk(completion_valid == 1'b0, "kill: killed push drains silently");
        idle();
        chk(fifo_empty == 1'b1 && fifo_count == 2'd0, "kill: FIFO clean after the dead entry");
    endtask

    //=========================================================================
    // 8. Fixed-seed random stress against an independent 2-entry FIFO queue
    //    model.  Model state, sources and scoreboard are updated once per
    //    cycle, after the DUT outputs of that cycle have been compared.
    //=========================================================================
    typedef struct packed {
        tag_t        tag;
        logic [31:0] result;
        logic [15:0] id;
        logic        live;      // 0 = killed entry ("hole"), drains silently
    } mdl_ent_t;

    mdl_ent_t    mdl_q[$];                      // ordered FIFO contents
    logic [1:0]  item_state [0:MAX_ITEMS-1];    // scoreboard per result id
    int unsigned next_id;
    logic [31:0] rng;

    logic        rfs_act;                       // TB fast-path source
    tag_t        rfs_tag;
    logic [31:0] rfs_result;
    logic [15:0] rfs_id;

    logic        rps_act;                       // TB push source (held stable)
    tag_t        rps_tag;
    logic [31:0] rps_result;
    logic [15:0] rps_id;

    function automatic logic [31:0] rnd();
        rng ^= (rng << 13);
        rng ^= (rng >> 17);
        rng ^= (rng << 5);
        rnd = rng;
    endfunction

    task automatic rand_model_step();
        logic        m_empty, m_full, m_fast_take, m_push_ready, m_push_fire;
        logic        m_head_kill, m_head_live, m_emit;
        tag_t        m_tag;
        logic [31:0] m_result;
        logic [15:0] m_id;

        //--- expected behaviour of the pre-edge model state ---------------
        m_empty      = (mdl_q.size() == 0);
        m_full       = (mdl_q.size() >= int'(DEPTH));
        m_push_ready = !m_full || !m_empty;
        m_push_fire  = push_valid && m_push_ready;
        m_fast_take  = fast_valid && m_empty && !kill_mask[fast_tag.slot_index];
        m_head_kill  = !m_empty && kill_mask[mdl_q[0].tag.slot_index];
        m_head_live  = !m_empty && mdl_q[0].live && !m_head_kill;
        m_emit       = m_fast_take || m_head_live;

        if (m_fast_take) begin
            m_tag = fast_tag; m_result = fast_result; m_id = rfs_id;
        end else if (m_head_live) begin
            m_tag = mdl_q[0].tag; m_result = mdl_q[0].result; m_id = mdl_q[0].id;
        end else begin
            m_tag = mktag(4'd0); m_result = 32'd0; m_id = 16'd0;
        end

        chk(fast_take == m_fast_take,         "rand: fast_take");
        chk(push_ready == m_push_ready,       "rand: push_ready");
        chk(fifo_empty == m_empty,            "rand: fifo_empty");
        chk(int'(fifo_count) == mdl_q.size(), "rand: fifo_count");
        chk(completion_valid == m_emit,       "rand: completion_valid");
        chk(!(fast_take && m_head_live),      "rand: one port owner per cycle");

        if (m_emit) begin
            chk(completion.tag == m_tag,         "rand: completion tag");
            chk(completion.result == m_result,   "rand: completion result");
            chk(completion.exception == 1'b0,    "rand: completion exception=0");
            chk(completion.cause == EXC_NONE,    "rand: completion cause=EXC_NONE");
            chk(completion.tval == 32'd0,        "rand: completion tval=0");
            chk(item_state[m_id] != ST_DONE,     "rand: result emitted at most once");
            chk(item_state[m_id] != ST_CANCEL,   "rand: killed result never emitted");
            chk(item_state[m_id] == ST_PEND,     "rand: emitted result was pending");
            item_state[m_id] = ST_DONE;
        end

        //--- post-edge state update (frozen arbitration rules) -------------
        if (!m_empty) begin
            // A live head killed in this very cycle is discarded by the pop
            // below, so it must be scored here (the scan further down only
            // sees the entries that are still buffered).
            if (m_head_kill)
                item_state[mdl_q[0].id] = ST_CANCEL;
            void'(mdl_q.pop_front());
        end

        for (int k = 0; k < mdl_q.size(); k++) begin
            if (mdl_q[k].live && kill_mask[mdl_q[k].tag.slot_index]) begin
                mdl_q[k].live = 1'b0;
                if (item_state[mdl_q[k].id] == ST_PEND)
                    item_state[mdl_q[k].id] = ST_CANCEL;
            end
        end

        if (m_push_fire) begin
            mdl_ent_t e;
            e.tag    = push_tag;
            e.result = push_result;
            e.id     = rps_id;
            e.live   = !kill_mask[push_tag.slot_index];
            if (!e.live)
                item_state[e.id] = ST_CANCEL;   // accepted but never emitted
            mdl_q.push_back(e);
        end

        if (m_fast_take) begin
            rfs_act = 1'b0;                     // granted, source drops it
        end else if (rfs_act && kill_mask[rfs_tag.slot_index]) begin
            item_state[rfs_id] = ST_CANCEL;     // killed before the grant
            rfs_act = 1'b0;
        end

        if (m_push_fire)
            rps_act = 1'b0;
    endtask

    task automatic test_random_stress();
        logic [CIQ_ENTRIES-1:0] km;
        logic [3:0]  k1, k2;
        int unsigned c;
        int unsigned items;
        int unsigned left_pending;

        rng      = SEED;
        rfs_act  = 1'b0;
        rps_act  = 1'b0;
        next_id  = 0;

        for (c = 0; c < RAND_CYCLES; c++) begin
            //--- stimulus decisions (before the falling edge) --------------
            km = '0;
            if ((rnd() % 100) < 15) begin
                k1 = rnd()[3:0];
                km[k1] = 1'b1;
                if (rnd()[0] != 1'b0) begin
                    k2 = rnd()[3:0];
                    km[k2] = 1'b1;
                end
            end
            if (!rfs_act && ((rnd() % 100) < 50)) begin
                rfs_act    = 1'b1;
                rfs_tag    = mktag(rnd()[3:0]);
                rfs_id     = next_id[15:0];
                next_id    = next_id + 1;
                rfs_result = payload(rfs_id);
                item_state[rfs_id] = ST_PEND;
            end
            if (!rps_act && ((rnd() % 100) < 60)) begin
                rps_act    = 1'b1;
                rps_tag    = mktag(rnd()[3:0]);
                rps_id     = next_id[15:0];
                next_id    = next_id + 1;
                rps_result = payload(rps_id);
                item_state[rps_id] = ST_PEND;
            end

            @(negedge clk);
            kill_mask  = km;
            fast_valid = rfs_act; fast_tag = rfs_tag; fast_result = rfs_result;
            push_valid = rps_act; push_tag = rps_tag; push_result = rps_result;
            #1;
            rand_model_step();
        end

        //--- drain: stop pushing, keep the fast source until it is served ---
        for (c = 0; c < 10; c++) begin
            @(negedge clk);
            kill_mask  = '0;
            fast_valid = rfs_act; fast_tag = rfs_tag; fast_result = rfs_result;
            push_valid = 1'b0;    push_tag = mktag(4'd0); push_result = 32'd0;
            #1;
            rand_model_step();
        end

        items = next_id;
        left_pending = 0;
        for (int unsigned i = 0; i < items; i++)
            if ((item_state[i[15:0]] != ST_DONE) && (item_state[i[15:0]] != ST_CANCEL))
                left_pending = left_pending + 1;

        chk(!rfs_act && !rps_act,       "rand: all sources drained");
        chk(mdl_q.size() == 0,          "rand: reference queue drained");
        chk(fifo_empty == 1'b1,         "rand: fifo_empty after drain");
        chk(fifo_count == 2'd0,         "rand: fifo_count after drain");
        chk(completion_valid == 1'b0,   "rand: port idle after drain");
        chk(left_pending == 0,          "rand: every result was emitted or killed");
        $display("  [random stress] %0d cycles, %0d result items, seed=0x%08x",
                 RAND_CYCLES, items, SEED);
    endtask

    //=========================================================================
    // Main sequence
    //=========================================================================
    initial begin
        rst         = 1'b1;
        fast_valid  = 1'b0; fast_tag = mktag(4'd0); fast_result = 32'd0;
        push_valid  = 1'b0; push_tag = mktag(4'd0); push_result = 32'd0;
        kill_mask   = '0;

        //--- 1. reset ------------------------------------------------------
        repeat (3) @(negedge clk);
        #1;
        chk(fifo_empty == 1'b1,       "reset: fifo_empty=1");
        chk(fifo_count == 2'd0,       "reset: fifo_count=0");
        chk(completion_valid == 1'b0, "reset: completion_valid=0");
        chk(fast_take == 1'b0,        "reset: fast_take=0");
        chk(push_ready == 1'b1,       "reset: push_ready from registered state only");
        @(negedge clk);
        #1;
        chk(fifo_empty == 1'b1 && completion_valid == 1'b0, "reset: state stays clean");
        rst = 1'b0;

        test_fast_path();
        test_fifo_blocks_fast();
        test_capacity_boundary();
        test_back_to_back_20();
        test_fast_push_interleave();
        test_kill();
        test_random_stress();

        chk(mon_kill_violation == 1'b0,
            "monitor: no killed tag ever reached completion_valid");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - L12 lsu_completion: reset, fast path (grant/fields/pulse), fast blocked+held source, push_ready + occupancy boundary, strict FIFO order, 20x back-to-back (head pointer wrap), fast/push interleave, kill priority (FIFO head / fast / same-cycle push), 20000-cycle fixed-seed random vs 2-entry FIFO queue model", checks);
            $finish;
        end else begin
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        end
    end

endmodule
