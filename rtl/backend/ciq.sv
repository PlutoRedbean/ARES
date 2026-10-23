//=============================================================================
// ARES backend - Centralized Issue Queue (B06)
//-----------------------------------------------------------------------------
// 16-entry circular queue holding every dispatched instruction until commit
// (backend.md sections 3, 4, 12, 13, 14.5, 15).  One entry keeps the decoded
// control information, the bound source dependencies, the execution result and
// the completion state (FREE / WAIT / EXEC / DONE).
//
// Structure and rules implemented here:
//   * three pointers (commit_ptr / issue_ptr / alloc_ptr), 4-bit slot index,
//     5-bit occupancy_count; free_count = 16 - occupancy (backend.md 3.2/5.1);
//   * register array with per-entry write-enable: every FU may register its
//     completion in the same cycle as long as the tags differ (backend.md 13);
//   * commit retires up to two entries and retires matching WAIT source
//     dependencies in the same edge (backend.md 14.5);
//   * kill_mask frees squashed entries (kill beats a same-cycle completion),
//     and a restore request repositions issue_ptr/alloc_ptr while the commit
//     pointer only moves forward (backend.md 15.4);
//   * valid-only slot lifetime, no allocation generation (backend.md 4).
//
// FREE items: FREE-06 (per-entry write-enable array, no shared write port),
//             FREE-04 (parallel tag compare), FREE-09 (state layout).
//=============================================================================
module ciq (
    input  logic                    clk,
    input  logic                    rst,

    //---- allocate (dispatch) ----------------------------------------------
    input  logic [1:0]              alloc_valid,
    input  ares_pkg::queue_entry_t            alloc_entry [2],
    output ares_pkg::tag_t                    alloc_ptr,

    //---- pointers / status -------------------------------------------------
    output ares_pkg::tag_t                    commit_ptr,
    output ares_pkg::tag_t                    issue_ptr,
    output logic [4:0]              free_count,
    output logic [4:0]              occupancy_count,
    output logic                    serializing_present,

    //---- entry array: issue candidates and result reads --------------------
    output ares_pkg::queue_entry_t            entry [ares_pkg::CIQ_ENTRIES],

    //---- completion registration (be_completion, one port per FU) ----------
    input  logic [7:0]              cmpl_we,
    input  ares_pkg::tag_t                    cmpl_tag [8],
    input  logic [31:0]             cmpl_result [8],
    input  logic                    cmpl_exception [8],
    input  ares_pkg::exception_cause_t        cmpl_cause [8],
    input  logic [31:0]             cmpl_tval [8],
    input  logic [31:0]             cmpl_csr_write_data [8],
    input  logic [31:0]             cmpl_actual_npc [8],
    input  logic                    cmpl_actual_taken [8],
    input  logic [31:0]             cmpl_actual_target [8],

    //---- issue (be_issue_sched): WAIT -> EXEC ------------------------------
    input  logic [ares_pkg::ISSUE_WIDTH_MAX-1:0] issue_fire,
    input  ares_pkg::tag_t                       issue_tag [ares_pkg::ISSUE_WIDTH_MAX],

    //---- commit ------------------------------------------------------------
    input  logic [1:0]              commit_fire,
    input  ares_pkg::tag_t                    commit_tag [2],

    //---- flush / kill (be_flush) -------------------------------------------
    input  logic                    restore_valid,
    input  logic                    restore_all,     // full flush: all three pointers collapse
    input  ares_pkg::tag_t                    restore_ptr,
    input  logic [ares_pkg::CIQ_ENTRIES-1:0]  kill_mask
);
    import ares_pkg::*;

    localparam int unsigned NCOMPL = 8;

    queue_entry_t entry_q [CIQ_ENTRIES];
    logic [3:0]   commit_idx, issue_idx, alloc_idx;
    logic [4:0]   occupancy_q;

    //-------------------------------------------------------------------------
    // Status
    //-------------------------------------------------------------------------
    always_comb begin
        commit_ptr.slot_index = commit_idx;
        issue_ptr.slot_index  = issue_idx;
        alloc_ptr.slot_index  = alloc_idx;
    end

    for (genvar g = 0; g < CIQ_ENTRIES; g++) begin : gen_entry_out
        assign entry[g] = entry_q[g];
    end

    assign occupancy_count = occupancy_q;
    assign free_count      = 5'd16 - occupancy_q;

    logic [CIQ_ENTRIES-1:0] valid_q;
    always_comb begin
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) valid_q[i] = entry_q[i].valid;
    end

    // A serializing instruction anywhere in the queue blocks new dispatch
    // (backend.md 5.1 Serializing Dispatch Gate).
    always_comb begin
        serializing_present = 1'b0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++)
            serializing_present |= entry_q[i].valid && entry_q[i].is_serializing;
    end

    //-------------------------------------------------------------------------
    // Completion gather: fold the per-FU completion ports onto the entry index
    // they address.  At most one port matches an entry (protocol error
    // otherwise, checked by be_completion), so OR-folding is exact.
    //-------------------------------------------------------------------------
    logic [CIQ_ENTRIES-1:0] w_hit;
    logic [31:0]            w_result [CIQ_ENTRIES];
    logic                   w_exc    [CIQ_ENTRIES];
    exception_cause_t       w_cause  [CIQ_ENTRIES];
    logic [31:0]            w_tval   [CIQ_ENTRIES];
    logic [31:0]            w_csr    [CIQ_ENTRIES];
    logic [31:0]            w_npc    [CIQ_ENTRIES];
    logic                   w_taken  [CIQ_ENTRIES];
    logic [31:0]            w_tgt    [CIQ_ENTRIES];

    always_comb begin
        w_hit = '0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            w_result[i] = 32'd0;
            w_exc[i]    = 1'b0;
            w_cause[i]  = EXC_NONE;
            w_tval[i]   = 32'd0;
            w_csr[i]    = 32'd0;
            w_npc[i]    = 32'd0;
            w_taken[i]  = 1'b0;
            w_tgt[i]    = 32'd0;
            for (int unsigned p = 0; p < NCOMPL; p++) begin
                // Tags are mutually exclusive per entry (be_completion
                // invariant). Decode once per port/entry and OR the masked
                // payloads instead of synthesizing a wide priority write mux.
                if (cmpl_we[p] && cmpl_tag[p].slot_index == 4'(i)) begin
                    w_hit[i]    = 1'b1;
                    w_result[i] |= cmpl_result[p];
                    w_exc[i]    |= cmpl_exception[p];
                    w_cause[i]  = exception_cause_t'(32'(w_cause[i]) | 32'(cmpl_cause[p]));
                    w_tval[i]   |= cmpl_tval[p];
                    w_csr[i]    |= cmpl_csr_write_data[p];
                    w_npc[i]    |= cmpl_actual_npc[p];
                    w_taken[i]  |= cmpl_actual_taken[p];
                    w_tgt[i]    |= cmpl_actual_target[p];
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Allocate / commit / dependency-retire decode
    //-------------------------------------------------------------------------
    logic [3:0] alloc_idx1;
    assign alloc_idx1 = alloc_idx + 4'd1;

    logic [CIQ_ENTRIES-1:0] alloc_hit;
    logic [1:0]             alloc_lane [CIQ_ENTRIES];
    always_comb begin
        alloc_hit = '0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            alloc_lane[i] = 2'd0;
            if (alloc_valid[0] && (alloc_idx == i[3:0])) begin
                alloc_hit[i]  = 1'b1;
                alloc_lane[i] = 2'd0;
            end else if (alloc_valid[1] && (alloc_idx1 == i[3:0])) begin
                alloc_hit[i]  = 1'b1;
                alloc_lane[i] = 2'd1;
            end
        end
    end

    logic [CIQ_ENTRIES-1:0] issue_hit;
    always_comb begin
        issue_hit = '0;
        for (int unsigned p = 0; p < ISSUE_WIDTH_MAX; p++)
            if (issue_fire[p]) issue_hit[issue_tag[p].slot_index] = 1'b1;
    end

    logic [CIQ_ENTRIES-1:0] commit_hit0, commit_hit1;
    always_comb begin
        commit_hit0 = '0;
        commit_hit1 = '0;
        if (commit_fire[0]) commit_hit0[commit_tag[0].slot_index] = 1'b1;
        if (commit_fire[1]) commit_hit1[commit_tag[1].slot_index] = 1'b1;
    end

    // backend.md 14.5: a WAIT consumer whose bound producer commits in this
    // cycle releases its dependency; the more senior normal commit still
    // applies on a flush cycle (surviving entries).
    logic [CIQ_ENTRIES-1:0] dep1_retire, dep2_retire;
    always_comb begin
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            dep1_retire[i] = entry_q[i].valid && (entry_q[i].state == ENTRY_WAIT)
                          && entry_q[i].src1_dep_valid
                          && ((commit_fire[0] && (entry_q[i].src1_dep_tag.slot_index == commit_tag[0].slot_index))
                           || (commit_fire[1] && (entry_q[i].src1_dep_tag.slot_index == commit_tag[1].slot_index)));
            dep2_retire[i] = entry_q[i].valid && (entry_q[i].state == ENTRY_WAIT)
                          && entry_q[i].src2_dep_valid
                          && ((commit_fire[0] && (entry_q[i].src2_dep_tag.slot_index == commit_tag[0].slot_index))
                           || (commit_fire[1] && (entry_q[i].src2_dep_tag.slot_index == commit_tag[1].slot_index)));
        end
    end

    //-------------------------------------------------------------------------
    // Pointer / occupancy next state
    //-------------------------------------------------------------------------
    logic [1:0] commit_count, alloc_count;
    logic [2:0] issue_count;
    logic [4:0] squash_count;
    assign commit_count = {1'b0, commit_fire[0]} + {1'b0, commit_fire[1]};
    assign alloc_count  = {1'b0, alloc_valid[0]} + {1'b0, alloc_valid[1]};

    // Issue grants are a contiguous prefix, so the number of granted entries is
    // exactly the number of set bits (backend.md 8.2): issue_ptr advances past
    // them and keeps pointing at the oldest not-yet-issued entry.
    always_comb begin
        issue_count = 3'd0;
        for (int unsigned p = 0; p < ISSUE_WIDTH_MAX; p++)
            issue_count = issue_count + {2'd0, issue_fire[p]};
    end

    always_comb begin
        squash_count = 5'd0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) squash_count = squash_count + {4'd0, kill_mask[i]};
    end

    logic [3:0] commit_next, issue_next, alloc_next;
    logic [4:0] occupancy_next;
    always_comb begin
        if (restore_valid) begin
            // Branch recovery keeps commit_ptr moving forward only by the normal
            // commit count (backend.md 15.4).  A full flush empties the queue, so
            // all three pointers collapse onto the post-flush position.
            commit_next    = restore_all ? restore_ptr.slot_index
                                         : commit_idx + {2'b00, commit_count};
            issue_next     = restore_ptr.slot_index;
            alloc_next     = restore_ptr.slot_index;
            occupancy_next = occupancy_q - {3'b000, commit_count} - squash_count;
        end else begin
            commit_next    = commit_idx + {2'b00, commit_count};
            issue_next     = issue_idx + {1'b0, issue_count};
            alloc_next     = alloc_idx + {2'b00, alloc_count};
            occupancy_next = occupancy_q + {3'b000, alloc_count} - {3'b000, commit_count};
        end
    end

    //-------------------------------------------------------------------------
    // Entry array
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
                entry_q[i]       <= '0;
                entry_q[i].state <= ENTRY_FREE;
            end
            commit_idx  <= 4'd0;
            issue_idx   <= 4'd0;
            alloc_idx   <= 4'd0;
            occupancy_q <= 5'd0;
        end else begin
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
                if (kill_mask[i]) begin
                    // Flush wins over a same-cycle completion (backend.md 15.5).
                    entry_q[i]       <= '0;
                    entry_q[i].state <= ENTRY_FREE;
                end else begin
                // Dependency retirement applies to every WAIT entry present at
                // the start of the cycle (backend.md 14.5) - including one that
                // is issued or completed in this same cycle.  Later assignments
                // in this branch deliberately override these two bits.
                if (dep1_retire[i]) entry_q[i].src1_dep_valid <= 1'b0;
                if (dep2_retire[i]) entry_q[i].src2_dep_valid <= 1'b0;

                if (commit_hit0[i] || commit_hit1[i]) begin
                    entry_q[i]       <= '0;
                    entry_q[i].state <= ENTRY_FREE;
                end else if (w_hit[i]) begin
                    // Completion registration (state/valid checked in B17).
                    entry_q[i].state            <= ENTRY_DONE;
                    entry_q[i].result           <= w_result[i];
                    entry_q[i].exception        <= w_exc[i];
                    entry_q[i].exception_cause  <= w_cause[i];
                    entry_q[i].exception_tval   <= w_tval[i];
                    entry_q[i].csr_write_data   <= w_csr[i];
                    entry_q[i].actual_npc       <= w_npc[i];
                    entry_q[i].actual_taken     <= w_taken[i];
                    entry_q[i].actual_target    <= w_tgt[i];
                end else if (issue_hit[i]) begin
                    // Issue grant: guaranteed-accept, the FU latches the request
                    // on this edge (backend.md 8.6/10).
                    entry_q[i].state <= ENTRY_EXEC;
                end else if (alloc_hit[i]) begin
                    entry_q[i] <= (alloc_lane[i] == 2'd0) ? alloc_entry[0] : alloc_entry[1];
                end
                end
            end
            commit_idx  <= commit_next;
            issue_idx   <= issue_next;
            alloc_idx   <= alloc_next;
            occupancy_q <= occupancy_next;
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol invariants (backend.md 3/13/14/15)
    //-------------------------------------------------------------------------
    logic [4:0] valid_count;
    always_comb begin
        valid_count = 5'd0;
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) valid_count = valid_count + {4'd0, valid_q[i]};
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            a_occupancy : assert (occupancy_q == valid_count);
            a_free      : assert (free_count == (5'd16 - valid_count));
            a_valid     : assert ((entry_q[commit_idx].valid == 1'b1) || (valid_count == 5'd0));
            a_bounded   : assert (valid_count <= 5'd16);
        end
    end
`endif
endmodule
