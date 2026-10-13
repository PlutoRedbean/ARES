//=============================================================================
// ARES LSU - Completion aggregation: Load-Hit fast path + 2-entry FIFO (L12)
//-----------------------------------------------------------------------------
// Single LSU Completion port: at most one result per cycle, no backpressure.
// Spec sources: memory.md section 7 (Completion 汇聚与 Load Hit Fast Path),
// section 2 (2-entry Completion FIFO) and section 8.1 (Flush cancels FIFO
// valid entries); frozen interface: rtl/memory/LSU_INTERFACES.md section 5.
//
//   Fast path (memory.md 7.1)
//     A C3 load hit whose owner still holds the result is granted the port
//     combinationally while the FIFO is empty and the tag is not killed, so it
//     does not pay the FIFO storage cycle (3-cycle load-use target).  A result
//     that is not granted stays in its owner (LQ/SQ result_valid); this module
//     never samples it into the FIFO unless the owner pushes it.
//
//   FIFO (memory.md 7.2)
//     Every other result (Store execute, non-fast Load, delayed hit) enters
//     the FIFO through push_valid/push_ready and is drained in order, at most
//     one entry per cycle.  Ownership of a source result moves exactly once:
//     either fast_take (straight to the port) or push_valid && push_ready
//     (into the FIFO).
//
//   Kill (memory.md 7.4 / 8.1, kill wins over a same-cycle Completion)
//     * fast path : fast_take is suppressed for the killed tag
//     * FIFO      : every buffered entry whose tag is hit by kill_mask is
//                   invalidated in place and later drains as a hole (popped
//                   without completion_valid)
//     * a result pushed in the same cycle its tag is killed is stored dead and
//       is never emitted
//
//   Arbitration
//     Because the port never back-pressures, a non-empty FIFO always pops its
//     head (emit when live, discard when killed/invalidated), hence
//     pop_fire = !fifo_empty and push_ready = (fifo_count < FIFO_DEPTH) ||
//     pop_fire never stalls a push.  At DEPTH = 2 the reachable occupancy is
//     count_next = count + push - (count > 0) <= 1, i.e. the second entry is
//     headroom; fifo_count/fifo_empty are still the authoritative state for the
//     upper layers and for the assertions.
//
//   Structure: circular register FIFO (head pointer + occupancy), one 2:1 mux
//   on the head entry, kill compare per entry -> no priority chain and no
//   combinational loop; the fast path is a pure feed-through.
//
// FREE items: FREE-02 (file organisation), FREE-04 (FIFO storage/arbitration
//             structure; memory.md leaves the implementation free).
// Self-check bench: rtl/memory/test/unit/tb_lsu_completion.sv
//
// Build/run (repository root, explicit file list; commands are single lines):
//   lint: verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module lsu_completion rtl/common/ares_pkg.sv rtl/memory/lsu_completion.sv
//   tb:   verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu_completion --Mdir sim/build/unit/tb_lsu_completion -o sim/build/unit/tb_lsu_completion/tb_lsu_completion rtl/common/ares_pkg.sv rtl/memory/lsu_completion.sv rtl/memory/test/unit/tb_lsu_completion.sv
//   sim/build/unit/tb_lsu_completion/tb_lsu_completion
//=============================================================================
module lsu_completion #(
    parameter int unsigned FIFO_DEPTH = 2
) (
    input  logic                            clk,
    input  logic                            rst,

    //---- Fast Path（C3 Hit；源在未获 grant 前保持稳定）--------------------
    input  logic                            fast_valid,
    input  ares_pkg::tag_t                  fast_tag,
    input  logic [31:0]                     fast_result,
    output logic                            fast_take,       // 组合 grant，单周期

    //---- FIFO 入队（Store execute / 非直通 Load）--------------------------
    input  logic                            push_valid,
    input  ares_pkg::tag_t                  push_tag,
    input  logic [31:0]                     push_result,
    output logic                            push_ready,

    //---- 单一 LSU Completion 端口 -----------------------------------------
    output logic                            completion_valid,
    output ares_pkg::fu_completion_t        completion,

    //---- Flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- 状态 -------------------------------------------------------------
    output logic [1:0]                      fifo_count,
    output logic                            fifo_empty
);
    import ares_pkg::*;

    // fifo_count is [1:0] (frozen interface), so the parameter is usable for
    // 1..3 entries; memory.md section 2 freezes the configured value at 2.
    localparam int unsigned PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;

    //-------------------------------------------------------------------------
    // Registered state - circular register FIFO.
    // Logical entry k (k = 0 is the head) sits in physical slot
    // (head_ptr + k) % FIFO_DEPTH.  ent_valid is the live bit: an entry killed
    // by Flush keeps its slot until it reaches the head ("hole") but is never
    // emitted.
    //-------------------------------------------------------------------------
    logic [PTR_W-1:0] head_ptr;
    logic [1:0]       count_q;
    logic             ent_valid  [FIFO_DEPTH];
    tag_t             ent_tag    [FIFO_DEPTH];
    logic [31:0]      ent_result [FIFO_DEPTH];

    //-------------------------------------------------------------------------
    // Combinational view / arbitration.  All of it is a function of registered
    // state (head_ptr, count_q, ent_*) and of the Flush mask only: push_ready
    // must not depend on push_valid (guaranteed-accept, section 0).
    //-------------------------------------------------------------------------
    logic             fifo_full;
    logic             head_kill;
    logic             head_live;
    logic             pop_fire;
    logic             push_fire;
    logic [PTR_W-1:0] push_idx;
    logic [PTR_W-1:0] head_next;
    int unsigned      idx_sum;

    assign fifo_empty = (count_q == 2'd0);
    assign fifo_count = count_q;
    assign fifo_full  = (int'(count_q) >= FIFO_DEPTH);

    // No backpressure on the Completion port -> the head is always consumed
    // when the FIFO is non-empty (memory.md 7.4: no loss through handshake or
    // reserved space).
    assign pop_fire   = !fifo_empty;
    assign push_ready = !fifo_full || pop_fire;
    assign push_fire  = push_valid && push_ready;

    // A killed entry is discarded, never emitted (memory.md 7.4 / 8.1).
    assign head_kill  = !fifo_empty && kill_mask[ent_tag[head_ptr].slot_index];
    assign head_live  = !fifo_empty && ent_valid[head_ptr] && !head_kill;

    // Fast path: only while the FIFO is empty (mutual exclusion with the FIFO
    // dequeue, one single port) and never for a killed tag.
    assign fast_take  = fast_valid && fifo_empty && !kill_mask[fast_tag.slot_index];

    always_comb begin
        // Slot of the next push: one past the tail.  When the FIFO is full and
        // the head is popped in the same cycle, this is exactly the freed head
        // slot (count stays FIFO_DEPTH and the push write happens last).
        idx_sum  = int'(head_ptr) + int'(count_q);
        push_idx = PTR_W'(idx_sum % FIFO_DEPTH);

        head_next = head_ptr + 1'b1;
        if (int'(head_ptr) == int'(FIFO_DEPTH) - 1)
            head_next = '0;
    end

    //-------------------------------------------------------------------------
    // Single Completion port.  fast_take and head_live are mutually exclusive
    // by construction (fast requires fifo_empty), so this is a 2:1 select.
    // Every field of the completion is driven on both paths; a Completion
    // produced by the LSU never carries an exception (memory.md 7, section 5
    // of LSU_INTERFACES.md: exception=0 / cause=EXC_NONE / tval=0).
    //-------------------------------------------------------------------------
    always_comb begin
        completion_valid = 1'b0;
        completion       = '0;

        if (fast_take) begin
            completion_valid     = 1'b1;
            completion.tag       = fast_tag;
            completion.result    = fast_result;
            completion.exception = 1'b0;
            completion.cause     = EXC_NONE;
            completion.tval      = 32'd0;
        end else if (head_live) begin
            completion_valid     = 1'b1;
            completion.tag       = ent_tag[head_ptr];
            completion.result    = ent_result[head_ptr];
            completion.exception = 1'b0;
            completion.cause     = EXC_NONE;
            completion.tval      = 32'd0;
        end
    end

    //-------------------------------------------------------------------------
    // FIFO state update.
    //
    // Program order matters (later non-blocking assignments win):
    //   1. pop frees the head slot (it is re-used by a same-cycle push only
    //      when the FIFO was full, i.e. the push write below must survive)
    //   2. Flush invalidates any buffered entry whose tag is killed, wherever
    //      it sits (memory.md 8.1: kill wins over a same-cycle Completion)
    //   3. push stores the new entry last
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            head_ptr <= '0;
            count_q  <= 2'd0;
            for (int unsigned i = 0; i < FIFO_DEPTH; i++) begin
                ent_valid[i]  <= 1'b0;
                ent_tag[i]    <= '0;
                ent_result[i] <= 32'd0;
            end
        end else begin
            if (pop_fire)
                head_ptr <= head_next;

            if (pop_fire && !push_fire)
                count_q <= count_q - 2'd1;
            else if (push_fire && !pop_fire)
                count_q <= count_q + 2'd1;

            // (1) the consumed head slot becomes free ...
            if (pop_fire)
                ent_valid[head_ptr] <= 1'b0;

            // (2) ... Flush invalidates every buffered entry whose tag it
            //     kills, wherever the entry sits (kill wins over a same-cycle
            //     Completion) ...
            for (int unsigned i = 0; i < FIFO_DEPTH; i++)
                if (ent_valid[i] && kill_mask[ent_tag[i].slot_index])
                    ent_valid[i] <= 1'b0;

            // (3) ... and a push into the freed slot wins.  A push of an
            //     already-killed tag is stored dead: ownership was
            //     transferred, but the result must never be emitted.
            if (push_fire) begin
                ent_valid[push_idx]  <= !kill_mask[push_tag.slot_index];
                ent_tag[push_idx]    <= push_tag;
                ent_result[push_idx] <= push_result;
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol / ordering assertions (memory.md 7 / 8.1, LSU_INTERFACES.md 5)
    //-------------------------------------------------------------------------
    always_comb begin
        // One and only one source owns the port each cycle.
        a_single_source:         assert ($onehot0({fast_take, head_live}));
        // Fast path only when nothing is pending ahead of it.
        a_fast_requires_empty:   assert (!fast_take || fifo_empty);
        a_fast_requires_valid:   assert (!fast_take || fast_valid);
        a_fast_never_killed:     assert (!fast_take || !kill_mask[fast_tag.slot_index]);
        // A killed result must never reach the port.
        a_completion_never_killed:
            assert (!completion_valid || !kill_mask[completion.tag.slot_index]);
        // Occupancy / ready semantics.
        a_empty_matches_count:   assert (fifo_empty == (fifo_count == 2'd0));
        a_count_in_range:        assert (int'(fifo_count) <= FIFO_DEPTH);
        a_push_ready_semantics:
            assert (push_ready == ((int'(fifo_count) < FIFO_DEPTH) || !fifo_empty));
        a_emit_source:           assert (!completion_valid || fast_take || head_live);
    end

    // Live entries always sit inside the occupied window [head, head+count).
    always_comb begin
        for (int unsigned i = 0; i < FIFO_DEPTH; i++)
            if (ent_valid[i])
                a_live_entry_in_window:
                    assert (((int'(i) - int'(head_ptr) + int'(FIFO_DEPTH))
                             % int'(FIFO_DEPTH)) < int'(count_q));
    end
`endif

endmodule
