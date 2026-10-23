// Micro-TAGE (uTAGE) fast S1 direction predictor.
//
// XiangShan MicroTage-inspired: a small number of tagged tables with short
// folded histories and 3-bit counters.  Unlike XiangShan's 1-way position-tagged
// table, each set has one entry per instruction slot (way), matching the full
// TAGE layout, so several conditional branches in the same fetch block do not
// evict each other.  The T0 base table of the full TAGE is the fallback.
//
// Timing structure:
//   S0: hash the block PC with the folded history -> indexed table read.
//   S1: read data is available; compare the tag of each slot's way and pick
//       the longest-history hit.  Only UTAGE_NUM_TABLES (2) tag compares and a
//       2-way priority mux, far shorter than the full 8-table S2 TAGE path.
//
// Training uses the per-slot meta captured at prediction time and happens at
// commit, in the same event that trains the full TAGE.
`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
module utage (
    input logic clk,
    input logic rst,

    // S0: index/tag hash for the block being requested this cycle
    input logic                                                              req_valid,
    input logic [fe_pkg::ADDR_WIDTH-1:0]                                     fetch_pc,
    input logic [fe_pkg::UTAGE_NUM_TABLES-1:0][fe_pkg::UTAGE_INDEX_WIDTH-1:0] fold_idx,
    input logic [fe_pkg::UTAGE_NUM_TABLES-1:0][fe_pkg::UTAGE_TAG_WIDTH-1:0]   fold_tag,

    // S1: uBTB CFI list and T0 base direction for the block requested in S0
    input logic                              [fe_pkg::FETCH_WIDTH-1:0]      cfi_valid,
    input fe_pkg::cfi_type_t                 [fe_pkg::FETCH_WIDTH-1:0]      cfi_type,
    input logic                              [fe_pkg::FETCH_WIDTH-1:0]      base_pred,

    output logic                             [fe_pkg::FETCH_WIDTH-1:0]      pred_taken,
    output fe_pkg::utage_meta_t              [fe_pkg::FETCH_WIDTH-1:0]      meta,

    // commit-time training
    input logic                                                              update_en,
    input logic                                                              is_branch,
    input logic [fe_pkg::ADDR_WIDTH-1:0]                                     update_pc,
    input logic                                                              actual_taken,
    input fe_pkg::utage_meta_t                                               update_meta
);
    import fe_pkg::*;
    import tage_pkg::*;

    localparam int unsigned NUM_SETS = 1 << UTAGE_INDEX_WIDTH;
    localparam int unsigned SLOTS    = UTAGE_SLOT_NUM;

    function automatic logic [UTAGE_CTR_WIDTH-1:0] utage_sat3(
        input logic [UTAGE_CTR_WIDTH-1:0] old, input logic inc);
        logic [UTAGE_CTR_WIDTH-1:0] maxv, minv;
        maxv = {1'b0, {(UTAGE_CTR_WIDTH-1){1'b1}}};
        minv = {1'b1, {(UTAGE_CTR_WIDTH-1){1'b0}}};
        if (inc) utage_sat3 = (old == maxv) ? maxv : old + 1'b1;
        else     utage_sat3 = (old == minv) ? minv : old - 1'b1;
    endfunction

    (* ram_style = "distributed" *)
    utage_entry_t mem[UTAGE_NUM_TABLES][NUM_SETS][SLOTS];

    // ------------------------------------------------------------------
    // S0: hashes and registered table read
    // ------------------------------------------------------------------
    logic [UTAGE_NUM_TABLES-1:0][UTAGE_INDEX_WIDTH-1:0] idx_s0;
    logic [UTAGE_NUM_TABLES-1:0][UTAGE_TAG_WIDTH-1:0]   tag_s0;

    logic [UTAGE_NUM_TABLES-1:0][UTAGE_INDEX_WIDTH-1:0] s1_idx;
    logic [UTAGE_NUM_TABLES-1:0][UTAGE_TAG_WIDTH-1:0]   s1_tag;
    utage_entry_t [UTAGE_NUM_TABLES-1:0][SLOTS-1:0]     s1_entry;

    always_comb begin
        for (int t = 0; t < UTAGE_NUM_TABLES; t++) begin
            idx_s0[t] = utage_index(fetch_pc, fold_idx[t]);
            tag_s0[t] = utage_tag(fetch_pc, fold_tag[t]);
        end
    end

    integer i, sl;
    always_ff @(posedge clk) begin
        if (rst) begin
            s1_idx <= '0;
            s1_tag <= '0;
            // Only the valid bits are reset so the data arrays can infer as RAM.
            for (int t = 0; t < UTAGE_NUM_TABLES; t++)
            for (i = 0; i < NUM_SETS; i++)
            for (sl = 0; sl < SLOTS; sl++)
                mem[t][i][sl].valid <= 1'b0;
        end else if (req_valid) begin
            s1_idx <= idx_s0;
            s1_tag <= tag_s0;
            for (int t = 0; t < UTAGE_NUM_TABLES; t++)
            for (int s = 0; s < SLOTS; s++)
                s1_entry[t][s] <= mem[t][idx_s0[t]][s];
        end
    end

    // ------------------------------------------------------------------
    // S1: per-slot tag match, longest-history provider, base fallback
    // ------------------------------------------------------------------
    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            logic                        is_cond;
            logic [UTAGE_NUM_TABLES-1:0] hit;
            logic                        provider_valid;
            logic [UTAGE_PROVIDER_WIDTH-1:0] provider;
            logic [UTAGE_CTR_WIDTH-1:0]  ctr;

            is_cond        = cfi_valid[s] && (cfi_type[s] == CFI_COND_BRANCH);
            provider_valid = 1'b0;
            provider       = '0;
            ctr            = '0;
            for (int t = 0; t < UTAGE_NUM_TABLES; t++)
                hit[t] = is_cond && s1_entry[t][s].valid
                      && (s1_entry[t][s].tag == s1_tag[t]);
            // longest-history hit wins
            for (int t = UTAGE_NUM_TABLES - 1; t >= 0; t--) begin
                if (hit[t] && !provider_valid) begin
                    provider_valid = 1'b1;
                    provider       = UTAGE_PROVIDER_WIDTH'(t);
                    ctr            = s1_entry[t][s].ctr;
                end
            end

            meta[s]          = '0;
            meta[s].valid    = is_cond;
            meta[s].hit      = provider_valid;
            meta[s].provider = provider;
            meta[s].pos      = UTAGE_POS_WIDTH'(s);
            meta[s].idx      = s1_idx;
            meta[s].tag      = s1_tag;
            meta[s].pred     = provider_valid ? ~ctr[UTAGE_CTR_WIDTH-1] : base_pred[s];

            pred_taken[s] = meta[s].pred;
        end
    end

    // ------------------------------------------------------------------
    // Commit-time training (port-B read at the captured index/slot)
    // ------------------------------------------------------------------
    utage_entry_t [UTAGE_NUM_TABLES-1:0] up_entry;
    logic         [UTAGE_NUM_TABLES-1:0] up_match;
    logic                                up_provider_match;
    logic                                mispred;
    logic                                alloc_en;
    logic [UTAGE_PROVIDER_WIDTH-1:0]     alloc_tbl;
    logic [UTAGE_CTR_WIDTH-1:0]          new_ctr;
    logic [UTAGE_CTR_WIDTH-1:0]          alloc_ctr;

    always_comb begin
        up_provider_match = 1'b0;
        for (int t = 0; t < UTAGE_NUM_TABLES; t++) begin
            up_entry[t] = mem[t][update_meta.idx[t]][update_meta.pos];
            up_match[t] = up_entry[t].valid && (up_entry[t].tag == update_meta.tag[t]);
        end
        if (update_meta.hit)
            up_provider_match = up_match[update_meta.provider];

        new_ctr = utage_sat3(up_entry[update_meta.provider].ctr, actual_taken);

        // Allocate a longer-history table on a misprediction:
        //   * miss / stale provider -> T0
        //   * provider == T0        -> T1
        //   * provider == T1        -> nothing to allocate
        mispred   = update_meta.valid && (update_meta.pred != actual_taken);
        alloc_en  = update_en && is_branch && mispred;
        alloc_tbl = 1'b0;
        if (mispred) begin
            if (!update_meta.hit || !up_provider_match)
                alloc_tbl = 1'b0;
            else if (update_meta.provider < UTAGE_PROVIDER_WIDTH'(UTAGE_NUM_TABLES - 1))
                alloc_tbl = update_meta.provider + 1'b1;
            else
                alloc_en = 1'b0;
        end
        alloc_ctr = actual_taken ? {{(UTAGE_CTR_WIDTH-1){1'b0}}, 1'b1}
                                 : {UTAGE_CTR_WIDTH{1'b1}};
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (update_en && is_branch && update_meta.hit && up_provider_match) begin
                mem[update_meta.provider][update_meta.idx[update_meta.provider]]
                   [update_meta.pos].ctr <= new_ctr;
            end
            if (alloc_en) begin
                mem[alloc_tbl][update_meta.idx[alloc_tbl]][update_meta.pos].valid <= 1'b1;
                mem[alloc_tbl][update_meta.idx[alloc_tbl]][update_meta.pos].tag   <= update_meta.tag[alloc_tbl];
                mem[alloc_tbl][update_meta.idx[alloc_tbl]][update_meta.pos].ctr   <= alloc_ctr;
            end
        end
    end

endmodule
`endif
