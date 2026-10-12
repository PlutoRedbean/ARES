//=============================================================================
// ARES backend - Completion Network (B17)
//-----------------------------------------------------------------------------
// Filters the per-FU completion events down to the CIQ entry writes
// (backend.md sections 11, 12, 13; plan section 5.7):
//
//   * a completion is accepted only for entry[tag].valid && state == EXEC and
//     when the entry is not killed in this cycle - kill beats a same-cycle
//     completion (backend.md 11.4/15.5);
//   * every FU has its own port; different FUs may register different entries
//     in the same cycle, there is no shared write-port arbitration;
//   * FU sideband fields (CSR csr_write_data, BRU actual_npc/taken/target) are
//     registered together with the matching completion only;
//   * two accepted completions for the same tag, or a completion for an entry
//     that is not in EXEC, are protocol errors reported on err_* (backend.md
//     13).  Stale-response protection is the FU operation-valid protocol, not
//     an allocation generation.
//
// FREE items: FREE-06 (per-entry write enables), FREE-04 (parallel compares).
//=============================================================================
module be_completion (
    //---- entry state visibility --------------------------------------------
    input  queue_entry_t            entry [CIQ_ENTRIES],
    input  logic [CIQ_ENTRIES-1:0]  kill_mask,

    //---- FU completion ports (indexed by fu_type_t) ------------------------
    input  logic [7:0]              fu_completion_valid,
    input  fu_completion_t          fu_completion [8],
    input  logic [31:0]             csr_write_data [8],
    input  logic [31:0]             actual_npc [8],
    input  logic                    actual_taken [8],
    input  logic [31:0]             actual_target [8],

    //---- filtered writes for the CIQ ---------------------------------------
    output logic [7:0]              cmpl_we,
    output tag_t                    cmpl_tag [8],
    output logic [31:0]             cmpl_result [8],
    output logic                    cmpl_exception [8],
    output exception_cause_t        cmpl_cause [8],
    output logic [31:0]             cmpl_tval [8],
    output logic [31:0]             cmpl_csr_write_data [8],
    output logic [31:0]             cmpl_actual_npc [8],
    output logic                    cmpl_actual_taken [8],
    output logic [31:0]             cmpl_actual_target [8],

    //---- protocol error flags (simulation assertions) ----------------------
    output logic                    err_bad_state,
    output logic                    err_dup_tag
);
    import ares_pkg::*;

    always_comb begin
        for (int unsigned p = 0; p < 8; p++) begin
            cmpl_we[p]              = fu_completion_valid[p]
                                      && entry[fu_completion[p].tag.slot_index].valid
                                      && (entry[fu_completion[p].tag.slot_index].state == ENTRY_EXEC)
                                      && !kill_mask[fu_completion[p].tag.slot_index];
            cmpl_tag[p]             = fu_completion[p].tag;
            cmpl_result[p]          = fu_completion[p].result;
            cmpl_exception[p]       = fu_completion[p].exception;
            cmpl_cause[p]           = fu_completion[p].cause;
            cmpl_tval[p]            = fu_completion[p].tval;
            cmpl_csr_write_data[p]  = csr_write_data[p];
            cmpl_actual_npc[p]      = actual_npc[p];
            cmpl_actual_taken[p]    = actual_taken[p];
            cmpl_actual_target[p]   = actual_target[p];
        end
    end

    always_comb begin
        err_bad_state = 1'b0;
        err_dup_tag   = 1'b0;
        for (int unsigned p = 0; p < 8; p++) begin
            // A completion suppressed by a same-cycle kill is the defined
            // kill-priority race, not a protocol error.
            if (fu_completion_valid[p] && !cmpl_we[p]
                && !kill_mask[fu_completion[p].tag.slot_index])
                err_bad_state = 1'b1;
            for (int unsigned q = 0; q < 8; q++) begin
                if ((q > p) && cmpl_we[p] && cmpl_we[q]
                    && (cmpl_tag[p].slot_index == cmpl_tag[q].slot_index))
                    err_dup_tag = 1'b1;
            end
        end
    end
endmodule
