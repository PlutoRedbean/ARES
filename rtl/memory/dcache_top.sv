//=============================================================================
// ARES LSU - DCache pipeline and port arbitration (L06)
//-----------------------------------------------------------------------------
// memory.md 6.2 / 6.3 / 6.5 / 6.8:
//   C2  accept one request (LQ load lookup or oldest COMMITTED SQ store drain),
//       register the owner and start the synchronous Way Tag/Data reads.
//   C3  re-check against the *registered* MSHR / Way-Lock / WB-visibility /
//       Pending-Store-Write state and return exactly one of
//       LOAD_HIT / STORE_HIT / MSHR_ACCEPT / RETRY.  RETRY only re-issues the
//       internal C2 read (the LQ/SQ handshake already happened and is not
//       repeated).
//
// Owns: arrays read/write-port arbitration per way, the 1-entry Pending Store
// Write, Tag/Valid/Dirty/LRU metadata writes, MSHR RESERVE / merge / overlay
// requests including the victim-way choice and Dirty-victim WB reservation.
//
// Spec sources: docs/microarch/memory.md 6.1-6.5, 6.8; plan 5.12;
//   rtl/memory/LSU_INTERFACES.md 9/13.
// FREE items: FREE-02 (file organisation), FREE-04 (parallel per-way hazard
//   compare), FREE-11 (pipeline register placement).
//
// Lint: verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//         -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module dcache_top \
//         rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/dcache_arrays.sv rtl/memory/dcache_top.sv
//=============================================================================
module dcache_top (
    input  logic                                     clk,
    input  logic                                     rst,

    //---- C2 request: LQ load lookup ---------------------------------------
    input  logic                                     lq_lookup_valid,
    output logic                                     lq_lookup_ready,
    input  logic [1:0]                               lq_lookup_idx,
    input  ares_pkg::tag_t                           lq_lookup_tag,
    input  logic [31:0]                              lq_lookup_addr,
    input  logic [7:0]                               lq_wait_epoch [ares_pkg::LQ_ENTRIES],

    //---- C2 speculative load probe (early read-only lookup) ----------------
    input  logic                                     probe_valid,
    output logic                                     probe_ready,
    input  logic [1:0]                               probe_idx,
    input  ares_pkg::tag_t                           probe_tag,
    input  logic [31:0]                              probe_addr,
    input  logic                                     probe_sq_empty,
    input  logic                                     probe_wb_empty,
    output logic                                     probe_hit_valid,
    output logic [1:0]                               probe_hit_idx,
    output logic [31:0]                              probe_hit_word,
    output ares_pkg::tag_t                           probe_hit_tag,

    //---- C3 result: load hit fill -----------------------------------------
    output logic                                     hit_fill_valid,
    output logic [1:0]                               hit_fill_idx,
    output logic [31:0]                              hit_fill_word,

    //---- C2 request: SQ oldest COMMITTED store drain ----------------------
    input  logic                                     sq_drain_valid,
    input  logic [2:0]                               sq_drain_idx,
    input  ares_pkg::tag_t                           sq_drain_tag,
    input  logic [31:0]                              sq_drain_addr,
    input  logic [31:0]                              sq_drain_data,
    input  logic [3:0]                               sq_drain_mask,
    input  logic                                     sq_high_water,
    output logic                                     store_start,
    output logic                                     store_takeover,

    //---- flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0]         kill_mask,

    //---- MSHR: way lock / same-line match ---------------------------------
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_lock_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]  mshr_lock_line_addr,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_lock_way,
    output logic [31:0]                              mshr_match_line_addr,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_match_hit,

    //---- MSHR: RESERVE ----------------------------------------------------
    output logic                                     mshr_resv_valid,
    input  logic                                     mshr_resv_ready,
    output logic [31:0]                              mshr_resv_line_addr,
    output logic [1:0]                               mshr_resv_way,
    output logic                                     mshr_resv_victim_dirty,
    output logic [1:0]                               mshr_resv_wb_idx,
    output logic                                     mshr_resv_is_store,
    output logic [1:0]                               mshr_resv_lq_idx,
    output ares_pkg::tag_t                           mshr_resv_lq_tag,
    output logic [7:0]                               mshr_resv_lq_epoch,
    output logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_resv_word_idx,
    output logic [3:0]                               mshr_resv_store_mask,
    output logic [31:0]                              mshr_resv_store_data,
    output logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_resv_store_widx,

    //---- MSHR: merge (load waiter) ----------------------------------------
    output logic                                     mshr_merge_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_merge_sel,
    input  logic                                     mshr_merge_ready,
    output logic                                     mshr_merge_is_store,
    output logic [1:0]                               mshr_merge_lq_idx,
    output ares_pkg::tag_t                           mshr_merge_lq_tag,
    output logic [7:0]                               mshr_merge_lq_epoch,
    output logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_merge_word_idx,
    output logic [3:0]                               mshr_merge_store_mask,
    output logic [31:0]                              mshr_merge_store_data,
    output logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_merge_store_widx,

    //---- MSHR: store overlay into an in-flight MSHR -----------------------
    output logic                                     mshr_ovl_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_ovl_sel,
    input  logic                                     mshr_ovl_ready,
    output logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]  mshr_ovl_widx,
    output logic [3:0]                               mshr_ovl_mask,
    output logic [31:0]                              mshr_ovl_data,

    //---- MSHR: victim capture read ----------------------------------------
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_cap_req_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_cap_req_way,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] mshr_cap_req_row,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_cap_gnt,
    output logic                                     cap_rsp_valid,
    output logic [ares_pkg::DCACHE_INDEX_BITS-1:0]   cap_rsp_set,
    output logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_rsp_row,
    output logic [1:0]                               cap_rsp_way,
    output logic [63:0]                              cap_rsp_data,

    //---- MSHR: install write ----------------------------------------------
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_inst_way,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] mshr_inst_set,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] mshr_inst_row,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]  mshr_inst_data,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][7:0]   mshr_inst_be,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_last,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_inst_gnt,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_pub_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]   mshr_pub_way,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] mshr_pub_tag,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]        mshr_pub_dirty,

    //---- WB buffer ---------------------------------------------------------
    input  logic [ares_pkg::WB_ENTRIES-1:0]          wb_free_mask,
    output logic                                     wb_alloc_valid,
    output logic [1:0]                               wb_alloc_idx,
    output logic [31:0]                              wb_alloc_line_addr,
    output logic [31:0]                              wb_vis_query,
    input  logic                                     wb_vis_block
);
    import ares_pkg::*;
    import lsu_pkg::*;

    localparam int unsigned WAYS  = DCACHE_NUM_WAYS;
    localparam int unsigned OFF   = DCACHE_OFFSET_BITS;
    localparam int unsigned IDXB  = DCACHE_INDEX_BITS;
    localparam int unsigned ROWB  = $clog2(ROWS_PER_LINE);
    localparam int unsigned TAGB  = DCACHE_TAG_BITS;
    localparam int unsigned WIDXB = OFF - 2;
    localparam int unsigned MSHRN = MSHR_ENTRIES;

    //-------------------------------------------------------------------------
    // Owner register (request accepted at C2, decided at C3)
    //-------------------------------------------------------------------------
    logic              own_valid;
    logic              own_rd_pending;   // the owner still owes its C2 address read
    logic              own_store;
    /* verilator lint_off UNUSEDSIGNAL */  // own_idx[2] is the store-only SQ index
    logic [2:0]        own_idx;
    /* verilator lint_on UNUSEDSIGNAL */
    tag_t              own_tag;
    logic [31:0]       own_addr;
    logic [31:0]       own_data;
    logic [3:0]        own_mask;
    logic [7:0]        own_epoch;

    wire [IDXB-1:0]  own_set  = own_addr[OFF +: IDXB];
    wire [ROWB-1:0]  own_row  = own_addr[3 +: ROWB];
    wire [TAGB-1:0]  own_tagx = own_addr[31 -: TAGB];
    wire [WIDXB-1:0] own_widx = own_addr[OFF-1:2];
    wire [31:0]      own_line = {own_addr[31:OFF], {OFF{1'b0}}};
    wire             own_kill = !own_store && kill_mask[own_tag.slot_index];

    // Speculative probe owner: a separate one-cycle pipeline that reads the
    // arrays but never publishes LRU/dirty/MSHR state.  It is accepted only
    // when the normal owner and capture paths are idle.
    logic            probe_own_valid;
    logic [1:0]      probe_idx_r;
    tag_t            probe_tag_r;
    /* verilator lint_off UNUSEDSIGNAL */  // only tag and word-select bits are consumed
    logic [31:0]     probe_addr_r;
    /* verilator lint_on UNUSEDSIGNAL */

    //-------------------------------------------------------------------------
    // 1-entry Pending Store Write (memory.md 6.3 / 6.5)
    //-------------------------------------------------------------------------
    logic            psw_valid;
    logic [1:0]      psw_way;
    logic [IDXB-1:0] psw_set;
    logic [ROWB-1:0] psw_row;
    logic [63:0]     psw_data;
    logic [7:0]      psw_be;

    //-------------------------------------------------------------------------
    // Request selection (round robin; SQ high-watermark forces the SQ)
    //-------------------------------------------------------------------------
    logic arb_last_store;   // 1 = last accepted request was a store

    wire new_req = !own_valid && (lq_lookup_valid || sq_drain_valid);
    wire sq_sel  = sq_drain_valid && (!lq_lookup_valid || sq_high_water || !arb_last_store);
    wire lq_sel  = lq_lookup_valid && !sq_sel;

    wire [31:0]     sel_addr = sq_sel ? sq_drain_addr : lq_lookup_addr;
    /* verilator lint_off UNUSEDSIGNAL */  // addr[2:0] selects the byte lane inside the row
    wire [31:0]     lk_addr  = own_valid ? own_addr : sel_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [IDXB-1:0] lk_set   = lk_addr[OFF +: IDXB];
    wire [ROWB-1:0] lk_row   = lk_addr[3 +: ROWB];
    wire [31:0]     lk_line  = {lk_addr[31:OFF], {OFF{1'b0}}};

    //-------------------------------------------------------------------------
    // MSHR way-lock / same-line decode for the set being accessed
    //-------------------------------------------------------------------------
    logic [MSHRN-1:0][IDXB-1:0] lock_set;
    logic [MSHRN-1:0]           lock_set_match;
    logic [MSHRN-1:0][1:0]      lock_way_here;
    logic [MSHRN-1:0][IDXB-1:0] cap_set;

    always_comb begin
        for (int unsigned i = 0; i < MSHRN; i++) begin
            lock_set[i]       = mshr_lock_line_addr[i][OFF +: IDXB];
            lock_set_match[i] = mshr_lock_valid[i] && (lock_set[i] == lk_set);
            lock_way_here[i]  = mshr_lock_valid[i] ? (mshr_lock_way[i] & {2{lock_set_match[i]}}) : 2'd0;
            cap_set[i]        = mshr_lock_line_addr[i][OFF +: IDXB];
        end
    end

    wire [1:0] way_locked = lock_way_here[0] | lock_way_here[1];
    wire       mshr_any   = |mshr_match_hit;
//-------------------------------------------------------------------------
    // Arrays read-port arbitration (memory.md 6.3)
    //   * lookup needs BOTH ways; capture needs one way; one capture per cycle
    //     because there is a single capture response port (LSU_INTERFACES 13),
    //   * lookup first; a capture denied 4 times in a row preempts the lookup,
    //   * a store write firing on the same set+row blocks the conflicting read
    //     (no read-during-write reliance).
    //-------------------------------------------------------------------------
    logic [1:0]  cap_starve;
    logic        cap_win;
    logic [MSHRN-1:0] cap_pw_hazard;
    logic [1:0]  inst_want_way;
    logic [1:0]  inst_gnt_w;
    logic [1:0]  inst_preempt;   // [w] = install preempts the store write on way w
    logic [1:0]  inst_deny_cnt [WAYS];
    logic        psw_fire;

    always_comb begin
        inst_want_way = 2'd0;
        for (int unsigned i = 0; i < MSHRN; i++) begin
            if (mshr_inst_valid[i]) inst_want_way |= mshr_inst_way[i];
        end
        inst_preempt[0] = (inst_deny_cnt[0] >= 2'd2) && inst_want_way[0];
        inst_preempt[1] = (inst_deny_cnt[1] >= 2'd2) && inst_want_way[1];
        psw_fire = psw_valid && !inst_preempt[psw_way[1]];
    end

    logic c3_active;   // the arrays response of the last lookup read is here
    logic retry_read;  // the owner still owes a read (RETRY or a lost/suppressed read)
    logic lk_rd_want;
    logic lk_rd;
    logic lk_pw_hazard;
    logic lk_inst_hazard;               // a granted install writes this set+row
    logic [MSHRN-1:0] cap_inst_hazard;  // ... into the way a capture wants

    assign lk_pw_hazard = psw_fire && (psw_set == lk_set) && (psw_row == lk_row);
    // The re-read is requested whenever the owner still owes one; it must NOT
    // depend on c3_active, otherwise a RETRY whose re-read was suppressed by a
    // capture/priority conflict would never be re-issued (deadlock).
    assign retry_read   = own_valid && own_rd_pending;
    assign lk_rd_want   = new_req || retry_read;

    always_comb begin
        for (int unsigned i = 0; i < MSHRN; i++) begin
            cap_pw_hazard[i] = psw_fire && (psw_way == mshr_cap_req_way[i])
                            && (psw_set == cap_set[i]) && (psw_row == mshr_cap_req_row[i]);
        end
        cap_win = (cap_starve >= 2'd3);
    end

    logic [MSHRN-1:0] cap_ok_pre;
    logic [MSHRN-1:0] cap_gnt_comb;
    wire  any_cap;

    always_comb begin
        cap_ok_pre = '0;
        for (int unsigned i = 0; i < MSHRN; i++) begin
            cap_ok_pre[i] = mshr_cap_req_valid[i] && !cap_pw_hazard[i]
                         && !cap_inst_hazard[i] && (cap_win || !lk_rd_want);
        end
    end
    assign cap_gnt_comb = {cap_ok_pre[1] && !cap_ok_pre[0], cap_ok_pre[0]};
    assign any_cap      = |cap_gnt_comb;
    assign lk_rd        = lk_rd_want && !lk_pw_hazard && !lk_inst_hazard && !any_cap;
    assign mshr_cap_gnt = cap_gnt_comb;

    logic [1:0]           rd_valid_w;
    logic [1:0][IDXB-1:0] rd_set_w;
    logic [1:0][ROWB-1:0] rd_row_w;

    wire [IDXB-1:0] probe_set = probe_addr[OFF +: IDXB];
    wire [ROWB-1:0] probe_row = probe_addr[3 +: ROWB];
    logic           probe_rd;

    // A probe is a read-only early lookup.  Keep it off the arrays whenever a
    // normal owner, capture, pending store or MSHR could be using the same
    // read port; the conservative gating also means the probe never needs a
    // write-after-read hazard check.
    always_comb begin
        probe_ready = probe_valid && !own_valid && !lk_rd && !any_cap
                   && !probe_own_valid && !psw_valid
                   && !(|mshr_inst_valid) && !(|mshr_lock_valid);
        probe_rd    = probe_valid && probe_ready;
    end

    always_comb begin
        for (int unsigned w = 0; w < WAYS; w++) begin
            rd_valid_w[w] = lk_rd || (cap_gnt_comb[0] && mshr_cap_req_way[0][w])
                                   || (cap_gnt_comb[1] && mshr_cap_req_way[1][w])
                                   || probe_rd;
            if (probe_rd) begin
                rd_set_w[w] = probe_set;
                rd_row_w[w] = probe_row;
            end else if (lk_rd) begin
                rd_set_w[w] = lk_set;
                rd_row_w[w] = lk_row;
            end else if (cap_gnt_comb[0] && mshr_cap_req_way[0][w]) begin
                rd_set_w[w] = cap_set[0];
                rd_row_w[w] = mshr_cap_req_row[0];
            end else begin
                rd_set_w[w] = cap_set[1];
                rd_row_w[w] = mshr_cap_req_row[1];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            probe_own_valid <= 1'b0;
            probe_idx_r     <= 2'd0;
            probe_tag_r     <= '0;
            probe_addr_r    <= 32'd0;
        end else if (probe_rd) begin
            probe_own_valid <= 1'b1;
            probe_idx_r     <= probe_idx;
            probe_tag_r     <= probe_tag;
            probe_addr_r    <= probe_addr;
        end else begin
            probe_own_valid <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Arrays
    //-------------------------------------------------------------------------
    logic [1:0]           a_rd_rsp_valid;
    /* verilator lint_off UNUSEDSIGNAL */  // way1 repeats the same set/row (C3 checks way0)
    logic [1:0][IDXB-1:0] a_rd_rsp_set;
    logic [1:0][ROWB-1:0] a_rd_rsp_row;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0][63:0]     a_rd_rsp_data;
    logic [1:0][TAGB-1:0] a_rd_rsp_tag;
    logic [1:0]           a_rd_rsp_line_valid;
    logic [1:0]           a_rd_rsp_dirty;

    // The probe response is the array read issued in the previous cycle.  It
    // never updates LRU/dirty/valid/MSHR; a probe hit is only a data source
    // for the LQ, and the normal lookup path remains the fallback.
    wire probe_hit0 = a_rd_rsp_valid[0] && a_rd_rsp_line_valid[0]
                   && (a_rd_rsp_tag[0] == probe_addr_r[31 -: TAGB]);
    wire probe_hit1 = a_rd_rsp_valid[1] && a_rd_rsp_line_valid[1]
                   && (a_rd_rsp_tag[1] == probe_addr_r[31 -: TAGB]);
    wire [31:0] probe_word0 = probe_addr_r[2] ? a_rd_rsp_data[0][63:32]
                                              : a_rd_rsp_data[0][31:0];
    wire [31:0] probe_word1 = probe_addr_r[2] ? a_rd_rsp_data[1][63:32]
                                              : a_rd_rsp_data[1][31:0];
    wire probe_kill = kill_mask[probe_tag_r.slot_index];
    wire probe_safe = probe_own_valid && probe_sq_empty && probe_wb_empty
                   && !psw_valid && !(|mshr_lock_valid) && !probe_kill;

    assign probe_hit_valid = probe_safe && (probe_hit0 || probe_hit1);
    assign probe_hit_idx   = probe_idx_r;
    assign probe_hit_word  = probe_hit1 ? probe_word1 : probe_word0;
    assign probe_hit_tag   = probe_tag_r;

    logic [1:0]           wr_valid_w;
    logic [1:0][IDXB-1:0] wr_set_w;
    logic [1:0][ROWB-1:0] wr_row_w;
    logic [1:0][63:0]     wr_data_w;
    logic [1:0][7:0]      wr_be_w;

    logic [1:0]           meta_valid_w;
    logic [1:0][IDXB-1:0] meta_set_w;
    logic [1:0][TAGB-1:0] meta_tag_w;
    logic [1:0]           meta_tag_en_w;
    logic [1:0]           meta_lv_en_w;
    logic [1:0]           meta_lv_w;
    logic [1:0]           meta_dirty_en_w;
    logic [1:0]           meta_dirty_w;

    logic                 lru_valid_w;
    logic [IDXB-1:0]      lru_set_w;
    logic                 lru_way_w;
    logic                 lru_last_way;

    logic [MSHRN-1:0]     inst_gnt_comb;
    logic [1:0]           inst_psw_hazard;
    logic                 inst_other_same_way;

    // W-port grants (store write / install) WIN over a conflicting read on the
    // same Way+set+row: memory.md 6.3 forbids a same-row R/W on one edge and the
    // write side is bounded (a pending write fires once, an install has at most
    // ROWS_PER_LINE rows), so the suppressed read cannot be starved forever.
    // The opposite priority (read wins) deadlocks against a Retrying Lookup
    // whose line is locked by the very MSHR that wants to install.
    always_comb begin
        inst_psw_hazard[0] = psw_fire && psw_way[0];
        inst_psw_hazard[1] = psw_fire && psw_way[1];
        inst_other_same_way = mshr_inst_valid[0] && mshr_inst_valid[1]
                           && (|(mshr_inst_way[0] & mshr_inst_way[1]));
        inst_gnt_comb[0] = mshr_inst_valid[0]
                        && !inst_psw_hazard[mshr_inst_way[0][1]];
        inst_gnt_comb[1] = mshr_inst_valid[1]
                        && !inst_psw_hazard[mshr_inst_way[1][1]]
                        && !(inst_other_same_way && inst_gnt_comb[0]);

        lk_inst_hazard = (inst_gnt_comb[0] && (mshr_inst_set[0] == lk_set)
                                           && (mshr_inst_row[0] == lk_row))
                      || (inst_gnt_comb[1] && (mshr_inst_set[1] == lk_set)
                                           && (mshr_inst_row[1] == lk_row));

        for (int unsigned i = 0; i < MSHRN; i++) begin
            cap_inst_hazard[i] =
                   (inst_gnt_comb[0] && (mshr_inst_way[0] == mshr_cap_req_way[i])
                    && (mshr_inst_set[0] == cap_set[i])
                    && (mshr_inst_row[0] == mshr_cap_req_row[i]))
                || (inst_gnt_comb[1] && (mshr_inst_way[1] == mshr_cap_req_way[i])
                    && (mshr_inst_set[1] == cap_set[i])
                    && (mshr_inst_row[1] == mshr_cap_req_row[i]));
        end
    end
    assign mshr_inst_gnt = inst_gnt_comb;
    assign inst_gnt_w    = (mshr_inst_way[0] & {2{inst_gnt_comb[0]}})
                         | (mshr_inst_way[1] & {2{inst_gnt_comb[1]}});

    always_comb begin
        for (int unsigned w = 0; w < WAYS; w++) begin
            wr_valid_w[w] = (psw_fire && psw_way[w])
                         || (inst_gnt_comb[0] && mshr_inst_way[0][w])
                         || (inst_gnt_comb[1] && mshr_inst_way[1][w]);
            if (psw_fire && psw_way[w]) begin
                wr_set_w[w]  = psw_set;
                wr_row_w[w]  = psw_row;
                wr_data_w[w] = psw_data;
                wr_be_w[w]   = psw_be;
            end else if (inst_gnt_comb[0] && mshr_inst_way[0][w]) begin
                wr_set_w[w]  = mshr_inst_set[0];
                wr_row_w[w]  = mshr_inst_row[0];
                wr_data_w[w] = mshr_inst_data[0];
                wr_be_w[w]   = mshr_inst_be[0];
            end else begin
                wr_set_w[w]  = mshr_inst_set[1];
                wr_row_w[w]  = mshr_inst_row[1];
                wr_data_w[w] = mshr_inst_data[1];
                wr_be_w[w]   = mshr_inst_be[1];
            end
        end
    end

    always_comb begin
        for (int unsigned w = 0; w < WAYS; w++) begin
            meta_valid_w[w]  = (mshr_pub_valid[0] && mshr_pub_way[0][w])
                            || (mshr_pub_valid[1] && mshr_pub_way[1][w])
                            || (psw_fire && psw_way[w]);
            if (mshr_pub_valid[0] && mshr_pub_way[0][w]) begin
                meta_set_w[w]      = lock_set[0];
                meta_tag_w[w]      = mshr_pub_tag[0];
                meta_tag_en_w[w]   = 1'b1;
                meta_lv_en_w[w]    = 1'b1;
                meta_lv_w[w]       = 1'b1;
                meta_dirty_en_w[w] = 1'b1;
                meta_dirty_w[w]    = mshr_pub_dirty[0];
            end else if (mshr_pub_valid[1] && mshr_pub_way[1][w]) begin
                meta_set_w[w]      = lock_set[1];
                meta_tag_w[w]      = mshr_pub_tag[1];
                meta_tag_en_w[w]   = 1'b1;
                meta_lv_en_w[w]    = 1'b1;
                meta_lv_w[w]       = 1'b1;
                meta_dirty_en_w[w] = 1'b1;
                meta_dirty_w[w]    = mshr_pub_dirty[1];
            end else begin
                meta_set_w[w]      = psw_set;
                meta_tag_w[w]      = '0;
                meta_tag_en_w[w]   = 1'b0;
                meta_lv_en_w[w]    = 1'b0;
                meta_lv_w[w]       = 1'b0;
                meta_dirty_en_w[w] = 1'b1;
                meta_dirty_w[w]    = 1'b1;
            end
        end
    end

    dcache_arrays u_arrays (
        .clk               (clk),
        .rst               (rst),
        .rd_valid          (rd_valid_w),
        .rd_set            (rd_set_w),
        .rd_row            (rd_row_w),
        .rd_rsp_valid      (a_rd_rsp_valid),
        .rd_rsp_set        (a_rd_rsp_set),
        .rd_rsp_row        (a_rd_rsp_row),
        .rd_rsp_data       (a_rd_rsp_data),
        .rd_rsp_tag        (a_rd_rsp_tag),
        .rd_rsp_line_valid (a_rd_rsp_line_valid),
        .rd_rsp_dirty      (a_rd_rsp_dirty),
        .wr_valid          (wr_valid_w),
        .wr_set            (wr_set_w),
        .wr_row            (wr_row_w),
        .wr_data           (wr_data_w),
        .wr_be             (wr_be_w),
        .meta_valid        (meta_valid_w),
        .meta_set          (meta_set_w),
        .meta_tag          (meta_tag_w),
        .meta_tag_en       (meta_tag_en_w),
        .meta_line_valid_en(meta_lv_en_w),
        .meta_line_valid   (meta_lv_w),
        .meta_dirty_en     (meta_dirty_en_w),
        .meta_dirty        (meta_dirty_w),
        .lru_valid         (lru_valid_w),
        .lru_set           (lru_set_w),
        .lru_way           (lru_way_w),
        .lru_rd_set        (own_set),
        .lru_rd_last_way   (lru_last_way)
    );

    //-------------------------------------------------------------------------
    // Read response routing (lookup vs the single capture slot)
    //-------------------------------------------------------------------------
    logic            cap_gnt_q;
    logic [1:0]      cap_way_q;
    logic [IDXB-1:0] cap_set_q;
    logic [ROWB-1:0] cap_row_q;
    logic            lk_rd_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            lk_rd_q   <= 1'b0;
            cap_gnt_q <= 1'b0;
            cap_way_q <= 2'd0;
            cap_set_q <= '0;
            cap_row_q <= '0;
        end else begin
            lk_rd_q   <= lk_rd;
            cap_gnt_q <= any_cap;
            if (cap_gnt_comb[0]) begin
                cap_way_q <= mshr_cap_req_way[0];
                cap_set_q <= cap_set[0];
                cap_row_q <= mshr_cap_req_row[0];
            end else if (cap_gnt_comb[1]) begin
                cap_way_q <= mshr_cap_req_way[1];
                cap_set_q <= cap_set[1];
                cap_row_q <= mshr_cap_req_row[1];
            end
        end
    end

    assign cap_rsp_valid = cap_gnt_q && (|(cap_way_q & a_rd_rsp_valid));
    assign cap_rsp_way   = cap_way_q;
    assign cap_rsp_set   = cap_set_q;
    assign cap_rsp_row   = cap_row_q;
    assign cap_rsp_data  = cap_way_q[0] ? a_rd_rsp_data[0] : a_rd_rsp_data[1];
//-------------------------------------------------------------------------
    // C3 decision (memory.md 6.3)
    //-------------------------------------------------------------------------
    assign c3_active = own_valid && lk_rd_q && (&a_rd_rsp_valid)
                    && (a_rd_rsp_set[0] == own_set) && (a_rd_rsp_row[0] == own_row);

    wire hit0    = a_rd_rsp_line_valid[0] && (a_rd_rsp_tag[0] == own_tagx);
    wire hit1    = a_rd_rsp_line_valid[1] && (a_rd_rsp_tag[1] == own_tagx);
    wire hit0_ok = hit0 && !way_locked[0];
    wire hit1_ok = hit1 && !way_locked[1];
    wire hit_any = hit0_ok || hit1_ok;
    wire hit_way = hit1_ok;                 // 1 = way1
    wire safe    = !wb_vis_block;

    wire load_hit  = c3_active && !own_kill && !own_store && safe && hit_any && !mshr_any;
    wire store_hit = c3_active && !own_kill &&  own_store && safe && hit_any && !mshr_any
                  && !psw_valid;

    // Victim choice for a miss: LRU way first, the other way when the LRU way is
    // locked / has an un-fired store write (memory.md 6.3/6.4).
    // Victim = the Way that is NOT the most recently used one (explicit one-hot
    // masks; a replicated bit would select BOTH ways and duplicate the line).
    wire [1:0] vic_pri = lru_last_way ? 2'b01 : 2'b10;
    wire [1:0] vic_alt = ~vic_pri;
    wire [1:0] psw_blocks = psw_way & {2{psw_valid && (psw_set == own_set)}};
    wire [1:0] vic_ok_pri = vic_pri & ~way_locked & ~psw_blocks;
    wire [1:0] vic_ok_alt = vic_alt & ~way_locked & ~psw_blocks;
    wire       vic_valid  = (|vic_ok_pri) || (|vic_ok_alt);
    wire [1:0] vic_way    = (|vic_ok_pri) ? vic_ok_pri : vic_ok_alt;
    wire       vic_dirty  = a_rd_rsp_line_valid[vic_way[1]] && a_rd_rsp_dirty[vic_way[1]];

    wire [1:0] wb_idx  = wb_free_mask[0] ? 2'd0 : 2'd1;
    wire       wb_ok   = (!vic_dirty) || (|wb_free_mask);

    // A request whose line is already resident but NOT usable right now (the
    // Way is locked by an in-flight MSHR, or the line is still held by the WB
    // before its writeback became visible) must RETRY: allocating a second copy
    // in the other Way would duplicate the line and could serve stale data
    // (memory.md 6.3 "命中锁定的旧 Victim / 不可见 WB Line 一律 RETRY",
    //  6.6 "不从下层读回旧数据").
    wire hit_tag_locked = (hit0 && way_locked[0]) || (hit1 && way_locked[1]);
    wire miss    = c3_active && !own_kill && !hit_any && !hit_tag_locked
                && !mshr_any && safe;
    wire can_resv = miss && vic_valid && wb_ok && mshr_resv_ready;

    wire merge_valid_c = c3_active && !own_kill && !own_store && mshr_any;
    wire ovl_valid_c   = c3_active && !own_kill &&  own_store && mshr_any;
    wire merge_ok      = merge_valid_c && mshr_merge_ready;
    wire ovl_ok        = ovl_valid_c && mshr_ovl_ready;

    wire act_done = own_kill || load_hit || store_hit || merge_ok || ovl_ok || can_resv;

    //-------------------------------------------------------------------------
    // Handshakes / MSHR requests
    //-------------------------------------------------------------------------
    assign lq_lookup_ready = new_req && lq_sel && lk_rd;
    assign store_start     = new_req && sq_sel && lk_rd;

    assign mshr_match_line_addr = own_valid ? own_line : lk_line;

    assign mshr_resv_valid        = can_resv;
    assign mshr_resv_line_addr    = own_line;
    assign mshr_resv_way          = vic_way;
    assign mshr_resv_victim_dirty = vic_dirty;
    assign mshr_resv_wb_idx       = wb_idx;
    assign mshr_resv_is_store     = own_store;
    assign mshr_resv_lq_idx       = own_idx[1:0];
    assign mshr_resv_lq_tag       = own_tag;
    assign mshr_resv_lq_epoch     = own_epoch;
    assign mshr_resv_word_idx     = own_widx;
    assign mshr_resv_store_mask   = own_mask;
    assign mshr_resv_store_data   = own_data;
    assign mshr_resv_store_widx   = own_widx;

    assign mshr_merge_valid       = merge_valid_c;
    assign mshr_merge_sel         = mshr_match_hit;
    assign mshr_merge_is_store    = 1'b0;
    assign mshr_merge_lq_idx      = own_idx[1:0];
    assign mshr_merge_lq_tag      = own_tag;
    assign mshr_merge_lq_epoch    = own_epoch;
    assign mshr_merge_word_idx    = own_widx;
    assign mshr_merge_store_mask  = own_mask;
    assign mshr_merge_store_data  = own_data;
    assign mshr_merge_store_widx  = own_widx;

    assign mshr_ovl_valid         = ovl_valid_c;
    assign mshr_ovl_sel           = mshr_match_hit;
    assign mshr_ovl_widx          = own_widx;
    assign mshr_ovl_mask          = own_mask;
    assign mshr_ovl_data          = own_data;

    assign wb_alloc_valid     = can_resv && vic_dirty;
    assign wb_alloc_idx       = wb_idx;
    assign wb_alloc_line_addr = {a_rd_rsp_tag[vic_way[1]], own_set, {OFF{1'b0}}};
    assign wb_vis_query       = own_line;

    //-------------------------------------------------------------------------
    // Results / takeover
    //-------------------------------------------------------------------------
    wire [31:0] hit_word = own_addr[2] ? a_rd_rsp_data[hit_way][63:32]
                                      : a_rd_rsp_data[hit_way][31:0];

    assign hit_fill_valid = load_hit;
    assign hit_fill_idx   = own_idx[1:0];
    assign hit_fill_word  = hit_word;

    assign store_takeover = psw_fire
                         || ovl_ok
                         || (can_resv && own_store);

    //-------------------------------------------------------------------------
    // LRU update (single write port; hit > store write > installs)
    //-------------------------------------------------------------------------
    wire pub_way_sel = mshr_pub_valid[1] ? mshr_pub_way[1][1] : mshr_pub_way[0][1];

    always_comb begin
        if (load_hit || store_hit) begin
            lru_valid_w = 1'b1;
            lru_set_w   = own_set;
            lru_way_w   = hit_way;
        end else if (psw_fire) begin
            lru_valid_w = 1'b1;
            lru_set_w   = psw_set;
            lru_way_w   = psw_way[1];
        end else if (|mshr_pub_valid) begin
            lru_valid_w = 1'b1;
            lru_set_w   = mshr_pub_valid[1] ? lock_set[1] : lock_set[0];
            lru_way_w   = pub_way_sel;
        end else begin
            lru_valid_w = 1'b0;
            lru_set_w   = '0;
            lru_way_w   = 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Sequential state
    //-------------------------------------------------------------------------
    logic [MSHRN-1:0] cap_deny_now;
    logic [1:0]       inst_deny_now;

    always_comb begin
        cap_deny_now = '0;
        for (int unsigned i = 0; i < MSHRN; i++) begin
            if (mshr_cap_req_valid[i] && !cap_gnt_comb[i]) cap_deny_now[i] = 1'b1;
        end
        for (int unsigned w = 0; w < WAYS; w++) begin
            inst_deny_now[w] = inst_want_way[w] && !inst_gnt_w[w];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            own_valid      <= 1'b0;
            own_rd_pending <= 1'b0;
            own_store      <= 1'b0;
            own_idx        <= 3'd0;
            own_tag        <= '0;
            own_addr       <= 32'd0;
            own_data       <= 32'd0;
            own_mask       <= 4'd0;
            own_epoch      <= 8'd0;
            psw_valid      <= 1'b0;
            psw_way        <= 2'd0;
            psw_set        <= '0;
            psw_row        <= '0;
            psw_data       <= 64'd0;
            psw_be         <= 8'd0;
            arb_last_store <= 1'b0;
            cap_starve     <= 2'd0;
            for (int unsigned w = 0; w < WAYS; w++) inst_deny_cnt[w] <= 2'd0;
        end else begin
            //---- C2 owner / C3 retire --------------------------------------
            if (new_req && lk_rd) begin
                own_valid      <= 1'b1;
                own_rd_pending <= 1'b0;      // the read is issued in this cycle
                own_store      <= sq_sel;
                own_idx        <= sq_sel ? sq_drain_idx : {1'b0, lq_lookup_idx};
                own_tag        <= sq_sel ? sq_drain_tag : lq_lookup_tag;
                own_addr       <= sq_sel ? sq_drain_addr : lq_lookup_addr;
                own_data       <= sq_sel ? sq_drain_data : 32'd0;
                own_mask       <= sq_sel ? sq_drain_mask : 4'd0;
                own_epoch      <= sq_sel ? 8'd0 : lq_wait_epoch[lq_lookup_idx];
                arb_last_store <= sq_sel;
            end else if (own_valid && c3_active && act_done) begin
                own_valid      <= 1'b0;
                own_rd_pending <= 1'b0;
            end else if (own_valid) begin
                if (lk_rd && retry_read) begin
                    own_rd_pending <= 1'b0;  // re-read issued
                end else if (c3_active && !act_done) begin
                    own_rd_pending <= 1'b1;  // RETRY, but the read was suppressed
                end
            end

            //---- pending store write --------------------------------------
            if (psw_fire) psw_valid <= 1'b0;
            if (store_hit) begin
                psw_valid <= 1'b1;
                psw_way   <= hit_way ? 2'b10 : 2'b01;
                psw_set   <= own_set;
                psw_row   <= own_row;
                psw_data  <= {32'b0, own_data} << (32*own_addr[2]);
                psw_be    <= {4'b0, own_mask} << (4*own_addr[2]);
            end

            //---- capture starvation ---------------------------------------
            if (any_cap) begin
                cap_starve <= 2'd0;
            end else if (|cap_deny_now) begin
                cap_starve <= (cap_starve == 2'd3) ? 2'd3 : (cap_starve + 2'd1);
            end

            //---- install starvation ---------------------------------------
            for (int unsigned w = 0; w < WAYS; w++) begin
                if (inst_gnt_w[w])         inst_deny_cnt[w] <= 2'd0;
                else if (inst_deny_now[w]) inst_deny_cnt[w] <= (inst_deny_cnt[w] == 2'd3)
                                                            ? 2'd3 : (inst_deny_cnt[w] + 2'd1);
            end
        end
    end

`ifdef CONFIG_SIMULATION
    a_single_owner: assert property (@(posedge clk) disable iff (rst)
        !(own_valid && new_req && lk_rd));

    a_lq_ready: assert property (@(posedge clk) disable iff (rst)
        lq_lookup_ready |-> !own_valid);
    a_store_start: assert property (@(posedge clk) disable iff (rst)
        store_start |-> !own_valid);

    a_takeover_src: assert property (@(posedge clk) disable iff (rst)
        store_takeover |-> (psw_fire || ovl_ok || (can_resv && own_store)));

    a_fill_load: assert property (@(posedge clk) disable iff (rst)
        hit_fill_valid |-> (!own_store && !own_kill));

    a_hit_safe: assert property (@(posedge clk) disable iff (rst)
        (load_hit || store_hit) |-> (safe && !mshr_any));

    a_cap_gnt: assert property (@(posedge clk) disable iff (rst)
        |mshr_cap_gnt |-> (|mshr_cap_req_valid));

    a_pw_no_read_race: assert property (@(posedge clk) disable iff (rst)
        psw_fire |-> !(lk_rd && (lk_set == psw_set) && (lk_row == psw_row)));

    a_inst_one_per_way: assert property (@(posedge clk) disable iff (rst)
        !(inst_gnt_comb[0] && inst_gnt_comb[1]
          && (|(mshr_inst_way[0] & mshr_inst_way[1]))));

    a_meta_one_per_way: assert property (@(posedge clk) disable iff (rst)
        !(psw_fire && (mshr_pub_valid[0] && mshr_pub_way[0][psw_way[1]])));

    a_pub_is_last0: assert property (@(posedge clk) disable iff (rst)
        mshr_pub_valid[0] |-> mshr_inst_last[0]);
    a_pub_is_last1: assert property (@(posedge clk) disable iff (rst)
        mshr_pub_valid[1] |-> mshr_inst_last[1]);
`endif

endmodule


