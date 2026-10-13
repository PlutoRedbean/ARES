//=============================================================================
// ARES LSU - 2-entry MSHR: refill / victim capture / overlay / wake (L08)
//-----------------------------------------------------------------------------
// Tracks up to MSHR_ENTRIES (2) in-flight cache line misses.  A miss owns one
// MSHR entry plus one locked DCache Way of one Set for its whole lifetime
// (RESERVE ... WAKE); the reservation is exported to the C3 hazard check via
// lock_valid/lock_line_addr/lock_way and is only dropped when the entry
// returns to FREE.
//
// Per-state behaviour (memory.md 6.4, LSU_INTERFACES.md section 10):
//   FREE            resv_ready reports a free entry; a C3 MSHR_ACCEPT latches
//                   line/Way/WB slot atomically and initialises the first Load
//                   waiter or the Store overlay.  Clean victim -> READ_BEATS,
//                   Dirty victim -> RESERVE.
//   RESERVE         holds the reservation; a Dirty victim already requests its
//                   first Row on the Victim Way R port (no idle cycle).
//   VICTIM_CAPTURE  requests the victim Rows one by one (cap_req_*), matches the
//                   synchronous responses by {set,row,way} and hands every
//                   64-bit Row to the Writeback Buffer (wb_wr_*); the last Row
//                   carries wb_wr_last.  READ_BEATS is entered only after the
//                   last Row was actually written into the WB entry, never on
//                   the last R grant.
//   READ_BEATS      issues exactly one refill read (16B beat at a time on the
//                   shared bus, single outstanding read, memory.md 6.7); once
//                   every beat arrived the line is latched and
//                   refill_rsp_ready is pulsed.
//   INSTALL         writes the merged line Row by Row into the target Way
//                   (overlay bytes win over refill bytes, inst_be = FF); on the
//                   last Row grant the new Tag/Valid/Dirty and the LRU are
//                   published (pub_*).
//   WAKE            hands out one waiter per cycle (wake_valid/wake_lq_idx/
//                   wake_word).  A waiter is identified by {lq_idx, tag, epoch};
//                   a waiter whose LQ token no longer matches (kill + slot
//                   reuse) is silently dropped - the MSHR only reports the word,
//                   it never writes a LQ slot.  With no waiter left the entry
//                   returns to FREE and releases the Way lock.
//
// Overlay (memory.md 6.5): accepted in RESERVE/VICTIM_CAPTURE/READ_BEATS only.
// A committed Store that hits an in-flight line atomically stores {mask,data}
// byte wise (newer bytes win); the LQ/SQ side may then take the Store over
// early.  During INSTALL/WAKE the overlay is frozen and the line is written
// with the merged bytes and published Dirty.
//
// Structure (FREE-04): one-hot mask arithmetic for the free/grant/select
// decisions (no serial priority chains), per byte muxes for the overlay merge
// and an OR reduction to pick the served waiter.  Pipeline position (FREE-11):
// mshr is the miss slice between dcache_top C3 (resv/merge/ovl), dcache_arrays
// (cap_rsp on the Victim R port, inst_gnt on the W port), line_adapter (refill)
// and wb_buffer (wb_wr_*); it adds no externally visible latency of its own.
//
// Spec sources: docs/microarch/memory.md 6.1 (geometry), 6.4 (per cycle
//   ownership and state transitions), 6.5 (overlay / takeover / same cycle
//   rules), 6.7 (single outstanding read), 6.8 (priority and invariants);
//   rtl/memory/LSU_INTERFACES.md section 10 (frozen interface).
// FREE items: FREE-02 (file organisation), FREE-04 (combinational structure),
//   FREE-11 (internal register placement - none added).
// Self-check bench: rtl/memory/test/unit/tb_mshr.sv
//
// Build / run (repository root; explicit file list; LINE_BYTES comes from the
// configuration menu - 16 / 32 / 64, default 32, ROWS_PER_LINE/LINE_BEATS are
// derived inside ares_pkg):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//     -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module mshr \
//     rtl/common/ares_pkg.sv rtl/memory/mshr.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     --top-module tb_mshr --Mdir sim/build/unit/tb_mshr -o tb_mshr \
//     rtl/common/ares_pkg.sv rtl/memory/mshr.sv \
//     rtl/memory/test/unit/tb_mshr.sv
//   sim/build/unit/tb_mshr/tb_mshr
//   (-o is resolved against --Mdir by Verilator 5.x, so the output name must be
//    given relative to the Mdir.)
//=============================================================================
module mshr (
    input  logic                                      clk,
    input  logic                                      rst,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         lock_valid,        // held incl. WAKE
    output logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]   lock_line_addr,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    lock_way,          // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         busy,              // != FREE
    input  logic [31:0]                               match_line_addr,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         match_hit,
    input  logic                                      resv_valid,
    output logic                                      resv_ready,        // reserve_fire
    input  logic [31:0]                               resv_line_addr,
    input  logic [1:0]                                resv_way,          // one-hot victim Way
    input  logic                                      resv_victim_dirty,
    input  logic [1:0]                                resv_wb_idx,       // pre-allocated WB entry
    input  logic                                      resv_is_store,
    input  logic [1:0]                                resv_lq_idx,
    input  ares_pkg::tag_t                            resv_lq_tag,
    input  logic [7:0]                                resv_lq_epoch,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   resv_word_idx,
    input  logic [3:0]                                resv_store_mask,
    input  logic [31:0]                               resv_store_data,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   resv_store_widx,
    input  logic                                      merge_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         merge_sel,         // one-hot
    output logic                                      merge_ready,
    input  logic                                      merge_is_store,
    input  logic [1:0]                                merge_lq_idx,
    input  ares_pkg::tag_t                            merge_lq_tag,
    input  logic [7:0]                                merge_lq_epoch,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   merge_word_idx,
    input  logic [3:0]                                merge_store_mask,
    input  logic [31:0]                               merge_store_data,
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   merge_store_widx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         cap_req_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    cap_req_way,       // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_req_row,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         cap_gnt,           // R accepted, rsp next cycle
    input  logic                                      cap_rsp_valid,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    cap_rsp_set,
    input  logic [$clog2(ares_pkg::ROWS_PER_LINE)-1:0] cap_rsp_row,
    input  logic [1:0]                                cap_rsp_way,       // one-hot
    input  logic [63:0]                               cap_rsp_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wb_wr_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    wb_wr_idx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] wb_wr_row,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]   wb_wr_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wb_wr_last,        // last Row -> WB READY
    input  logic                                      ovl_valid,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         ovl_sel,           // one-hot
    output logic                                      ovl_ready,         // accepted -> Early Takeover
    input  logic [ares_pkg::DCACHE_OFFSET_BITS-3:0]   ovl_widx,
    input  logic [3:0]                                ovl_mask,
    input  logic [31:0]                               ovl_data,
    output logic                                      refill_req_valid,
    input  logic                                      refill_req_ready,
    output logic [31:0]                               refill_line_addr,
    input  logic                                      refill_rsp_valid,
    output logic                                      refill_rsp_ready,
    input  logic [8*ares_pkg::LINE_BYTES-1:0]         refill_line_data,
    input  logic [ares_pkg::LINE_BEATS-1:0]           refill_beat_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    inst_way,          // one-hot
    output logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] inst_set,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] inst_row,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][63:0]   inst_data,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][7:0]    inst_be,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_last,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         inst_gnt,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         pub_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    pub_way,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] pub_tag,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         pub_dirty,
    output logic [ares_pkg::MSHR_ENTRIES-1:0]         wake_valid,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][1:0]    wake_lq_idx,
    output logic [ares_pkg::MSHR_ENTRIES-1:0][31:0]   wake_word,
    input  logic [ares_pkg::MSHR_ENTRIES-1:0]         wake_ready,        // processed (delivered or dropped)
    input  logic [ares_pkg::LQ_ENTRIES-1:0]           lq_wait_pending,
    input  ares_pkg::tag_t                            lq_wait_tag [ares_pkg::LQ_ENTRIES],
    input  logic [7:0]                                lq_wait_epoch [ares_pkg::LQ_ENTRIES]
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Geometry (all derived from ares_pkg; LINE_BYTES = 16/32/64)
    //-------------------------------------------------------------------------
    localparam int unsigned N      = MSHR_ENTRIES;              // 2
    localparam int unsigned LQN    = LQ_ENTRIES;                // 4
    localparam int unsigned ROWS   = ROWS_PER_LINE;             // 2/4/8
    localparam int unsigned ROWW   = $clog2(ROWS);              // 1/2/3
    localparam int unsigned CNTW   = ROWW + 1;                  // Row counters
    localparam int unsigned LBYTES = LINE_BYTES;                // 16/32/64
    localparam int unsigned NW     = 8 * LINE_BYTES;            // line bits
    localparam int unsigned NBEAT  = LINE_BEATS;                // 1/2/4
    localparam int unsigned WIDXW  = DCACHE_OFFSET_BITS - 2;    // word index (OFFSET_BITS-3:0)
    localparam int unsigned IBITS  = DCACHE_INDEX_BITS;
    localparam int unsigned TBITS  = DCACHE_TAG_BITS;
    localparam int unsigned OBITS  = DCACHE_OFFSET_BITS;
    localparam int unsigned LQIW   = $clog2(LQ_ENTRIES);

    localparam logic [CNTW-1:0] ROWS_CNT = CNTW'(ROWS);
    localparam logic [CNTW-1:0] LAST_ROW = CNTW'(ROWS - 1);

    //-------------------------------------------------------------------------
    // States (memory.md 6.4)
    //-------------------------------------------------------------------------
    typedef enum logic [2:0] {
        MS_FREE    = 3'd0,
        MS_RESERVE = 3'd1,
        MS_CAPTURE = 3'd2,
        MS_READ    = 3'd3,
        MS_INSTALL = 3'd4,
        MS_WAKE    = 3'd5
    } mshr_state_e;

    mshr_state_e state_q [N];

    logic [31:0]       line_q      [N];   // miss line address (Way lock address)
    logic [1:0]        way_q       [N];   // locked Way, one-hot
    logic [1:0]        wb_idx_q    [N];   // reserved WB entry (Dirty victim)
    logic [CNTW-1:0]   cap_gnt_q   [N];   // victim Rows granted
    logic [CNTW-1:0]   cap_rsp_q   [N];   // victim Rows already handed to the WB
    logic [N-1:0]      rd_sent_q;         // refill read owned (request accepted)
    logic [NW-1:0]     line_data_q [N];   // latched refill line
    logic [N-1:0]      line_full_q;       // refill line complete
    logic [CNTW-1:0]   inst_row_q  [N];   // next Row to install
    logic [LBYTES-1:0] ovl_mask_q  [N];   // Store overlay byte mask (new line)
    logic [NW-1:0]     ovl_data_q  [N];   // Store overlay bytes (new line)
    logic [LQN-1:0]    wq_v_q      [N];   // waiter valid
    tag_t              wq_tag_q    [N][LQN];
    logic [7:0]        wq_epoch_q  [N][LQN];
    logic [WIDXW-1:0]  wq_widx_q   [N][LQN];

    logic [IBITS-1:0]  line_idx    [N];   // Set index of the locked line

    always_comb begin
        for (int unsigned e = 0; e < N; e++) line_idx[e] = line_q[e][OBITS +: IBITS];
    end

    //-------------------------------------------------------------------------
    // Free mask / Way lock / same-line match
    //-------------------------------------------------------------------------
    logic [N-1:0] free_mask;
    logic [N-1:0] busy_c;

    always_comb begin
        for (int unsigned e = 0; e < N; e++) free_mask[e] = (state_q[e] == MS_FREE);
    end
    assign busy_c = ~free_mask;

    generate
        for (genvar e = 0; e < N; e++) begin : g_vis
            assign busy[e]           = busy_c[e];
            assign lock_valid[e]     = busy_c[e];
            assign lock_line_addr[e] = busy_c[e] ? line_q[e] : 32'd0;
            assign lock_way[e]       = busy_c[e] ? way_q[e] : 2'd0;
            assign match_hit[e]      = busy_c[e] && (line_q[e] == match_line_addr);
        end
    endgenerate

    //=========================================================================
    // Allocation (RESERVE) - one free entry per cycle, lowest index
    //=========================================================================
    // resv_ready is a pure function of the cycle-start FREE state: the MSHR does
    // not borrow an entry the current cycle releases, and it does not know about
    // Victim Way / WB availability (L06 checks those before C3).
    assign resv_ready = |free_mask;

    logic [N-1:0] resv_gnt;
    logic         resv_fire;

    always_comb resv_gnt = free_mask & (~free_mask + 1'b1);   // isolate lowest free

    assign resv_fire = resv_valid && resv_ready;

    //=========================================================================
    // Merge / Overlay acceptance (memory.md 6.4/6.5)
    //=========================================================================
    logic [N-1:0] wq_space;
    logic [N-1:0] merge_accept;
    logic [N-1:0] ovl_accept;
    logic [N-1:0] merge_gnt;
    logic [N-1:0] ovl_gnt;
    logic [N-1:0] merge_fire;
    logic [N-1:0] ovl_fire;

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            wq_space[e]     = ~(&wq_v_q[e]);
            merge_accept[e] = ((state_q[e] == MS_RESERVE) ||
                               (state_q[e] == MS_CAPTURE) ||
                               (state_q[e] == MS_READ))
                              && (merge_is_store || wq_space[e]);
            ovl_accept[e]   = (state_q[e] == MS_RESERVE) ||
                              (state_q[e] == MS_CAPTURE) ||
                              (state_q[e] == MS_READ);
        end
    end

    // ready is a function of the registered state and the one-hot select only
    // (guaranteed accept): the transfer happens on valid && ready.
    assign merge_gnt   = merge_sel & merge_accept;
    assign ovl_gnt     = ovl_sel   & ovl_accept;
    assign merge_ready = |merge_gnt;
    assign ovl_ready   = |ovl_gnt;
    // actual transfers (valid && ready)
    assign merge_fire  = merge_valid ? merge_gnt : {N{1'b0}};
    assign ovl_fire    = ovl_valid   ? ovl_gnt   : {N{1'b0}};

    //=========================================================================
    // Victim capture (memory.md 6.4)
    //=========================================================================
    logic [N-1:0] cap_req_v;
    logic [N-1:0] cap_rsp_match;

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            cap_req_v[e]   = ((state_q[e] == MS_RESERVE) || (state_q[e] == MS_CAPTURE))
                             && (cap_gnt_q[e] < ROWS_CNT);
            cap_req_way[e] = way_q[e];
            cap_req_row[e] = ROWW'(cap_gnt_q[e]);
            // The R response comes one cycle after its grant and carries
            // {set,row,way}: only the entry that owns that Row may consume it.
            cap_rsp_match[e] = cap_rsp_valid
                               && ((state_q[e] == MS_RESERVE) || (state_q[e] == MS_CAPTURE))
                               && (cap_gnt_q[e] > cap_rsp_q[e])
                               && (cap_rsp_way == way_q[e])
                               && (cap_rsp_set == line_idx[e])
                               && (cap_rsp_row == ROWW'(cap_rsp_q[e]));
        end
    end
    assign cap_req_valid = cap_req_v;

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            wb_wr_valid[e] = cap_rsp_match[e];
            wb_wr_idx[e]   = wb_idx_q[e];
            wb_wr_row[e]   = ROWW'(cap_rsp_q[e]);
            wb_wr_data[e]  = cap_rsp_data;
            wb_wr_last[e]  = cap_rsp_match[e] && (cap_rsp_q[e] == LAST_ROW);
        end
    end

    //=========================================================================
    // Refill read ownership (memory.md 6.4/6.7: one outstanding read)
    //=========================================================================
    logic [N-1:0] refill_req_mask;
    logic [N-1:0] refill_gnt;
    logic [N-1:0] rd_owner;
    logic         refill_beat_full;
    logic         refill_rsp_fire;

    always_comb begin
        for (int unsigned e = 0; e < N; e++)
            refill_req_mask[e] = (state_q[e] == MS_READ) && !rd_sent_q[e];
    end

    // Internal arbitration: one MSHR owns the refill port, lowest index wins.
    // A second entry may already take the port in the very cycle the current
    // owner consumes its response (the line adapter frees its buffer there).
    always_comb refill_gnt = refill_req_mask & (~refill_req_mask + 1'b1);

    assign refill_beat_full = (refill_beat_valid == {NBEAT{1'b1}});
    assign refill_rsp_fire  = refill_rsp_valid && refill_beat_full && (|rd_sent_q);

    assign refill_req_valid = (|refill_req_mask) && ((~|rd_sent_q) || refill_rsp_fire);
    assign refill_rsp_ready = refill_rsp_fire;

    always_comb rd_owner = rd_sent_q & (~rd_sent_q + 1'b1);

    always_comb begin
        refill_line_addr = 32'd0;
        for (int unsigned e = 0; e < N; e++)
            if (refill_gnt[e]) refill_line_addr = line_q[e];
    end

    //=========================================================================
    // Install (memory.md 6.4): merged line, Row by Row, publish with the last
    //=========================================================================
    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            inst_valid[e] = (state_q[e] == MS_INSTALL) && line_full_q[e];
            inst_way[e]   = way_q[e];
            inst_set[e]   = line_idx[e];
            inst_row[e]   = ROWW'(inst_row_q[e]);
            inst_be[e]    = 8'hFF;
            inst_last[e]  = (inst_row_q[e] == LAST_ROW);
            for (int unsigned b = 0; b < 8; b++) begin
                // byte index inside the line: 8*row + b
                if (ovl_mask_q[e][8*32'(inst_row_q[e]) + 32'(b)])
                    inst_data[e][8*b +: 8] = ovl_data_q[e][8*(8*32'(inst_row_q[e]) + 32'(b)) +: 8];
                else
                    inst_data[e][8*b +: 8] = line_data_q[e][8*(8*32'(inst_row_q[e]) + 32'(b)) +: 8];
            end
            pub_way[e]   = way_q[e];
            pub_tag[e]   = line_q[e][31 -: TBITS];
            pub_dirty[e] = |ovl_mask_q[e];
        end
    end

    // Publish is a separate block: it depends on the W-port grant, while
    // inst_valid must not (else dcache_top's grant arbitration would form a
    // combinational loop; Verilator analyses dependencies per always block).
    always_comb begin
        for (int unsigned e = 0; e < N; e++)
            pub_valid[e] = inst_valid[e] && inst_gnt[e] && inst_last[e];
    end

    //=========================================================================
    // WAKE (memory.md 6.4, D-M2b-04/05): one waiter per entry per cycle
    //=========================================================================
    logic [LQN-1:0] wq_live  [N];
    logic [LQN-1:0] wq_stale [N];
    logic [LQN-1:0] wq_sel   [N];
    logic [LQN-1:0] wq_clr   [N];
    logic [LQN-1:0] wq_v_n   [N];
    logic [NW-1:0]  merged_line [N];

    // Byte wise merge: overlay bytes win over the refilled line.
    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            merged_line[e] = line_data_q[e];
            for (int unsigned b = 0; b < LBYTES; b++)
                if (ovl_mask_q[e][b]) merged_line[e][8*b +: 8] = ovl_data_q[e][8*b +: 8];
        end
    end

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            for (int unsigned i = 0; i < LQN; i++) begin
                wq_live[e][i]  = wq_v_q[e][i] && lq_wait_pending[i]
                                 && (lq_wait_tag[i] == wq_tag_q[e][i])
                                 && (lq_wait_epoch[i] == wq_epoch_q[e][i]);
                wq_stale[e][i] = wq_v_q[e][i] && !wq_live[e][i];
            end
            // served waiter = lowest live one (one-hot OR picks its word index)
            wq_sel[e] = (state_q[e] == MS_WAKE) ? (wq_live[e] & (~wq_live[e] + 1'b1))
                                                : {LQN{1'b0}};

            wake_valid[e]  = |wq_sel[e];
            wake_lq_idx[e] = '0;
            wake_word[e]   = 32'd0;
            for (int unsigned i = 0; i < LQN; i++) begin
                if (wq_sel[e][i]) begin
                    wake_lq_idx[e] = LQIW'(i);
                    wake_word[e]   = merged_line[e][32*32'(wq_widx_q[e][i]) +: 32];
                end
            end
        end
    end

    // Separate block: the waiter next-state depends on wake_ready, while
    // wake_valid above must NOT (else lsu_top's wake arbitration closes a
    // combinational loop; Verilator analyses dependencies per always block).
    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            // stale waiters are dropped silently (never reported as delivered);
            // a delivered waiter is dropped on its wake_ready
            wq_clr[e] = (state_q[e] == MS_WAKE)
                        ? (wq_stale[e] | (wake_ready[e] ? wq_sel[e] : {LQN{1'b0}}))
                        : {LQN{1'b0}};
            wq_v_n[e] = wq_v_q[e] & ~wq_clr[e];
            if (merge_fire[e] && !merge_is_store) wq_v_n[e][merge_lq_idx] = 1'b1;
            if (resv_fire && resv_gnt[e])     // a new reservation owns the waiter set
                wq_v_n[e] = resv_is_store ? {LQN{1'b0}} : (LQN'(1) << resv_lq_idx);
        end
    end

    //=========================================================================
    // Store Overlay next value (reserve seeding / merge port / ovl port)
    //=========================================================================
    logic [LBYTES-1:0] ovl_mask_n [N];
    logic [NW-1:0]     ovl_data_n [N];

    function automatic logic [LBYTES-1:0] ovl_mask_upd(input logic [LBYTES-1:0] m,
                                                       input logic [WIDXW-1:0]   widx,
                                                       input logic [3:0]         bmask);
        ovl_mask_upd = m | (LBYTES'(bmask) << (4 * 32'(widx)));
    endfunction

    function automatic logic [NW-1:0] ovl_data_upd(input logic [NW-1:0] d,
                                                   input logic [WIDXW-1:0] widx,
                                                   input logic [3:0]       bmask,
                                                   input logic [31:0]      wdata);
        logic [NW-1:0] r;
        begin
            r = d;
            for (int unsigned b = 0; b < 4; b++)
                if (bmask[b]) r[8*(4*32'(widx) + 32'(b)) +: 8] = wdata[8*b +: 8];
            ovl_data_upd = r;
        end
    endfunction

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            if (resv_fire && resv_gnt[e]) begin
                // a new reservation never inherits the previous transaction's
                // overlay: the Store bytes must be seeded from an empty overlay
                if (resv_is_store) begin          // Store reserve seeds it
                    ovl_mask_n[e] = ovl_mask_upd('0, resv_store_widx, resv_store_mask);
                    ovl_data_n[e] = ovl_data_upd('0, resv_store_widx, resv_store_mask,
                                                 resv_store_data);
                end else begin                    // Load reserve: empty overlay
                    ovl_mask_n[e] = '0;
                    ovl_data_n[e] = '0;
                end
            end else begin
                ovl_mask_n[e] = ovl_mask_q[e];
                ovl_data_n[e] = ovl_data_q[e];
                if (merge_fire[e] && merge_is_store) begin
                    ovl_mask_n[e] = ovl_mask_upd(ovl_mask_n[e], merge_store_widx, merge_store_mask);
                    ovl_data_n[e] = ovl_data_upd(ovl_data_n[e], merge_store_widx, merge_store_mask,
                                                 merge_store_data);
                end
                if (ovl_fire[e]) begin
                    ovl_mask_n[e] = ovl_mask_upd(ovl_mask_n[e], ovl_widx, ovl_mask);
                    ovl_data_n[e] = ovl_data_upd(ovl_data_n[e], ovl_widx, ovl_mask, ovl_data);
                end
            end
        end
    end

    //=========================================================================
    // Next state (memory.md 6.4 transition table)
    //=========================================================================
    mshr_state_e state_n [N];

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            state_n[e] = state_q[e];
            unique case (state_q[e])
                MS_FREE: begin
                    if (resv_fire && resv_gnt[e])
                        state_n[e] = resv_victim_dirty ? MS_RESERVE : MS_READ;
                end
                MS_RESERVE: begin
                    if (cap_gnt[e]) state_n[e] = MS_CAPTURE;
                end
                MS_CAPTURE: begin           // only once the last Row reached the WB
                    if (cap_rsp_match[e] && (cap_rsp_q[e] == LAST_ROW))
                        state_n[e] = MS_READ;
                end
                MS_READ: begin
                    if (refill_rsp_fire && rd_owner[e]) state_n[e] = MS_INSTALL;
                end
                MS_INSTALL: begin
                    if (inst_valid[e] && inst_gnt[e] && inst_last[e])
                        state_n[e] = MS_WAKE;
                end
                default: begin              // MS_WAKE
                    if (wq_v_n[e] == '0) state_n[e] = MS_FREE;
                end
            endcase
        end
    end

    //=========================================================================
    // Sequential update
    //=========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned e = 0; e < N; e++) begin
                state_q[e]     <= MS_FREE;
                line_q[e]      <= 32'd0;
                way_q[e]       <= 2'd0;
                wb_idx_q[e]    <= 2'd0;
                cap_gnt_q[e]   <= '0;
                cap_rsp_q[e]   <= '0;
                rd_sent_q[e]   <= 1'b0;
                line_data_q[e] <= '0;
                line_full_q[e] <= 1'b0;
                inst_row_q[e]  <= '0;
                ovl_mask_q[e]  <= '0;
                ovl_data_q[e]  <= '0;
                wq_v_q[e]      <= '0;
                for (int unsigned i = 0; i < LQN; i++) begin
                    wq_tag_q[e][i]   <= '0;
                    wq_epoch_q[e][i] <= 8'd0;
                    wq_widx_q[e][i]  <= '0;
                end
            end
        end else begin
            for (int unsigned e = 0; e < N; e++) begin
                state_q[e]    <= state_n[e];
                wq_v_q[e]     <= wq_v_n[e];
                ovl_mask_q[e] <= ovl_mask_n[e];
                ovl_data_q[e] <= ovl_data_n[e];

                if (resv_fire && resv_gnt[e]) begin
                    //---- atomic RESERVE: line, Way lock, WB slot, first owner
                    line_q[e]      <= resv_line_addr;
                    way_q[e]       <= resv_way;
                    wb_idx_q[e]    <= resv_wb_idx;
                    cap_gnt_q[e]   <= '0;
                    cap_rsp_q[e]   <= '0;
                    rd_sent_q[e]   <= 1'b0;
                    line_data_q[e] <= '0;
                    line_full_q[e] <= 1'b0;
                    inst_row_q[e]  <= '0;
                    if (!resv_is_store) begin
                        wq_tag_q[e][resv_lq_idx]   <= resv_lq_tag;
                        wq_epoch_q[e][resv_lq_idx] <= resv_lq_epoch;
                        wq_widx_q[e][resv_lq_idx]  <= resv_word_idx;
                    end
                end else begin
                    //---- Load hits the in-flight line: record the waiter token
                    if (merge_fire[e] && !merge_is_store) begin
                        wq_tag_q[e][merge_lq_idx]   <= merge_lq_tag;
                        wq_epoch_q[e][merge_lq_idx] <= merge_lq_epoch;
                        wq_widx_q[e][merge_lq_idx]  <= merge_word_idx;
                    end
                    //---- victim capture progress: the grant advances the request
                    //     Row, the response frees the matching WB Row
                    if (cap_gnt[e]) cap_gnt_q[e] <= cap_gnt_q[e] + CNTW'(1'b1);
                    if (cap_rsp_match[e] && (cap_rsp_q[e] != LAST_ROW))
                        cap_rsp_q[e] <= cap_rsp_q[e] + CNTW'(1'b1);
                    //---- refill ownership / response capture
                    if (refill_req_valid && refill_req_ready && refill_gnt[e])
                        rd_sent_q[e] <= 1'b1;
                    if (refill_rsp_fire && rd_owner[e]) begin
                        line_data_q[e] <= refill_line_data;
                        line_full_q[e] <= 1'b1;
                        rd_sent_q[e]   <= 1'b0;
                    end
                    //---- install Row pointer
                    if (inst_valid[e] && inst_gnt[e] && !inst_last[e])
                        inst_row_q[e] <= inst_row_q[e] + CNTW'(1'b1);
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //=========================================================================
    // Protocol assertions (LSU_INTERFACES.md section 10, memory.md 6.8)
    //=========================================================================
    logic [N-1:0] in_wake;
    logic [N-1:0] in_install_wake;
    logic         line_dup;
    logic         lock_dup;

    always_comb begin
        for (int unsigned e = 0; e < N; e++) begin
            in_wake[e]        = (state_q[e] == MS_WAKE);
            in_install_wake[e]= (state_q[e] == MS_INSTALL) || (state_q[e] == MS_WAKE);
        end
    end

    always_comb begin
        line_dup = 1'b0;
        lock_dup = 1'b0;
        for (int unsigned i = 0; i < N; i++) begin
            for (int unsigned j = i + 1; j < N; j++) begin
                if (busy_c[i] && busy_c[j] && (line_q[i] == line_q[j])) line_dup = 1'b1;
                if (busy_c[i] && busy_c[j] && (way_q[i] == way_q[j])
                    && (line_idx[i] == line_idx[j])) lock_dup = 1'b1;
            end
        end
    end

    // capture / refill ownership
    a_cap_rsp_matched: assert property (@(posedge clk) disable iff (rst)
        cap_rsp_valid |-> |cap_rsp_match);
    a_cap_gnt_requests: assert property (@(posedge clk) disable iff (rst)
        ((cap_gnt & ~cap_req_valid) == '0));
    a_cap_rsp_single: assert property (@(posedge clk) disable iff (rst)
        $onehot0(cap_rsp_match));
    a_rd_sent_single: assert property (@(posedge clk) disable iff (rst)
        $onehot0(rd_sent_q));
    a_refill_single_outstanding: assert property (@(posedge clk) disable iff (rst)
        ((|rd_sent_q) && !refill_rsp_fire) |-> !refill_req_valid);
    a_refill_rsp_complete: assert property (@(posedge clk) disable iff (rst)
        refill_rsp_ready |-> refill_beat_full);
    a_refill_req_only_read: assert property (@(posedge clk) disable iff (rst)
        refill_req_valid |-> (|refill_req_mask));

    // install only after the whole line arrived; publish only with the last Row
    a_inst_line_full: assert property (@(posedge clk) disable iff (rst)
        ((inst_valid & ~line_full_q) == '0));
    a_pub_with_last_row: assert property (@(posedge clk) disable iff (rst)
        ((pub_valid & ~(inst_valid & inst_gnt & inst_last)) == '0));

    // overlay / merge frozen outside RESERVE/VICTIM_CAPTURE/READ_BEATS
    a_merge_accept: assert property (@(posedge clk) disable iff (rst)
        ((merge_fire & ~merge_accept) == '0));
    a_ovl_accept: assert property (@(posedge clk) disable iff (rst)
        ((ovl_fire & ~ovl_accept) == '0));
    a_frozen_install_wake: assert property (@(posedge clk) disable iff (rst)
        (((merge_fire | ovl_fire) & in_install_wake) == '0));

    // WB capture only for a matching, capturing entry
    a_wb_only_capture: assert property (@(posedge clk) disable iff (rst)
        ((wb_wr_valid & ~cap_rsp_match) == '0));

    // wake handshake and FREE invariants
    a_wake_ready_valid: assert property (@(posedge clk) disable iff (rst)
        ((wake_ready & ~wake_valid) == '0));
    a_wake_only_in_wake: assert property (@(posedge clk) disable iff (rst)
        ((wake_valid & ~in_wake) == '0));
    a_free_quiet: assert property (@(posedge clk) disable iff (rst)
        (busy == '0) |-> (lock_valid == '0) && (wake_valid == '0) &&
                         (cap_req_valid == '0) && (inst_valid == '0) &&
                         (refill_req_valid == 1'b0) && (wb_wr_valid == '0));
    a_busy_is_lock: assert property (@(posedge clk) disable iff (rst)
        busy == lock_valid);

    // same physical line never tracked twice, same (set,way) never double locked
    a_line_unique: assert property (@(posedge clk) disable iff (rst) !line_dup);
    a_lock_unique: assert property (@(posedge clk) disable iff (rst) !lock_dup);

    // allocation only ever targets a cycle-start FREE entry
    a_resv_target_free: assert property (@(posedge clk) disable iff (rst)
        resv_fire |-> ((resv_gnt & ~free_mask) == '0));
    a_resv_gnt_onehot: assert property (@(posedge clk) disable iff (rst)
        $onehot0(resv_gnt));

    // FSM legal transitions
    mshr_state_e state_p [N];
    always_ff @(posedge clk) begin
        if (rst) for (int unsigned e = 0; e < N; e++) state_p[e] <= MS_FREE;
        else     for (int unsigned e = 0; e < N; e++) state_p[e] <= state_q[e];
    end

    function automatic logic trans_legal(input mshr_state_e a, input mshr_state_e b);
        if (a == b) trans_legal = 1'b1;
        else unique case (a)
            MS_FREE:    trans_legal = (b == MS_RESERVE) || (b == MS_READ);
            MS_RESERVE: trans_legal = (b == MS_CAPTURE);
            MS_CAPTURE: trans_legal = (b == MS_READ);
            MS_READ:    trans_legal = (b == MS_INSTALL);
            MS_INSTALL: trans_legal = (b == MS_WAKE);
            default:    trans_legal = (b == MS_FREE);
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (!rst) begin
            for (int unsigned e = 0; e < N; e++)
                a_legal_transition: assert (trans_legal(state_p[e], state_q[e]))
                    else $error("mshr[%0d]: illegal transition %0d -> %0d", e, state_p[e], state_q[e]);
        end
    end
`endif

endmodule
