//=============================================================================
// ARES backend - Flush / kill generation and Producer Map restore (B22)
//-----------------------------------------------------------------------------
// backend.md sections 15.1-15.5, 17.3; plan section 5.9.
//
//   * branch recovery: age-selective kill - kill[i] = valid[i] &&
//     age(i) > age(recovery_branch_tag); the mispredicting branch itself and
//     all older entries survive.  issue_ptr/alloc_ptr return to
//     branch_slot+1 while commit_ptr only moves forward by this cycle's
//     commit count;
//   * full flush (ECALL trap / MRET / IRQ boundary): every valid entry that is
//     not committing in this cycle is killed and the pointers collapse to the
//     target supplied by be_trap_ctrl; the Producer Map and every checkpoint
//     are cleared (no checkpoint validation, backend.md 17.3);
//   * the Producer Map restore is the frozen checkpoint row validated against
//     the surviving entries (backend.md 15.3): cp.valid && entry[id].valid &&
//     !kill[id] && !commit_free[id] && entry[id].rd_wen && entry[id].rd == r,
//     otherwise the register is restored as invalid;
//   * a checkpoint is released when its slot is freed (commit or kill) or when
//     the recovering branch resumes.
//
// FREE items: FREE-04 (parallel 32-entry validation), FREE-09 (restore form).
//=============================================================================
module be_flush (
    //---- entry array --------------------------------------------------------
    input  queue_entry_t            entry [CIQ_ENTRIES],
    input  tag_t                    commit_ptr,

    //---- normal commit of this cycle (frees slots, advances commit_ptr) ----
    input  logic [1:0]              commit_fire,
    input  tag_t                    commit_tag [2],

    //---- branch recovery ----------------------------------------------------
    input  logic                    recovery_valid,
    input  tag_t                    recovery_branch_tag,

    //---- full-queue flush (trap / mret / IRQ boundary) ---------------------
    input  logic                    full_flush_valid,
    input  logic                    full_flush_keep_head,  // MRET commits lane 0 first
    input  tag_t                    full_flush_ptr,

    //---- frozen checkpoint row read (be_checkpoint) ------------------------
    input  logic [31:0]             cp_rvalid,
    input  tag_t                    cp_rtag [32],

    //---- outputs ------------------------------------------------------------
    output logic [CIQ_ENTRIES-1:0]  kill_mask,
    output logic                    restore_valid,
    output tag_t                    restore_ptr,
    output logic [31:0]             restore_map_valid,
    output tag_t                    restore_map_tag [32],
    output logic [CIQ_ENTRIES-1:0]  cp_release
);
    import ares_pkg::*;

    logic [CIQ_ENTRIES-1:0] commit_hit, commit_free;
    always_comb begin
        commit_hit  = '0;
        commit_free = '0;
        if (commit_fire[0]) begin commit_hit[commit_tag[0].slot_index] = 1'b1; commit_free[commit_tag[0].slot_index] = 1'b1; end
        if (commit_fire[1]) begin commit_hit[commit_tag[1].slot_index] = 1'b1; commit_free[commit_tag[1].slot_index] = 1'b1; end
    end

    logic [3:0] age_branch;
    assign age_branch = recovery_branch_tag.slot_index - commit_ptr.slot_index;

    always_comb begin
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            logic [3:0] age_i;
            age_i = 4'(i) - commit_ptr.slot_index;
            if (full_flush_valid)
                // ECALL (and every full flush) kills the whole queue; MRET is
                // committing in this cycle, so it is the one surviving entry.
                // (Using commit_fire here would close a combinational loop back
                // through be_commit's kill check.)
                kill_mask[i] = entry[i].valid
                            && !(full_flush_keep_head && (4'(i) == commit_ptr.slot_index));
            else if (recovery_valid)
                kill_mask[i] = entry[i].valid && (age_i > age_branch);
            else
                kill_mask[i] = 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Pointer restore (branch: branch_slot+1, full flush: trap target)
    //-------------------------------------------------------------------------
    always_comb begin
        restore_valid = recovery_valid || full_flush_valid;
        if (recovery_valid)
            restore_ptr.slot_index = recovery_branch_tag.slot_index + 4'd1;
        else
            restore_ptr.slot_index = full_flush_ptr.slot_index;
    end

    //-------------------------------------------------------------------------
    // Producer Map restore: validated frozen checkpoint (branch only)
    //-------------------------------------------------------------------------
    always_comb begin
        for (int unsigned r = 0; r < 32; r++) begin
            logic [3:0] id;
            id = cp_rtag[r].slot_index;
            restore_map_valid[r] = !full_flush_valid
                                 && cp_rvalid[r]
                                 && entry[id].valid
                                 && !kill_mask[id]
                                 && !commit_free[id]
                                 && entry[id].rd_wen
                                 && (entry[id].rd == 5'(r));
            restore_map_tag[r]   = cp_rtag[r];
        end
        restore_map_valid[0] = 1'b0;   // x0 is never a producer
    end

    //-------------------------------------------------------------------------
    // Checkpoint release: slot freed or branch resumed
    //-------------------------------------------------------------------------
    always_comb begin
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
            cp_release[i] = kill_mask[i] || commit_hit[i]
                         || (recovery_valid && (recovery_branch_tag.slot_index == 4'(i)));
        end
    end
endmodule
