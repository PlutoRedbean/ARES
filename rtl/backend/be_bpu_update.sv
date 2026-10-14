//=============================================================================
// ARES backend - BPU update events and credit gate (B19)
//-----------------------------------------------------------------------------
// frontend_backend_contract.md section 4; backend.md 14.5.
//
//   * one event per normally retired CFI, aligned with the commit lanes,
//     lane 0 older than lane 1; empty lanes carry valid = 0;
//   * the CFI event count of the candidate commit prefix is compared against
//     the registered bpu_update_credit before the prefix is formed: when the
//     credit is insufficient the CFI and every younger commit are blocked
//     (older non-CFI commits are still allowed).  The credit input is a
//     registered FE value, so no BE->FE->BE combinational loop exists;
//   * events are only generated for commit_fire lanes, never at BRU
//     resolution, so a squashed CFI is never trained.
//
// FREE items: FREE-04 (parallel credit arithmetic).
//=============================================================================
module be_bpu_update (
    //---- FE registered credit ----------------------------------------------
    input  logic [1:0]              bpu_update_credit,

    //---- commit candidates and the final commit decision -------------------
    input  logic [1:0]              commit_fire,
    input  logic [1:0]              cand_is_cfi,
    input  logic [31:0]             cand_pc [2],
    input  logic                    cand_actual_taken [2],
    input  logic [31:0]             cand_actual_target [2],
    input  ares_pkg::cfi_type_t               cand_actual_cfi_type [2],
    input  ares_pkg::pred_meta_t              cand_pred_meta [2],

    //---- credit blocking for the commit prefix -----------------------------
    output logic [1:0]              bpu_block,

    //---- training events ----------------------------------------------------
    output logic [1:0]              bpu_update_valid,
    output ares_pkg::bpu_update_t             bpu_update [2]
);
    import ares_pkg::*;

    logic [1:0] cfi_lane0, cfi_prefix;
    always_comb begin
        // Event count required by the candidate prefix (lane 0 then lane 1).
        cfi_lane0  = {1'b0, cand_is_cfi[0]};
        cfi_prefix = {1'b0, cand_is_cfi[0]} + {1'b0, cand_is_cfi[1]};

        // Block a CFI (and every younger commit) when its event would exceed
        // the registered credit.
        bpu_block[0] = cand_is_cfi[0] && (cfi_lane0  > bpu_update_credit);
        bpu_block[1] = cand_is_cfi[1] && (cfi_prefix > bpu_update_credit);
    end

    always_comb begin
        for (int unsigned l = 0; l < 2; l++) begin
            bpu_update_valid[l]      = commit_fire[l] && cand_is_cfi[l];
            bpu_update[l]            = '0;
            bpu_update[l].update_pc        = cand_pc[l];
            bpu_update[l].actual_taken     = cand_actual_taken[l];
            bpu_update[l].actual_target    = cand_actual_target[l];
            bpu_update[l].actual_cfi_type  = cand_actual_cfi_type[l];
            bpu_update[l].pred_meta        = cand_pred_meta[l];
        end
    end

`ifdef CONFIG_SIMULATION
    always_comb begin
        a_event_needs_fire : assert (!(|bpu_update_valid) || (|commit_fire));
        a_credit_respected : assert (({1'b0, bpu_update_valid[0]} + {1'b0, bpu_update_valid[1]})
                                     <= {1'b0, bpu_update_credit});
    end
`endif
endmodule
