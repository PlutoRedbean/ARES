`timescale 1ns/1ps
//=============================================================================
// ARES LSU - self-checking unit test for the unified 8-entry SQ (L04)
//-----------------------------------------------------------------------------
// Spec sources : memory.md 5.1 / 5.2 / 5.3 (3.1 for the MMIO store path);
//                rtl/memory/LSU_INTERFACES.md section 4 (frozen port list).
// DUT          : rtl/memory/sq.sv
// FREE items   : FREE-02 (file organisation), FREE-04 (stimulus/model structure).
//
// The bench drives the DUT with a fixed-seed stimulus stream and mirrors the
// spec with an INDEPENDENT reference model: a queue ordered by store age
// (q[0] = head) from which head/commit_ptr/tail/occupancy/committed_cnt and the
// per-slot state are derived, instead of the DUT's modular pointer arithmetic.
//
// commit_fire is the GLOBAL commit event (plan 5.8/5.10): a non-Store lane
// raises it with store_commit_valid=0 / store_commit_ok=0 and the SQ must ignore
// that lane.  The bench exercises exactly that case.
//
// Coverage (single run):
//   * reset: head/commit_ptr/tail/occupancy/committed_cnt = 0, outputs clean
//   * alloc / AGU / exec: exactly one exec_valid per store, ring order
//     head -> tail (oldest ready first), exec_valid holds while exec_ready = 0
//   * pointer/count invariants checked every cycle: commit_ptr=(head+cmt_cnt)&7,
//     tail=(head+occupancy)&7, occupancy=popcount(occupied), tail-head=occupancy
//     (the RTL carries the same assertions, compiled with --assert)
//   * empty / full boundaries (credit 8 / 0) and > 8 ring wrap-arounds
//   * 2-wide commit: lane0 = commit_ptr, lane1 = next SPEC, non-store global
//     lane skipped (including a global commit_fire on that lane), lane0-only
//     commit, wrong tag -> ok=0, addr_valid=0 -> ok=0, ok independent of
//     commit_fire
//   * same-edge a/c/t/k combinations (alloc+commit+takeover; flush+commit)
//   * takeover: drain_start -> inflight -> drain_valid=0 (never re-sent),
//     takeover releases the entry and advances head, same-cycle start+takeover
//     leaves no inflight behind
//   * MMIO store: sq_mmio_store_pending while COMMITTED, COMMITTED store never
//     killed, cleared by takeover; SPEC MMIO store is killable
//   * flush: youngest contiguous SPEC suffix rolls tail/occupancy back, the
//     COMMITTED prefix is untouched
//   * store_credit = 8 - occupancy from cycle-start state (same-cycle takeover
//     is not borrowed)
//   * >= 10k cycles of fixed-seed random stimulus against the reference model
//
// Negative run (separate invocation, expect the a_kill_suffix assertion):
//   $ sim/build/unit/tb_sq/tb_sq +negative_kill
//
// Build / run (repo root, explicit file list):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//         -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_sq \
//         --Mdir sim/build/unit/tb_sq -o tb_sq rtl/common/ares_pkg.sv \
//         rtl/memory/sq.sv rtl/memory/test/unit/tb_sq.sv
//   $ sim/build/unit/tb_sq/tb_sq
//=============================================================================
module tb_sq;
    import ares_pkg::*;

    localparam int unsigned RAND_CYCLES = 12000;
    localparam int unsigned RNG_SEED    = 32'h1234_5678;

    //-------------------------------------------------------------------------
    // Clock / reset (self-contained, no harness)
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic                    alloc_valid;
    tag_t                    alloc_tag;
    logic [2:0]              alloc_idx;

    logic                    agu_valid;
    logic [2:0]              agu_qidx;
    tag_t                    agu_tag;
    logic [31:0]             agu_addr;
    logic [3:0]              agu_byte_mask;
    logic [31:0]             agu_store_data;
    logic                    agu_is_mmio;

    logic                    exec_valid;
    logic                    exec_ready;
    tag_t                    exec_tag;

    logic [1:0]              store_commit_valid;
    tag_t                    store_commit_tag [2];
    logic [1:0]              store_commit_ok;
    logic [1:0]              commit_fire;

    logic                    drain_valid;
    logic [2:0]              drain_idx;
    tag_t                    drain_tag;
    logic [31:0]             drain_addr;
    logic [31:0]             drain_data;
    logic [3:0]              drain_mask;
    logic                    drain_is_mmio;
    logic                    drain_start;
    logic                    drain_takeover;

    logic [7:0]              sq_occupied;
    logic [7:0]              sq_takeover;
    logic [7:0]              sq_addr_valid;
    logic [7:0][31:0]        sq_addr;
    logic [7:0][31:0]        sq_data;
    logic [7:0][3:0]         sq_byte_mask;
    logic [7:0]              sq_is_mmio;
    logic [2:0]              sq_head_ptr;
    logic [3:0]              sq_occupancy;
    logic                    sq_mmio_store_pending;

    logic [CIQ_ENTRIES-1:0]  kill_mask;

    logic [3:0]              store_credit;
    logic                    sq_full;

    sq dut (
        .clk                   (clk),
        .rst                   (rst),
        .alloc_valid           (alloc_valid),
        .alloc_tag             (alloc_tag),
        .alloc_idx             (alloc_idx),
        .agu_valid             (agu_valid),
        .agu_qidx              (agu_qidx),
        .agu_tag               (agu_tag),
        .agu_addr              (agu_addr),
        .agu_byte_mask         (agu_byte_mask),
        .agu_store_data        (agu_store_data),
        .agu_is_mmio           (agu_is_mmio),
        .exec_valid            (exec_valid),
        .exec_ready            (exec_ready),
        .exec_tag              (exec_tag),
        .store_commit_valid    (store_commit_valid),
        .store_commit_tag      (store_commit_tag),
        .store_commit_ok       (store_commit_ok),
        .commit_fire           (commit_fire),
        .drain_valid           (drain_valid),
        .drain_idx             (drain_idx),
        .drain_tag             (drain_tag),
        .drain_addr            (drain_addr),
        .drain_data            (drain_data),
        .drain_mask            (drain_mask),
        .drain_is_mmio         (drain_is_mmio),
        .drain_start           (drain_start),
        .drain_takeover        (drain_takeover),
        .sq_occupied           (sq_occupied),
        .sq_takeover           (sq_takeover),
        .sq_addr_valid         (sq_addr_valid),
        .sq_addr               (sq_addr),
        .sq_data               (sq_data),
        .sq_byte_mask          (sq_byte_mask),
        .sq_is_mmio            (sq_is_mmio),
        .sq_head_ptr           (sq_head_ptr),
        .sq_occupancy          (sq_occupancy),
        .sq_mmio_store_pending (sq_mmio_store_pending),
        .kill_mask             (kill_mask),
        .store_credit          (store_credit),
        .sq_full               (sq_full)
    );

    //-------------------------------------------------------------------------
    // Reference model: age-ordered queue, q[0] is the SQ head
    //-------------------------------------------------------------------------
    typedef struct packed {
        logic [3:0]  tag;
        logic        committed;
        logic        addr_valid;
        logic [31:0] addr;
        logic [31:0] data;
        logic [3:0]  mask;
        logic        mmio;
        logic        exec_done;
        logic        inflight;
        int unsigned exec_count;
    } entry_t;

    entry_t     q [$];
    logic [2:0] m_head;

    // retained per-slot payload (the RTL does not clear addr/data/mask on free)
    logic [7:0][3:0]  m_tag_v;
    logic [7:0][31:0] m_addr_v;
    logic [7:0][31:0] m_data_v;
    logic [7:0][3:0]  m_mask_v;

    // live state vectors rebuilt from the queue every cycle
    logic [7:0] m_occ_v;
    logic [7:0] m_committed_v;
    logic [7:0] m_addr_valid_v;
    logic [7:0] m_exec_done_v;
    logic [7:0] m_inflight_v;
    logic [7:0] m_mmio_v;

    // per-cycle expectations
    logic       e_ok0, e_ok1;
    int         e_cidx0, e_cidx1;
    logic [7:0] e_commit_q;
    logic [7:0] e_kill_q;
    int         e_exec_k;
    logic       e_alloc;
    logic       e_drain_valid;
    logic       e_takeover;

    // bookkeeping
    int unsigned checks;
    int unsigned errors;
    int unsigned cycle_cnt;
    logic        chk_en;          // checker processes enabled (after reset)

    //-------------------------------------------------------------------------
    // Deterministic RNG (fixed seed, xorshift32 - no tool-specific $random)
    //-------------------------------------------------------------------------
    int unsigned rng_state;

    function automatic int unsigned rnd();
        rng_state = rng_state ^ (rng_state << 13);
        rng_state = rng_state ^ (rng_state >> 17);
        rng_state = rng_state ^ (rng_state << 5);
        return rng_state;
    endfunction

    function automatic int unsigned rnd_range(input int unsigned n);
        if (n == 0) return 0;
        return rnd() % n;
    endfunction

    //-------------------------------------------------------------------------
    // Model helpers
    //-------------------------------------------------------------------------
    function automatic logic [3:0] m_committed_cnt();
        int n;
        n = 0;
        for (int k = 0; k < q.size(); k++) if (q[k].committed) n = n + 1;
        return 4'(n);
    endfunction

    function automatic logic [2:0] m_commit_ptr();
        return 3'(m_head + m_committed_cnt());
    endfunction

    function automatic logic [2:0] m_tail();
        return 3'(m_head + q.size());
    endfunction

    // index in q of the n-th uncommitted (SPEC) entry, -1 when absent
    function automatic int m_spec_idx(input int n);
        int seen;
        seen = 0;
        for (int k = 0; k < q.size(); k++) begin
            if (!q[k].committed) begin
                if (seen == n) return k;
                seen = seen + 1;
            end
        end
        return -1;
    endfunction

    // tag of the n-th uncommitted (SPEC) entry in age order
    function automatic logic [3:0] m_spec_tag(input int n);
        int k;
        k = m_spec_idx(n);
        return (k >= 0) ? q[k].tag : 4'h0;
    endfunction

    function automatic logic [3:0] m_free_tag(input logic [3:0] start);
        logic [15:0] used;
        logic        found;
        logic [3:0]  cand;
        used  = 16'd0;
        found = 1'b0;
        for (int k = 0; k < q.size(); k++) used[q[k].tag] = 1'b1;
        m_free_tag = start;
        for (int t = 0; t < 16; t++) begin
            cand = 4'(t) + start;
            if (!found && !used[cand]) begin
                m_free_tag = cand;
                found      = 1'b1;
            end
        end
    endfunction

    task automatic m_reset();
        q.delete();
        m_head   = 3'd0;
        m_tag_v  = '0;
        m_addr_v = '0;
        m_data_v = '0;
        m_mask_v = '0;
    endtask

    task automatic m_alloc(input logic [3:0] tg);
        entry_t e;
        logic [2:0] slot;
        e.tag        = tg;
        e.committed  = 1'b0;
        e.addr_valid = 1'b0;
        e.addr       = 32'd0;
        e.data       = 32'd0;
        e.mask       = 4'd0;
        e.mmio       = 1'b0;
        e.exec_done  = 1'b0;
        e.inflight   = 1'b0;
        e.exec_count = 0;
        q.push_back(e);
        slot = 3'(int'(m_head) + q.size() - 1);
        m_tag_v[slot] = tg;
    endtask

    // Commit lane match for this cycle (frozen interface rules: lane0 = oldest
    // SPEC, lane1 = next SPEC or lane0 itself when lane0 is not a store, ok[1]
    // depends on ok[0], only registered state is inspected).
    task automatic m_eval_commit();
        int k0;
        int k1;
        e_ok0   = 1'b0;
        e_ok1   = 1'b0;
        e_cidx0 = -1;
        e_cidx1 = -1;
        k0 = m_spec_idx(0);
        if (store_commit_valid[0] && (k0 >= 0) && q[k0].addr_valid
            && (q[k0].tag == store_commit_tag[0].slot_index)) begin
            e_ok0   = 1'b1;
            e_cidx0 = k0;
        end
        k1 = -1;
        if (store_commit_valid[0]) begin
            for (int k = k0 + 1; k < q.size(); k++)
                if ((k1 < 0) && !q[k].committed) k1 = k;
        end else begin
            k1 = k0;
        end
        if (store_commit_valid[1] && (k1 >= 0) && q[k1].addr_valid
            && (q[k1].tag == store_commit_tag[1].slot_index)
            && (!store_commit_valid[0] || e_ok0)) begin
            e_ok1   = 1'b1;
            e_cidx1 = k1;
        end
    endtask

    // Expectations for the current cycle (cycle-start model state + inputs)
    task automatic m_eval();
        int n0;
        m_eval_commit();
        n0 = q.size();
        e_commit_q = 8'd0;
        if (commit_fire[0] && e_ok0 && (e_cidx0 >= 0)) e_commit_q[e_cidx0] = 1'b1;
        if (commit_fire[1] && e_ok1 && (e_cidx1 >= 0)) e_commit_q[e_cidx1] = 1'b1;

        e_kill_q = 8'd0;
        for (int k = 0; k < n0; k++)
            e_kill_q[k] = !q[k].committed && !e_commit_q[k] && kill_mask[q[k].tag];

        e_exec_k = -1;
        for (int k = 0; k < n0; k++)
            if ((e_exec_k < 0) && !q[k].committed && !e_kill_q[k]
                && q[k].addr_valid && !q[k].exec_done)
                e_exec_k = k;

        e_alloc = alloc_valid && (n0 < 8) && !kill_mask[alloc_tag.slot_index];

        e_drain_valid = (n0 > 0) && q[0].committed && q[0].addr_valid && !q[0].inflight;
        e_takeover    = drain_takeover && (n0 > 0) && q[0].committed;
    endtask

    // Model state advance for the cycle whose inputs are currently driven
    task automatic m_update();
        int n0;
        int k;
        logic [2:0] s;
        n0 = q.size();
        // 1) AGU registration (matched by tag + physical slot, live SPEC only)
        if (agu_valid) begin
            for (k = 0; k < n0; k++) begin
                s = 3'(int'(m_head) + k);
                if (!q[k].committed && !e_kill_q[k] && (q[k].tag == agu_tag.slot_index)
                    && (s == agu_qidx)) begin
                    q[k].addr_valid = 1'b1;
                    q[k].addr       = agu_addr;
                    q[k].data       = agu_store_data;
                    q[k].mask       = agu_byte_mask;
                    q[k].mmio       = agu_is_mmio;
                    m_addr_v[s]     = agu_addr;
                    m_data_v[s]     = agu_store_data;
                    m_mask_v[s]     = agu_byte_mask;
                end
            end
        end
        // 2) execution Completion handshake (exactly once per store)
        if ((e_exec_k >= 0) && exec_ready) begin
            q[e_exec_k].exec_count = q[e_exec_k].exec_count + 1;
            q[e_exec_k].exec_done  = 1'b1;
        end
        // 3) SPEC -> COMMITTED
        for (k = 0; k < n0; k++) if (e_commit_q[k]) q[k].committed = 1'b1;
        // 4) allocation in the tail slot (appends behind the pre-update entries)
        if (e_alloc) m_alloc(alloc_tag.slot_index);
        // 5) SPEC flush of the youngest suffix: delete by pre-update index,
        //    highest first, BEFORE any head deletion shifts the indices
        for (k = n0 - 1; k >= 0; k--) if (e_kill_q[k]) q.delete(k);
        // 6) drain_start then takeover (same-edge start+takeover leaves nothing)
        if (drain_start && e_drain_valid && (n0 > 0)) q[0].inflight = 1'b1;
        if (e_takeover) begin
            if (q[0].exec_count != 1) begin
                errors = errors + 1;
                $display("[%0t] COMMITTED store tag %0d taken over with exec_count=%0d (must be exactly 1)",
                         $time, q[0].tag, q[0].exec_count);
                $fatal(1, "tb_sq FAILED: execution Completion not exactly once per store");
            end
            q.delete(0);
            m_head = 3'(int'(m_head) + 1);
        end
    endtask

    // map a queue-index mask (bit k = q[k]) to a physical-slot mask
    function automatic logic [7:0] m_slots_of(input logic [7:0] mask);
        logic [7:0] v;
        v = 8'd0;
        for (int k = 0; k < q.size(); k++)
            if (mask[k]) v[3'(int'(m_head) + k)] = 1'b1;
        return v;
    endfunction

    task automatic m_build_vectors();
        int k;
        logic [2:0] s;
        m_occ_v        = 8'd0;
        m_committed_v  = 8'd0;
        m_addr_valid_v = 8'd0;
        m_exec_done_v  = 8'd0;
        m_inflight_v   = 8'd0;
        m_mmio_v       = 8'd0;
        for (k = 0; k < q.size(); k++) begin
            s = 3'(int'(m_head) + k);
            m_occ_v[s]        = 1'b1;
            m_committed_v[s]  = q[k].committed;
            m_addr_valid_v[s] = q[k].addr_valid;
            m_exec_done_v[s]  = q[k].exec_done;
            m_inflight_v[s]   = q[k].inflight;
            m_mmio_v[s]       = q[k].mmio;
        end
    endtask

    //-------------------------------------------------------------------------
    // Checkers
    //-------------------------------------------------------------------------
    task automatic dump_state();
        int slot;
        $display("  DUT head=%0d cmt_ptr=%0d tail=%0d occ=%0d cmt_cnt=%0d",
                 dut.head_r, dut.commit_ptr_r, dut.tail_r, dut.occupancy_r, dut.committed_cnt_r);
        $display("  DUT occ=%b cmt=%b addr_valid=%b exec_done=%b inflight=%b mmio=%b",
                 dut.occ_r, dut.committed_r, dut.addr_valid_r, dut.exec_done_r,
                 dut.inflight_r, dut.mmio_r);
        $display("  DUT tag=%h addr=%h data=%h mask=%h", dut.tag_r, dut.addr_r,
                 dut.data_r, dut.mask_r);
        $display("  MDL size=%0d head=%0d occ=%b cmt=%b tag=%h", q.size(), m_head,
                 m_occ_v, m_committed_v, m_tag_v);
        for (int k = 0; k < q.size(); k++) begin
            slot = (int'(m_head) + k) % 8;
            $display("    q[%0d] tag=%0d slot=%0d cmt=%0b av=%0b addr=%08h data=%08h mask=%b mmio=%0b done=%0b inf=%0b",
                     k, q[k].tag, slot, q[k].committed, q[k].addr_valid,
                     q[k].addr, q[k].data, q[k].mask, q[k].mmio, q[k].exec_done, q[k].inflight);
        end
    endtask

    task automatic chk_fatal(input logic cond, input string what);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("[%0t] MISMATCH: %s (cycle %0d)", $time, what, cycle_cnt);
            dump_state();
            $fatal(1, "tb_sq FAILED");
        end
    endtask

    // Combinational checks: DUT outputs against the cycle-start model
    task automatic check_outputs();
        m_eval();
        chk_fatal(alloc_idx == m_tail(),
                  $sformatf("alloc_idx=%0d expected tail=%0d", alloc_idx, m_tail()));
        chk_fatal(exec_valid == (e_exec_k >= 0),
                  $sformatf("exec_valid=%0b expected %0b", exec_valid, e_exec_k >= 0));
        if (e_exec_k >= 0)
            chk_fatal(exec_tag.slot_index == q[e_exec_k].tag,
                      $sformatf("exec_tag=%0d expected oldest ready tag=%0d",
                                exec_tag.slot_index, q[e_exec_k].tag));
        chk_fatal(store_commit_ok == {e_ok1, e_ok0},
                  $sformatf("store_commit_ok=%b expected %b", store_commit_ok, {e_ok1, e_ok0}));
        chk_fatal(drain_valid == e_drain_valid,
                  $sformatf("drain_valid=%0b expected %0b", drain_valid, e_drain_valid));
        if (e_drain_valid) begin
            chk_fatal(drain_idx == m_head, "drain_idx = head");
            chk_fatal(drain_tag.slot_index == q[0].tag, "drain_tag = head tag");
            chk_fatal(drain_addr == q[0].addr, "drain_addr = head addr");
            chk_fatal(drain_data == q[0].data, "drain_data = head data");
            chk_fatal(drain_mask == q[0].mask, "drain_mask = head mask");
            chk_fatal(drain_is_mmio == q[0].mmio, "drain_is_mmio = head mmio");
        end
        chk_fatal(sq_takeover == (e_takeover ? (8'd1 << m_head) : 8'd0),
                  $sformatf("sq_takeover=%b expected one-hot at head=%0d", sq_takeover, m_head));
        // pointer / count invariants (interface doc section 4 point 10)
        chk_fatal(dut.commit_ptr_r == 3'(dut.head_r + dut.committed_cnt_r),
                  "commit_ptr = (head + committed_cnt) mod 8");
        chk_fatal(dut.tail_r == 3'(dut.head_r + dut.occupancy_r),
                  "tail = (head + occupancy) mod 8");
        chk_fatal(3'(dut.tail_r - dut.head_r) == dut.occupancy_r[2:0],
                  "tail - head = occupancy");
        chk_fatal(dut.occupancy_r == 4'(dut.occ_r[0]) + 4'(dut.occ_r[1]) + 4'(dut.occ_r[2])
                                    + 4'(dut.occ_r[3]) + 4'(dut.occ_r[4]) + 4'(dut.occ_r[5])
                                    + 4'(dut.occ_r[6]) + 4'(dut.occ_r[7]),
                  "occupancy = popcount(occupied)");
        chk_fatal(dut.committed_cnt_r == 4'(dut.committed_r[0]) + 4'(dut.committed_r[1])
                                       + 4'(dut.committed_r[2]) + 4'(dut.committed_r[3])
                                       + 4'(dut.committed_r[4]) + 4'(dut.committed_r[5])
                                       + 4'(dut.committed_r[6]) + 4'(dut.committed_r[7]),
                  "committed_cnt = popcount(committed)");
        chk_fatal((dut.committed_r & ~dut.occ_r) == 8'd0, "committed subset of occupied");
        // internal decision cross-check (SUT structure vs reference model)
        chk_fatal(dut.alloc_fire == e_alloc,
                  $sformatf("alloc_fire=%0b expected %0b", dut.alloc_fire, e_alloc));
        chk_fatal(dut.takeover_hit == (e_takeover ? (8'd1 << m_head) : 8'd0),
                  "dut.takeover_hit = expected takeover");
        chk_fatal(dut.commit_hit == m_slots_of(e_commit_q),
                  $sformatf("commit_hit=%b expected %b", dut.commit_hit, m_slots_of(e_commit_q)));
        chk_fatal(dut.kill_hit == m_slots_of(e_kill_q),
                  $sformatf("kill_hit=%b expected %b", dut.kill_hit, m_slots_of(e_kill_q)));
        chk_fatal(dut.exec_idx == ((e_exec_k >= 0) ? 3'(int'(m_head) + e_exec_k) : 3'd0),
                  $sformatf("exec_idx=%0d expected %0d", dut.exec_idx,
                            (e_exec_k >= 0) ? 3'(int'(m_head) + e_exec_k) : 3'd0));
        chk_fatal(dut.drain_valid == e_drain_valid, "drain_valid = expected");
    endtask

    // Sequential checks: DUT registers against the updated model
    task automatic check_state();
        logic mmio_pending;
        m_build_vectors();
        chk_fatal(dut.head_r == m_head,
                  $sformatf("head=%0d expected %0d", dut.head_r, m_head));
        chk_fatal(dut.occupancy_r == 4'(q.size()),
                  $sformatf("occupancy=%0d expected %0d", dut.occupancy_r, q.size()));
        chk_fatal(dut.committed_cnt_r == m_committed_cnt(),
                  $sformatf("committed_cnt=%0d expected %0d", dut.committed_cnt_r, m_committed_cnt()));
        chk_fatal(dut.commit_ptr_r == m_commit_ptr(),
                  $sformatf("commit_ptr=%0d expected %0d", dut.commit_ptr_r, m_commit_ptr()));
        chk_fatal(dut.tail_r == m_tail(),
                  $sformatf("tail=%0d expected %0d", dut.tail_r, m_tail()));
        chk_fatal(dut.occ_r == m_occ_v,
                  $sformatf("occupied=%b expected %b", dut.occ_r, m_occ_v));
        chk_fatal(dut.committed_r == m_committed_v,
                  $sformatf("committed=%b expected %b", dut.committed_r, m_committed_v));
        chk_fatal(dut.addr_valid_r == m_addr_valid_v,
                  $sformatf("addr_valid=%b expected %b", dut.addr_valid_r, m_addr_valid_v));
        chk_fatal(dut.exec_done_r == m_exec_done_v,
                  $sformatf("exec_done=%b expected %b", dut.exec_done_r, m_exec_done_v));
        chk_fatal(dut.inflight_r == m_inflight_v,
                  $sformatf("inflight=%b expected %b", dut.inflight_r, m_inflight_v));
        chk_fatal(dut.mmio_r == m_mmio_v,
                  $sformatf("mmio=%b expected %b", dut.mmio_r, m_mmio_v));
        chk_fatal(dut.tag_r == m_tag_v,
                  $sformatf("tag=%h expected %h", dut.tag_r, m_tag_v));
        chk_fatal(dut.addr_r == m_addr_v,
                  $sformatf("addr=%h expected %h", dut.addr_r, m_addr_v));
        chk_fatal(dut.data_r == m_data_v,
                  $sformatf("data=%h expected %h", dut.data_r, m_data_v));
        chk_fatal(dut.mask_r == m_mask_v,
                  $sformatf("mask=%h expected %h", dut.mask_r, m_mask_v));
        // forwarding read port (registered cycle-start view)
        chk_fatal(sq_occupied == m_occ_v, "sq_occupied = occupied");
        chk_fatal(sq_addr_valid == m_addr_valid_v, "sq_addr_valid = addr_valid");
        chk_fatal(sq_is_mmio == m_mmio_v, "sq_is_mmio = mmio");
        chk_fatal(sq_addr == m_addr_v, "sq_addr = addr");
        chk_fatal(sq_data == m_data_v, "sq_data = data");
        chk_fatal(sq_byte_mask == m_mask_v, "sq_byte_mask = mask");
        chk_fatal(sq_head_ptr == m_head, "sq_head_ptr = head");
        chk_fatal(sq_occupancy == 4'(q.size()), "sq_occupancy = occupancy");
        chk_fatal(store_credit == 4'd8 - 4'(q.size()),
                  $sformatf("store_credit=%0d expected %0d", store_credit, 8 - q.size()));
        chk_fatal(sq_full == (q.size() == 8), "sq_full = (occupancy == 8)");
        mmio_pending = ((m_occ_v & m_committed_v & m_mmio_v) != 8'd0);
        chk_fatal(sq_mmio_store_pending == mmio_pending,
                  $sformatf("sq_mmio_store_pending=%0b expected %0b",
                            sq_mmio_store_pending, mmio_pending));
    endtask

    //-------------------------------------------------------------------------
    // Checker processes
    //
    // The two heavy checker bodies live in exactly one place each: inlining
    // them at every stimulus step would duplicate the whole comparison code
    // hundreds of times (Verilator inlines tasks, and a non-inlined task may
    // not reference module-level signals).
    //
    //   negedge : combinational view of the cycle that is about to complete
    //   posedge+#1 : DUT registers and reference model advance together
    // The stimulus process resumes at posedge+#2, so the input values the DUT
    // sampled are still stable while the model update runs.
    //-------------------------------------------------------------------------
    always @(negedge clk) begin
        if (chk_en) begin
            m_eval();
            check_outputs();
        end
    end

    always @(posedge clk) begin
        if (chk_en) begin
            #1;
            cycle_cnt <= cycle_cnt + 1;
            m_update();
            check_state();
        end
    end

    //-------------------------------------------------------------------------
    // Clocking helpers (stimulus process side)
    //-------------------------------------------------------------------------
    task automatic check_now();
        @(negedge clk);
        #1;
    endtask

    task automatic finish_cycle();
        @(posedge clk);
        #2;
    endtask

    task automatic tick();
        check_now();
        finish_cycle();
    endtask

    task automatic clear_inputs();
        alloc_valid          = 1'b0;
        alloc_tag.slot_index = 4'd0;
        agu_valid            = 1'b0;
        agu_qidx             = 3'd0;
        agu_tag.slot_index   = 4'd0;
        agu_addr             = 32'd0;
        agu_byte_mask        = 4'd0;
        agu_store_data       = 32'd0;
        agu_is_mmio          = 1'b0;
        exec_ready           = 1'b0;
        store_commit_valid   = 2'b00;
        store_commit_tag[0].slot_index = 4'd0;
        store_commit_tag[1].slot_index = 4'd0;
        commit_fire          = 2'b00;
        drain_start          = 1'b0;
        drain_takeover       = 1'b0;
        kill_mask            = 16'd0;
    endtask

    task automatic alloc_one(input logic [3:0] tg);
        alloc_tag.slot_index = tg;
        alloc_valid          = 1'b1;
        tick();
        alloc_valid          = 1'b0;
    endtask

    task automatic agu_reg(input logic [2:0] slot, input logic [3:0] tg,
                           input logic [31:0] a, input logic [3:0] bm,
                           input logic [31:0] d, input logic mmio);
        agu_valid          = 1'b1;
        agu_qidx           = slot;
        agu_tag.slot_index = tg;
        agu_addr           = a;
        agu_byte_mask      = bm;
        agu_store_data     = d;
        agu_is_mmio        = mmio;
        tick();
        agu_valid          = 1'b0;
    endtask

    task automatic exec_once();
        exec_ready = 1'b1;
        tick();
        exec_ready = 1'b0;
    endtask

    task automatic commit_lanes(input logic [1:0] v, input logic [3:0] t0,
                                input logic [3:0] t1, input logic [1:0] f);
        store_commit_valid = v;
        store_commit_tag[0].slot_index = t0;
        store_commit_tag[1].slot_index = t1;
        commit_fire = f;
        tick();
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
    endtask

    task automatic drain_go(input logic st, input logic tk);
        drain_start    = st;
        drain_takeover = tk;
        tick();
        drain_start    = 1'b0;
        drain_takeover = 1'b0;
    endtask

    // Allocate + AGU-register (optionally execute) one store entry.
    task automatic add_store(input logic [3:0] tg, input logic [31:0] a,
                             input logic [3:0] bm, input logic [31:0] d, input logic mmio,
                             input logic do_exec);
        logic [2:0] slot;
        slot = m_tail();
        alloc_one(tg);
        agu_reg(slot, tg, a, bm, d, mmio);
        if (do_exec) exec_once();
    endtask

    function automatic int unsigned pc8(input logic [7:0] v);
        int unsigned n;
        n = 0;
        for (int i = 0; i < 8; i++) n = n + int'(v[i]);
        return n;
    endfunction

    // Kill every remaining SPEC entry (the youngest contiguous suffix).
    task automatic kill_spec_suffix();
        kill_mask = 16'd0;
        for (int k = 0; k < q.size(); k++)
            if (!q[k].committed) kill_mask[q[k].tag] = 1'b1;
        tick();
        kill_mask = 16'd0;
    endtask

    // Take over every COMMITTED entry (the COMMITTED prefix) until empty.
    task automatic drain_empty();
        while (dut.occupancy_r != 4'd0) drain_go(1'b0, 1'b1);
    endtask

    // Leave a clean ring: drop the SPEC suffix, then drain the committed prefix.
    task automatic flush_and_drain();
        kill_spec_suffix();
        drain_empty();
    endtask

    //-------------------------------------------------------------------------
    // Phase 0: reset
    //-------------------------------------------------------------------------
    task automatic check_reset_clean(input string what);
        chk_fatal((m_head == 3'd0) && (q.size() == 0),
                  $sformatf("model clean (%s)", what));
        chk_fatal((dut.head_r == 3'd0) && (dut.commit_ptr_r == 3'd0) && (dut.tail_r == 3'd0)
                  && (dut.occupancy_r == 4'd0) && (dut.committed_cnt_r == 4'd0),
                  $sformatf("head/commit_ptr/tail/occupancy/committed_cnt zero (%s)", what));
        chk_fatal((dut.occ_r == 8'd0) && (dut.committed_r == 8'd0) && (dut.addr_valid_r == 8'd0)
                  && (dut.exec_done_r == 8'd0) && (dut.inflight_r == 8'd0) && (dut.mmio_r == 8'd0)
                  && (dut.tag_r == 32'd0) && (dut.addr_r == 256'd0) && (dut.data_r == 256'd0)
                  && (dut.mask_r == 32'd0),
                  $sformatf("entry state zero (%s)", what));
        chk_fatal((sq_occupied == 8'd0) && (sq_addr_valid == 8'd0) && (sq_is_mmio == 8'd0)
                  && (sq_occupancy == 4'd0) && (sq_head_ptr == 3'd0) && (sq_full == 1'b0)
                  && (sq_mmio_store_pending == 1'b0) && (store_credit == 4'd8),
                  $sformatf("outputs clean (%s)", what));
        chk_fatal((exec_valid == 1'b0) && (drain_valid == 1'b0) && (store_commit_ok == 2'b00)
                  && (sq_takeover == 8'd0) && (alloc_idx == 3'd0),
                  $sformatf("handshake outputs idle (%s)", what));
    endtask

    task automatic phase_reset();
        $display("[tb_sq] phase 0: reset");
        clear_inputs();
        rst = 1'b1;
        m_reset();
        repeat (3) begin
            @(posedge clk);
            #1;
        end
        check_reset_clean("during reset");
        rst = 1'b0;
        @(posedge clk);
        #1;
        check_reset_clean("first cycle after reset release");
        chk_en = 1'b1;
    endtask

    //-------------------------------------------------------------------------
    // Phase 1: single store lifecycle (alloc/AGU/exec/commit/drain/takeover)
    //-------------------------------------------------------------------------
    task automatic phase_single_lifecycle();
        $display("[tb_sq] phase 1: single store lifecycle");
        clear_inputs();
        alloc_tag.slot_index = 4'h3;
        alloc_valid          = 1'b1;
        tick();
        alloc_valid = 1'b0;
        chk_fatal((sq_occupancy == 4'd1) && (sq_head_ptr == 3'd0) && (store_credit == 4'd7)
                  && !sq_full && (sq_occupied == 8'h01) && (alloc_idx == 3'd1),
                  "after first alloc: occupancy/head/credit/next alloc_idx");
        chk_fatal(!exec_valid, "no exec_valid before AGU registration");
        chk_fatal(!drain_valid, "no drain before commit");

        agu_reg(3'd0, 4'h3, 32'h1000_0004, 4'b1111, 32'hDEAD_BEEF, 1'b0);
        chk_fatal(exec_valid && (exec_tag.slot_index == 4'h3), "exec_valid for the only ready store");
        chk_fatal(!drain_valid, "SPEC store does not drain");

        // exec_ready = 0 must hold the request, no double completion
        repeat (3) tick();
        chk_fatal(exec_valid && (exec_tag.slot_index == 4'h3), "exec_valid holds while exec_ready=0");
        chk_fatal(dut.exec_done_r == 8'd0, "no exec_done while exec_ready=0");

        exec_once();
        chk_fatal(dut.exec_done_r == 8'h01, "exec_done set on handshake");
        chk_fatal(!exec_valid, "no second exec_valid for the same store");

        // ok must not depend on commit_fire
        store_commit_valid = 2'b01;
        store_commit_tag[0].slot_index = 4'h3;
        repeat (3) begin
            tick();
            chk_fatal(store_commit_ok == 2'b01, "lane0 ok stable while commit_fire=0");
        end
        store_commit_valid = 2'b00;

        commit_lanes(2'b01, 4'h3, 4'h0, 2'b01);
        chk_fatal((dut.committed_cnt_r == 4'd1)
                  && (dut.commit_ptr_r == 3'(dut.head_r + 3'd1)),
                  "commit moves SPEC -> COMMITTED and advances commit_ptr");
        chk_fatal(drain_valid && (drain_idx == 3'd0) && (drain_tag.slot_index == 4'h3),
                  "oldest COMMITTED head drains");
        chk_fatal((drain_addr == 32'h1000_0004) && (drain_mask == 4'b1111)
                  && (drain_data == 32'hDEAD_BEEF) && !drain_is_mmio, "drain payload");

        drain_start = 1'b1;
        tick();
        drain_start = 1'b0;
        chk_fatal(dut.inflight_r == 8'h01, "drain_start sets drain_inflight");
        chk_fatal(!drain_valid, "drain_valid drops while in flight (no re-send)");
        repeat (2) tick();
        chk_fatal(!drain_valid && (dut.inflight_r == 8'h01), "request not re-sent while in flight");

        drain_takeover = 1'b1;
        tick();
        drain_takeover = 1'b0;
        chk_fatal((dut.occupancy_r == 4'd0) && (dut.head_r == 3'd1) && (dut.committed_cnt_r == 4'd0),
                  "takeover releases the entry and advances head");
        chk_fatal((store_credit == 4'd8) && (sq_occupancy == 4'd0), "empty again: credit 8");
    endtask

    //-------------------------------------------------------------------------
    // Phase 2: fill, full boundary, exec order, wrap-around > 8 rounds
    //-------------------------------------------------------------------------
    task automatic phase_fill_wrap();
        int unsigned round;
        logic [3:0]  tg_base;
        logic [2:0]  expect_idx;
        logic [3:0]  seen [8];
        int unsigned nseen;
        logic [2:0]  head_start;
        $display("[tb_sq] phase 2: fill/full/exec order/wrap");
        clear_inputs();
        head_start = dut.head_r;
        chk_fatal(dut.occupancy_r == 4'd0, "phase 2 starts from an empty ring");

        for (round = 0; round < 3; round++) begin
            tg_base = 4'(round * 8);
            // ---- fill 8 entries (tail wraps during the fill) --------------
            for (int unsigned i = 0; i < 8; i++) begin
                expect_idx = m_tail();
                alloc_tag.slot_index = 4'(tg_base + 4'(i));
                alloc_valid          = 1'b1;
                check_now();                 // alloc_idx is sampled before the edge
                chk_fatal(alloc_idx == expect_idx,
                          $sformatf("round %0d alloc %0d: alloc_idx=%0d expected %0d",
                                    round, i, alloc_idx, expect_idx));
                finish_cycle();
                alloc_valid = 1'b0;
                // register the address right away (slot = the reserved tail)
                agu_valid          = 1'b1;
                agu_qidx           = expect_idx;
                agu_tag.slot_index = 4'(tg_base + 4'(i));
                agu_addr           = 32'h2000_0000 + 32'(round * 256 + i * 4);
                agu_byte_mask      = 4'b1111;
                agu_store_data     = 32'hA000_0000 + 32'(round * 16 + i);
                agu_is_mmio        = 1'b0;
                tick();
                agu_valid = 1'b0;
            end
            chk_fatal((dut.occupancy_r == 4'd8) && sq_full && (store_credit == 4'd0)
                      && (sq_occupancy == 4'd8), "full boundary: occupancy 8, credit 0, sq_full");

            // ---- exec in ring order, one per cycle ------------------------
            nseen = 0;
            while (exec_valid) begin
                chk_fatal(nseen < 8, "no more than 8 exec completions per fill");
                seen[nseen] = exec_tag.slot_index;
                nseen = nseen + 1;
                exec_ready = 1'b1;
                tick();
                exec_ready = 1'b0;
                chk_fatal(pc8(dut.exec_done_r) == nseen,
                          "one new exec_done bit per exec handshake (exactly once)");
            end
            chk_fatal(nseen == 8, "exactly one exec_valid per store");
            for (int unsigned i = 0; i < 8; i++)
                chk_fatal(seen[i] == 4'(tg_base + 4'(i)),
                          $sformatf("exec order %0d: tag %0d expected %0d (head -> tail)",
                                    i, seen[i], 4'(tg_base + 4'(i))));

            // ---- commit all (2-wide) and drain all (wrap x8) --------------
            while (dut.committed_cnt_r < 4'd8) begin
                store_commit_valid = 2'b11;
                store_commit_tag[0].slot_index = m_spec_tag(0);
                store_commit_tag[1].slot_index = m_spec_tag(1);
                commit_fire = 2'b11;
                tick();
                store_commit_valid = 2'b00;
                commit_fire        = 2'b00;
            end
            chk_fatal((dut.committed_cnt_r == 4'd8) && (dut.commit_ptr_r == dut.tail_r),
                      "all committed: commit_ptr reaches tail");
            for (int unsigned i = 0; i < 8; i++) begin
                chk_fatal(drain_valid, "committed head drains");
                chk_fatal(drain_tag.slot_index == 4'(tg_base + 4'(i)),
                          $sformatf("drain order %0d: tag %0d expected %0d",
                                    i, drain_tag.slot_index, 4'(tg_base + 4'(i))));
                drain_takeover = 1'b1;
                tick();
                drain_takeover = 1'b0;
            end
            chk_fatal((dut.occupancy_r == 4'd0) && (store_credit == 4'd8), "drained empty");
        end
        chk_fatal(dut.head_r == head_start,
                  "head wrapped a full 3 x 8 rounds back to its start value");
    endtask

    //-------------------------------------------------------------------------
    // Phase 3: 2-wide store commit matching corner cases
    //-------------------------------------------------------------------------
    task automatic phase_commit_cases();
        logic [3:0] ta, tb;
        logic [2:0] s_l, s_m;
        $display("[tb_sq] phase 3: 2-wide commit matching");
        clear_inputs();

        // -- (a..d) four SPEC stores, all with address + exec done ----------
        add_store(4'h1, 32'h3000_0000, 4'b1111, 32'h1111_1111, 1'b0, 1'b1);
        add_store(4'h2, 32'h3000_0004, 4'b0011, 32'h2222_2222, 1'b0, 1'b1);
        add_store(4'h3, 32'h3000_0008, 4'b0001, 32'h3333_3333, 1'b0, 1'b1);
        add_store(4'h4, 32'h3000_000C, 4'b1111, 32'h4444_4444, 1'b0, 1'b1);

        // (a) wrong lane0 tag -> both lanes fail (ok[1] depends on ok[0])
        store_commit_valid = 2'b11;
        store_commit_tag[0].slot_index = 4'hF;
        store_commit_tag[1].slot_index = m_spec_tag(1);
        commit_fire = 2'b00;
        check_now();
        chk_fatal(store_commit_ok == 2'b00, "wrong lane0 tag: ok=00 (lane1 depends on lane0)");
        finish_cycle();
        store_commit_valid = 2'b00;

        // (b) lane0 is a non-store global lane: lane1 matches commit_ptr
        ta = m_spec_tag(0);
        store_commit_valid = 2'b10;
        store_commit_tag[0].slot_index = 4'hF;
        store_commit_tag[1].slot_index = ta;
        check_now();
        chk_fatal(store_commit_ok == 2'b10, "non-store lane0 skipped: lane1 hits commit_ptr");
        finish_cycle();
        // a global commit_fire on the Load lane must not touch the SQ
        commit_fire = 2'b01;
        check_now();
        chk_fatal(store_commit_ok == 2'b10, "ok unaffected by a global lane0 commit_fire");
        finish_cycle();
        chk_fatal((dut.committed_cnt_r == 4'd0) && (dut.commit_ptr_r == dut.head_r),
                  "global non-store commit_fire does not commit an SQ entry");
        commit_fire = 2'b11;
        tick();
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
        chk_fatal((dut.committed_cnt_r == 4'd1)
                  && (dut.commit_ptr_r == 3'(dut.head_r + 3'd1)),
                  "lane1 store commits with a global lane0 fire");

        // (c) both lanes correct, lane0-only fire
        ta = m_spec_tag(0);
        tb = m_spec_tag(1);
        store_commit_valid = 2'b11;
        store_commit_tag[0].slot_index = ta;
        store_commit_tag[1].slot_index = tb;
        commit_fire = 2'b01;
        check_now();
        chk_fatal(store_commit_ok == 2'b11, "both lanes match");
        finish_cycle();
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
        chk_fatal((dut.committed_cnt_r == 4'd2)
                  && (dut.commit_ptr_r == 3'(dut.head_r + 3'd2)),
                  "partial commit: only lane0 moved");

        // (d) lane1 tag wrong -> ok=01
        ta = m_spec_tag(0);
        store_commit_valid = 2'b11;
        store_commit_tag[0].slot_index = ta;
        store_commit_tag[1].slot_index = 4'hF;
        check_now();
        chk_fatal(store_commit_ok == 2'b01, "wrong lane1 tag: ok=01");
        finish_cycle();
        store_commit_valid = 2'b00;
        flush_and_drain();
        chk_fatal(dut.head_r == dut.tail_r, "phase 3a drained clean");

        // -- (e) addr_valid = 0 blocks the commit of the oldest SPEC --------
        s_l = m_tail();
        alloc_one(4'h5);                    // oldest SPEC, no AGU yet
        s_m = m_tail();
        add_store(4'h6, 32'h3000_0010, 4'b1111, 32'h6666_6666, 1'b0, 1'b0);
        store_commit_valid = 2'b11;
        store_commit_tag[0].slot_index = 4'h5;
        store_commit_tag[1].slot_index = 4'h6;
        check_now();
        chk_fatal(store_commit_ok == 2'b00, "addr_valid=0 on the oldest SPEC: both lanes blocked");
        finish_cycle();
        store_commit_valid = 2'b00;
        agu_reg(s_l, 4'h5, 32'h3000_0014, 4'b1111, 32'h5555_5555, 1'b0);
        exec_once();                        // exec the oldest (tag 5)
        exec_once();                        // exec the next (tag 6)
        store_commit_valid = 2'b11;
        store_commit_tag[0].slot_index = 4'h5;
        store_commit_tag[1].slot_index = 4'h6;
        commit_fire = 2'b11;
        check_now();
        chk_fatal(store_commit_ok == 2'b11, "2-wide ok after both addresses registered");
        finish_cycle();
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
        chk_fatal((dut.committed_cnt_r == 4'd2)
                  && (dut.commit_ptr_r == 3'(dut.head_r + 3'd2)),
                  "2-wide commit moved two entries");
        chk_fatal(s_m == 3'(s_l + 3'd1), "the two stores are adjacent in the ring");
        flush_and_drain();
    endtask

    //-------------------------------------------------------------------------
    // Phase 4: same-edge a / c / t / k combinations
    //-------------------------------------------------------------------------
    task automatic phase_same_cycle();
        logic [3:0] t_spec, t_cmt2, t_spec2;
        logic [2:0] head0, tail0, cmt_ptr0;
        logic [3:0] occ0, cc0;
        $display("[tb_sq] phase 4: same-edge alloc/commit/takeover/flush");
        clear_inputs();

        // [C][S][S]: alloc + commit + takeover in the same cycle
        add_store(4'h6, 32'h4000_0000, 4'b1111, 32'h6666_6666, 1'b0, 1'b1);
        add_store(4'h7, 32'h4000_0004, 4'b1111, 32'h7777_7777, 1'b0, 1'b1);
        add_store(4'h8, 32'h4000_0008, 4'b1111, 32'h8888_8888, 1'b0, 1'b1);
        commit_lanes(2'b01, m_spec_tag(0), 4'h0, 2'b01);
        t_spec = m_spec_tag(0);
        head0  = dut.head_r;
        tail0  = dut.tail_r;
        occ0   = dut.occupancy_r;
        cc0    = dut.committed_cnt_r;
        cmt_ptr0 = dut.commit_ptr_r;

        alloc_tag.slot_index = 4'h9;
        alloc_valid          = 1'b1;
        store_commit_valid   = 2'b01;
        store_commit_tag[0].slot_index = t_spec;
        commit_fire          = 2'b01;
        drain_takeover       = 1'b1;
        tick();
        alloc_valid        = 1'b0;
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
        drain_takeover     = 1'b0;
        chk_fatal(dut.head_r == 3'(head0 + 3'd1), "same-edge: head += t");
        chk_fatal(dut.tail_r == 3'(tail0 + 3'd1), "same-edge: tail += a");
        chk_fatal(dut.occupancy_r == occ0, "same-edge: occupancy += a - t");
        chk_fatal(dut.committed_cnt_r == cc0, "same-edge: committed_cnt += c - t");
        chk_fatal(dut.commit_ptr_r == 3'(cmt_ptr0 + 3'd1), "same-edge: commit_ptr += c");
        chk_fatal(q[0].committed && (q[0].tag == t_spec),
                  "same-edge: the newly committed store is the new head");

        // flush + commit in the same cycle (a = 0 on a flush cycle)
        add_store(4'hA, 32'h4000_000C, 4'b1111, 32'hAAAA_AAAA, 1'b0, 1'b1);
        add_store(4'hB, 32'h4000_0010, 4'b1111, 32'hBBBB_BBBB, 1'b0, 1'b1);
        t_cmt2  = q[m_spec_idx(0)].tag;      // oldest SPEC -> COMMITTED
        t_spec2 = q[q.size() - 1].tag;       // youngest SPEC -> killed
        tail0   = dut.tail_r;
        occ0    = dut.occupancy_r;
        store_commit_valid = 2'b01;
        store_commit_tag[0].slot_index = t_cmt2;
        commit_fire        = 2'b01;
        kill_mask          = 16'd0;
        kill_mask[t_spec2] = 1'b1;      // youngest SPEC suffix = 1 entry
        tick();
        store_commit_valid = 2'b00;
        commit_fire        = 2'b00;
        kill_mask          = 16'd0;
        chk_fatal(dut.tail_r == 3'(tail0 - 3'd1), "flush+commit: tail -= k");
        chk_fatal(dut.occupancy_r == 4'(occ0 - 4'd1), "flush+commit: occupancy -= k");
        chk_fatal(dut.committed_cnt_r == 4'd2, "flush+commit: commit still applied");
        flush_and_drain();
        chk_fatal((dut.head_r == dut.commit_ptr_r) && (dut.tail_r == dut.head_r),
                  "clean slate after phase 4");
    endtask

    //-------------------------------------------------------------------------
    // Phase 5: flush of the youngest SPEC suffix
    //-------------------------------------------------------------------------
    task automatic phase_flush();
        logic [2:0] tail0, cmt_ptr0;
        logic [3:0] occ0, cc0;
        $display("[tb_sq] phase 5: SPEC suffix flush");
        clear_inputs();
        for (int unsigned i = 0; i < 6; i++)
            add_store(4'(i + 1), 32'h5000_0000 + 32'(i * 4), 4'b1111,
                      32'h5000_0000 + 32'(i), 1'b0, 1'b1);
        // commit the two oldest
        commit_lanes(2'b11, m_spec_tag(0), m_spec_tag(1), 2'b11);
        chk_fatal(dut.committed_cnt_r == 4'd2, "two COMMITTED entries");
        tail0    = dut.tail_r;
        cmt_ptr0 = dut.commit_ptr_r;
        occ0     = dut.occupancy_r;
        cc0      = dut.committed_cnt_r;

        // kill the two youngest SPEC entries
        kill_mask = 16'd0;
        kill_mask[q[5].tag] = 1'b1;
        kill_mask[q[4].tag] = 1'b1;
        tick();
        kill_mask = 16'd0;
        chk_fatal(dut.tail_r == 3'(tail0 - 3'd2), "flush: tail rolls back by k");
        chk_fatal(dut.occupancy_r == 4'(occ0 - 4'd2), "flush: occupancy -= k");
        chk_fatal((dut.committed_cnt_r == cc0) && (dut.commit_ptr_r == cmt_ptr0),
                  "flush: COMMITTED prefix untouched");
        chk_fatal(dut.head_r == 3'(tail0 - 3'd6), "flush: head unchanged");

        // a COMMITTED tag in the mask, plus a non-live tag: no effect at all
        tail0 = dut.tail_r;
        occ0  = dut.occupancy_r;
        kill_mask = 16'd0;
        kill_mask[q[0].tag] = 1'b1;      // COMMITTED store: never killed
        kill_mask[4'hF]     = 1'b1;      // not in the SQ: no effect
        tick();
        kill_mask = 16'd0;
        chk_fatal((dut.tail_r == tail0) && (dut.occupancy_r == occ0)
                  && (dut.committed_cnt_r == cc0),
                  "kill of COMMITTED / dead tag has no effect");
        chk_fatal((sq_occupied != 8'd0) && (dut.head_r == 3'(tail0 - 3'd4)),
                  "head still points at the oldest COMMITTED store");

        // kill the whole remaining SPEC suffix
        kill_mask = 16'd0;
        for (int k = 2; k < q.size(); k++) kill_mask[q[k].tag] = 1'b1;
        tick();
        kill_mask = 16'd0;
        chk_fatal((dut.tail_r == dut.commit_ptr_r) && (dut.occupancy_r == 4'd2)
                  && (dut.committed_cnt_r == 4'd2),
                  "full SPEC suffix flush leaves only the COMMITTED prefix");
    endtask

    //-------------------------------------------------------------------------
    // Phase 6: MMIO store (pending flag, kill protection)
    //-------------------------------------------------------------------------
    task automatic phase_mmio();
        $display("[tb_sq] phase 6: MMIO store");
        clear_inputs();
        drain_empty();                                          // clean slate

        // SPEC MMIO store is killable
        add_store(4'hC, 32'hA000_0004, 4'b1111, 32'hCAFE_0000, 1'b1, 1'b0);
        chk_fatal(sq_is_mmio[3'(m_tail() - 3'd1)], "MMIO attribute visible on the SQ port");
        chk_fatal(!sq_mmio_store_pending, "SPEC MMIO store does not raise the pending flag");
        kill_mask = 16'd0;
        kill_mask[4'hC] = 1'b1;
        tick();
        kill_mask = 16'd0;
        chk_fatal(dut.occupancy_r == 4'd0, "SPEC MMIO store is killed by flush");

        // COMMITTED MMIO store: pending 1, never killed, cleared by takeover
        add_store(4'hD, 32'hA000_0008, 4'b1111, 32'hCAFE_0004, 1'b1, 1'b1);
        chk_fatal(!sq_mmio_store_pending, "MMIO store not committed yet: pending 0");
        commit_lanes(2'b01, 4'hD, 4'h0, 2'b01);
        chk_fatal(sq_mmio_store_pending, "COMMITTED MMIO store raises sq_mmio_store_pending");
        chk_fatal(drain_valid && drain_is_mmio, "MMIO head drains through the MMIO path");

        kill_mask = 16'd0;
        kill_mask[4'hD] = 1'b1;
        repeat (2) tick();
        kill_mask = 16'd0;
        chk_fatal((dut.committed_cnt_r == 4'd1) && sq_mmio_store_pending,
                  "COMMITTED MMIO store survives kill_mask");
        chk_fatal(sq_mmio_store_pending, "pending still 1 while COMMITTED and not taken over");

        drain_start = 1'b1;
        tick();
        drain_start = 1'b0;
        chk_fatal(sq_mmio_store_pending, "pending stays 1 while the Write Ack is outstanding");
        drain_takeover = 1'b1;
        tick();
        drain_takeover = 1'b0;
        chk_fatal(!sq_mmio_store_pending && (dut.occupancy_r == 4'd0),
                  "Write Ack (takeover) clears the pending flag");
    endtask

    //-------------------------------------------------------------------------
    // Phase 7: store_credit is cycle-start based (no borrowing)
    //-------------------------------------------------------------------------
    task automatic phase_credit();
        $display("[tb_sq] phase 7: credit without borrowing");
        clear_inputs();
        // 4 COMMITTED + 4 SPEC, occupancy 8, credit 0
        for (int unsigned i = 0; i < 8; i++)
            add_store(4'(i + 1), 32'h6000_0000 + 32'(i * 4), 4'b1111,
                      32'h6000_0000 + 32'(i), 1'b0, 1'b1);
        commit_lanes(2'b11, m_spec_tag(0), m_spec_tag(1), 2'b11);
        commit_lanes(2'b11, m_spec_tag(0), m_spec_tag(1), 2'b11);
        chk_fatal((dut.committed_cnt_r == 4'd4) && (store_credit == 4'd0),
                  "full: credit 0 with 4 committed");

        drain_takeover = 1'b1;
        check_now();
        chk_fatal(store_credit == 4'd0,
                  "takeover cycle: credit still based on cycle-start occupancy (8)");
        finish_cycle();
        drain_takeover = 1'b0;
        chk_fatal(store_credit == 4'd1, "credit reflects the release only on the next cycle");

        // same-cycle start + takeover must not leave drain_inflight behind, and
        // the next COMMITTED head must be able to drain immediately.
        drain_start    = 1'b1;
        drain_takeover = 1'b1;
        tick();
        drain_start    = 1'b0;
        drain_takeover = 1'b0;
        chk_fatal(dut.inflight_r == 8'd0, "same-edge start+takeover leaves no inflight");
        chk_fatal(drain_valid, "next committed head drains right away (no stale inflight)");
        flush_and_drain();
    endtask

    //-------------------------------------------------------------------------
    // Phase 8: fixed-seed random stimulus against the reference model
    //-------------------------------------------------------------------------
    typedef struct packed {
        logic [2:0] slot;
        logic [3:0] tag;
    } agu_ev_t;

    agu_ev_t agu_pend [$];

    task automatic random_store(output logic [31:0] a, output logic [3:0] bm,
                                output logic [31:0] d, output logic mm);
        logic [1:0] sz;
        logic [1:0] lo;
        sz = 2'(rnd_range(3));
        lo = 2'(rnd_range(3));
        if (sz == 2'd0) begin
            a  = (30'(rnd()) << 2) | {30'd0, lo};          // byte aligned
            bm = 4'b0001 << lo;
            d  = {24'd0, 8'(rnd())} << (8 * lo);
        end else if (sz == 2'd1) begin
            a  = (29'(rnd()) << 3) | {30'd0, lo[1], 1'b0};
            bm = 4'b0011 << lo[1];
            d  = {16'd0, 16'(rnd())} << (8 * lo[1]);
        end else begin
            a  = 30'(rnd()) << 2;
            bm = 4'b1111;
            d  = rnd();
        end
        mm = (rnd_range(100) < 15);
    endtask

    task automatic random_cycle();
        int          spec_cnt;
        int          kill_n;
        int          ev_k;
        int          k;
        int          k1;
        logic [3:0]  tg;
        logic [31:0] a;
        logic [3:0]  bm;
        logic [31:0] d;
        logic        mm;
        logic        do_alloc;
        logic [3:0]  alloc_tg;
        agu_ev_t     ev;

        clear_inputs();

        // ---- flush decision: youngest contiguous SPEC suffix --------------
        spec_cnt = 0;
        for (k = 0; k < q.size(); k++) if (!q[k].committed) spec_cnt = spec_cnt + 1;
        kill_n = 0;
        if ((spec_cnt > 0) && (rnd_range(100) < 8))
            kill_n = 1 + int'(rnd_range((spec_cnt > 3) ? 3 : spec_cnt));
        for (k = q.size() - kill_n; k < q.size(); k++) kill_mask[q[k].tag] = 1'b1;
        // stale CIQ tags of COMMITTED entries / dead tags must be harmless
        for (k = 0; k < q.size(); k++)
            if (q[k].committed && (rnd_range(100) < 30)) kill_mask[q[k].tag] = 1'b1;
        if (rnd_range(100) < 20) begin
            tg = m_free_tag(4'(rnd_range(16)));
            kill_mask[tg] = 1'b1;
        end

        // ---- allocation ---------------------------------------------------
        do_alloc = 1'b0;
        alloc_tg = 4'd0;
        if ((kill_n == 0) && (q.size() < 8) && (rnd_range(100) < 40)) begin
            alloc_tg = m_free_tag(4'(rnd_range(16)));
            if (!kill_mask[alloc_tg]) do_alloc = 1'b1;
        end
        if (do_alloc) begin
            alloc_valid          = 1'b1;
            alloc_tag.slot_index = alloc_tg;
            agu_pend.push_back(agu_ev_t'{slot: m_tail(), tag: alloc_tg});
        end

        // ---- AGU registration ---------------------------------------------
        if ((agu_pend.size() > 0) && (rnd_range(100) < 70)) begin
            ev   = agu_pend.pop_front();
            ev_k = -1;
            for (k = 0; k < q.size(); k++)
                if ((ev_k < 0) && !q[k].committed && (q[k].tag == ev.tag)
                    && (3'(int'(m_head) + k) == ev.slot))
                    ev_k = k;
            if (ev_k >= 0) begin
                agu_valid          = 1'b1;
                agu_qidx           = ev.slot;
                agu_tag.slot_index = ev.tag;
                random_store(a, bm, d, mm);
                agu_addr       = a;
                agu_byte_mask  = bm;
                agu_store_data = d;
                agu_is_mmio    = mm;
            end
        end else if (rnd_range(100) < 3) begin
            // late result for a slot that no longer holds that store: dropped
            agu_valid          = 1'b1;
            agu_qidx           = 3'(rnd_range(8));
            agu_tag.slot_index = 4'(rnd_range(16));
            random_store(a, bm, d, mm);
            agu_addr       = a;
            agu_byte_mask  = bm;
            agu_store_data = d;
            agu_is_mmio    = mm;
        end

        // ---- exec ----------------------------------------------------------
        exec_ready = (rnd_range(100) < 70);

        // ---- commit (fire only where ok is expected; lane1 after lane0) ---
        store_commit_valid = 2'b00;
        if (q.size() > 0) begin
            if (rnd_range(100) < 55) begin
                k1 = m_spec_idx(0);
                store_commit_valid = 2'b01;
                store_commit_tag[0].slot_index = (rnd_range(100) < 80)
                    ? q[(k1 >= 0) ? k1 : 0].tag : 4'(rnd_range(16));
            end
            if (rnd_range(100) < 45) begin
                k1 = store_commit_valid[0] ? m_spec_idx(1) : m_spec_idx(0);
                store_commit_valid[1] = 1'b1;
                store_commit_tag[1].slot_index = (rnd_range(100) < 80)
                    ? q[(k1 >= 0) ? k1 : 0].tag : 4'(rnd_range(16));
            end
        end
        m_eval_commit();
        // The backend only commits CIQ-DONE operations, i.e. stores whose
        // execution Completion already handshaked.  Lane1 commits only after
        // lane0 when lane0 presents a store (memory.md 5.2).
        if (e_ok0 && (e_cidx0 >= 0) && q[e_cidx0].exec_done && (rnd_range(100) < 60))
            commit_fire[0] = 1'b1;
        if (e_ok1 && (e_cidx1 >= 0) && q[e_cidx1].exec_done
            && (store_commit_valid[0] ? commit_fire[0] : 1'b1) && (rnd_range(100) < 60))
            commit_fire[1] = 1'b1;

        // ---- drain / takeover ---------------------------------------------
        m_eval();
        if (e_drain_valid) begin
            drain_start = (rnd_range(100) < 50);
            if (rnd_range(100) < 60) drain_takeover = 1'b1;
        end else if ((q.size() > 0) && q[0].committed && q[0].inflight
                     && (rnd_range(100) < 60)) begin
            drain_takeover = 1'b1;
        end
        if (drain_start && (rnd_range(100) < 20)) drain_takeover = 1'b1;

        tick();
    endtask

    task automatic phase_random();
        int unsigned n_cycles;
        // Runtime trip count: a compile-time constant here would make Verilator
        // unroll 12000 copies of the cycle body (33 MB of generated C++).
        n_cycles = RAND_CYCLES;
        if ($value$plusargs("cycles=%d", n_cycles)) begin
            if (n_cycles < 10000) n_cycles = RAND_CYCLES;
        end
        $display("[tb_sq] phase 8: %0d random cycles (seed %08h)", n_cycles, RNG_SEED);
        clear_inputs();
        flush_and_drain();
        agu_pend.delete();
        rng_state = RNG_SEED;
        for (int unsigned i = 0; i < n_cycles; i++) random_cycle();
        chk_fatal(dut.occupancy_r <= 4'd8, "occupancy never exceeds 8");
    endtask

    //-------------------------------------------------------------------------
    // Negative run: a kill that is not the youngest contiguous suffix must
    // trip the DUT's a_kill_suffix assertion (separate +negative_kill run).
    //-------------------------------------------------------------------------
    task automatic negative_kill_test();
        $display("[tb_sq] negative run: expecting the a_kill_suffix assertion to fire");
        clear_inputs();
        alloc_one(4'h1);
        agu_reg(3'd0, 4'h1, 32'h7000_0000, 4'b1111, 32'h1111_1111, 1'b0);
        alloc_one(4'h2);
        agu_reg(3'd1, 4'h2, 32'h7000_0004, 4'b1111, 32'h2222_2222, 1'b0);
        chk_fatal(dut.occupancy_r == 4'd2, "two SPEC entries set up");
        // kill only the OLDER entry: the younger one survives -> suffix violated
        kill_mask = 16'd0;
        kill_mask[4'h1] = 1'b1;
        #1;
        kill_mask = 16'd0;
        $fatal(1, "negative kill test: a_kill_suffix did NOT fire");
    endtask

    //-------------------------------------------------------------------------
    // Main
    //-------------------------------------------------------------------------
    initial begin
        checks    = 0;
        errors    = 0;
        cycle_cnt = 0;
        chk_en    = 1'b0;
        rng_state = RNG_SEED;
        m_reset();
        clear_inputs();

        phase_reset();
        if ($test$plusargs("negative_kill")) begin
            negative_kill_test();
        end else begin
            phase_single_lifecycle();
            phase_fill_wrap();
            phase_commit_cases();
            phase_same_cycle();
            phase_flush();
            phase_mmio();
            phase_credit();
            phase_random();
            $display("ALL TESTS PASSED: %0d checks - reset/empty/full, exec once + ring order, 2-wide commit lanes (non-store lane skipped + global commit_fire ignored), same-edge alloc/commit/takeover/flush, kill suffix + COMMITTED protection, MMIO pending, drain inflight/takeover, credit no-borrow, ring wrap, %0d-cycle fixed-seed random vs reference model",
                     checks, RAND_CYCLES);
        end
        $finish;
    end
endmodule
