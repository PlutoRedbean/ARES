//=============================================================================
// ARES backend - In-order Commit (B18)
//-----------------------------------------------------------------------------
// 2-wide, strictly in-order commit of the contiguous DONE prefix at commit_ptr
// (backend.md section 14; plan section 5.8):
//
//   * commit_fire[i] means "successfully retired normally": DONE && !exception
//     && !kill && (for a Store) store_commit_ok[i] && BPU credit available;
//     commit1_fire requires commit0_fire;
//   * a serializing instruction (CSR/MRET) commits exclusively in lane 0 - a
//     serializing candidate in lane 1 only lets the older lane 0 retire;
//   * ECALL never commits here: it retires through the trap path (be_trap_ctrl)
//     with its exception recorded by the CSR unit;
//   * architectural writes (GPR data, CSR write, store authorization) are only
//     produced together with commit_fire; the CIQ entry is released on the same
//     edge and the LSU does not have to accept the write in that cycle;
//   * the BPU event count of the candidate prefix is limited by the registered
//     FE credit through bpu_block (contract 4);
//   * commit_pc_next is the true successor of the retiring instruction (pc+4,
//     BRU actual_npc, or mepc for MRET) used by architectural_next_pc.
//
// FREE items: FREE-04 (parallel prefix formation), FREE-02 (retire hooks here).
//=============================================================================
module be_commit (
    input  logic                    clk,
    input  logic                    rst,

    //---- CIQ state ----------------------------------------------------------
    input  queue_entry_t            entry [CIQ_ENTRIES],
    input  tag_t                    commit_ptr,
    input  logic [CIQ_ENTRIES-1:0]  kill_mask,

    //---- external commit conditions ----------------------------------------
    input  logic [1:0]              store_commit_ok,
    input  logic [1:0]              bpu_block,

    //---- CSR values needed for the successor PC ----------------------------
    input  logic [31:0]             mepc,

    //---- commit lanes -------------------------------------------------------
    output logic [1:0]              commit_fire,
    output tag_t                    commit_tag [2],
    output logic [1:0]              commit_rd_wen,
    output logic [4:0]              commit_rd [2],
    output logic [31:0]             commit_wdata [2],
    output logic [31:0]             commit_pc_next [2],
    output logic [1:0]              commit_is_cfi,
    output logic [1:0]              commit_is_mret,

    //---- CFI training attributes (to be_bpu_update) ------------------------
    output logic [31:0]             commit_pc [2],
    output logic                    commit_actual_taken [2],
    output logic [31:0]             commit_actual_target [2],
    output cfi_type_t               commit_actual_cfi_type [2],
    output pred_meta_t              commit_pred_meta [2],

    //---- architectural writes ----------------------------------------------
    output logic                    csr_commit_we,
    output logic [11:0]             csr_commit_addr,
    output logic [31:0]             csr_commit_wdata,

    //---- Store lane handshake with the LSU (backend.md 14.6) ---------------
    output logic [1:0]              store_commit_valid,
    output tag_t                    store_commit_tag [2],

    //---- retire observation (simulation hooks, backend.md 16.1) -----------
    output logic [1:0]              retire_valid,
    output logic [31:0]             retire_pc [2],
    output logic [31:0]             retire_pc_next [2],
    output logic [1:0]              retire_rd_wen,
    output logic [4:0]              retire_rd [2],
    output logic [31:0]             retire_wdata [2],
    output logic [1:0]              retire_is_ebreak
);
    import ares_pkg::*;

    queue_entry_t cand [2];
    logic [3:0]   idx1;

    assign idx1 = commit_ptr.slot_index + 4'd1;

    always_comb begin
        cand[0] = entry[commit_ptr.slot_index];
        cand[1] = entry[idx1];
    end

    // A DONE entry carrying an exception is never a normal commit candidate;
    // ECALL is the only exception in v1 and is handled by be_trap_ctrl.
    logic c0_ok, c1_ok;
    always_comb begin
        c0_ok = cand[0].valid && (cand[0].state == ENTRY_DONE) && !cand[0].exception
                && !kill_mask[commit_ptr.slot_index];
        c1_ok = cand[1].valid && (cand[1].state == ENTRY_DONE) && !cand[1].exception
                && !kill_mask[idx1];
    end

    assign store_commit_valid[0] = c0_ok && cand[0].is_store;
    assign store_commit_valid[1] = c1_ok && cand[1].is_store && c0_ok;
    assign store_commit_tag[0]   = commit_ptr;
    assign store_commit_tag[1]   = tag_t'{slot_index: idx1};

    always_comb begin
        commit_fire[0] = c0_ok && bpu_block[0] == 1'b0
                         && (!cand[0].is_store || store_commit_ok[0]);
        commit_fire[1] = commit_fire[0] && c1_ok && bpu_block[1] == 1'b0
                         && !cand[0].is_serializing
                         && !cand[1].is_serializing
                         && (!cand[1].is_store || store_commit_ok[1]);
    end

    always_comb begin
        commit_tag[0]    = commit_ptr;
        commit_tag[1]    = tag_t'{slot_index: idx1};
        for (int unsigned l = 0; l < 2; l++) begin
            // Architectural writes happen only on a successful retire: the write
            // enables must be gated by commit_fire, otherwise an entry waiting at
            // the commit head clobbers its destination with a stale/default result.
            commit_rd_wen[l]        = commit_fire[l] && cand[l].rd_wen && (cand[l].rd != 5'd0);
            commit_rd[l]            = cand[l].rd;
            commit_wdata[l]         = cand[l].result;
            commit_is_cfi[l]        = cand[l].is_branch;
            commit_is_mret[l]       = (cand[l].op == OP_MRET);
            commit_pc[l]            = cand[l].pc;
            commit_actual_taken[l]  = cand[l].actual_taken;
            commit_actual_target[l] = cand[l].actual_target;
            commit_actual_cfi_type[l] = cand[l].actual_cfi_type;
            commit_pred_meta[l]     = cand[l].pred_meta;

            // True architectural successor (backend.md 17.2)
            commit_pc_next[l] = cand[l].is_branch ? cand[l].actual_npc
                              : (cand[l].op == OP_MRET) ? mepc
                              : (cand[l].pc + 32'd4);
        end
    end

    // CSR architectural write: serializing, so lane 0 only (backend.md 16.3).
    assign csr_commit_we    = commit_fire[0] && cand[0].is_csr && cand[0].csr_write_en;
    assign csr_commit_addr  = cand[0].csr_addr;
    assign csr_commit_wdata = cand[0].csr_write_data;

    // Retire observation (EBREAK is a normal retire; the simulation shadow is
    // built in the TB, never in the exception protocol - backend.md 16.1).
    always_comb begin
        for (int unsigned l = 0; l < 2; l++) begin
            retire_valid[l]     = commit_fire[l];
            retire_pc[l]        = cand[l].pc;
            retire_pc_next[l]   = commit_pc_next[l];
            retire_rd_wen[l]    = commit_rd_wen[l];
            retire_rd[l]        = cand[l].rd;
            retire_wdata[l]     = cand[l].result;
            retire_is_ebreak[l] = commit_fire[l] && (cand[l].op == OP_EBREAK);
        end
    end

`ifdef CONFIG_SIMULATION
    always_ff @(posedge clk) begin
        if (!rst) begin
            a_lane_order : assert (!commit_fire[1] || commit_fire[0]);
            a_no_exc     : assert (!(cand[0].valid && (cand[0].state == ENTRY_DONE)
                                     && cand[0].exception
                                     && (cand[0].exception_cause != EXC_ECALL_M))
                                   || !commit_fire[0]);
        end
    end
`endif
endmodule
