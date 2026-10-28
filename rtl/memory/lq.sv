//=============================================================================
// ARES LSU - 4-entry Load Queue (L03)
//-----------------------------------------------------------------------------
// Bitmap-allocated, out-of-order-completing load queue.  Each entry advances
// independently through:
//
//   alloc (issue, atomic reservation of the slot)
//     -> AGU registration (addr / size / byte mask / is_mmio)
//     -> forwarding snapshot confirmation (first cycle with dep_ready == 1)
//          . full forward   : result is produced WITHOUT any DCache lookup
//          . partial forward: DCache lookup -> fill -> merge forwarded bytes
//     -> MMIO loads wait for the Commit Head, then use one device read
//     -> result_valid -> Completion handshake -> release
//
// Only "Completion actually fired" or "Flush kill" releases an entry
// (memory.md 4.1 / 7): an entry whose result is pending still occupies the
// queue, so the load credit is not returned early.
//
// Spec sources : docs/microarch/memory.md 3.1 (uncached MMIO Load),
//                4.1 (LQ lifetime / oldest-serviceable arbitration),
//                4.2 (older_store_mask + forwarding snapshot visibility),
//                6.2 / 6.3, 7 (single completion owner / fast path),
//                8 (flush and old-response isolation).
// Interface    : rtl/memory/LSU_INTERFACES.md section 3 (plus section 0
//                common rules and section 8 verification requirements).
// FREE items   : FREE-02 (file organisation), FREE-04 (parallel per-entry
//                compare, short arbitration trees), plus the local
//                FREE-05-style choices documented below.
//
// Local implementation choices (contract preserving):
//   * One store_forward instance per LQ entry: every entry owns its own
//     dep_ready / fwd_mask / fwd_data, so an entry takes its snapshot on the
//     first cycle its own dependency set is ready, independently of the
//     arbiter (memory.md 4.2).
//   * An un-accepted lookup request is HELD (payload frozen) until
//     lookup_ready: a valid/ready payload must not change before ready.  If
//     the held entry is killed, the request is dropped for one cycle instead
//     of being re-pointed mid-flight.
//   * The completion arbiter picks the lowest occupied entry index; any entry
//     with a latched result may complete (out-of-order completion).
//   * lq_alloc_idx exports the lowest free slot (valid when !lq_full) so that
//     lsu_top can reserve a slot at issue without duplicating the bitmap.
//   * At most one MMIO request is outstanding in the LQ: a new device read is
//     postponed while another entry still waits for its response
//     (memory.md 3.1: one MMIO transaction at a time).
//
// Build / lint (repository root, explicit file list - one line per command):
// cmd: verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module lq rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/store_forward.sv rtl/memory/lq.sv
//
// Self-check bench (rtl/memory/test/unit/tb_lq.sv):
// cmd: verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lq --Mdir sim/build/unit/tb_lq -o tb_lq rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/store_forward.sv rtl/memory/lq.sv rtl/memory/test/unit/tb_lq.sv
//   sim/build/unit/tb_lq/tb_lq    (-o must be a file NAME: the generated make runs inside --Mdir)
//=============================================================================
module lq (
    input  logic                            clk,
    input  logic                            rst,

    //---- issue allocation (atomic reservation) ----------------------------
    input  logic                            alloc_valid,
    input  logic [1:0]                      alloc_idx,       // free slot from lsu_top
    input  ares_pkg::tag_t                  alloc_tag,

    //---- AGU registration -------------------------------------------------
    input  logic                            agu_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // LQ slot is agu_qidx[1:0] (LSU_INTERFACES 3 item 2)
    input  logic [2:0]                      agu_qidx,
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */  // carried for symmetry; cross-checked by a sim assertion
    input  ares_pkg::tag_t                  agu_tag,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0]                     agu_addr,
    input  lsu_pkg::lsu_size_t              agu_size,
    input  logic [3:0]                      agu_byte_mask,
    input  logic                            agu_is_unsigned,
    input  logic                            agu_is_mmio,

    //---- SQ state (mask + forwarding + head) ------------------------------
    input  logic [7:0]                      sq_occupied,
    input  logic [7:0]                      sq_takeover,
    input  logic [7:0]                      sq_addr_valid,
    input  logic [7:0][31:0]                sq_addr,
    input  logic [7:0][31:0]                sq_data,
    input  logic [7:0][3:0]                 sq_byte_mask,
    input  logic [7:0]                      sq_is_mmio,
    input  logic [2:0]                      sq_head_ptr,
    input  logic [3:0]                      sq_occupancy,

    //---- DCache read request (oldest serviceable load, one at a time) -----
    output logic                            lookup_valid,
    input  logic                            lookup_ready,
    output logic [1:0]                      lookup_idx,
    output ares_pkg::tag_t                  lookup_tag,
    output logic [31:0]                     lookup_addr,
    output lsu_pkg::lsu_size_t              lookup_size,   // size of lookup_idx

    //---- data return ------------------------------------------------------
    input  logic                            fill_valid,
    input  logic [1:0]                      fill_idx,
    input  logic [31:0]                     fill_word,

    //---- early speculative probe return -----------------------------------
    input  logic                            probe_fill_valid,
    input  logic [1:0]                      probe_fill_idx,
    input  logic [31:0]                     probe_fill_word,
    input  ares_pkg::tag_t                  probe_fill_tag,

    //---- MMIO load (Head-only, one device read) ---------------------------
    input  logic                            load_head_valid,
    input  ares_pkg::tag_t                  load_head_tag,
    output logic                            mmio_req_valid,
    input  logic                            mmio_req_ready,
    output logic [31:0]                     mmio_req_addr,   // word aligned
    input  logic                            mmio_rsp_valid,
    input  logic [31:0]                     mmio_rsp_data,

    //---- Completion (ownership to L12) ------------------------------------
    output logic                            compl_valid,
    input  logic                            compl_ready,
    output ares_pkg::tag_t                  compl_tag,
    output logic [31:0]                     compl_result,

    //---- Flush ------------------------------------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,

    //---- M2b waiter tokens (D-M2b-04: additive read-only outputs) ----------
    output logic [ares_pkg::LQ_ENTRIES-1:0] lq_wait_pending,   // == e_lk_inflight[i]
    output ares_pkg::tag_t                  lq_wait_tag [ares_pkg::LQ_ENTRIES],
    output logic [7:0]                      lq_wait_epoch [ares_pkg::LQ_ENTRIES],

    //---- status / allocation index ----------------------------------------
    output logic [1:0]                      lq_alloc_idx,    // lowest free slot (!lq_full)
    output logic [2:0]                      lq_used,
    output logic                            lq_full
);
    import ares_pkg::*;
    import lsu_pkg::*;

    //-------------------------------------------------------------------------
    // Per-entry state (memory.md 4.1)
    //-------------------------------------------------------------------------
    logic                     e_alive       [LQ_ENTRIES];
    logic [CIQ_SLOT_BITS-1:0] e_tag         [LQ_ENTRIES];
    logic                     e_addr_valid  [LQ_ENTRIES];
    logic [ADDR_WIDTH-1:0]    e_addr        [LQ_ENTRIES];
    lsu_size_t                e_size        [LQ_ENTRIES];
    logic [3:0]               e_byte_mask   [LQ_ENTRIES];
    logic                     e_unsigned    [LQ_ENTRIES];
    logic                     e_mmio        [LQ_ENTRIES];
    logic [7:0]               e_older       [LQ_ENTRIES];  // older store mask
    logic                     e_snap_valid  [LQ_ENTRIES];  // forwarding snapshot valid
    logic [3:0]               e_snap_mask   [LQ_ENTRIES];
    logic [31:0]              e_snap_data   [LQ_ENTRIES];
    logic                     e_lk_inflight [LQ_ENTRIES];  // lookup accepted, fill owed
    logic                     e_result_vld  [LQ_ENTRIES];  // result latched, completion owed
    logic [31:0]              e_result      [LQ_ENTRIES];
    logic                     e_mmio_sent   [LQ_ENTRIES];  // device read issued once
    logic [7:0]               e_epoch       [LQ_ENTRIES];  // allocation generation

    //-------------------------------------------------------------------------
    // Allocation-order list: ord[0] is the OLDEST live load; arbitrary entries
    // can be removed (memory.md 4.1 "4-entry LQ allocation order table").
    //-------------------------------------------------------------------------
    logic [1:0]  ord     [LQ_ENTRIES];
    logic [2:0]  ord_cnt;

    //-------------------------------------------------------------------------
    // One byte-wise forwarding compare per entry (L05 store_forward).
    //-------------------------------------------------------------------------
    logic [3:0]  fwd_mask_c [LQ_ENTRIES];
    logic [31:0] fwd_data_c [LQ_ENTRIES];
    logic        dep_ready_c[LQ_ENTRIES];

    for (genvar g = 0; g < LQ_ENTRIES; g++) begin : g_forward
        store_forward u_store_forward (
            .load_addr      (e_addr[g]),
            .load_byte_mask (e_byte_mask[g]),
            .older_mask     (e_older[g]),
            .sq_occupied    (sq_occupied),
            .sq_addr_valid  (sq_addr_valid),
            .sq_addr        (sq_addr),
            .sq_data        (sq_data),
            .sq_byte_mask   (sq_byte_mask),
            .sq_is_mmio     (sq_is_mmio),
            .sq_head_ptr    (sq_head_ptr),
            .sq_occupancy   (sq_occupancy),
            .fwd_mask       (fwd_mask_c[g]),
            .fwd_data       (fwd_data_c[g]),
            .dep_ready      (dep_ready_c[g])
        );
    end

    //-------------------------------------------------------------------------
    // Completion election: the lowest occupied entry index with a latched
    // result that is not killed this cycle (kill beats completion).
    //-------------------------------------------------------------------------
    logic [LQ_ENTRIES-1:0] compl_req;
    logic                  compl_valid_c;
    logic [1:0]            compl_idx;
    logic                  compl_fire;

    always_comb begin
        for (int unsigned i = 0; i < LQ_ENTRIES; i++)
            compl_req[i] = e_alive[i] && e_result_vld[i] && !kill_mask[e_tag[i]];
    end

    always_comb begin
        compl_valid_c = 1'b0;
        compl_idx     = 2'd0;
        for (int k = LQ_ENTRIES-1; k >= 0; k--) begin
            if (compl_req[k]) begin
                compl_valid_c = 1'b1;
                compl_idx     = k[1:0];
            end
        end
    end

    assign compl_fire = compl_valid_c && compl_ready;

    //-------------------------------------------------------------------------
    // Release: real Completion handshake or Flush kill (kill wins).
    //-------------------------------------------------------------------------
    logic [LQ_ENTRIES-1:0] rel_entry;

    always_comb begin
        for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
            logic [1:0] si;
            si = i[1:0];
            rel_entry[i] = e_alive[i]
                      && (kill_mask[e_tag[i]] || (compl_fire && (compl_idx == si)));
        end
    end

    //-------------------------------------------------------------------------
    // Per-entry derived conditions (pure combinational; release/ord do not
    // depend on these, so there is no combinational loop).
    //-------------------------------------------------------------------------
    logic        snap_now    [LQ_ENTRIES];  // latch the forwarding snapshot now
    logic        ff_now      [LQ_ENTRIES];  // full forward -> result, no lookup
    logic [31:0] ff_result   [LQ_ENTRIES];
    logic [31:0] fill_result [LQ_ENTRIES];
    logic [31:0] probe_fill_result [LQ_ENTRIES];
    logic [31:0] mmio_result [LQ_ENTRIES];
    logic        agu_reg_now [LQ_ENTRIES];
    logic        lookup_elig [LQ_ENTRIES];
    logic        mmio_elig   [LQ_ENTRIES];

    // Block 1: entry state conditions ONLY.  It must not depend on any data
    // input (fill_word / mmio_rsp_data), otherwise Verilator's block-level
    // dependency analysis would close a combinational loop
    //   lq lookup -> dcache_top -> mshr -> lq fill.
    always_comb begin
        for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
            logic [3:0]  fm;
            logic [1:0]  si;
            si = i[1:0];

            // memory.md 4.2: the snapshot is frozen once confirmed; takeover,
            // drain and SQ slot reuse must not change it.
            fm = e_snap_valid[i] ? e_snap_mask[i] : fwd_mask_c[i];

            // memory.md 4.1/4.2: the snapshot is confirmed on the first cycle
            // the entry owns an address and every older store is ready.
            snap_now[i] = e_alive[i] && e_addr_valid[i] && !e_mmio[i]
                       && !e_snap_valid[i] && dep_ready_c[i] && !rel_entry[i];

            // memory.md 4.2 item 3/4: fully forwarded bytes produce the result
            // without a lookup and without occupying an MSHR.
            ff_now[i] = snap_now[i] && ((fm & e_byte_mask[i]) == e_byte_mask[i]);

            agu_reg_now[i] = agu_valid && (agu_qidx[1:0] == si)
                          && e_alive[i] && !rel_entry[i];

            // LSU_INTERFACES 3 item 4: oldest entry with a registered address,
            // ready dependencies, no lookup in flight and no result yet.
            lookup_elig[i] = e_alive[i] && e_addr_valid[i] && !e_mmio[i]
                          && !e_lk_inflight[i] && !e_result_vld[i]
                          && !(probe_fill_valid && (probe_fill_idx == si)
                               && (probe_fill_tag.slot_index == e_tag[i])
                               && (e_older[i] == '0) && !e_snap_valid[i])
                          && dep_ready_c[i] && !ff_now[i] && !rel_entry[i];

            // LSU_INTERFACES 3 item 8: Head-only single device read, every
            // older store already handed over.
            mmio_elig[i] = e_alive[i] && e_addr_valid[i] && e_mmio[i]
                        && !e_mmio_sent[i] && (e_older[i] == 8'd0)
                        && load_head_valid
                        && (load_head_tag.slot_index == e_tag[i])
                        && !rel_entry[i];
        end
    end

    // Block 2: data merge results (do NOT feed back into the lookup decision).
    always_comb begin
        for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
            logic [3:0]  fm;
            logic [31:0] fd;
            fm = e_snap_valid[i] ? e_snap_mask[i] : fwd_mask_c[i];
            fd = e_snap_valid[i] ? e_snap_data[i] : fwd_data_c[i];

            ff_result[i] = lsu_merge_extract(32'd0, fwd_mask_c[i], fwd_data_c[i],
                                             e_unsigned[i], e_addr[i][1:0], e_size[i]);

            // memory.md 4.2 item 4: forwarded bytes win over the DCache word,
            // then LB/LH/LW/LBU/LHU select + sign/zero extension.
            fill_result[i] = lsu_merge_extract(fill_word, fm, fd,
                                               e_unsigned[i], e_addr[i][1:0], e_size[i]);
            probe_fill_result[i] = lsu_merge_extract(probe_fill_word, 4'd0, 32'd0,
                                                     e_unsigned[i], e_addr[i][1:0], e_size[i]);

            // memory.md 3.1: a MMIO result comes from the device word only.
            mmio_result[i] = lsu_merge_extract(mmio_rsp_data, 4'd0, 32'd0,
                                               e_unsigned[i], e_addr[i][1:0], e_size[i]);
        end
    end

    //-------------------------------------------------------------------------
    // Lookup arbitration: OLDEST eligible entry of the age list.
    //-------------------------------------------------------------------------
    logic        lk_arb_valid;
    logic [1:0]  lk_arb_idx;
    logic        lk_hold_valid;   // un-accepted request is held stable
    logic [1:0]  lk_hold_idx;
    logic        lk_hold_ok;
    logic        lk_sel_valid;
    logic [1:0]  lk_sel_idx;

    always_comb begin
        lk_arb_valid = 1'b0;
        lk_arb_idx   = 2'd0;
        for (int k = LQ_ENTRIES-1; k >= 0; k--) begin
            if ((k[2:0] < ord_cnt) && lookup_elig[ord[k]]) begin
                lk_arb_valid = 1'b1;
                lk_arb_idx   = ord[k];
            end
        end
    end

    assign lk_hold_ok   = lk_hold_valid && lookup_elig[lk_hold_idx];
    assign lk_sel_valid = lk_hold_ok || (!lk_hold_valid && lk_arb_valid);
    assign lk_sel_idx   = lk_hold_ok ? lk_hold_idx : lk_arb_idx;

    assign lookup_valid = lk_sel_valid;
    assign lookup_idx   = lk_sel_valid ? lk_sel_idx : 2'd0;
    assign lookup_addr  = lk_sel_valid ? e_addr[lk_sel_idx] : 32'd0;
    assign lookup_size  = lk_sel_valid ? e_size[lk_sel_idx] : LSZ_BYTE;

    always_comb begin
        lookup_tag.slot_index = lk_sel_valid ? e_tag[lk_sel_idx] : '0;
    end

    //-------------------------------------------------------------------------
    // MMIO arbitration: at most one entry can match the Commit Head tag, so
    // the payload is inherently stable while valid.
    //-------------------------------------------------------------------------
    logic        mmio_arb_valid;
    logic [1:0]  mmio_arb_idx;
    logic        mmio_pending;

    always_comb begin
        mmio_arb_valid = 1'b0;
        mmio_arb_idx   = 2'd0;
        for (int k = LQ_ENTRIES-1; k >= 0; k--) begin
            if ((k[2:0] < ord_cnt) && mmio_elig[ord[k]]) begin
                mmio_arb_valid = 1'b1;
                mmio_arb_idx   = ord[k];
            end
        end
    end

    always_comb begin
        mmio_pending = 1'b0;
        for (int unsigned i = 0; i < LQ_ENTRIES; i++)
            mmio_pending = mmio_pending || (e_alive[i] && e_mmio_sent[i] && !rel_entry[i]);
    end

    assign mmio_req_valid = mmio_arb_valid && !mmio_pending;
    assign mmio_req_addr  = {e_addr[mmio_arb_idx][31:2], 2'b00};

    //-------------------------------------------------------------------------
    // Completion outputs.
    //-------------------------------------------------------------------------
    assign compl_valid  = compl_valid_c;
    assign compl_result = e_result[compl_idx];

    always_comb begin
        compl_tag.slot_index = e_tag[compl_idx];
    end

    //-------------------------------------------------------------------------
    // Age-list compaction (combinationally prepared for the next state).
    //-------------------------------------------------------------------------
    logic [2:0]  surv_cnt;
    logic [1:0]  surv [LQ_ENTRIES];

    always_comb begin
        surv_cnt = 3'd0;
        for (int unsigned k = 0; k < LQ_ENTRIES; k++) begin
            surv[k] = 2'd0;
            if ((k[2:0] < ord_cnt) && !rel_entry[ord[k]]) begin
                surv[surv_cnt[1:0]] = ord[k];
                surv_cnt       = surv_cnt + 3'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Sequential state.
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
                e_alive[i]       <= 1'b0;
                e_tag[i]         <= '0;
                e_addr_valid[i]  <= 1'b0;
                e_addr[i]        <= '0;
                e_size[i]        <= LSZ_BYTE;
                e_byte_mask[i]   <= '0;
                e_unsigned[i]    <= 1'b0;
                e_mmio[i]        <= 1'b0;
                e_older[i]       <= '0;
                e_snap_valid[i]  <= 1'b0;
                e_snap_mask[i]   <= '0;
                e_snap_data[i]   <= '0;
                e_lk_inflight[i] <= 1'b0;
                e_result_vld[i]  <= 1'b0;
                e_result[i]      <= '0;
                e_mmio_sent[i]   <= 1'b0;
            end
            ord_cnt <= 3'd0;
            for (int unsigned k = 0; k < LQ_ENTRIES; k++) begin
                ord[k]     <= 2'd0;
                e_epoch[k] <= 8'd0;
            end
            lk_hold_valid <= 1'b0;
            lk_hold_idx   <= 2'd0;
        end else begin
            for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
                logic [1:0] si;
                si = i[1:0];

                if (alloc_valid && (alloc_idx == si)) begin
                    // New lifetime.  memory.md 4.2: the older store mask is
                    // latched at issue time from the SQ state of this cycle;
                    // younger stores never join an existing mask.
                    e_alive[i]       <= 1'b1;
                    e_tag[i]         <= alloc_tag.slot_index;
                    e_addr_valid[i]  <= 1'b0;
                    e_addr[i]        <= '0;
                    e_size[i]        <= LSZ_BYTE;
                    e_byte_mask[i]   <= '0;
                    e_unsigned[i]    <= 1'b0;
                    e_mmio[i]        <= 1'b0;
                    e_older[i]       <= sq_occupied & ~sq_takeover;
                    e_snap_valid[i]  <= 1'b0;
                    e_snap_mask[i]   <= '0;
                    e_snap_data[i]   <= '0;
                    e_lk_inflight[i] <= 1'b0;
                    e_result_vld[i]  <= 1'b0;
                    e_result[i]      <= '0;
                    e_mmio_sent[i]   <= 1'b0;
                    // New lifetime: bump the generation so a stale MSHR waiter
                    // can never be handed to this (reused) slot (D-M2b-04).
                    e_epoch[i]       <= e_epoch[i] + 8'd1;
                end else if (rel_entry[i]) begin
                    // Completion fired or Flush kill.  Kill beats a same-cycle
                    // fill / result: the pending state is dropped without a
                    // completion ever being produced.
                    e_alive[i]       <= 1'b0;
                    e_addr_valid[i]  <= 1'b0;
                    e_snap_valid[i]  <= 1'b0;
                    e_lk_inflight[i] <= 1'b0;
                    e_result_vld[i]  <= 1'b0;
                    e_mmio_sent[i]   <= 1'b0;
                end else if (e_alive[i]) begin
                    if (agu_reg_now[i]) begin
                        e_addr_valid[i] <= 1'b1;
                        e_addr[i]       <= agu_addr;
                        e_size[i]       <= agu_size;
                        e_byte_mask[i]  <= agu_byte_mask;
                        e_unsigned[i]   <= agu_is_unsigned;
                        e_mmio[i]       <= agu_is_mmio;
                    end

                    if (lk_sel_valid && lookup_ready && (lk_sel_idx == si))
                        e_lk_inflight[i] <= 1'b1;

                    if (mmio_req_valid && mmio_req_ready && (mmio_arb_idx == si))
                        e_mmio_sent[i] <= 1'b1;

                    if (probe_fill_valid && (probe_fill_idx == si)
                        && (probe_fill_tag.slot_index == e_tag[i])
                        && !e_result_vld[i] && !e_lk_inflight[i]
                        && (e_older[i] == '0) && !e_snap_valid[i]) begin
                        // Early speculative probe hit: complete without a
                        // normal lookup.  e_older must be empty because the
                        // probe bypasses the normal forwarding snapshot.
                        e_snap_valid[i]  <= 1'b1;
                        e_snap_mask[i]   <= 4'd0;
                        e_snap_data[i]   <= 32'd0;
                        e_result_vld[i]  <= 1'b1;
                        e_result[i]      <= probe_fill_result[i];
                        e_lk_inflight[i] <= 1'b0;
                    end else if (ff_now[i]) begin
                        e_snap_valid[i] <= 1'b1;
                        e_snap_mask[i]  <= fwd_mask_c[i];
                        e_snap_data[i]  <= fwd_data_c[i];
                        e_result_vld[i] <= 1'b1;
                        e_result[i]     <= ff_result[i];
                    end else if (snap_now[i]) begin
                        e_snap_valid[i] <= 1'b1;
                        e_snap_mask[i]  <= fwd_mask_c[i];
                        e_snap_data[i]  <= fwd_data_c[i];
                    end else if (fill_valid && (fill_idx == si) && e_lk_inflight[i]) begin
                        // A stale response for a reused slot cannot land here:
                        // a fresh entry always starts with inflight cleared.
                        e_result_vld[i]  <= 1'b1;
                        e_result[i]      <= fill_result[i];
                        e_lk_inflight[i] <= 1'b0;
                    end else if (mmio_rsp_valid && e_mmio_sent[i]) begin
                        e_result_vld[i] <= 1'b1;
                        e_result[i]     <= mmio_result[i];
                        e_mmio_sent[i]  <= 1'b0;
                    end

                    // memory.md 4.2: every live entry drops the bits of stores
                    // that take over this cycle; the snapshot keeps its data.
                    e_older[i] <= e_older[i] & ~sq_takeover;
                end
            end

            //-----------------------------------------------------------------
            // Age list: compact the survivors, append a new allocation as the
            // youngest entry.
            //-----------------------------------------------------------------
            for (int unsigned m = 0; m < LQ_ENTRIES; m++) begin
                if (m[2:0] < surv_cnt)
                    ord[m] <= surv[m];
                else if (alloc_valid && (m[2:0] == surv_cnt))
                    ord[m] <= alloc_idx;
                else
                    ord[m] <= 2'd0;
            end
            ord_cnt <= surv_cnt + (alloc_valid ? 3'd1 : 3'd0);

            //-----------------------------------------------------------------
            // Lookup hold: keep the payload stable until it is accepted.
            //-----------------------------------------------------------------
            if (lk_sel_valid && lookup_ready) begin
                lk_hold_valid <= 1'b0;
                lk_hold_idx   <= 2'd0;
            end else if (lk_sel_valid) begin
                lk_hold_valid <= 1'b1;
                lk_hold_idx   <= lk_sel_idx;
            end else begin
                lk_hold_valid <= 1'b0;
                lk_hold_idx   <= 2'd0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Status: occupancy, full flag and the lowest free slot for lsu_top.
    //-------------------------------------------------------------------------
    logic [2:0] alive_cnt;

    always_comb begin
        alive_cnt = 3'd0;
        for (int unsigned i = 0; i < LQ_ENTRIES; i++)
            alive_cnt = alive_cnt + {2'b0, e_alive[i]};
    end

    always_comb begin
        lq_alloc_idx = 2'd0;
        for (int k = LQ_ENTRIES-1; k >= 0; k--)
            if (!e_alive[k])
                lq_alloc_idx = k[1:0];
    end

    assign lq_used = alive_cnt;
    assign lq_full = (alive_cnt == 3'(LQ_ENTRIES));

    //-------------------------------------------------------------------------
    // M2b waiter tokens (D-M2b-04): a pure observation of the registered entry
    // state, used by mshr to drop stale waiters (idx + tag + epoch match).
    //-------------------------------------------------------------------------
    for (genvar gw = 0; gw < LQ_ENTRIES; gw++) begin : g_wait_token
        assign lq_wait_pending[gw] = e_lk_inflight[gw];
        assign lq_wait_tag[gw]     = e_tag[gw];
        assign lq_wait_epoch[gw]   = e_epoch[gw];
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Assertions (LSU_INTERFACES.md section 3 item 12 + section 8).
    //-------------------------------------------------------------------------
    logic dbg_compl_done [LQ_ENTRIES];
    logic dbg_lookup_done[LQ_ENTRIES];

    always_comb begin
        for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
            if (e_alive[i])
                a_older_mask_live: assert ((e_older[i] & ~sq_occupied) == 8'd0);
            a_no_inflight_with_result: assert (!(e_lk_inflight[i] && e_result_vld[i]));
            if (e_lk_inflight[i])
                a_lookup_needs_snapshot: assert (e_snap_valid[i]);
            if (e_result_vld[i])
                a_result_has_source: assert (e_snap_valid[i] || e_mmio[i]);
        end
        if (!lq_full)
            a_alloc_idx_free: assert (!e_alive[lq_alloc_idx]);
        a_compl_not_killed: assert (!(compl_valid_c && kill_mask[compl_tag.slot_index]));
        a_ord_count: assert (ord_cnt == alive_cnt);
        for (int a = 0; a < LQ_ENTRIES; a++) begin
            for (int b = a + 1; b < LQ_ENTRIES; b++) begin
                if ((a[2:0] < ord_cnt) && (b[2:0] < ord_cnt))
                    a_ord_unique: assert (ord[a] != ord[b]);
                if (e_alive[a] && e_alive[b])
                    a_tag_unique: assert (e_tag[a] != e_tag[b]);
            end
        end
        if (lookup_valid)
            a_lookup_registered: assert (e_addr_valid[lk_sel_idx] && !e_mmio[lk_sel_idx]);
        if (mmio_req_valid)
            a_mmio_head_owned: assert (load_head_valid && (e_older[mmio_arb_idx] == 8'd0));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
                dbg_compl_done[i]  <= 1'b0;
                dbg_lookup_done[i] <= 1'b0;
            end
        end else begin
            for (int unsigned i = 0; i < LQ_ENTRIES; i++) begin
                if (alloc_valid && (alloc_idx == i[1:0])) begin
                    dbg_compl_done[i]  <= 1'b0;
                    dbg_lookup_done[i] <= 1'b0;
                end else begin
                    if (compl_fire && (compl_idx == i[1:0])) begin
                        a_one_completion_per_lifetime: assert (!dbg_compl_done[i]);
                        dbg_compl_done[i] <= 1'b1;
                    end
                    if (lk_sel_valid && lookup_ready && (lk_sel_idx == i[1:0])) begin
                        a_one_lookup_per_lifetime: assert (!dbg_lookup_done[i]);
                        dbg_lookup_done[i] <= 1'b1;
                    end
                end
            end
        end
    end

    // Issue / AGU protocol cross-checks, sampled at the clock edge (before the
    // state update): an allocation must target a free slot and an AGU
    // registration must carry the slot's tag and happen exactly once.
    always_ff @(posedge clk) begin
        if (!rst && alloc_valid)
            a_no_double_alloc: assert (!e_alive[alloc_idx]);
        if (!rst && agu_valid && e_alive[agu_qidx[1:0]]) begin
            a_agu_tag_match: assert (agu_tag.slot_index == e_tag[agu_qidx[1:0]]);
            a_agu_registered_once: assert (!e_addr_valid[agu_qidx[1:0]]);
        end
    end

    // Lookup payload stability while a request is not yet accepted.
    logic        dbg_lk_v;
    logic        dbg_lk_r;
    logic [1:0]  dbg_lk_idx;
    logic [31:0] dbg_lk_addr;

    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_lk_v    <= 1'b0;
            dbg_lk_r    <= 1'b0;
            dbg_lk_idx  <= 2'd0;
            dbg_lk_addr <= 32'd0;
        end else begin
            dbg_lk_v    <= lookup_valid;
            dbg_lk_r    <= lookup_ready;
            dbg_lk_idx  <= lookup_idx;
            dbg_lk_addr <= lookup_addr;
            if (dbg_lk_v && !dbg_lk_r && lookup_valid)
                a_lookup_payload_stable: assert ((lookup_idx == dbg_lk_idx)
                                              && (lookup_addr == dbg_lk_addr));
        end
    end
`endif

endmodule
