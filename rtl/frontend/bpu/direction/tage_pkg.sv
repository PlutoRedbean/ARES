// TAGE shared package (docs/tage-design.md §6, §7).
//
// Compiled on its own (not `include`d); `tage.sv` and the storage modules
// import it.  It provides the entry types, the history (ghv + folded history)
// helpers and the pure counter / selection / training functions, so no module
// holds conditionally-assigned combinational state and no latches are inferred.
`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
package tage_pkg;
    /* verilator lint_off UNUSEDSIGNAL */ // pure hash/update helpers intentionally read only relevant fields
    import fe_pkg::*;

    // ------------------------------------------------------------------
    // Entry types
    // ------------------------------------------------------------------

    typedef struct packed {
        logic                         valid;
        logic [TAGE_TAG_WIDTH-1:0]    tag;
        logic [TAGE_CTR_WIDTH-1:0]    ctr;
        logic [TAGE_USEFUL_WIDTH-1:0] useful;
    } tage_tagged_entry_t;

    // Speculative/committed history: a linear global history vector (bit 0 is
    // the newest conditional branch) plus, per tagged table, the three
    // pre-computed folded histories (index, tag1, tag2).
    typedef struct packed {
        logic [TAGE_GHV_WIDTH-1:0]                        ghr;
        logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] fold_idx;
        logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0]   fold_tag1;
        logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-2:0] fold_tag2;
`ifdef CONFIG_FE_UTAGE
        // uTAGE (S1 fast predictor) folded histories.
        logic [UTAGE_NUM_TABLES-1:0][UTAGE_INDEX_WIDTH-1:0] fold_idx_u;
        logic [UTAGE_NUM_TABLES-1:0][UTAGE_TAG_WIDTH-1:0]   fold_tag_u;
`endif
    } tage_hist_t;

    // Result of the s2 provider/alt selection for one slot.
    typedef struct packed {
        logic                                              hit_any;
        logic [TAGE_NUM_TABLES-1:0]                        hit;
        logic                                              provided;
        logic [TAGE_PROVIDER_WIDTH-1:0]                    provider;
        logic                                              alt_hit;
        logic [TAGE_PROVIDER_WIDTH-1:0]                    alt;
        logic [TAGE_CTR_WIDTH-1:0]                         provider_ctr;
        logic                                              provider_pred;
        logic                                              alt_pred;
        logic                                              prov_unconf;
        logic [TAGE_NUM_TABLES-1:0][TAGE_USEFUL_WIDTH-1:0] useful;
        logic                                              pred;
    } tage_slot_pred_t;

    // ------------------------------------------------------------------
    // Pure functions
    // ------------------------------------------------------------------

    // 2-bit saturating counter in [0,3] (T0).
    function automatic logic [1:0] tage_sat2(input logic [1:0] old, input logic inc);
        if (inc) tage_sat2 = (old == 2'b11) ? 2'b11 : old + 2'b01;
        else tage_sat2 = (old == 2'b00) ? 2'b00 : old - 2'b01;
    endfunction

    // 2-bit saturating useful counter in [0,3].
    function automatic logic [TAGE_USEFUL_WIDTH-1:0] tage_sat_useful(
        input logic [TAGE_USEFUL_WIDTH-1:0] old, input logic inc);
        logic [TAGE_USEFUL_WIDTH-1:0] mx;
        mx = {TAGE_USEFUL_WIDTH{1'b1}};
        if (inc) tage_sat_useful = (old == mx) ? mx : old + 1'b1;
        else tage_sat_useful = (old == '0) ? '0 : old - 1'b1;
    endfunction

    // 3-bit signed saturating counter in [-4,+3].
    function automatic logic [TAGE_CTR_WIDTH-1:0] tage_sat3(input logic [TAGE_CTR_WIDTH-1:0] old,
                                                            input logic inc);
        logic [TAGE_CTR_WIDTH-1:0] maxv, minv;
        maxv = {1'b0, {(TAGE_CTR_WIDTH - 1) {1'b1}}};  // +3
        minv = {1'b1, {(TAGE_CTR_WIDTH - 1) {1'b0}}};  // -4
        if (inc) tage_sat3 = (old == maxv) ? maxv : old + 1'b1;
        else tage_sat3 = (old == minv) ? minv : old - 1'b1;
    endfunction

    // XOR conversion between the raw stored useful and its effective value
    // (docs/tage-design.md §10.3 useful-epoch scheme).  XOR is its own inverse.
    function automatic logic [TAGE_USEFUL_WIDTH-1:0] tage_useful_eff(
        input logic [TAGE_USEFUL_WIDTH-1:0] raw, input logic epoch);
        tage_useful_eff = raw;  // no periodic useful reset (match reference TAGE)
    endfunction

    // ------------------------------------------------------------------
    // History (ghv + folded history)
    // ------------------------------------------------------------------

    // Push one conditional-branch direction bit (newest at ghr[0]).
    function automatic tage_hist_t tage_hist_push(input tage_hist_t h, input logic b);
        tage_hist_t n;
        n = h;
        n.ghr = {h.ghr[TAGE_GHV_WIDTH-2:0], b};
        for (int unsigned t = 0; t < TAGE_NUM_TABLES; t++) begin
            logic evict;
            evict = h.ghr[TAGE_HIST_LENGTH[t]-1];
            n.fold_idx[t] = {h.fold_idx[t][TAGE_INDEX_WIDTH-2:0], h.fold_idx[t][TAGE_INDEX_WIDTH-1]}
                          ^ {{(TAGE_INDEX_WIDTH-1){1'b0}}, b}
                          ^ (evict ? ({{(TAGE_INDEX_WIDTH-1){1'b0}}, 1'b1}
                                     << (TAGE_HIST_LENGTH[t] % TAGE_INDEX_WIDTH)) : '0);
            n.fold_tag1[t] = {h.fold_tag1[t][TAGE_TAG_WIDTH-2:0], h.fold_tag1[t][TAGE_TAG_WIDTH-1]}
                           ^ {{(TAGE_TAG_WIDTH-1){1'b0}}, b}
                           ^ (evict ? ({{(TAGE_TAG_WIDTH-1){1'b0}}, 1'b1}
                                      << (TAGE_HIST_LENGTH[t] % TAGE_TAG_WIDTH)) : '0);
            n.fold_tag2[t] = {h.fold_tag2[t][TAGE_TAG_WIDTH-3:0],
                              h.fold_tag2[t][TAGE_TAG_WIDTH-2]}
                           ^ {{(TAGE_TAG_WIDTH-2){1'b0}}, b}
                           ^ (evict ? ({{(TAGE_TAG_WIDTH-2){1'b0}}, 1'b1}
                                      << (TAGE_HIST_LENGTH[t] % (TAGE_TAG_WIDTH-1))) : '0);
        end
`ifdef CONFIG_FE_UTAGE
        for (int unsigned t = 0; t < UTAGE_NUM_TABLES; t++) begin
            logic evict_u;
            evict_u = h.ghr[UTAGE_HIST_LENGTH[t]-1];
            n.fold_idx_u[t] = {h.fold_idx_u[t][UTAGE_INDEX_WIDTH-2:0],
                               h.fold_idx_u[t][UTAGE_INDEX_WIDTH-1]}
                            ^ {{(UTAGE_INDEX_WIDTH-1){1'b0}}, b}
                            ^ (evict_u ? ({{(UTAGE_INDEX_WIDTH-1){1'b0}}, 1'b1}
                                        << (UTAGE_HIST_LENGTH[t] % UTAGE_INDEX_WIDTH)) : '0);
            n.fold_tag_u[t] = {h.fold_tag_u[t][UTAGE_TAG_WIDTH-2:0],
                               h.fold_tag_u[t][UTAGE_TAG_WIDTH-1]}
                            ^ {{(UTAGE_TAG_WIDTH-1){1'b0}}, b}
                            ^ (evict_u ? ({{(UTAGE_TAG_WIDTH-1){1'b0}}, 1'b1}
                                        << (UTAGE_HIST_LENGTH[t] % UTAGE_TAG_WIDTH)) : '0);
        end
`endif
        return n;
    endfunction

    // Push every on-path conditional branch of a block, in slot order (slot 0
    // first).  `mask` = branch && on_path, `dir` = final predicted direction.
    function automatic tage_hist_t tage_hist_push_block(
        input tage_hist_t h, input logic [FETCH_WIDTH-1:0] mask, input logic [FETCH_WIDTH-1:0] dir);
        tage_hist_t n;
        n = h;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            if (mask[s]) n = tage_hist_push(n, dir[s]);
        end
        return n;
    endfunction

    // Block push with the fold recurrence unrolled into independent XOR terms.
    //
    // A single push is a fixed rotate plus a one-hot direction bit and a one-hot
    // eviction bit:
    //     f' = R(f) ^ B(dir) ^ E(evict, L % W)
    // so after P pushes the result is
    //     f_P = R^P(f_0) ^ XOR_s R^(P-1-i_s) (B(dir_s) ^ E(evict_s, L % W))
    // where i_s is the push ordinal of slot s.  The eviction bit is a wire tap
    // into the original ghr (the history shift is pure wiring); when L is
    // shorter than the number of pushes it is one of the just-inserted
    // directions.  Each slot's contribution is therefore an independent
    // rotate/XOR, and the per-table result is one XOR tree instead of a chain
    // of conditional full-width pushes.
    function automatic tage_hist_t tage_hist_push_block_fast(
        input tage_hist_t h, input logic [FETCH_WIDTH-1:0] mask, input logic [FETCH_WIDTH-1:0] dir);
        tage_hist_t n;
        logic [FETCH_WIDTH-1:0] pushed_dir;
        logic [TAGE_GHV_WIDTH-1:0] ghr_new;
        int unsigned total;

        n = h;
        pushed_dir = '0;
        ghr_new    = h.ghr;
        total      = 0;
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            if (mask[s]) begin
                pushed_dir[total] = dir[s];
                ghr_new = {ghr_new[TAGE_GHV_WIDTH-2:0], dir[s]};
                total = total + 1;
            end
        end
        n.ghr = ghr_new;

        for (int unsigned t = 0; t < TAGE_NUM_TABLES; t++) begin
            logic [TAGE_INDEX_WIDTH-1:0] base, acc, contrib;
            int unsigned cnt;
            base = h.fold_idx[t];
            acc  = '0;
            cnt  = 0;
            for (int s = 0; s < FETCH_WIDTH; s++) begin
                if (mask[s]) begin
                    logic ev;
                    int unsigned after;
                    if (TAGE_HIST_LENGTH[t] > cnt)
                        ev = h.ghr[TAGE_HIST_LENGTH[t]-1-cnt];
                    else
                        ev = pushed_dir[cnt-TAGE_HIST_LENGTH[t]];
                    contrib = '0;
                    if (dir[s]) contrib[0] = contrib[0] ^ 1'b1;
                    if (ev) contrib[TAGE_HIST_LENGTH[t]%TAGE_INDEX_WIDTH]
                        = contrib[TAGE_HIST_LENGTH[t]%TAGE_INDEX_WIDTH] ^ 1'b1;
                    after = total - cnt - 1;
                    for (int r = 0; r < FETCH_WIDTH; r++)
                        if (r < after)
                            contrib = {contrib[TAGE_INDEX_WIDTH-2:0],
                                       contrib[TAGE_INDEX_WIDTH-1]};
                    acc  = acc ^ contrib;
                    base = {base[TAGE_INDEX_WIDTH-2:0], base[TAGE_INDEX_WIDTH-1]};
                    cnt  = cnt + 1;
                end
            end
            n.fold_idx[t] = base ^ acc;
        end

        for (int unsigned t = 0; t < TAGE_NUM_TABLES; t++) begin
            logic [TAGE_TAG_WIDTH-1:0] base, acc, contrib;
            int unsigned cnt;
            base = h.fold_tag1[t];
            acc  = '0;
            cnt  = 0;
            for (int s = 0; s < FETCH_WIDTH; s++) begin
                if (mask[s]) begin
                    logic ev;
                    int unsigned after;
                    if (TAGE_HIST_LENGTH[t] > cnt)
                        ev = h.ghr[TAGE_HIST_LENGTH[t]-1-cnt];
                    else
                        ev = pushed_dir[cnt-TAGE_HIST_LENGTH[t]];
                    contrib = '0;
                    if (dir[s]) contrib[0] = contrib[0] ^ 1'b1;
                    if (ev) contrib[TAGE_HIST_LENGTH[t]%TAGE_TAG_WIDTH]
                        = contrib[TAGE_HIST_LENGTH[t]%TAGE_TAG_WIDTH] ^ 1'b1;
                    after = total - cnt - 1;
                    for (int r = 0; r < FETCH_WIDTH; r++)
                        if (r < after)
                            contrib = {contrib[TAGE_TAG_WIDTH-2:0], contrib[TAGE_TAG_WIDTH-1]};
                    acc  = acc ^ contrib;
                    base = {base[TAGE_TAG_WIDTH-2:0], base[TAGE_TAG_WIDTH-1]};
                    cnt  = cnt + 1;
                end
            end
            n.fold_tag1[t] = base ^ acc;
        end

        for (int unsigned t = 0; t < TAGE_NUM_TABLES; t++) begin
            logic [TAGE_TAG_WIDTH-2:0] base, acc, contrib;
            int unsigned cnt;
            base = h.fold_tag2[t];
            acc  = '0;
            cnt  = 0;
            for (int s = 0; s < FETCH_WIDTH; s++) begin
                if (mask[s]) begin
                    logic ev;
                    int unsigned after;
                    if (TAGE_HIST_LENGTH[t] > cnt)
                        ev = h.ghr[TAGE_HIST_LENGTH[t]-1-cnt];
                    else
                        ev = pushed_dir[cnt-TAGE_HIST_LENGTH[t]];
                    contrib = '0;
                    if (dir[s]) contrib[0] = contrib[0] ^ 1'b1;
                    if (ev) contrib[TAGE_HIST_LENGTH[t]%(TAGE_TAG_WIDTH-1)]
                        = contrib[TAGE_HIST_LENGTH[t]%(TAGE_TAG_WIDTH-1)] ^ 1'b1;
                    after = total - cnt - 1;
                    for (int r = 0; r < FETCH_WIDTH; r++)
                        if (r < after)
                            contrib = {contrib[TAGE_TAG_WIDTH-3:0],
                                       contrib[TAGE_TAG_WIDTH-2]};
                    acc  = acc ^ contrib;
                    base = {base[TAGE_TAG_WIDTH-3:0], base[TAGE_TAG_WIDTH-2]};
                    cnt  = cnt + 1;
                end
            end
            n.fold_tag2[t] = base ^ acc;
        end

`ifdef CONFIG_FE_UTAGE
        for (int unsigned t = 0; t < UTAGE_NUM_TABLES; t++) begin
            logic [UTAGE_INDEX_WIDTH-1:0] base, acc, contrib;
            int unsigned cnt;
            base = h.fold_idx_u[t];
            acc  = '0;
            cnt  = 0;
            for (int s = 0; s < FETCH_WIDTH; s++) begin
                if (mask[s]) begin
                    logic ev;
                    int unsigned after;
                    if (UTAGE_HIST_LENGTH[t] > cnt)
                        ev = h.ghr[UTAGE_HIST_LENGTH[t]-1-cnt];
                    else
                        ev = pushed_dir[cnt-UTAGE_HIST_LENGTH[t]];
                    contrib = '0;
                    if (dir[s]) contrib[0] = contrib[0] ^ 1'b1;
                    if (ev) contrib[UTAGE_HIST_LENGTH[t]%UTAGE_INDEX_WIDTH]
                        = contrib[UTAGE_HIST_LENGTH[t]%UTAGE_INDEX_WIDTH] ^ 1'b1;
                    after = total - cnt - 1;
                    for (int r = 0; r < FETCH_WIDTH; r++)
                        if (r < after)
                            contrib = {contrib[UTAGE_INDEX_WIDTH-2:0],
                                       contrib[UTAGE_INDEX_WIDTH-1]};
                    acc  = acc ^ contrib;
                    base = {base[UTAGE_INDEX_WIDTH-2:0], base[UTAGE_INDEX_WIDTH-1]};
                    cnt  = cnt + 1;
                end
            end
            n.fold_idx_u[t] = base ^ acc;
        end
        for (int unsigned t = 0; t < UTAGE_NUM_TABLES; t++) begin
            logic [UTAGE_TAG_WIDTH-1:0] base, acc, contrib;
            int unsigned cnt;
            base = h.fold_tag_u[t];
            acc  = '0;
            cnt  = 0;
            for (int s = 0; s < FETCH_WIDTH; s++) begin
                if (mask[s]) begin
                    logic ev;
                    int unsigned after;
                    if (UTAGE_HIST_LENGTH[t] > cnt)
                        ev = h.ghr[UTAGE_HIST_LENGTH[t]-1-cnt];
                    else
                        ev = pushed_dir[cnt-UTAGE_HIST_LENGTH[t]];
                    contrib = '0;
                    if (dir[s]) contrib[0] = contrib[0] ^ 1'b1;
                    if (ev) contrib[UTAGE_HIST_LENGTH[t]%UTAGE_TAG_WIDTH]
                        = contrib[UTAGE_HIST_LENGTH[t]%UTAGE_TAG_WIDTH] ^ 1'b1;
                    after = total - cnt - 1;
                    for (int r = 0; r < FETCH_WIDTH; r++)
                        if (r < after)
                            contrib = {contrib[UTAGE_TAG_WIDTH-2:0],
                                       contrib[UTAGE_TAG_WIDTH-1]};
                    acc  = acc ^ contrib;
                    base = {base[UTAGE_TAG_WIDTH-2:0], base[UTAGE_TAG_WIDTH-1]};
                    cnt  = cnt + 1;
                end
            end
            n.fold_tag_u[t] = base ^ acc;
        end
`endif
        return n;
    endfunction

    // Recompute all folded histories from a raw ghr (used by REDIRECT_ARCH).
    function automatic tage_hist_t tage_hist_collapse(input logic [TAGE_GHV_WIDTH-1:0] ghr);
        tage_hist_t n;
        n.ghr = ghr;
        n.fold_idx = '0;
        n.fold_tag1 = '0;
        n.fold_tag2 = '0;
        for (int unsigned t = 0; t < TAGE_NUM_TABLES; t++) begin
            for (int unsigned j = 0; j < TAGE_INDEX_WIDTH; j++) begin
                logic acc;
                acc = 1'b0;
                for (int unsigned k = j; k < TAGE_HIST_LENGTH[t]; k += TAGE_INDEX_WIDTH)
                acc ^= ghr[k];
                n.fold_idx[t][j] = acc;
            end
            for (int unsigned j = 0; j < TAGE_TAG_WIDTH; j++) begin
                logic acc;
                acc = 1'b0;
                for (int unsigned k = j; k < TAGE_HIST_LENGTH[t]; k += TAGE_TAG_WIDTH)
                acc ^= ghr[k];
                n.fold_tag1[t][j] = acc;
            end
            for (int unsigned j = 0; j < TAGE_TAG_WIDTH-1; j++) begin
                logic acc;
                acc = 1'b0;
                for (int unsigned k = j; k < TAGE_HIST_LENGTH[t]; k += TAGE_TAG_WIDTH-1)
                    acc ^= ghr[k];
                n.fold_tag2[t][j] = acc;
            end
        end
`ifdef CONFIG_FE_UTAGE
        n.fold_idx_u = '0;
        n.fold_tag_u = '0;
        for (int unsigned t = 0; t < UTAGE_NUM_TABLES; t++) begin
            for (int unsigned j = 0; j < UTAGE_INDEX_WIDTH; j++) begin
                logic acc;
                acc = 1'b0;
                for (int unsigned k = j; k < UTAGE_HIST_LENGTH[t]; k += UTAGE_INDEX_WIDTH)
                    acc ^= ghr[k];
                n.fold_idx_u[t][j] = acc;
            end
            for (int unsigned j = 0; j < UTAGE_TAG_WIDTH; j++) begin
                logic acc;
                acc = 1'b0;
                for (int unsigned k = j; k < UTAGE_HIST_LENGTH[t]; k += UTAGE_TAG_WIDTH)
                    acc ^= ghr[k];
                n.fold_tag_u[t][j] = acc;
            end
        end
`endif
        return n;
    endfunction

    // ── index/tag hashing (docs/tage-design.md §8.1) ─────────────────────
    // Matches native `TageDirection.v`: two PC fields + a per-table constant.
    function automatic logic [TAGE_INDEX_WIDTH-1:0] tage_index(
        input logic [ADDR_WIDTH-1:0] pc, input logic [TAGE_INDEX_WIDTH-1:0] fold,
        input int unsigned tbl);
        tage_index = pc[TAGE_INDEX_WIDTH+1:2]
                   ^ pc[2*TAGE_INDEX_WIDTH+1:TAGE_INDEX_WIDTH+2]
                   ^ fold ^ TAGE_INDEX_WIDTH'(tbl);
    endfunction

    function automatic logic [TAGE_TAG_WIDTH-1:0] tage_tag(input logic [ADDR_WIDTH-1:0] pc,
                                                           input logic [TAGE_TAG_WIDTH-1:0] fold1,
                                                           input logic [TAGE_TAG_WIDTH-2:0] fold2,
                                                           input int unsigned tbl);
        tage_tag = pc[TAGE_TAG_WIDTH+1:2]
                 ^ pc[2*TAGE_TAG_WIDTH+1:TAGE_TAG_WIDTH+2]
                 ^ fold1 ^ {fold2, 1'b0} ^ TAGE_TAG_WIDTH'(tbl);
    endfunction

    function automatic logic [UTAGE_INDEX_WIDTH-1:0] utage_index(
        input logic [ADDR_WIDTH-1:0] pc, input logic [UTAGE_INDEX_WIDTH-1:0] fold);
        utage_index = pc[UTAGE_INDEX_WIDTH+1:2] ^ fold;
    endfunction

    function automatic logic [UTAGE_TAG_WIDTH-1:0] utage_tag(
        input logic [ADDR_WIDTH-1:0] pc, input logic [UTAGE_TAG_WIDTH-1:0] fold);
        utage_tag = pc[UTAGE_TAG_WIDTH+1:2]
                  ^ pc[2*UTAGE_TAG_WIDTH+1:UTAGE_TAG_WIDTH+2]
                  ^ fold;
    endfunction

    // ── provider/alt selection for one slot ──────────────────────────────
    // r_* are the two physical slots read from every tagged table; `slot` picks
    // the physical slot of this conditional branch.  `raw_eff` is the
    // epoch-adjusted useful bit of table i's read entry (for the alloc gate).
    function automatic tage_slot_pred_t tage_slot_select(
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] r_valid,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] r_tag,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] r_ctr,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_USEFUL_WIDTH-1:0] raw_eff,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] calc_tag,
        input logic [TAGE_SLOT_WIDTH-1:0] slot, input logic base_pred);
        tage_slot_pred_t o;
        logic [TAGE_NUM_TABLES-1:0] hit;
        logic found_alt;

        o   = '0;
        hit = '0;
        for (int t = 0; t < TAGE_NUM_TABLES; t++)
        hit[t] = r_valid[t][slot] && (r_tag[t][slot] == calc_tag[t]);

        // provider = longest-history hit
        for (int t = TAGE_NUM_TABLES - 1; t >= 0; t--)
        if ((o.provider == '0) && hit[t]) o.provider = TAGE_PROVIDER_WIDTH'(t + 1);

        // alt = next-longest hit strictly below provider
        found_alt = 1'b0;
        for (int t = TAGE_NUM_TABLES - 1; t >= 0; t--)
        if (!found_alt && hit[t] && ((t + 1) < o.provider)) begin
            o.alt = TAGE_PROVIDER_WIDTH'(t + 1);
            found_alt = 1'b1;
        end

        o.hit      = hit;
        o.hit_any  = |hit;
        o.provided = (o.provider != '0);
        o.alt_hit  = (o.alt != '0);
        o.useful   = raw_eff;

        if (o.provided) begin
            o.provider_ctr  = r_ctr[o.provider-1][slot];
            o.provider_pred = ~o.provider_ctr[TAGE_CTR_WIDTH-1];
            o.prov_unconf   = (o.provider_ctr == '0) || (&o.provider_ctr);
        end else begin
            o.prov_unconf   = 1'b0;
            o.provider_pred = base_pred;
        end

        o.alt_pred = o.alt_hit ? ~r_ctr[o.alt-1][slot][TAGE_CTR_WIDTH-1] : base_pred;
        o.pred     = o.provider_pred;
        return o;
    endfunction

    // ── full per-slot prediction (s2) ────────────────────────────────────
    // One direction + one tage_meta_t for a single fetch-block slot.  Keeping
    // this in a pure function means the top-level always_comb has no
    // conditionally-assigned signals (and therefore no spurious latches).
    typedef struct packed {
        logic       pred;
        tage_meta_t meta;
    } tage_slot_out_t;

    function automatic tage_slot_out_t tage_predict_slot(
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] r_valid,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] r_tag,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] r_ctr,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] r_useful,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] calc_idx,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] calc_tag,
        input logic [TAGE_NUM_BANKS-1:0] useful_epoch,
        input logic [TAGE_COND_PREFIX_WIDTH-1:0] cond_prefix,
        input logic [TAGE_CKPT_PTR_WIDTH-1:0] ckpt_ptr,
        input logic [TAGE_SLOT_ID_WIDTH-1:0] slot_id,
        input logic [TAGE_BLOCK_META_PTR_WIDTH-1:0] block_ptr,
        input logic [TAGE_BLOCK_META_SEQ_WIDTH-1:0] block_seq,
        input logic [1:0] base_ctr,
        input logic base_pred, input logic use_alt_bit, input logic has_cfi);
        tage_slot_out_t o;
        tage_slot_pred_t sel;
        logic [TAGE_NUM_TABLES-1:0][TAGE_USEFUL_WIDTH-1:0] eff;
        logic take_alt;

        o                  = '0;
        o.meta.meta_valid  = 1'b1;  // every S2 slot carries a usable ckpt_ptr/cond_prefix
        o.meta.ckpt_ptr    = ckpt_ptr;
        o.meta.cond_prefix = cond_prefix;
        o.meta.slot_id     = slot_id;
        o.meta.block_ptr   = block_ptr;
        o.meta.block_seq   = block_seq;
        o.meta.base_ctr    = base_ctr;
        o.pred             = 1'b0;

        if (has_cfi) begin
            // The tagged way is the instruction slot.  Unlike the branch
            // ordinal, the instruction slot is stable when uBTB/mBTB CFI
            // coverage changes between the S1 provisional and S2 final
            // prediction.
            if (int'(slot_id) < int'(TAGE_NUM_SLOTS)) begin
                for (int t = 0; t < TAGE_NUM_TABLES; t++)
                eff[t] = tage_useful_eff(
                    r_useful[t][slot_id[TAGE_SLOT_WIDTH-1:0]],
                    useful_epoch[calc_idx[t][$clog2(
                        TAGE_NUM_BANKS)-1:0]]
                );
                sel = tage_slot_select(
                    r_valid,
                    r_tag,
                    r_ctr,
                    eff,
                    calc_tag,
                    slot_id[TAGE_SLOT_WIDTH-1:0],
                    base_pred
                );
                take_alt = TAGE_USE_ALT_ON_NA && sel.prov_unconf && use_alt_bit;
                o.meta.valid = 1'b1;
                o.meta.provided = sel.provided;
                o.meta.provider = sel.provider;
                o.meta.provider_ctr = sel.provider_ctr;
                o.meta.provider_pred = sel.provider_pred;
                o.meta.alt_pred = sel.alt_pred;
                o.meta.tage_pred = take_alt ? sel.alt_pred : sel.provider_pred;
                o.pred = o.meta.tage_pred;
            end else begin
                // 3rd+ conditional branch: T0 only, not TAGE-managed
                o.meta.valid         = 1'b0;
                o.meta.provider_pred = base_pred;
                o.meta.alt_pred      = base_pred;
                o.meta.tage_pred     = base_pred;
                o.pred               = base_pred;
            end

        end
        return o;
    endfunction

    // ── full training decision ───────────────────────────────────────────
    // Pure function of update_meta + the port-B read-back of the tables; the
    // top level only unpacks the result onto the write ports.
    typedef struct packed {
        logic [TAGE_NUM_TABLES-1:0]                        wr_en;
        logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0]  wr_idx;
        logic [TAGE_NUM_TABLES-1:0][TAGE_SLOT_WIDTH-1:0]   wr_slot;
        logic [TAGE_NUM_TABLES-1:0]                        wr_valid;
        logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0]    wr_tag;
        logic [TAGE_NUM_TABLES-1:0][TAGE_CTR_WIDTH-1:0]    wr_ctr;
        logic [TAGE_NUM_TABLES-1:0][TAGE_USEFUL_WIDTH-1:0] wr_useful;
        logic                                              alloc_trig;
        logic                                              alloc_found;
        logic [$clog2(TAGE_NUM_BANKS)-1:0]                 alloc_bank;
    } tage_update_t;

    function automatic tage_update_t tage_update_compute(
        input logic upd_en, input logic upd_taken, input tage_meta_t m,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_INDEX_WIDTH-1:0] idx,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_TAG_WIDTH-1:0] tag,
        input logic [TAGE_SLOT_ID_WIDTH-1:0] slot_id,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0] up_valid,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_TAG_WIDTH-1:0] up_tag,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_CTR_WIDTH-1:0] up_ctr,
        input logic [TAGE_NUM_TABLES-1:0][TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] up_useful,
        input logic [TAGE_NUM_BANKS-1:0] useful_epoch);
        tage_update_t                       u;
        logic         [TAGE_SLOT_WIDTH-1:0] cslot;
        logic         [TAGE_NUM_TABLES-1:0] cand;
        int unsigned                        pt;
        int unsigned                        alloc_cnt;
        logic                               tag_match;
        logic                               free_or_match;
        logic                               eph;
        logic         [ TAGE_CTR_WIDTH-1:0] nctr;
        logic [TAGE_USEFUL_WIDTH-1:0] nuseful, eff, neweff;

        u     = '0;
        cslot = slot_id[TAGE_SLOT_WIDTH-1:0];
        for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
            u.wr_en[t]     = 1'b0;
            u.wr_idx[t]    = idx[t];
            u.wr_slot[t]   = cslot;
            u.wr_valid[t]  = 1'b0;
            u.wr_tag[t]    = '0;
            u.wr_ctr[t]    = '0;
            u.wr_useful[t] = '0;
        end
        if (upd_en && m.valid) begin
            // ---- provider counter + useful ----
            if (m.provider != '0) begin
                pt        = int'(m.provider) - 1;
                tag_match = up_valid[pt][cslot] && (up_tag[pt][cslot] == tag[pt]);
                if (tag_match) begin
                    eph     = useful_epoch[idx[pt][$clog2(TAGE_NUM_BANKS)-1:0]];
                    nctr    = tage_sat3(up_ctr[pt][cslot], upd_taken);
                    nuseful = tage_useful_eff(up_useful[pt][cslot], eph);
                    if (m.provider_pred != m.alt_pred)
                        nuseful = tage_sat_useful(nuseful, m.provider_pred == upd_taken);
                    u.wr_en[pt]     = 1'b1;
                    u.wr_idx[pt]    = idx[pt];
                    u.wr_slot[pt]   = cslot;
                    u.wr_valid[pt]  = 1'b1;
                    u.wr_tag[pt]    = tag[pt];
                    u.wr_ctr[pt]    = nctr;
                    u.wr_useful[pt] = tage_useful_eff(nuseful, eph);
                end
            end

            // ---- allocation ----
            // Native `TageDirection.v` allocates on any misprediction (up to
            // two longer-history tables); that fills the tagged tables faster
            // and improves accuracy over the conservative golden condition.
            // Allocate at most one longer-history table, like XiangShan.  A
            // single allocation shortens the useful-reset/write pressure and
            // avoids the systematic pollution of the old two-table rule.  The
            // provider is never overwritten, and the highest table is skipped.
            u.alloc_trig = (m.tage_pred != upd_taken)
                        && !(m.provided && (int'(m.provider) == int'(TAGE_NUM_TABLES)));
            if (u.alloc_trig) begin
                for (int t = 0; t < TAGE_NUM_TABLES; t++)
                cand[t] = !m.provided || ((t + 1) > m.provider);
                u.alloc_found = 1'b0;
                alloc_cnt = 0;
                for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                    // An invalid entry or an entry whose useful counter has
                    // decayed to zero is allocatable.  Scan from the shortest
                    // longer-history table so the new entry lands closest to
                    // the provider.
                    free_or_match = !up_valid[t][cslot]
                                 || (tage_useful_eff(up_useful[t][cslot],
                                         useful_epoch[idx[t][$clog2(TAGE_NUM_BANKS)-1:0]]) == '0);
                    if ((alloc_cnt < 2) && cand[t] && free_or_match) begin
                        if (!u.alloc_found)
                            u.alloc_bank = idx[t][$clog2(TAGE_NUM_BANKS)-1:0];
                        u.alloc_found = 1'b1;
                        alloc_cnt = alloc_cnt + 1;
                        u.wr_en[t] = 1'b1;
                        u.wr_idx[t] = idx[t];
                        u.wr_slot[t] = cslot;
                        u.wr_valid[t] = 1'b1;
                        u.wr_tag[t] = tag[t];
                        u.wr_ctr[t] = upd_taken ? {TAGE_CTR_WIDTH{1'b0}} : {TAGE_CTR_WIDTH{1'b1}};
                        u.wr_useful[t] = '0;
                    end
                end
                if (!u.alloc_found) begin
                    for (int t = 0; t < TAGE_NUM_TABLES; t++) begin
                        if (cand[t] && up_valid[t][cslot] && !u.wr_en[t]) begin
                            eph            = useful_epoch[idx[t][$clog2(TAGE_NUM_BANKS)-1:0]];
                            eff            = tage_useful_eff(up_useful[t][cslot], eph);
                            neweff         = (eff == '0) ? '0 : eff - 1'b1;
                            u.wr_en[t]     = 1'b1;
                            u.wr_idx[t]    = idx[t];
                            u.wr_slot[t]   = cslot;
                            u.wr_valid[t]  = 1'b1;
                            u.wr_tag[t]    = up_tag[t][cslot];
                            u.wr_ctr[t]    = up_ctr[t][cslot];
                            u.wr_useful[t] = tage_useful_eff(neweff, eph);
                        end
                    end
                end
            end
        end
        return u;
    endfunction

endpackage
/* verilator lint_on UNUSEDSIGNAL */
`endif
