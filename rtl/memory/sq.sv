//=============================================================================
// ARES LSU - unified 8-entry Store Queue (L04)
//-----------------------------------------------------------------------------
// One ordered ring holds every issued store through its whole lifetime:
//
//     [ COMMITTED prefix ][ SPEC suffix ]     head <= commit_ptr <= tail
//
//   head        oldest COMMITTED store that has not been taken over yet
//   commit_ptr  oldest SPEC store (the next one the backend may commit)
//   tail        next allocation slot (reserved by lsu_top at issue)
//   cmt_cnt     number of COMMITTED entries
//
// Invariants (memory.md 5.1):
//   commit_ptr = (head + committed_cnt) mod 8
//   tail       = (head + occupancy)     mod 8
//   occupancy  = popcount(occupied);  committed_cnt = popcount(committed)
// Empty/full are decided by the counters, never by pointer equality.
//
// Per cycle the state advances by (memory.md 5.1), a = issue (0/1),
// c = commits (0..2), t = head takeover (0/1), k = SPEC entries removed by a
// flush (the youngest contiguous suffix):
//   head += t;  commit_ptr += c;  tail += a - k
//   occupancy += a - t - k;  committed_cnt += c - t
// All effects are atomic and land on the same clock edge.  A flush cycle never
// allocates (a = 0): the ring cannot represent the hole a simultaneous
// allocation would leave inside the killed suffix, so simulation checks it.
//
// Store lifetime:
//   alloc (tail, SPEC) -> AGU registers addr/data/mask/mmio -> exactly one
//   execution Completion -> commit_fire turns the entry COMMITTED (the CIQ tag
//   becomes stale, the entry stays in the SQ) -> the oldest COMMITTED head is
//   drained, drain_start marks drain_inflight (never re-sent), drain_takeover
//   releases the entry.  A COMMITTED store is never killed; a SPEC store is
//   released by kill_mask only as part of the youngest contiguous suffix.
//   MMIO stores follow the same path and additionally raise
//   sq_mmio_store_pending until their device Write Ack (= drain_takeover).
//
// Forwarding view (sq_occupied/addr/data/mask/mmio) exposes the registered
// cycle-start state, so a store taken over in cycle N still forwards in cycle N
// and is gone in N+1 (memory.md 4.2 point 5); sq_takeover marks that store for
// the LQ mask clear at the same edge.
//
// Structure (FREE-04): fully parallel per-entry compares, an isolated
// lowest-set-bit arbitration for the oldest exec candidate and direct indexed
// drain selection - no serial priority chain, no latch, no combinational loop.
//
// Spec sources: memory.md 5.1 / 5.2 / 5.3 (3.1 for the MMIO store path).
// FREE items: FREE-02 (file organisation), FREE-04 (combinational structure).
// Interface contract: rtl/memory/LSU_INTERFACES.md section 4 (frozen port list).
// Self-check bench: rtl/memory/test/unit/tb_sq.sv
//
// Build / run (repo root, explicit file list):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//         -DCONFIG_SIMULATION --top-module sq rtl/common/ares_pkg.sv rtl/memory/sq.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//         -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_sq \
//         --Mdir sim/build/unit/tb_sq -o tb_sq rtl/common/ares_pkg.sv \
//         rtl/memory/sq.sv rtl/memory/test/unit/tb_sq.sv
//   $ sim/build/unit/tb_sq/tb_sq
//=============================================================================
module sq (
    input  logic                            clk,
    input  logic                            rst,

    //---- issue allocation (tail reserves a SPEC entry) --------------------
    input  logic                            alloc_valid,
    input  ares_pkg::tag_t                  alloc_tag,
    output logic [2:0]                      alloc_idx,       // = sq_tail_ptr

    //---- AGU registration -------------------------------------------------
    input  logic                            agu_valid,
    input  logic [2:0]                      agu_qidx,
    input  ares_pkg::tag_t                  agu_tag,
    input  logic [31:0]                     agu_addr,
    input  logic [3:0]                      agu_byte_mask,
    input  logic [31:0]                     agu_store_data,
    input  logic                            agu_is_mmio,

    //---- execution Completion (exactly one per store) ---------------------
    output logic                            exec_valid,
    input  logic                            exec_ready,
    output ares_pkg::tag_t                  exec_tag,

    //---- 2-wide Store Commit (memory.md 5.2) ------------------------------
    input  logic [1:0]                      store_commit_valid,
    input  ares_pkg::tag_t                  store_commit_tag [2],
    output logic [1:0]                      store_commit_ok,
    input  logic [1:0]                      commit_fire,

    //---- oldest COMMITTED store drain (DCache / MMIO bridge) --------------
    output logic                            drain_valid,     // COMMITTED && addr_valid && !inflight
    output logic [2:0]                      drain_idx,
    output ares_pkg::tag_t                  drain_tag,
    output logic [31:0]                     drain_addr,
    output logic [31:0]                     drain_data,
    output logic [3:0]                      drain_mask,
    output logic                            drain_is_mmio,
    input  logic                            drain_start,     // request accepted -> inflight
    input  logic                            drain_takeover,  // visibility taken -> release entry

    //---- forwarding read port (LQ) ----------------------------------------
    output logic [7:0]                      sq_occupied,
    output logic [7:0]                      sq_takeover,     // this cycle's takeover, one-hot
    output logic [7:0]                      sq_addr_valid,
    output logic [7:0][31:0]                sq_addr,
    output logic [7:0][31:0]                sq_data,
    output logic [7:0][3:0]                 sq_byte_mask,
    output logic [7:0]                      sq_is_mmio,
    output logic [2:0]                      sq_head_ptr,
    output logic [3:0]                      sq_occupancy,
    output logic                            sq_mmio_store_pending, // COMMITTED MMIO not taken over

    //---- flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- status -----------------------------------------------------------
    output logic [3:0]                      store_credit,    // 8 - occupancy (cycle start)
    output logic                            sq_full
);
    import ares_pkg::*;

    localparam logic [2:0] PTR_MASK = 3'd7;
    localparam logic [3:0] SQ_DEPTH = 4'd8;

    //-------------------------------------------------------------------------
    // Registered state
    //-------------------------------------------------------------------------
    logic [7:0]       occ_r;           // occupied
    logic [7:0]       committed_r;     // SPEC (0) / COMMITTED (1)
    logic [7:0]       addr_valid_r;    // addr/data/mask/mmio registered by AGU
    logic [7:0]       exec_done_r;     // execution Completion already handshaked
    logic [7:0]       inflight_r;      // drain request sent, takeover pending
    logic [7:0][3:0]  tag_r;           // CIQ tag (valid until commit)
    logic [7:0][31:0] addr_r;
    logic [7:0][31:0] data_r;          // AGU-aligned store data
    logic [7:0][3:0]  mask_r;
    logic [7:0]       mmio_r;

    logic [2:0]       head_r;
    logic [2:0]       commit_ptr_r;
    logic [2:0]       tail_r;
    logic [3:0]       occupancy_r;
    logic [3:0]       committed_cnt_r;

    //-------------------------------------------------------------------------
    // Helpers
    //-------------------------------------------------------------------------
    // Ring age: 0 = head (oldest), increasing towards tail (youngest).
    function automatic logic [2:0] ring_age(input logic [2:0] idx);
        ring_age = (idx - head_r) & PTR_MASK;
    endfunction

    function automatic logic [3:0] popcount8(input logic [7:0] v);
        popcount8 = 4'd0;
        for (int unsigned i = 0; i < 8; i++)
            popcount8 = popcount8 + {3'd0, v[i]};
    endfunction

    // A commit candidate matches when the slot still holds an uncommitted SPEC
    // entry that registered its address/data and carries the presented tag.
    // Purely combinational on registered state - never on commit_fire
    // (memory.md 5.2: only existing state is inspected).
    function automatic logic commit_match(input logic [2:0] idx, input logic [3:0] tag);
        commit_match = occ_r[idx] && !committed_r[idx] && addr_valid_r[idx]
                    && (tag_r[idx] == tag);
    endfunction

    //-------------------------------------------------------------------------
    // Allocation: lsu_top reserves the tail slot at issue and only asserts
    // alloc_valid while a credit exists.  A store killed in its own issue cycle
    // is dropped here too (kill wins over the younger operation).
    //-------------------------------------------------------------------------
    logic       alloc_fire;
    logic [3:0] alloc_inc;

    assign alloc_fire = alloc_valid && (occupancy_r != SQ_DEPTH)
                     && !kill_mask[alloc_tag.slot_index];
    assign alloc_inc  = {3'd0, alloc_fire};
    assign alloc_idx  = tail_r;

    //-------------------------------------------------------------------------
    // 2-wide Store Commit match (memory.md 5.2)
    //   lane 0 -> SPEC entry at commit_ptr
    //   lane 1 -> next SPEC entry, or commit_ptr itself when lane 0 is not a
    //             store: a non-store global lane consumes no SQ entry.
    //   ok[1] depends on ok[0] (the second store only commits when the first
    //   one did).
    //-------------------------------------------------------------------------
    logic [2:0] lane0_idx;
    logic [2:0] lane1_idx;
    logic [1:0] commit_ok_c;
    logic [7:0] commit_hit;      // one-hot / two-hot entries moving to COMMITTED
    logic [3:0] commit_inc;

    assign lane0_idx = commit_ptr_r;
    assign lane1_idx = commit_ptr_r + (store_commit_valid[0] ? 3'd1 : 3'd0);
    assign store_commit_ok = commit_ok_c;

    always_comb begin
        commit_ok_c[0] = store_commit_valid[0]
                      && commit_match(lane0_idx, store_commit_tag[0].slot_index);
        commit_ok_c[1] = store_commit_valid[1]
                      && commit_match(lane1_idx, store_commit_tag[1].slot_index)
                      && (!store_commit_valid[0] || commit_ok_c[0]);
    end

    // commit_hit is the only part of the commit logic that may observe
    // commit_fire.  It deliberately lives in its OWN always_comb block: if it
    // shared a block with commit_ok_c, a whole-block dependency analysis would
    // make store_commit_ok depend on commit_fire, which closes a combinational
    // loop through be_commit (Verilator UNOPTFLAT on be_top.commit_fire_w).
    always_comb begin
        commit_hit = 8'd0;
        if (commit_fire[0] && commit_ok_c[0]) commit_hit[lane0_idx] = 1'b1;
        if (commit_fire[1] && commit_ok_c[1]) commit_hit[lane1_idx] = 1'b1;
    end

    //-------------------------------------------------------------------------
    // Flush: only SPEC entries leave on kill_mask, and (checked in simulation)
    // only as the youngest contiguous suffix.  A COMMITTED store is never
    // killed, not even by a mask bit that still carries its stale CIQ tag.
    //-------------------------------------------------------------------------
    logic [7:0] kill_hit;
    logic [3:0] kill_inc;

    always_comb begin
        kill_hit = 8'd0;
        kill_inc = 4'd0;
        for (int unsigned i = 0; i < 8; i++) begin
            kill_hit[i] = occ_r[i] && !committed_r[i] && !commit_hit[i]
                       && kill_mask[tag_r[i]];
            kill_inc = kill_inc + {3'd0, kill_hit[i]};
        end
    end

    //-------------------------------------------------------------------------
    // Oldest-COMMITTED-head drain and takeover
    //-------------------------------------------------------------------------
    logic       drain_head_committed;   // there is a COMMITTED entry at head
    logic       takeover_ack;
    logic [7:0] takeover_hit;
    logic [3:0] takeover_inc;

    assign drain_head_committed = (committed_cnt_r != 4'd0)
                               && occ_r[head_r] && committed_r[head_r];
    assign takeover_ack = drain_takeover && drain_head_committed;
    assign takeover_hit = takeover_ack ? (8'd1 << head_r) : 8'd0;
    assign takeover_inc = {3'd0, takeover_ack};

    assign drain_valid = drain_head_committed && addr_valid_r[head_r]
                      && !inflight_r[head_r];
    assign drain_idx   = head_r;
    assign drain_addr  = addr_r[head_r];
    assign drain_data  = data_r[head_r];
    assign drain_mask  = mask_r[head_r];
    assign drain_is_mmio = mmio_r[head_r];
    always_comb drain_tag.slot_index = tag_r[head_r];

    //-------------------------------------------------------------------------
    // Execution Completion arbitration: the oldest (head -> tail) SPEC entry
    // with a registered address that has not completed yet.  Bit j of exec_ord
    // is the candidate j steps behind head, so the isolated lowest set bit is
    // the oldest candidate - a parallel reduction, not a priority chain.
    //-------------------------------------------------------------------------
    logic [7:0] exec_cand;
    logic [7:0] exec_ord;
    logic [7:0] exec_pick;
    logic [2:0] exec_idx;

    always_comb begin
        exec_cand = 8'd0;
        for (int unsigned i = 0; i < 8; i++)
            // COMMITTED entries already released their CIQ tag, killed entries
            // must not complete: neither may produce exec_valid.
            exec_cand[i] = occ_r[i] && !committed_r[i] && !kill_hit[i]
                        && addr_valid_r[i] && !exec_done_r[i];
    end

    always_comb begin
        exec_ord = 8'd0;
        for (int unsigned j = 0; j < 8; j++)
            exec_ord[j] = (occupancy_r > 4'(j))
                       && exec_cand[(head_r + 3'(j)) & PTR_MASK];
        exec_pick = exec_ord & (~exec_ord + 8'd1);
        exec_idx  = 3'd0;
        for (int unsigned j = 0; j < 8; j++)
            if (exec_pick[j]) exec_idx = (head_r + 3'(j)) & PTR_MASK;
        exec_valid = |exec_ord;
        exec_tag.slot_index = tag_r[exec_idx];
    end

    //-------------------------------------------------------------------------
    // Commit count and next-state pointers / counters (memory.md 5.1: all
    // effects land on the same edge).
    //-------------------------------------------------------------------------
    logic [2:0] head_n, commit_ptr_n, tail_n;
    logic [3:0] occupancy_n, committed_cnt_n;

    always_comb begin
        commit_inc = {3'd0, commit_hit[0]} + {3'd0, commit_hit[1]}
                   + {3'd0, commit_hit[2]} + {3'd0, commit_hit[3]}
                   + {3'd0, commit_hit[4]} + {3'd0, commit_hit[5]}
                   + {3'd0, commit_hit[6]} + {3'd0, commit_hit[7]};
        head_n          = 3'(head_r + takeover_inc);
        commit_ptr_n    = 3'({1'b0, commit_ptr_r} + commit_inc);
        tail_n          = 3'({1'b0, tail_r} + alloc_inc - kill_inc);
        occupancy_n     = occupancy_r + alloc_inc - takeover_inc - kill_inc;
        committed_cnt_n = committed_cnt_r + commit_inc - takeover_inc;
    end

    //-------------------------------------------------------------------------
    // Forwarding read port (registered cycle-start view)
    //-------------------------------------------------------------------------
    assign sq_occupied      = occ_r;
    assign sq_takeover      = takeover_hit;
    assign sq_addr_valid    = addr_valid_r;
    assign sq_addr          = addr_r;
    assign sq_data          = data_r;
    assign sq_byte_mask     = mask_r;
    assign sq_is_mmio       = mmio_r;
    assign sq_head_ptr      = head_r;
    assign sq_occupancy     = occupancy_r;
    assign sq_mmio_store_pending = |(occ_r & committed_r & mmio_r);
    assign store_credit     = SQ_DEPTH - occupancy_r;
    assign sq_full          = (occupancy_r == SQ_DEPTH);

    //-------------------------------------------------------------------------
    // Sequential state
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            head_r          <= 3'd0;
            commit_ptr_r    <= 3'd0;
            tail_r          <= 3'd0;
            occupancy_r     <= 4'd0;
            committed_cnt_r <= 4'd0;
            occ_r           <= 8'd0;
            committed_r     <= 8'd0;
            addr_valid_r    <= 8'd0;
            exec_done_r     <= 8'd0;
            inflight_r      <= 8'd0;
            mmio_r          <= 8'd0;
            for (int unsigned i = 0; i < 8; i++) begin
                tag_r[i]  <= 4'd0;
                addr_r[i] <= 32'd0;
                data_r[i] <= 32'd0;
                mask_r[i] <= 4'd0;
            end
        end else begin
            head_r          <= head_n;
            commit_ptr_r    <= commit_ptr_n;
            tail_r          <= tail_n;
            occupancy_r     <= occupancy_n;
            committed_cnt_r <= committed_cnt_n;

            for (int unsigned i = 0; i < 8; i++) begin
                // 1) AGU registration: only into the entry the result belongs
                //    to (slot + tag) and only while it is still a live SPEC
                //    entry.  A late result for a killed/reused slot is dropped.
                if (agu_valid && (agu_qidx == 3'(i)) && occ_r[i] && !committed_r[i]
                    && !kill_hit[i] && (tag_r[i] == agu_tag.slot_index)) begin
                    addr_valid_r[i] <= 1'b1;
                    addr_r[i]       <= agu_addr;
                    data_r[i]       <= agu_store_data;
                    mask_r[i]       <= agu_byte_mask;
                    mmio_r[i]       <= agu_is_mmio;
                end

                // 2) Execution Completion handshake: exec_done freezes the
                //    entry, so each store completes exactly once.
                if (exec_valid && exec_ready && (exec_idx == 3'(i))) begin
                    exec_done_r[i] <= 1'b1;
                end

                // 3) SPEC -> COMMITTED (only commit_fire moves the entry).
                if (commit_hit[i]) begin
                    committed_r[i] <= 1'b1;
                end

                // 4) Allocation starts a fresh SPEC entry in the reused slot.
                if (alloc_fire && (tail_r == 3'(i))) begin
                    occ_r[i]        <= 1'b1;
                    committed_r[i]  <= 1'b0;
                    addr_valid_r[i] <= 1'b0;
                    exec_done_r[i]  <= 1'b0;
                    inflight_r[i]   <= 1'b0;
                    mmio_r[i]       <= 1'b0;
                    tag_r[i]        <= alloc_tag.slot_index;
                end

                // 5) drain_start: the request is in flight, never re-sent.
                if (drain_start && drain_valid && (head_r == 3'(i))) begin
                    inflight_r[i] <= 1'b1;
                end

                // 6) takeover releases the oldest COMMITTED entry; a same-cycle
                //    start+takeover must not leave drain_inflight behind.
                if (takeover_hit[i]) begin
                    occ_r[i]        <= 1'b0;
                    committed_r[i]  <= 1'b0;
                    addr_valid_r[i] <= 1'b0;
                    exec_done_r[i]  <= 1'b0;
                    inflight_r[i]   <= 1'b0;
                    mmio_r[i]       <= 1'b0;
                end

                // 7) SPEC flush of the youngest suffix (COMMITTED untouched).
                if (kill_hit[i]) begin
                    occ_r[i]        <= 1'b0;
                    committed_r[i]  <= 1'b0;
                    addr_valid_r[i] <= 1'b0;
                    exec_done_r[i]  <= 1'b0;
                    inflight_r[i]   <= 1'b0;
                    mmio_r[i]       <= 1'b0;
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Simulation-only invariant / protocol checks (LSU_INTERFACES.md section 4
    // point 10, memory.md 5.1/5.2).  They add no hardware.
    //-------------------------------------------------------------------------
    logic kill_suffix_violation;
    logic occupied_prefix_violation;
    logic committed_prefix_violation;

    always_comb begin
        // A flushed SPEC store must be part of the youngest contiguous suffix:
        // no surviving older SPEC entry may exist.
        kill_suffix_violation = 1'b0;
        for (int unsigned i = 0; i < 8; i++)
            for (int unsigned j = 0; j < 8; j++)
                if (kill_hit[i] && occ_r[j] && !committed_r[j] && !kill_hit[j]
                    && (ring_age(3'(i)) < ring_age(3'(j))))
                    kill_suffix_violation = 1'b1;

        // occupied = [head, head+occupancy), committed = [head, head+cmt_cnt)
        occupied_prefix_violation  = 1'b0;
        committed_prefix_violation = 1'b0;
        for (int unsigned i = 0; i < 8; i++) begin
            if (occ_r[i] != ({1'b0, ring_age(3'(i))} < occupancy_r))
                occupied_prefix_violation = 1'b1;
            if (committed_r[i] != ({1'b0, ring_age(3'(i))} < committed_cnt_r))
                committed_prefix_violation = 1'b1;
        end
    end

    always_comb begin
        a_commit_ptr_invariant: assert (commit_ptr_r ==
            ((head_r + committed_cnt_r[2:0]) & PTR_MASK));
        a_tail_invariant:       assert (tail_r ==
            ((head_r + occupancy_r[2:0]) & PTR_MASK));
        a_occupancy_popcount:   assert (occupancy_r == popcount8(occ_r));
        a_committed_popcount:   assert (committed_cnt_r == popcount8(committed_r));
        a_tail_head_delta:      assert (((tail_r - head_r) & PTR_MASK)
                                        == occupancy_r[2:0]);
        a_occupied_prefix:      assert (!occupied_prefix_violation);
        a_committed_prefix:     assert (!committed_prefix_violation);
        a_kill_suffix:          assert (!kill_suffix_violation);
    end

    // Interface-pulse protocol checks.  These combine an external pulse
    // (alloc_valid / drain_start / drain_takeover / exec_valid) with state that
    // the same edge updates, so they MUST be concurrent properties: an
    // immediate assertion inside always_comb is also evaluated while the design
    // settles right after the edge, where a driver that holds the pulse for the
    // whole cycle (test bench, or any non-flop source) is seen together with
    // the already-updated state.
    a_exec_once: assert property (@(posedge clk) disable iff (rst)
        (!exec_valid || !exec_done_r[exec_idx]));
    a_drain_valid_entry: assert property (@(posedge clk) disable iff (rst)
        (!drain_valid || (occ_r[head_r] && committed_r[head_r] && addr_valid_r[head_r])));
    a_takeover_head: assert property (@(posedge clk) disable iff (rst)
        (!drain_takeover || drain_head_committed));
    a_start_needs_valid: assert property (@(posedge clk) disable iff (rst)
        (!drain_start || drain_valid));
    a_alloc_not_full: assert property (@(posedge clk) disable iff (rst)
        (!alloc_valid || !sq_full));
    // memory.md 5.1: a flush cycle never allocates - the ring cannot
    // represent the hole a simultaneous allocation would leave behind.
    a_alloc_no_flush: assert property (@(posedge clk) disable iff (rst)
        (!alloc_valid || (kill_inc == 4'd0)));

    // commit_fire is the GLOBAL commit event (plan 5.8/5.10): a non-Store lane
    // fires it with store_commit_valid=0 / store_commit_ok=0, so the
    // "authorization" invariant only applies to lanes that present a Store.
    //
    // This one is a *concurrent* property on purpose: it combines an interface
    // pulse with a combinational function of the flops, so it must be sampled
    // in the preponed region (just before the edge).  An immediate assertion
    // inside always_comb would also be evaluated while the design settles
    // right after the edge - at that instant a source that holds commit_fire
    // for the whole cycle (a test bench, or any non-flop driver) is seen
    // together with the *already advanced* commit pointer.
    a_commit_fire_store_ok: assert property (@(posedge clk) disable iff (rst)
        ((commit_fire & store_commit_valid) & ~commit_ok_c) == 2'b00);
`endif

endmodule
