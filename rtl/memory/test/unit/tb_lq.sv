`timescale 1ns/1ps
//=============================================================================
// ARES LSU - self-checking unit bench for the 4-entry Load Queue (L03)
//-----------------------------------------------------------------------------
// Covers (LSU_INTERFACES.md section 3 / section 8, memory.md 3.1 / 4.1 / 4.2):
//   * reset leaves every valid/occupancy/pointer clean
//   * issue allocation + older_store_mask = sq_occupied & ~sq_takeover
//     (younger stores never join an existing mask, hand-over clears bits)
//   * AGU registration gates arbitration (unregistered entries are invisible)
//   * dep_ready blocks the lookup until every older store is registered
//   * full forwarding (LB/LH/LW/LBU/LHU): no lookup, direct merged/extended result
//   * partial forwarding + fill: forwarded bytes override the cache word
//   * oldest-serviceable arbitration, age-list compaction on arbitrary release,
//     lookup payload stability while an un-accepted request is held
//   * lookup_inflight: no duplicate lookup, killed responses are dropped
//   * kill priority: entry released immediately, kill beats a same-cycle
//     completion AND a same-cycle fill, no completion is ever produced for a
//     killed load, later stale fills are dropped
//   * completion handshake: release only on compl_valid && compl_ready
//   * MMIO load: Head-gated single device read, held until ready, response
//     merge/extract, no forwarding snapshot, no lookup, stale response dropped
//   * fixed-seed random trace (12000 cycles) against an independent reference
//     model: lq_used / lq_full / lq_alloc_idx, lookup arbitration and payload,
//     MMIO request, completion set and result data, one completion per lifetime
//
// Spec sources : docs/microarch/memory.md 3.1 / 4.1 / 4.2 / 7 / 8,
//                rtl/memory/LSU_INTERFACES.md sections 0, 3, 8.
// FREE items   : FREE-02 (bench organisation), FREE-04 (reference model uses
//                its own byte-select / extraction formulation).
//
// Build / run (repository root, explicit file list):
// cmd: verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lq --Mdir sim/build/unit/tb_lq -o tb_lq rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/store_forward.sv rtl/memory/lq.sv rtl/memory/test/unit/tb_lq.sv
//   sim/build/unit/tb_lq/tb_lq
//=============================================================================
module tb_lq;
    import ares_pkg::*;
    import lsu_pkg::*;

    //-------------------------------------------------------------------------
    // clock / reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic                            alloc_valid;
    logic [1:0]                      alloc_idx;
    tag_t                            alloc_tag;

    logic                            agu_valid;
    logic [2:0]                      agu_qidx;
    tag_t                            agu_tag;
    logic [31:0]                     agu_addr;
    lsu_size_t                       agu_size;
    logic [3:0]                      agu_byte_mask;
    logic                            agu_is_unsigned;
    logic                            agu_is_mmio;

    logic [7:0]                      sq_occupied;
    logic [7:0]                      sq_takeover;
    logic [7:0]                      sq_addr_valid;
    logic [7:0][31:0]                sq_addr;
    logic [7:0][31:0]                sq_data;
    logic [7:0][3:0]                 sq_byte_mask;
    logic [7:0]                      sq_is_mmio;
    logic [2:0]                      sq_head_ptr;
    logic [3:0]                      sq_occupancy;

    logic                            lookup_ready;
    logic                            fill_valid;
    logic [1:0]                      fill_idx;
    logic [31:0]                     fill_word;

    logic                            load_head_valid;
    tag_t                            load_head_tag;
    logic                            mmio_req_ready;
    logic                            mmio_rsp_valid;
    logic [31:0]                     mmio_rsp_data;

    logic                            compl_ready;
    logic [CIQ_ENTRIES-1:0]          kill_mask;

    logic                            lookup_valid;
    logic [1:0]                      lookup_idx;
    tag_t                            lookup_tag;
    logic [31:0]                     lookup_addr;
    lsu_size_t                       lookup_size;
    logic                            mmio_req_valid;
    logic [31:0]                     mmio_req_addr;
    logic                            compl_valid;
    tag_t                            compl_tag;
    logic [31:0]                     compl_result;
    logic [1:0]                      lq_alloc_idx;
    logic [2:0]                      lq_used;
    logic                            lq_full;

    // M2b waiter tokens (D-M2b-04) + per-slot allocation generation model
    logic [LQ_ENTRIES-1:0] lq_wait_pending;
    tag_t                  lq_wait_tag   [LQ_ENTRIES];
    logic [7:0]            lq_wait_epoch [LQ_ENTRIES];
    logic [7:0]            prev_epoch    [LQ_ENTRIES];
    tag_t                  last_tag_seen;
    int unsigned           n_wait_seen = 0;
    int unsigned           n_epoch_seen = 0;

    initial for (int unsigned e = 0; e < LQ_ENTRIES; e++) prev_epoch[e] = 8'd0;

    lq dut (.*);

    //-------------------------------------------------------------------------
    // checking / timing helpers
    //-------------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic chk(input logic cond, input string msg);
        checks = checks + 1;
        if (cond !== 1'b1) begin
            errors = errors + 1;
            if (errors <= 40) $display("ERROR @%0t ns : %s", $time, msg);
        end
    endtask

    task automatic chk32(input logic [31:0] got, input logic [31:0] exp, input string msg);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            if (errors <= 40) $display("ERROR @%0t ns : %s got=%08x exp=%08x", $time, msg, got, exp);
        end
    endtask

    task automatic settle(); #1; endtask

    // Token observation (M2b additive ports): count generation advances and
    // pending samples so the exported token ports are exercised by the bench.
    task automatic chk_tokens();
        int unsigned i;
        begin
            i = 0;
            while (i < LQ_ENTRIES) begin
                if (lq_wait_epoch[i] !== prev_epoch[i]) begin
                    prev_epoch[i] = lq_wait_epoch[i];
                    n_epoch_seen  = n_epoch_seen + 1;
                end
                if (lq_wait_pending[i]) begin
                    n_wait_seen   = n_wait_seen + 1;
                    last_tag_seen = lq_wait_tag[i];
                end
                i = i + 1;
            end
        end
    endtask

    task automatic tick();
        @(posedge clk);
        #1;
        chk_tokens();
    endtask

    // fixed-seed PRNG (independent of simulator seeding)
    logic [31:0] rng_state;
    function automatic logic [31:0] rnd();
        rng_state = rng_state * 32'd1664525 + 32'd1013904223;
        rnd = rng_state;
    endfunction
    function automatic int unsigned rnd_range(input int unsigned lo, input int unsigned hi);
        rnd_range = lo + (rnd() % (hi - lo + 1));
    endfunction

    //-------------------------------------------------------------------------
    // independent result reference: byte merge + shift + extension
    //-------------------------------------------------------------------------
    function automatic logic [31:0] tb_extract(input logic [31:0] word, input logic [3:0] fm,
                                               input logic [31:0] fdat, input logic uns,
                                               input logic [1:0] low, input lsu_size_t sz);
        logic [31:0] m;
        logic [31:0] sh;
        begin
            for (int b = 0; b < 4; b++)
                m[8*b +: 8] = fm[b] ? fdat[8*b +: 8] : word[8*b +: 8];
            sh = m >> (8 * low);
            case (sz)
                LSZ_BYTE: tb_extract = uns ? {24'd0, sh[7:0]} : {{24{sh[7]}}, sh[7:0]};
                LSZ_HALF: tb_extract = uns ? {16'd0, sh[15:0]} : {{16{sh[15]}}, sh[15:0]};
                default:  tb_extract = sh;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // SQ stimulus helpers (the LQ is driven directly; the SQ model must always
    // be a consistent ring: head, contiguous occupancy, popcount).
    //-------------------------------------------------------------------------
    function automatic logic [7:0] ring_mask(input logic [2:0] head, input int unsigned n);
        logic [7:0] m;
        logic [2:0] sum;
        begin
            m = 8'd0;
            for (int k = 0; k < 8; k++) begin
                if (k < n) begin
                    sum = head + k[2:0];
                    m[sum] = 1'b1;
                end
            end
            ring_mask = m;
        end
    endfunction

    task automatic sq_clear();
        sq_occupied  = 8'd0;
        sq_takeover  = 8'd0;
        sq_addr_valid= 8'd0;
        sq_addr      = '0;
        sq_data      = '0;
        sq_byte_mask = '0;
        sq_is_mmio   = 8'd0;
        sq_head_ptr  = 3'd0;
        sq_occupancy = 4'd0;
    endtask

    task automatic sq_ring_begin(input logic [2:0] head, input int unsigned n);
        sq_head_ptr  = head;
        sq_occupancy = n[3:0];
        sq_occupied  = ring_mask(head, n);
    endtask

    task automatic sq_put(input int unsigned s, input logic [31:0] a, input logic [31:0] d,
                          input logic [3:0] bm, input logic mm, input logic av);
        sq_addr[s]       = a;
        sq_data[s]       = d;
        sq_byte_mask[s]  = bm;
        sq_is_mmio[s]    = mm;
        sq_addr_valid[s] = av;
    endtask

    task automatic idle_inputs();
        alloc_valid = 1'b0; alloc_idx = 2'd0; alloc_tag = '0;
        agu_valid = 1'b0; agu_qidx = 3'd0; agu_tag = '0; agu_addr = 32'd0;
        agu_size = LSZ_WORD; agu_byte_mask = 4'd0;
        agu_is_unsigned = 1'b0; agu_is_mmio = 1'b0;
        lookup_ready = 1'b0;
        fill_valid = 1'b0; fill_idx = 2'd0; fill_word = 32'd0;
        load_head_valid = 1'b0; load_head_tag = '0;
        mmio_req_ready = 1'b0; mmio_rsp_valid = 1'b0; mmio_rsp_data = 32'd0;
        compl_ready = 1'b1;
        kill_mask = '0;
    endtask

    task automatic idle_all();
        idle_inputs();
        sq_clear();
    endtask

    task automatic do_reset();
        // Reset first: the SQ model must stay consistent with the LQ mask
        // registers until the reset edge has released every entry.
        rst = 1'b1;
        tick();
        idle_all();
        repeat (2) tick();
        rst = 1'b0;
        tick();
        idle_all();
    endtask

    task automatic alloc_load(input logic [1:0] idx, input logic [3:0] tag);
        alloc_valid = 1'b1;
        alloc_idx   = idx;
        alloc_tag   = '{slot_index: tag};
        settle();
        tick();
        alloc_valid = 1'b0;
    endtask

    task automatic agu_reg(input logic [1:0] idx, input logic [3:0] tag, input logic [31:0] addr,
                           input lsu_size_t size, input logic [3:0] bmask,
                           input logic unsigned_, input logic is_mmio);
        agu_valid      = 1'b1;
        agu_qidx       = {1'b0, idx};
        agu_tag        = '{slot_index: tag};
        agu_addr       = addr;
        agu_size       = size;
        agu_byte_mask  = bmask;
        agu_is_unsigned= unsigned_;
        agu_is_mmio    = is_mmio;
        settle();
        tick();
        agu_valid = 1'b0;
    endtask

    //-------------------------------------------------------------------------
    // reference model state (random trace)
    //-------------------------------------------------------------------------
    logic        m_alive[4];
    logic [3:0]  m_tag[4];
    logic        m_av[4];
    logic [31:0] m_addr[4];
    lsu_size_t   m_size[4];
    logic [3:0]  m_bmask[4];
    logic        m_uns[4];
    logic        m_mmio[4];
    logic [7:0]  m_older[4];
    logic        m_snap_v[4];
    logic [3:0]  m_smask[4];
    logic [31:0] m_snap_data[4];
    logic        m_inflight[4];
    logic        m_resv[4];
    logic [31:0] m_res[4];
    logic        m_msent[4];
    logic        m_mdone[4];
    int unsigned m_agu_dly[4];
    int unsigned m_fill_dly[4];
    int unsigned m_rsp_dly[4];
    logic [1:0]  m_ord[4];
    logic [2:0]  m_ordcnt;
    logic        m_hold_v;
    logic [1:0]  m_hold_idx;

    // model expectations recomputed every cycle
    logic [3:0]  m_fm[4];
    logic [31:0] m_fd[4];
    logic [3:0]  m_dep;
    logic [3:0]  m_ff;
    logic [3:0]  m_snap_now;
    logic [3:0]  m_elig;
    logic [3:0]  m_mel;
    logic [3:0]  m_rel;

    // SQ model
    logic [7:0]       m_occ, m_sav, m_smmio;
    logic [7:0][31:0] m_saddr, m_sdata;
    logic [7:0][3:0]  m_sbmask;
    logic [2:0]       m_head;
    logic [3:0]       m_occn;
    logic [7:0]       m_takeover;

    task automatic model_clear();
        for (int unsigned i = 0; i < 4; i++) begin
            m_alive[i]=1'b0; m_tag[i]=4'd0; m_av[i]=1'b0; m_addr[i]=32'd0;
            m_size[i]=LSZ_WORD; m_bmask[i]=4'd0; m_uns[i]=1'b0; m_mmio[i]=1'b0;
            m_older[i]=8'd0; m_snap_v[i]=1'b0; m_smask[i]=4'd0; m_snap_data[i]=32'd0;
            m_inflight[i]=1'b0; m_resv[i]=1'b0; m_res[i]=32'd0; m_msent[i]=1'b0;
            m_mdone[i]=1'b0; m_agu_dly[i]=0; m_fill_dly[i]=0; m_rsp_dly[i]=0;
        end
        for (int unsigned i = 0; i < 4; i++) m_ord[i]=2'd0;
        m_ordcnt=3'd0; m_hold_v=1'b0; m_hold_idx=2'd0;
        m_occ=8'd0; m_sav=8'd0; m_smmio=8'd0; m_head=3'd0; m_occn=4'd0; m_takeover=8'd0;
        for (int unsigned s = 0; s < 8; s++) begin
            m_saddr[s]=32'd0; m_sdata[s]=32'd0; m_sbmask[s]=4'd0;
        end
    endtask

    function automatic int unsigned model_used();
        int unsigned n;
        n = 0;
        for (int unsigned i = 0; i < 4; i++) if (m_alive[i]) n = n + 1;
        return n;
    endfunction

    function automatic logic [1:0] model_free();
        logic [1:0] f;
        f = 2'd0;
        for (int k = 3; k >= 0; k--) if (!m_alive[k]) f = k[1:0];
        return f;
    endfunction

    function automatic logic [3:0] model_popcount(input logic [7:0] v);
        logic [3:0] n;
        n = 4'd0;
        for (int unsigned b = 0; b < 8; b++) if (v[b]) n = n + 4'd1;
        return n;
    endfunction

    function automatic logic model_dep(input logic [1:0] i);
        model_dep = ((~m_older[i]) | m_sav) == 8'hFF;
    endfunction

    // Reference byte-wise forwarding: per byte take the YOUNGEST older store
    // that covers it (the same closest-older-store rule as store_forward, but
    // written as an explicit max-age search over the ring).
    task automatic model_fwd(input logic [1:0] i, output logic [3:0] fm, output logic [31:0] fd);
        logic [2:0] s;
        int k;
        begin
            fm = 4'd0;
            fd = 32'd0;
            if (m_snap_v[i]) begin
                fm = m_smask[i];
                fd = m_snap_data[i];
            end else begin
                for (int b = 0; b < 4; b++) begin
                    for (k = int'(m_occn) - 1; k >= 0; k--) begin
                        s = (m_head + k[2:0]) & 3'd7;
                        if (m_older[i][s] && m_occ[s] && !m_smmio[s] && m_sav[s]
                            && m_sbmask[s][b] && (m_saddr[s][31:2] == m_addr[i][31:2])) begin
                            fm[b]        = 1'b1;
                            fd[8*b +: 8] = m_sdata[s][8*b +: 8];
                            break;
                        end
                    end
                end
            end
        end
    endtask

    function automatic logic [1:0] model_tag_idx(input logic [3:0] t, output logic found);
        logic [1:0] idx;
        idx = 2'd0;
        found = 1'b0;
        for (int unsigned i = 0; i < 4; i++)
            if (m_alive[i] && (m_tag[i] == t)) begin idx = i[1:0]; found = 1'b1; end
        return idx;
    endfunction

    task automatic drive_sq();
        sq_occupied   = m_occ;
        sq_addr_valid = m_sav;
        sq_is_mmio    = m_smmio;
        for (int unsigned s = 0; s < 8; s++) begin
            sq_addr[s]      = m_saddr[s];
            sq_data[s]      = m_sdata[s];
            sq_byte_mask[s] = m_sbmask[s];
        end
        sq_head_ptr  = m_head;
        sq_occupancy = m_occn;
        sq_takeover  = m_takeover;
    endtask

    //=========================================================================
    // T1 reset
    //=========================================================================
    task automatic test_reset();
        $display("[T1] reset / clean state");
        idle_all();
        rst = 1'b1;
        alloc_valid = 1'b1; alloc_idx = 2'd0; alloc_tag = '{slot_index: 4'hF};
        lookup_ready = 1'b1; compl_ready = 1'b1; mmio_req_ready = 1'b1;
        kill_mask = {CIQ_ENTRIES{1'b1}};
        repeat (3) tick();
        chk(lq_used == 3'd0,       "T1 reset: lq_used == 0");
        chk(!lq_full,              "T1 reset: !lq_full");
        chk(!lookup_valid,         "T1 reset: !lookup_valid");
        chk(!compl_valid,          "T1 reset: !compl_valid");
        chk(!mmio_req_valid,       "T1 reset: !mmio_req_valid");
        chk(lq_alloc_idx == 2'd0,  "T1 reset: lq_alloc_idx == 0");
        // release reset with every stimulus deasserted: nothing may be
        // allocated by the stimulus that was ignored during reset
        alloc_valid = 1'b0;
        lookup_ready = 1'b0;
        compl_ready = 1'b1;
        kill_mask = '0;
        rst = 1'b0;
        tick();
        idle_all();
        chk(lq_used == 3'd0,       "T1 post-reset: lq_used == 0");
        chk(!lookup_valid,         "T1 post-reset: !lookup_valid");
    endtask

    //=========================================================================
    // T2 older_store_mask snapshot
    //=========================================================================
    task automatic test_alloc_mask();
        $display("[T2] allocation + older_store_mask snapshot");
        // (a) a store handing over in the issue cycle must not enter the mask
        do_reset();
        sq_ring_begin(3'd0, 2);
        sq_put(0, 32'h1000, 32'hAABB_CCDD, 4'hF, 1'b0, 1'b1);
        sq_put(1, 32'h2000, 32'h1122_3344, 4'hF, 1'b0, 1'b1);
        sq_takeover = 8'h02;
        alloc_load(2'd0, 4'h1);
        sq_takeover = 8'h00;
        sq_ring_begin(3'd0, 1);
        agu_reg(2'd0, 4'h1, 32'h2000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid,            "T2a: handed-over store excluded from the mask -> lookup");
        chk(lookup_idx == 2'd0,      "T2a: lookup idx");
        chk32(lookup_addr, 32'h2000, "T2a: lookup addr");
        chk(lookup_size == LSZ_WORD, "T2a: lookup size follows the registered op");
        lookup_ready = 1'b1;
        tick();
        lookup_ready = 1'b0;
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'h0102_0304;
        settle(); tick();
        fill_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h1), "T2a: completion");
        chk32(compl_result, 32'h0102_0304, "T2a: no forward from the handed-over store");
        tick();

        // (b) a younger store must never join an existing mask
        do_reset();
        alloc_load(2'd0, 4'h2);
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h3000, 32'hFFFF_FFFF, 4'hF, 1'b0, 1'b1);
        agu_reg(2'd0, 4'h2, 32'h3000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0),
            "T2b: younger store must not join an already latched mask");
        lookup_ready = 1'b1;
        tick();
        lookup_ready = 1'b0;
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'h5555_5555;
        settle(); tick();
        fill_valid = 1'b0;
        settle();
        chk32(compl_result, 32'h5555_5555, "T2b: cache word used, no young-store forward");
        tick();

        // (c) a store present at issue time IS in the mask (full forward)
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h4000, 32'h0BAD_F00D, 4'hF, 1'b0, 1'b1);
        alloc_load(2'd0, 4'h3);
        agu_reg(2'd0, 4'h3, 32'h4000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(!lookup_valid, "T2c: fully forwarded load must not request a lookup");
        tick();
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h3), "T2c: completion");
        chk32(compl_result, 32'h0BAD_F00D, "T2c: forwarded store data");
        tick();
    endtask

    //=========================================================================
    // T3 AGU registration gates arbitration
    //=========================================================================
    task automatic test_agu_arb();
        $display("[T3] AGU registration / oldest arbitration");
        do_reset();
        alloc_load(2'd0, 4'h1);
        alloc_load(2'd1, 4'h2);
        agu_reg(2'd1, 4'h2, 32'h7000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd1), "T3: unregistered entry must not arbitrate");
        chk32(lookup_addr, 32'h7000, "T3: unregistered entry address not presented");
        tick();
        lookup_ready = 1'b1;
        settle(); tick();
        lookup_ready = 1'b0;
        chk(lq_used == 3'd2, "T3: both entries still occupied");
        agu_reg(2'd0, 4'h1, 32'h6000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0), "T3: oldest registered load wins");
        chk32(lookup_addr, 32'h6000, "T3: oldest load address");
        tick();
        // the younger entry keeps advancing independently (out-of-order completion)
        fill_valid = 1'b1; fill_idx = 2'd1; fill_word = 32'hDEAD_BEEF;
        tick();
        fill_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h2), "T3: younger entry completes out of order");
        chk32(compl_result, 32'hDEAD_BEEF, "T3: younger entry result");
        tick();
        chk(lq_used == 3'd1, "T3: only the older load remains");
    endtask

    //=========================================================================
    // T4 dep_ready / takeover bit clearing
    //=========================================================================
    task automatic test_takeover_dep();
        $display("[T4] dep_ready blocking + takeover mask clearing");
        // (a) still-registering older store blocks the lookup
        do_reset();
        sq_ring_begin(3'd0, 4);
        sq_put(0, 32'h100, 32'h1111_1111, 4'hF, 1'b0, 1'b1);
        sq_put(1, 32'h200, 32'h2222_2222, 4'hF, 1'b0, 1'b0);  // not registered yet
        sq_put(2, 32'h300, 32'h3333_3333, 4'hF, 1'b0, 1'b1);
        sq_put(3, 32'h400, 32'h4444_4444, 4'hF, 1'b0, 1'b1);
        sq_addr_valid = 8'b1101;
        alloc_load(2'd0, 4'h4);
        agu_reg(2'd0, 4'h4, 32'h9000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        lookup_ready = 1'b0;
        repeat (3) begin
            settle();
            chk(!lookup_valid, "T4a: dep_ready=0 must block the lookup");
            tick();
        end
        sq_addr_valid = 8'b1111;
        repeat (3) begin
            settle();
            chk(lookup_valid && (lookup_idx == 2'd0), "T4a: lookup once every older store is ready");
            chk32(lookup_addr, 32'h9000, "T4a: lookup payload stable while not accepted");
            tick();
        end
        lookup_ready = 1'b1;
        settle(); tick();
        lookup_ready = 1'b0;

        // (b) takeover clears the mask bit of a live entry (no snapshot yet)
        do_reset();
        sq_ring_begin(3'd0, 4);
        sq_put(0, 32'h100, 32'h1111_1111, 4'hF, 1'b0, 1'b0);  // never registered
        sq_put(1, 32'h200, 32'h2222_2222, 4'hF, 1'b0, 1'b1);
        sq_put(2, 32'h300, 32'h3333_3333, 4'hF, 1'b0, 1'b1);
        sq_put(3, 32'h400, 32'h4444_4444, 4'hF, 1'b0, 1'b1);
        sq_addr_valid = 8'b1110;
        alloc_load(2'd0, 4'h5);
        agu_reg(2'd0, 4'h5, 32'hA000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(!lookup_valid, "T4b: unregistered older store blocks the lookup");
        tick();
        // store 0 (the ring head) hands over; the SQ ring advances
        sq_takeover = 8'h01;
        settle();
        chk(!lookup_valid, "T4b: takeover cycle itself does not release the dependency yet");
        tick();
        sq_takeover = 8'h00;
        sq_head_ptr = 3'd1; sq_occupancy = 4'd3; sq_occupied = 8'h0E; sq_addr_valid = 8'h0E;
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0), "T4b: takeover cleared the stale mask bit");
        tick();
    endtask

    //=========================================================================
    // T5 partial forward + fill (snapshot frozen across takeover)
    //=========================================================================
    task automatic test_partial_fill();
        $display("[T5] partial forward + fill");
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h2000, 32'h0000_0011, 4'b0001, 1'b0, 1'b1);
        alloc_load(2'd0, 4'h6);
        agu_reg(2'd0, 4'h6, 32'h2000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0), "T5: partial forward still needs the cache");
        tick();
        // freeze test: change the store data and hand the store over
        sq_data[0]    = 32'h0000_0099;
        sq_takeover   = 8'h01;
        settle(); tick();
        sq_takeover   = 8'h00;
        sq_occupied   = 8'd0;
        sq_addr_valid = 8'd0;
        sq_occupancy  = 4'd0;
        sq_head_ptr   = 3'd0;
        lookup_ready = 1'b1;
        settle(); tick();
        lookup_ready = 1'b0;
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'hAABB_CCDD;
        settle(); tick();
        fill_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h6), "T5: completion after the fill");
        chk32(compl_result, 32'hAABB_CC11, "T5: forwarded byte wins over the cache word");
        tick();
    endtask

    //=========================================================================
    // T6 full forwarding for LB / LBU / LH / LHU / LW
    //=========================================================================
    task automatic ff_case(input string name, input lsu_size_t size, input logic [3:0] bmask,
                           input logic unsigned_, input logic [31:0] laddr,
                           input logic [31:0] sdata, input logic [3:0] sbm,
                           input logic [31:0] expected);
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, laddr, sdata, sbm, 1'b0, 1'b1);
        alloc_load(2'd0, 4'h7);
        agu_reg(2'd0, 4'h7, laddr, size, bmask, unsigned_, 1'b0);
        settle();
        chk(!lookup_valid, {name, ": full forward must not issue a lookup"});
        tick();
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h7), {name, ": completion without fill"});
        chk32(compl_result, expected, {name, ": merged / extended result"});
        tick();
        chk(lq_used == 3'd0, {name, ": released on completion"});
    endtask

    task automatic test_full_forward_all();
        $display("[T6] full forwarding LB/LBU/LH/LHU/LW");
        ff_case("LB ", LSZ_BYTE, 4'b0001, 1'b0, 32'h1000, 32'h0000_0080, 4'b0001, 32'hFFFF_FF80);
        ff_case("LBU", LSZ_BYTE, 4'b0100, 1'b1, 32'h1002, 32'h0080_0000, 4'b0100, 32'h0000_0080);
        ff_case("LH ", LSZ_HALF, 4'b0011, 1'b0, 32'h1004, 32'h0000_8001, 4'b0011, 32'hFFFF_8001);
        ff_case("LHU", LSZ_HALF, 4'b1100, 1'b1, 32'h1006, 32'h8001_0000, 4'b1100, 32'h0000_8001);
        ff_case("LW ", LSZ_WORD, 4'b1111, 1'b0, 32'h1008, 32'hDEAD_BEEF, 4'b1111, 32'hDEAD_BEEF);
    endtask

    //=========================================================================
    // T7 age list wrap-around + lq_alloc_idx + lookup stability
    //=========================================================================
    task automatic test_order_wrap();
        $display("[T7] age list / wrap-around / allocation index");
        do_reset();
        alloc_load(2'd0, 4'h1);
        settle(); chk(lq_alloc_idx == 2'd1, "T7: lowest free slot after idx0");
        tick();
        alloc_load(2'd1, 4'h2);
        settle(); chk(lq_alloc_idx == 2'd2, "T7: lowest free slot after idx1");
        tick();
        alloc_load(2'd2, 4'h3);
        settle(); chk(lq_alloc_idx == 2'd3, "T7: lowest free slot after idx2");
        tick();
        alloc_load(2'd3, 4'h4);
        settle();
        chk(lq_full,            "T7: lq_full after 4 allocations");
        chk(lq_used == 3'd4,    "T7: lq_used == 4");
        tick();
        agu_reg(2'd1, 4'h2, 32'h1100, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd2, 4'h3, 32'h2200, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd3, 4'h4, 32'h3300, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd1), "T7: oldest registered of the four");
        tick();
        // kill the oldest -> the request must not be re-pointed in that cycle
        kill_mask = 16'd1 << 4'h2;
        settle();
        chk(!lookup_valid, "T7: held request dropped (entry killed)");
        tick();
        kill_mask = '0;
        settle();
        chk(lookup_valid && (lookup_idx == 2'd2), "T7: next oldest after the kill");
        tick();
        // kill slot 3 and reuse the LOWEST free slot (1) for a new load: the
        // age list must treat the re-used low index as the youngest entry
        kill_mask = 16'd1 << 4'h4;
        settle(); tick();
        kill_mask = '0;
        settle();
        chk(lq_alloc_idx == 2'd1, "T7: lowest free slot after two kills");
        tick();
        alloc_load(2'd1, 4'h8);
        agu_reg(2'd1, 4'h8, 32'h4400, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd2), "T7: re-used low slot is the youngest");
        tick();
        // complete idx2: idx0 is still unregistered, the new idx1 is next
        lookup_ready = 1'b1;
        settle(); tick();
        lookup_ready = 1'b0;
        fill_valid = 1'b1; fill_idx = 2'd2; fill_word = 32'h0F0F_0F0F;
        settle(); tick();
        fill_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h3), "T7: completion of idx2");
        tick();
        settle();
        chk(lookup_valid && (lookup_idx == 2'd1), "T7: youngest registered load next");
        chk(lq_alloc_idx == 2'd2, "T7: lowest free slot after the completion");
        tick();
        // accept the youngest, then register the oldest of all: it must win
        lookup_ready = 1'b1;
        settle(); tick();
        lookup_ready = 1'b0;
        agu_reg(2'd0, 4'h1, 32'h5500, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0), "T7: oldest live load wins after wrap");
        tick();
    endtask

    //=========================================================================
    // T8 lookup_inflight / kill + stale response
    //=========================================================================
    task automatic test_inflight_kill();
        $display("[T8] lookup_inflight / kill / stale fill");
        do_reset();
        alloc_load(2'd0, 4'h9);
        agu_reg(2'd0, 4'h9, 32'h1000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        lookup_ready = 1'b1;
        settle();
        chk(lookup_valid && (lookup_idx == 2'd0), "T8: lookup for the only entry");
        tick();
        chk(lq_used == 3'd1, "T8: entry occupies the queue while in flight");
        repeat (4) begin
            settle();
            chk(!lookup_valid, "T8: no duplicate lookup for an in-flight entry");
            tick();
        end
        // kill it while in flight WITH the response in the same cycle: kill
        // wins and the same-cycle fill must be dropped
        kill_mask = 16'd1 << 4'h9;
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'hBADC_0FFE;
        settle();
        chk(!compl_valid, "T8: kill beats a same-cycle fill (no completion)");
        tick();
        kill_mask = '0;
        chk(lq_used == 3'd0, "T8: killed entry released immediately");
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'hBADC_0FFE;
        repeat (2) begin
            settle();
            chk(!compl_valid, "T8: stale fill after kill produces no completion");
            tick();
        end
        fill_valid = 1'b0;
        chk(lq_used == 3'd0, "T8: queue still empty after the stale fill");
        // re-use the slot: the stale response must not write the new lifetime
        alloc_load(2'd0, 4'hA);
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'h1234_5678;
        settle();
        chk(!compl_valid, "T8: stale fill must not complete a fresh (not in-flight) entry");
        tick();
        fill_valid = 1'b0;
        agu_reg(2'd0, 4'hA, 32'h2000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        lookup_ready = 1'b1;
        settle();
        chk(lookup_valid, "T8: fresh entry still able to issue its own lookup");
        tick();
        lookup_ready = 1'b0;
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'hCAFE_BABE;
        tick();
        fill_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'hA), "T8: fresh entry completes normally");
        chk32(compl_result, 32'hCAFE_BABE, "T8: fresh entry result");
        tick();
    endtask

    //=========================================================================
    // T9 kill priority / completion handshake / full queue
    //=========================================================================
    task automatic test_kill_priority();
        $display("[T9] kill priority and completion handshake");
        // (a) kill beats a same-cycle completion
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h3000, 32'h1111_2222, 4'hF, 1'b0, 1'b1);
        alloc_load(2'd0, 4'hB);
        agu_reg(2'd0, 4'hB, 32'h3000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        tick();
        settle();
        chk(compl_valid, "T9a: completion pending");
        kill_mask = 16'd1 << 4'hB;
        compl_ready = 1'b1;
        settle();
        chk(!compl_valid, "T9a: kill beats a same-cycle completion");
        tick();
        kill_mask = '0;
        chk(lq_used == 3'd0, "T9a: entry released by the kill");

        // (b) a kill of one entry does not disturb another completion
        do_reset();
        sq_clear();
        alloc_load(2'd0, 4'hC);
        alloc_load(2'd1, 4'hD);
        agu_reg(2'd0, 4'hC, 32'h4000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd1, 4'hD, 32'h5000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        lookup_ready = 1'b1;
        settle(); tick();
        fill_valid = 1'b1; fill_idx = 2'd0; fill_word = 32'h0101_0101;
        tick();
        fill_valid = 1'b0;
        lookup_ready = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'hC), "T9b: entry C has a result");
        kill_mask = 16'd1 << 4'hD;
        settle(); tick();
        kill_mask = '0;
        chk(lq_used == 3'd0, "T9b: C completed, D killed");
        tick();

        // (c) completion requires compl_ready; result is stable while waiting
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h6000, 32'hFEED_FACE, 4'hF, 1'b0, 1'b1);
        alloc_load(2'd0, 4'hE);
        agu_reg(2'd0, 4'hE, 32'h6000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        compl_ready = 1'b0;
        tick();
        repeat (3) begin
            settle();
            chk(compl_valid && (compl_tag.slot_index == 4'hE), "T9c: completion held");
            chk32(compl_result, 32'hFEED_FACE, "T9c: result stable under backpressure");
            chk(lq_used == 3'd1, "T9c: not released without compl_ready");
            tick();
        end
        compl_ready = 1'b1;
        settle(); tick();
        chk(lq_used == 3'd0, "T9c: released on compl_ready");

        // (d) full queue: four independent results, one completion per cycle
        do_reset();
        sq_clear();
        compl_ready = 1'b0;
        alloc_load(2'd0, 4'h1);
        alloc_load(2'd1, 4'h2);
        alloc_load(2'd2, 4'h3);
        alloc_load(2'd3, 4'h4);
        chk(lq_full && (lq_used == 3'd4), "T9d: queue full after four allocations");
        agu_reg(2'd0, 4'h1, 32'h1000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd1, 4'h2, 32'h2000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd2, 4'h3, 32'h3000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        agu_reg(2'd3, 4'h4, 32'h4000, LSZ_WORD, 4'hF, 1'b0, 1'b0);
        lookup_ready = 1'b1;
        for (int unsigned k = 0; k < 4; k++) begin
            settle();
            chk(lookup_valid && (lookup_idx == k[1:0]), "T9d: four lookups, oldest first");
            tick();
        end
        lookup_ready = 1'b0;
        settle();
        chk(!lookup_valid, "T9d: no fifth lookup while all four are in flight");
        tick();
        for (int unsigned k = 0; k < 4; k++) begin
            fill_valid = 1'b1;
            fill_idx   = k[1:0];
            fill_word  = 32'h1000_0000 << (8 * k);
            settle(); tick();
        end
        fill_valid = 1'b0;
        compl_ready = 1'b1;
        for (int unsigned k = 0; k < 4; k++) begin
            settle();
            chk(compl_valid, "T9d: completion offered");
            chk(compl_tag.slot_index == (4'h1 + k[3:0]), "T9d: lowest-index completion order");
            chk32(compl_result, 32'h1000_0000 << (8 * k), "T9d: per-entry result data");
            chk(lq_used == (3'd4 - k[2:0]), "T9d: one release per accepted completion");
            tick();
        end
        chk(lq_used == 3'd0, "T9d: queue drained");
        chk(lq_alloc_idx == 2'd0, "T9d: lowest free slot after drain");
    endtask

    //=========================================================================
    // T10 MMIO load
    //=========================================================================
    task automatic test_mmio();
        $display("[T10] MMIO load path");
        // (a) older store hand-over + Head gating, request held until ready
        do_reset();
        sq_ring_begin(3'd0, 1);
        sq_put(0, 32'h8000, 32'h0000_0000, 4'hF, 1'b0, 1'b1);
        alloc_load(2'd0, 4'h9);
        agu_reg(2'd0, 4'h9, 32'h4000, LSZ_WORD, 4'hF, 1'b0, 1'b1);
        load_head_valid = 1'b1; load_head_tag = '{slot_index: 4'h9};
        mmio_req_ready  = 1'b1;
        repeat (2) begin
            settle();
            chk(!mmio_req_valid, "T10a: older store still live -> no device read");
            chk(!lookup_valid,   "T10a: MMIO never issues a lookup");
            tick();
        end
        sq_takeover  = 8'h01;
        settle();
        chk(!mmio_req_valid, "T10a: takeover cycle still blocks the read");
        tick();
        sq_takeover  = 8'h00;
        sq_ring_begin(3'd0, 0);
        load_head_valid = 1'b0;
        settle();
        chk(!mmio_req_valid, "T10a: no Head grant -> no device read");
        tick();
        load_head_valid = 1'b1;
        mmio_req_ready  = 1'b0;
        settle();
        chk(mmio_req_valid,          "T10a: device read once Head granted and mask empty");
        chk32(mmio_req_addr, 32'h4000, "T10a: word-aligned device address");
        chk(!lookup_valid,           "T10a: no lookup for an MMIO entry");
        repeat (2) begin
            tick();
            chk(mmio_req_valid,          "T10a: request held until ready");
            chk32(mmio_req_addr, 32'h4000, "T10a: address stable while held");
            chk(!compl_valid,            "T10a: no completion before the response");
        end
        mmio_req_ready = 1'b1;
        tick();
        settle();
        chk(!mmio_req_valid, "T10a: exactly one device read");
        chk(!compl_valid,    "T10a: no completion before the response");
        tick();
        mmio_rsp_valid = 1'b1; mmio_rsp_data = 32'h8001_0000;
        tick();
        mmio_rsp_valid = 1'b0;
        settle();
        chk(compl_valid && (compl_tag.slot_index == 4'h9), "T10a: completion after the response");
        chk32(compl_result, 32'h8001_0000, "T10a: LW device result");
        tick();
        chk(lq_used == 3'd0, "T10a: released after completion");

        // (b) half-word MMIO extract with a shifted lane
        do_reset();
        sq_clear();
        alloc_load(2'd0, 4'hA);
        agu_reg(2'd0, 4'hA, 32'h4006, LSZ_HALF, 4'b1100, 1'b1, 1'b1);
        load_head_valid = 1'b1; load_head_tag = '{slot_index: 4'hA};
        mmio_req_ready  = 1'b1;
        settle();
        chk(mmio_req_valid,            "T10b: request");
        chk32(mmio_req_addr, 32'h4004, "T10b: word-aligned address of 0x4006");
        tick();
        settle();
        mmio_rsp_valid = 1'b1; mmio_rsp_data = 32'h8001_0000;
        tick();
        mmio_rsp_valid = 1'b0;
        settle();
        chk32(compl_result, 32'h0000_8001, "T10b: LHU upper half, zero extended");
        tick();

        // (c) kill after the request: the response must be discarded
        do_reset();
        sq_clear();
        alloc_load(2'd0, 4'hB);
        agu_reg(2'd0, 4'hB, 32'h4100, LSZ_WORD, 4'hF, 1'b0, 1'b1);
        load_head_valid = 1'b1; load_head_tag = '{slot_index: 4'hB};
        mmio_req_ready  = 1'b1;
        settle();
        chk(mmio_req_valid, "T10c: request issued");
        tick();
        kill_mask = 16'd1 << 4'hB;
        settle();
        chk(!mmio_req_valid, "T10c: no further request after the kill");
        tick();
        kill_mask = '0;
        chk(lq_used == 3'd0, "T10c: killed MMIO entry released");
        mmio_rsp_valid = 1'b1; mmio_rsp_data = 32'hDEAD_BEEF;
        repeat (2) begin
            settle();
            chk(!compl_valid, "T10c: killed device response is discarded");
            tick();
        end
        mmio_rsp_valid = 1'b0;
        chk(lq_used == 3'd0, "T10c: no completion, no resurrection");
    endtask

    //=========================================================================
    // T11 fixed-seed random trace against the reference model
    //=========================================================================
    task automatic rand_cycle();
        logic [3:0] mres;
        logic       el_v; logic [1:0] el_i;
        logic       all_el;
        logic       mmm_v; logic [1:0] mmm_i;
        logic       mmio_pend;
        logic       found;
        logic [1:0] ti;
        int unsigned used;
        logic [1:0] freei;
        logic [3:0] ntag;
        logic [1:0] agu_sel;
        logic agu_any;
        logic [31:0] fill_w;
        logic [31:0] rsp_w;
        logic fill_ok, mmio_ok;
        begin
            //-----------------------------------------------------------------
            // stimulus
            //-----------------------------------------------------------------
            idle_inputs();
            kill_mask = 16'd0;
            compl_ready  = (rnd_range(0, 99) < 80);
            lookup_ready = (rnd_range(0, 99) < 70);
            mmio_req_ready = (rnd_range(0, 99) < 70);

            // store hand-over at the ring head (keeps the SQ ring consistent)
            m_takeover = 8'd0;
            if ((m_occn != 4'd0) && (rnd_range(0, 99) < 25)) begin
                m_takeover[m_head] = 1'b1;
            end

            // new store at the tail
            if ((m_occn != 4'd8) && (rnd_range(0, 99) < 40)) begin
                logic [2:0] tail;
                logic [1:0] low;
                lsu_size_t  sz;
                tail = (m_head + m_occn[2:0]) & 3'd7;
                m_saddr[tail]  = rnd();
                low            = m_saddr[tail][1:0];
                sz             = lsu_size_t'(rnd_range(0, 2));
                m_sbmask[tail] = lsu_size_mask(low, sz);
                m_sdata[tail]  = rnd();
                m_smmio[tail]  = (rnd_range(0, 99) < 10);
                m_sav[tail]    = (rnd_range(0, 99) < 60);
                m_occ[tail]    = 1'b1;
            end

            // load allocation (use the DUT's lowest-free-slot output)
            if ((model_used() < 4) && (rnd_range(0, 99) < 35)) begin
                freei = lq_alloc_idx;
                ntag  = 4'(rnd_range(0, 15));
                // avoid duplicating a live tag
                for (int unsigned g = 0; g < 16; g++) begin
                    logic dup;
                    dup = 1'b0;
                    for (int unsigned j = 0; j < 4; j++)
                        if (m_alive[j] && (m_tag[j] == ntag)) dup = 1'b1;
                    if (!dup) break;
                    ntag = 4'(ntag + 4'd1);
                end
                alloc_valid = 1'b1;
                alloc_idx   = freei;
                alloc_tag   = '{slot_index: ntag};
                m_agu_dly[freei] = rnd_range(1, 3);
            end

            // kill a random live entry
            if ((model_used() != 0) && (rnd_range(0, 99) < 12)) begin
                int unsigned k;
                logic hit;
                k = rnd_range(0, 3);
                hit = 1'b0;
                for (int unsigned g = 0; g < 4; g++) begin
                    if (!hit && m_alive[(k + g) % 4]) begin
                        kill_mask = 16'd1 << m_tag[(k + g) % 4];
                        hit = 1'b1;
                    end
                end
            end

            // AGU registration for the oldest pending allocation
            agu_any = 1'b0;
            agu_sel = 0;
            for (int unsigned i = 0; i < 4; i++) begin
                if (!agu_any && m_alive[i] && (m_agu_dly[i] == 0) && !m_av[i]) begin
                    agu_any = 1'b1;
                    agu_sel = i[1:0];
                end
            end
            if (agu_any) begin
                agu_valid       = 1'b1;
                agu_qidx        = {1'b0, agu_sel};
                agu_tag         = '{slot_index: m_tag[agu_sel]};
                agu_addr        = m_addr[agu_sel];
                agu_size        = m_size[agu_sel];
                agu_byte_mask   = m_bmask[agu_sel];
                agu_is_unsigned = m_uns[agu_sel];
                agu_is_mmio     = m_mmio[agu_sel];
            end

            // fills for in-flight entries
            fill_valid = 1'b0;
            fill_w     = rnd();
            for (int unsigned i = 0; i < 4; i++) begin
                if (!fill_valid && m_alive[i] && m_inflight[i] && (m_fill_dly[i] == 0)
                    && (rnd_range(0, 99) < 60)) begin
                    fill_valid = 1'b1;
                    fill_idx   = i[1:0];
                    fill_word  = fill_w;
                end
            end
            // occasionally a stale fill that owns no in-flight entry
            if (!fill_valid && (rnd_range(0, 99) < 8)) begin
                fill_valid = 1'b1;
                fill_idx   = 2'(rnd_range(0, 3));
                fill_word  = fill_w;
            end

            // MMIO response for the pending device read
            mmio_rsp_valid = 1'b0;
            rsp_w          = rnd();
            for (int unsigned i = 0; i < 4; i++) begin
                if (!mmio_rsp_valid && m_alive[i] && m_msent[i] && (m_rsp_dly[i] == 0)) begin
                    mmio_rsp_valid = 1'b1;
                    mmio_rsp_data  = rsp_w;
                end
            end

            // Commit Head: the oldest live load is the head
            if ((model_used() != 0) && (rnd_range(0, 99) < 55)) begin
                load_head_valid = 1'b1;
                load_head_tag   = '{slot_index: m_tag[m_ord[0]]};
            end

            drive_sq();
            // settle first: the model expectations and the checks below read
            // DUT combinational outputs (compl_valid / lookup_valid / ...)
            settle();

            //-----------------------------------------------------------------
            // model expectations (independent reference)
            //-----------------------------------------------------------------
            mres = 4'd0;
            for (int unsigned i = 0; i < 4; i++) begin
                // release decided this cycle (kill or actual completion)
                m_rel[i] = m_alive[i]
                         && (kill_mask[m_tag[i]]
                             || (compl_valid && compl_ready
                                 && (compl_tag.slot_index == m_tag[i])));
            end
            for (int unsigned i = 0; i < 4; i++) begin
                m_dep[i]      = model_dep(i[1:0]);
                model_fwd(i[1:0], m_fm[i], m_fd[i]);
                m_snap_now[i] = m_alive[i] && m_av[i] && !m_mmio[i] && !m_snap_v[i]
                             && m_dep[i] && !m_rel[i];
                m_ff[i]       = m_snap_now[i]
                             && ((m_fm[i] & m_bmask[i]) == m_bmask[i]);
                m_elig[i]     = m_alive[i] && m_av[i] && !m_mmio[i] && !m_inflight[i]
                             && !m_resv[i] && m_dep[i] && !m_ff[i] && !m_rel[i];
                m_mel[i]      = m_alive[i] && m_av[i] && m_mmio[i] && !m_msent[i]
                             && (m_older[i] == 8'd0) && load_head_valid
                             && (load_head_tag.slot_index == m_tag[i]) && !m_rel[i];
                // a killed entry never produces a completion
                if (m_resv[i] && !kill_mask[m_tag[i]]) mres[i] = 1'b1;
            end
            // oldest-serviceable lookup arbitration (with the request hold)
            el_v = 1'b0; el_i = 2'd0; all_el = 1'b0;
            for (int k = 3; k >= 0; k--) begin
                if ((k[2:0] < m_ordcnt) && m_elig[m_ord[k]]) begin
                    all_el = 1'b1; el_i = m_ord[k];
                end
            end
            if (m_hold_v && m_elig[m_hold_idx]) begin
                el_v = 1'b1; el_i = m_hold_idx;
            end else if (!m_hold_v) begin
                el_v = all_el;
            end
            // MMIO request (single outstanding in the LQ)
            mmm_v = 1'b0; mmm_i = 2'd0;
            for (int k = 3; k >= 0; k--)
                if ((k[2:0] < m_ordcnt) && m_mel[m_ord[k]]) begin mmm_v = 1'b1; mmm_i = m_ord[k]; end
            mmio_pend = 1'b0;
            for (int unsigned i = 0; i < 4; i++)
                mmio_pend = mmio_pend || (m_alive[i] && m_msent[i] && !m_rel[i]);

            used = model_used();
            freei = model_free();

            //-----------------------------------------------------------------
            // compare
            //-----------------------------------------------------------------
            chk(lq_used == used[2:0], "RND: lq_used");
            chk(lq_full == (used == 4), "RND: lq_full");
            if (used < 4) chk(lq_alloc_idx == freei, "RND: lq_alloc_idx");
            chk(lookup_valid == el_v, "RND: lookup_valid");
            if (lookup_valid) begin
                chk(lookup_idx == el_i, "RND: lookup_idx (oldest serviceable)");
                chk32(lookup_addr, m_addr[lookup_idx], "RND: lookup_addr");
                chk(lookup_tag.slot_index == m_tag[lookup_idx], "RND: lookup_tag");
            end
            chk(compl_valid == (mres != 4'd0), "RND: compl_valid set");
            if (compl_valid) begin
                ti = model_tag_idx(compl_tag.slot_index, found);
                chk(found, "RND: completion tag is a live entry");
                if (found) begin
                    chk(m_resv[ti], "RND: completion entry has a result");
                    chk32(compl_result, m_res[ti], "RND: completion result");
                    chk(!m_mdone[ti], "RND: one completion per lifetime");
                end
            end
            chk(mmio_req_valid == (mmm_v && !mmio_pend), "RND: mmio_req_valid");
            if (mmio_req_valid)
                chk32(mmio_req_addr, {m_addr[mmm_i][31:2], 2'b00}, "RND: mmio_req_addr");

            //-----------------------------------------------------------------
            // model update for this clock edge
            //-----------------------------------------------------------------
            for (int unsigned i = 0; i < 4; i++) begin
                if (alloc_valid && (alloc_idx == i[1:0])) begin
                    m_alive[i]   = 1'b1;
                    m_tag[i]     = alloc_tag.slot_index;
                    m_av[i]      = 1'b0;
                    m_addr[i]    = rnd();
                    m_size[i]    = lsu_size_t'(rnd_range(0, 2));
                    m_bmask[i]   = lsu_size_mask(m_addr[i][1:0], m_size[i]);
                    m_uns[i]     = (rnd_range(0, 99) < 50);
                    m_mmio[i]    = (rnd_range(0, 99) < 25);
                    m_older[i]   = m_occ & ~m_takeover;
                    m_snap_v[i]  = 1'b0;
                    m_inflight[i]= 1'b0;
                    m_resv[i]    = 1'b0;
                    m_msent[i]   = 1'b0;
                    m_mdone[i]   = 1'b0;
                    m_fill_dly[i]= 0;
                    m_rsp_dly[i] = 0;
                    if (m_agu_dly[i] == 0) m_agu_dly[i] = 1;
                end else if (m_rel[i]) begin
                    m_alive[i]   = 1'b0;
                    m_av[i]      = 1'b0;
                    m_snap_v[i]  = 1'b0;
                    m_inflight[i]= 1'b0;
                    m_resv[i]    = 1'b0;
                    m_msent[i]   = 1'b0;
                    m_agu_dly[i] = 0;
                    m_fill_dly[i]= 0;
                    m_rsp_dly[i] = 0;
                end else if (m_alive[i]) begin
                    // acceptance of a response uses the PRE-edge ownership flag
                    // (a fill in the lookup-fire cycle must be rejected, exactly
                    //  like the RTL does)
                    fill_ok = m_inflight[i];
                    mmio_ok = m_msent[i];
                    if (agu_valid && (agu_qidx[1:0] == i[1:0])) begin
                        m_av[i] = 1'b1;
                    end
                    if (lookup_valid && lookup_ready && (lookup_idx == i[1:0])) begin
                        m_inflight[i] = 1'b1;
                        m_fill_dly[i] = rnd_range(1, 3);
                    end
                    if (mmio_req_valid && mmio_req_ready && (mmm_i == i[1:0])) begin
                        m_msent[i] = 1'b1;
                        m_rsp_dly[i] = rnd_range(1, 3);
                    end
                    if (m_ff[i]) begin
                        m_snap_v[i] = 1'b1;
                        m_smask[i]  = m_fm[i];
                        m_snap_data[i] = m_fd[i];
                        m_resv[i]   = 1'b1;
                        m_res[i]    = tb_extract(32'd0, m_fm[i], m_fd[i], m_uns[i],
                                                 m_addr[i][1:0], m_size[i]);
                    end else if (m_snap_now[i]) begin
                        m_snap_v[i] = 1'b1;
                        m_smask[i]  = m_fm[i];
                        m_snap_data[i] = m_fd[i];
                    end else if (fill_valid && (fill_idx == i[1:0]) && fill_ok) begin
                        m_resv[i]    = 1'b1;
                        m_res[i]     = tb_extract(fill_word, m_fm[i], m_fd[i], m_uns[i],
                                                  m_addr[i][1:0], m_size[i]);
                        m_inflight[i]= 1'b0;
                    end else if (mmio_rsp_valid && mmio_ok) begin
                        m_resv[i] = 1'b1;
                        m_res[i]  = tb_extract(mmio_rsp_data, 4'd0, 32'd0, m_uns[i],
                                               m_addr[i][1:0], m_size[i]);
                        m_msent[i] = 1'b0;
                    end
                    m_older[i] = m_older[i] & ~m_takeover;
                end
            end
            // completion bookkeeping (entry leaves after compl_valid && compl_ready)
            if (compl_valid && compl_ready) begin
                ti = model_tag_idx(compl_tag.slot_index, found);
                if (found) m_mdone[ti] = 1'b1;
            end

            // age list: compact survivors, append a new allocation
            begin
                logic [1:0] surv[4];
                logic [2:0] scnt;
                scnt = 3'd0;
                for (int unsigned k = 0; k < 4; k++) begin
                    surv[k] = 2'd0;
                    if ((k[2:0] < m_ordcnt) && !m_rel[m_ord[k]]) begin
                        surv[scnt[1:0]] = m_ord[k];
                        scnt = scnt + 3'd1;
                    end
                end
                for (int unsigned m = 0; m < 4; m++) begin
                    if (m[2:0] < scnt) m_ord[m] = surv[m];
                    else if (alloc_valid && (m[2:0] == scnt)) m_ord[m] = alloc_idx;
                    else m_ord[m] = 2'd0;
                end
                m_ordcnt = scnt + (alloc_valid ? 3'd1 : 3'd0);
            end

            // lookup hold
            if (el_v && lookup_ready) begin
                m_hold_v = 1'b0; m_hold_idx = 2'd0;
            end else if (el_v) begin
                m_hold_v = 1'b1; m_hold_idx = el_i;
            end else begin
                m_hold_v = 1'b0; m_hold_idx = 2'd0;
            end

            // SQ model update: hand-over, then the new store
            if (m_takeover != 8'd0) begin
                for (int unsigned s = 0; s < 8; s++)
                    if (m_takeover[s]) begin
                        m_occ[s] = 1'b0;
                        m_sav[s] = 1'b0;
                    end
                // the head advances past the handed-over store
                m_head = (m_head + 3'd1) & 3'd7;
            end
            // (the new store was already written above into m_occ/m_sav)
            for (int unsigned i = 0; i < 4; i++) if (m_agu_dly[i] != 0) m_agu_dly[i] = m_agu_dly[i] - 1;
            for (int unsigned i = 0; i < 4; i++) if (m_fill_dly[i] != 0) m_fill_dly[i] = m_fill_dly[i] - 1;
            for (int unsigned i = 0; i < 4; i++) if (m_rsp_dly[i] != 0) m_rsp_dly[i] = m_rsp_dly[i] - 1;
            m_occn = model_popcount(m_occ);

            tick();
        end
    endtask

    task automatic test_random();
        $display("[T11] fixed-seed random trace (12000 cycles) vs reference model");
        do_reset();
        model_clear();
        drive_sq();
        rng_state = 32'hC0FF_EE01;
        for (int unsigned c = 0; c < 12000; c++) rand_cycle();
        // final state must be consistent
        settle();
        chk(lq_used == model_used()[2:0], "RND final: lq_used");
        $display("      random trace done: %0d checks so far, %0d errors", checks, errors);
    endtask

    //=========================================================================
    // main sequence
    //=========================================================================
    initial begin
        rst = 1'b1;
        idle_all();
        rng_state = 32'hC0FF_EE01;
        repeat (3) tick();
        rst = 1'b0;
        tick();

        test_reset();
        test_alloc_mask();
        test_agu_arb();
        test_takeover_dep();
        test_partial_fill();
        test_full_forward_all();
        test_order_wrap();
        test_inflight_kill();
        test_kill_priority();
        test_mmio();
        test_random();

        chk(n_wait_seen > 0, "waiter token was never observed pending");
        chk(n_epoch_seen > 0, "allocation generation never advanced");
        if (errors == 0)
            $display("ALL TESTS PASSED: %0d checks - reset/alloc+older_store_mask/AGU-gate/dep_ready+takeover/partial+fill/full-forward LB-LBU-LH-LHU-LW/age-list+wrap+alloc_idx/kill+stale-fill/completion-handshake/MMIO/waiter-tokens(%0d epoch bumps, %0d pending samples, last tag %0d)/12000-cycle random-vs-model", checks, n_epoch_seen, n_wait_seen, last_tag_seen.slot_index);
        else
            $fatal(1, "FAILED: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule
