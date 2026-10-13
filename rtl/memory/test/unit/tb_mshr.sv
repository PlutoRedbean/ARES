//=============================================================================
// ARES LSU - self-checking unit bench for the L08 MSHR
//-----------------------------------------------------------------------------
// DUT : rtl/memory/mshr.sv - 2-entry MSHR (reserve / victim capture / refill /
//       store overlay / install / wake).
// Spec: docs/microarch/memory.md 6.4 (per cycle ownership + state machine),
//       6.5 (overlay / early takeover / same cycle rules), 6.6 (dirty victim
//       writeback), 6.7 (single outstanding 16B read), 6.8 (priority and
//       invariants); rtl/memory/LSU_INTERFACES.md section 10 (frozen interface)
//       and section 8 (verification requirements); docs/m2b_decisions.md
//       D-M2b-04 (waiter token isolation), D-M2b-05 (one WAKE handover per
//       cycle), D-M2b-08 (in-TB state/transition coverage gate).
// FREE items: FREE-10 (verification environment internal structure).
//
// Structure (independent top, own clock/reset, no DPI, no harness):
//   * TB side byte memory plus a per {set,way} tag/line model; the capture R
//     port model answers one cycle after cap_gnt with the victim Row, the
//     refill model reassembles the line behind a single outstanding read and
//     the install W port model builds the target cache line image,
//   * a cycle accurate reference model (state, Way lock, waiter token set,
//     overlay mask/data, latched refill line, Row counters) compared against
//     the DUT every cycle - outputs and internal state through XMR,
//   * directed scenarios: Clean miss full flow, Dirty victim capture + WB Rows,
//     Store overlay early takeover + install byte merge, two MSHRs competing
//     for the refill port, four waiters handed over one per cycle, a stale
//     (killed + reused) waiter that must never be delivered, the frozen
//     INSTALL/WAKE overlay window, resv_ready / busy behaviour and the
//     incomplete-beat negative case,
//   * a fixed seed randomised phase (RAND_CYCLES) with random reserve / merge /
//     overlay / LQ kill+reuse traffic against stalled capture, install, refill
//     and wake channels,
//   * SV state / transition coverage counters for the 6-state FSM (100% gate).
//
// Build / run (repository root, LINE_BYTES = 16 | 32 | 64; ROWS_PER_LINE and
// LINE_BEATS come from ares_pkg):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//       --top-module tb_mshr --Mdir sim/build/unit/tb_mshr -o tb_mshr \
//       rtl/common/ares_pkg.sv rtl/memory/mshr.sv \
//       rtl/memory/test/unit/tb_mshr.sv
//   sim/build/unit/tb_mshr/tb_mshr
//   (-o is resolved against --Mdir by Verilator 5.x, so the output name must be
//    given relative to the Mdir.)
//=============================================================================
`timescale 1ns/1ps

module tb_mshr;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Configuration / geometry
    //-------------------------------------------------------------------------
    localparam int unsigned N       = MSHR_ENTRIES;              // 2
    localparam int unsigned LQN     = LQ_ENTRIES;                // 4
    localparam int unsigned ROWS    = ROWS_PER_LINE;             // 2/4/8
    localparam int unsigned ROWW    = $clog2(ROWS);              // 1/2/3
    localparam int unsigned CNTW    = ROWW + 1;
    localparam int unsigned LBYTES  = LINE_BYTES;                // 16/32/64
    localparam int unsigned NW      = 8 * LINE_BYTES;
    localparam int unsigned NBEAT   = LINE_BEATS;                // 1/2/4
    localparam int unsigned WIDXW   = DCACHE_OFFSET_BITS - 2;    // word index
    localparam int unsigned IBITS   = DCACHE_INDEX_BITS;
    localparam int unsigned TBITS   = DCACHE_TAG_BITS;
    localparam int unsigned OBITS   = DCACHE_OFFSET_BITS;
    localparam int unsigned LQIW    = $clog2(LQ_ENTRIES);
    localparam int unsigned TAGW    = 4;                         // TB line tag
    localparam int unsigned MEM_BYTES = 1 << 16;
    localparam int unsigned NSETS     = DCACHE_NUM_SETS;
    localparam logic [CNTW-1:0] LAST_ROW = CNTW'(ROWS - 1);

    // FSM encoding of rtl/memory/mshr.sv (checked implicitly by the coverage
    // and transition checks below).
    localparam logic [2:0] ST_FREE = 3'd0;
    localparam logic [2:0] ST_RESV = 3'd1;
    localparam logic [2:0] ST_CAP  = 3'd2;
    localparam logic [2:0] ST_READ = 3'd3;
    localparam logic [2:0] ST_INST = 3'd4;
    localparam logic [2:0] ST_WAKE = 3'd5;
    localparam int unsigned N_STATES = 6;
    localparam int unsigned N_TRANS  = 13;

    localparam int unsigned RAND_CYCLES = 11000;
    localparam int unsigned WATCHDOG_CYCLES = 500000;

    //-------------------------------------------------------------------------
    // Clock / reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        repeat (WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1, "TB FAILED: watchdog timeout after %0d cycles", WATCHDOG_CYCLES);
    end

    //-------------------------------------------------------------------------
    // DUT ports (frozen names, LSU_INTERFACES.md section 10)
    //-------------------------------------------------------------------------
    logic [N-1:0]                  lock_valid;
    logic [N-1:0][31:0]              lock_line_addr;
    logic [N-1:0][1:0]               lock_way;
    logic [N-1:0]                  busy;
    logic [31:0]                     match_line_addr;
    logic [N-1:0]                  match_hit;
    logic                            resv_valid;
    logic                            resv_ready;
    logic [31:0]                     resv_line_addr;
    logic [1:0]                      resv_way;
    logic                            resv_victim_dirty;
    logic [1:0]                      resv_wb_idx;
    logic                            resv_is_store;
    logic [1:0]                      resv_lq_idx;
    ares_pkg::tag_t                  resv_lq_tag;
    logic [7:0]                      resv_lq_epoch;
    logic [WIDXW-1:0]                resv_word_idx;
    logic [3:0]                      resv_store_mask;
    logic [31:0]                     resv_store_data;
    logic [WIDXW-1:0]                resv_store_widx;
    logic                            merge_valid;
    logic [N-1:0]                    merge_sel;
    logic                            merge_ready;
    logic                            merge_is_store;
    logic [1:0]                      merge_lq_idx;
    ares_pkg::tag_t                  merge_lq_tag;
    logic [7:0]                      merge_lq_epoch;
    logic [WIDXW-1:0]                merge_word_idx;
    logic [3:0]                      merge_store_mask;
    logic [31:0]                     merge_store_data;
    logic [WIDXW-1:0]                merge_store_widx;
    logic [N-1:0]                  cap_req_valid;
    logic [N-1:0][1:0]               cap_req_way;
    logic [N-1:0][ROWW-1:0]          cap_req_row;
    logic [N-1:0]                  cap_gnt;
    logic                            cap_rsp_valid;
    logic [IBITS-1:0]                cap_rsp_set;
    logic [ROWW-1:0]                 cap_rsp_row;
    logic [1:0]                      cap_rsp_way;
    logic [63:0]                     cap_rsp_data;
    logic [N-1:0]                  wb_wr_valid;
    logic [N-1:0][1:0]               wb_wr_idx;
    logic [N-1:0][ROWW-1:0]          wb_wr_row;
    logic [N-1:0][63:0]              wb_wr_data;
    logic [N-1:0]                  wb_wr_last;
    logic                            ovl_valid;
    logic [N-1:0]                    ovl_sel;
    logic                            ovl_ready;
    logic [WIDXW-1:0]                ovl_widx;
    logic [3:0]                      ovl_mask;
    logic [31:0]                     ovl_data;
    logic                            refill_req_valid;
    logic                            refill_req_ready;
    logic [31:0]                     refill_line_addr;
    logic                            refill_rsp_valid;
    logic                            refill_rsp_ready;
    logic [NW-1:0]                   refill_line_data;
    logic [NBEAT-1:0]                refill_beat_valid;
    logic [N-1:0]                  inst_valid;
    logic [N-1:0][1:0]               inst_way;
    logic [N-1:0][IBITS-1:0]         inst_set;
    logic [N-1:0][ROWW-1:0]          inst_row;
    logic [N-1:0][63:0]              inst_data;
    logic [N-1:0][7:0]               inst_be;
    logic [N-1:0]                  inst_last;
    logic [N-1:0]                  inst_gnt;
    logic [N-1:0]                  pub_valid;
    logic [N-1:0][1:0]               pub_way;
    logic [N-1:0][TBITS-1:0]         pub_tag;
    logic [N-1:0]                  pub_dirty;
    logic [N-1:0]                  wake_valid;
    logic [N-1:0][1:0]               wake_lq_idx;
    logic [N-1:0][31:0]              wake_word;
    logic [N-1:0]                  wake_ready;
    logic [LQN-1:0]                  lq_wait_pending;
    ares_pkg::tag_t                  lq_wait_tag [LQN];
    logic [7:0]                      lq_wait_epoch [LQN];

    mshr dut (.*);

    //-------------------------------------------------------------------------
    // Checker / counters
    //-------------------------------------------------------------------------
    int unsigned checks;
    int unsigned errors;
    int unsigned wake_deliveries;
    int unsigned n_reserve;
    int unsigned n_refill;
    int unsigned n_install;
    int unsigned n_pub;
    int unsigned n_wb_row;

    task automatic chk(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 60) $display("[%0t] FAIL: %s", $time, msg);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // TB memory + {set,way} cache model
    //-------------------------------------------------------------------------
    logic [7:0]      mem [MEM_BYTES];
    logic [TAGW-1:0] cam_tag [NSETS][2];
    logic            cam_valid [NSETS][2];
    logic            cam_dirty [NSETS][2];
    logic [NW-1:0]   cam_line [NSETS][2];      // image built by the install port
    logic            mem_init_done;

    function automatic logic [7:0] mem_pattern(input logic [31:0] byte_addr);
        logic [31:0] x;
        begin
            x = byte_addr * 32'h9E37_79B1;
            mem_pattern = x[31:24] ^ x[23:16] ^ x[15:8] ^ x[7:0];
        end
    endfunction

    function automatic logic [31:0] tb_addr(input logic [TAGW-1:0] tag, input logic [IBITS-1:0] set);
        tb_addr = (32'(tag) << (IBITS + OBITS)) | (32'(set) << OBITS);
    endfunction

    function automatic logic [63:0] mem_row(input logic [31:0] base, input logic [ROWW-1:0] row);
        logic [63:0] d;
        begin
            for (int unsigned b = 0; b < 8; b++)
                d[8*b +: 8] = mem[16'((base + 32'(row) * 32'd8 + 32'(b)) & 32'h0000_FFFF)];
            mem_row = d;
        end
    endfunction

    function automatic logic [NW-1:0] mem_line(input logic [31:0] base);
        logic [NW-1:0] d;
        begin
            for (int unsigned b = 0; b < LBYTES; b++)
                d[8*b +: 8] = mem[16'((base + 32'(b)) & 32'h0000_FFFF)];
            mem_line = d;
        end
    endfunction

    function automatic logic [NW-1:0] tb_merge(input logic [NW-1:0] line,
                                               input logic [LBYTES-1:0] mask,
                                               input logic [NW-1:0] data);
        logic [NW-1:0] r;
        begin
            r = line;
            for (int unsigned b = 0; b < LBYTES; b++)
                if (mask[b]) r[8*b +: 8] = data[8*b +: 8];
            tb_merge = r;
        end
    endfunction

    function automatic logic [31:0] tb_word(input logic [NW-1:0] line, input logic [WIDXW-1:0] widx);
        tb_word = line[32*32'(widx) +: 32];
    endfunction

    function automatic logic [63:0] tb_row(input logic [NW-1:0] line, input logic [CNTW-1:0] row);
        logic [63:0] d;
        begin
            for (int unsigned b = 0; b < 8; b++)
                d[8*b +: 8] = line[8*(8*32'(row) + 32'(b)) +: 8];
            tb_row = d;
        end
    endfunction

    function automatic logic [LBYTES-1:0] ovl_mask_upd_tb(input logic [LBYTES-1:0] m,
                                                          input logic [WIDXW-1:0] widx,
                                                          input logic [3:0] bmask);
        ovl_mask_upd_tb = m | (LBYTES'(bmask) << (4 * 32'(widx)));
    endfunction

    function automatic logic [NW-1:0] ovl_data_upd_tb(input logic [NW-1:0] d,
                                                      input logic [WIDXW-1:0] widx,
                                                      input logic [3:0] bmask,
                                                      input logic [31:0] wdata);
        logic [NW-1:0] r;
        begin
            r = d;
            for (int unsigned b = 0; b < 4; b++)
                if (bmask[b]) r[8*(4*32'(widx) + 32'(b)) +: 8] = wdata[8*b +: 8];
            ovl_data_upd_tb = r;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!mem_init_done) begin
            mem_init_done <= 1'b1;
            for (int unsigned a = 0; a < MEM_BYTES; a++) mem[a] <= mem_pattern(32'(a));
            for (int unsigned s = 0; s < NSETS; s++) begin
                for (int unsigned w = 0; w < 2; w++) begin
                    cam_tag[s][w]   <= TAGW'((s + 3*w + 1) & 15);
                    cam_valid[s][w] <= 1'b1;
                    cam_dirty[s][w] <= 1'b0;
                    cam_line[s][w]  <= '0;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Capture R port model (dcache_arrays read channel, response next cycle)
    //-------------------------------------------------------------------------
    logic cap_go;
    logic capr_valid;
    logic [IBITS-1:0] capr_set;
    logic [ROWW-1:0]  capr_row;
    logic [1:0]       capr_way;
    logic [63:0]      capr_data;

    always_comb cap_gnt = cap_go ? (cap_req_valid & (~cap_req_valid + 1'b1)) : {N{1'b0}};

    assign cap_rsp_valid = capr_valid;
    assign cap_rsp_set   = capr_set;
    assign cap_rsp_row   = capr_row;
    assign cap_rsp_way   = capr_way;
    assign cap_rsp_data  = capr_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            capr_valid <= 1'b0;
            capr_set   <= '0;
            capr_row   <= '0;
            capr_way   <= 2'd0;
            capr_data  <= '0;
        end else begin
            capr_valid <= |cap_gnt;
            for (int unsigned e = 0; e < N; e++) begin
                if (cap_gnt[e]) begin
                    capr_set  <= dut.line_q[e][OBITS +: IBITS];
                    capr_way  <= cap_req_way[e];
                    capr_row  <= cap_req_row[e];
                    capr_data <= mem_row(tb_addr(cam_tag[dut.line_q[e][OBITS +: IBITS]][cap_req_way[e][1]],
                                                 dut.line_q[e][OBITS +: IBITS]),
                                         cap_req_row[e]);
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Refill read model (single outstanding read, LINE_BEATS reassembly)
    //-------------------------------------------------------------------------
    int unsigned     rf_lat;
    logic            rf_partial;
    logic [NBEAT-1:0] rf_pmask;
    logic            rf_busy;
    logic            rf_rsp;
    int unsigned     rf_cnt;
    logic [31:0]     rf_addr;
    logic [NW-1:0]   rf_line;
    int unsigned     mdl_prot_err;

    assign refill_req_ready  = (!rf_busy) || (rf_rsp && refill_rsp_ready);
    assign refill_rsp_valid  = rf_rsp;
    assign refill_line_data  = rf_line;
    assign refill_beat_valid = rf_rsp ? (rf_partial ? rf_pmask : {NBEAT{1'b1}}) : {NBEAT{1'b0}};

    logic rf_req_fire;
    assign rf_req_fire = refill_req_valid && refill_req_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            rf_busy <= 1'b0;
            rf_rsp  <= 1'b0;
            rf_cnt  <= 0;
            rf_addr <= 32'd0;
            rf_line <= '0;
        end else if (rf_req_fire) begin
            rf_busy <= 1'b1;
            rf_rsp  <= 1'b0;
            rf_cnt  <= rf_lat;
            rf_addr <= refill_line_addr;
            rf_line <= mem_line(refill_line_addr);
        end else if (rf_busy && !rf_rsp) begin
            if (rf_cnt == 0) begin
                rf_rsp  <= 1'b1;
                rf_line <= mem_line(rf_addr);      // reassembled line for this address
            end else begin
                rf_cnt <= rf_cnt - 1;
            end
        end else if (rf_rsp && refill_rsp_ready) begin
            rf_rsp  <= 1'b0;
            rf_busy <= 1'b0;
        end
    end

    // protocol guard: never accept a read while one is outstanding
    always_ff @(posedge clk) begin
        if (!rst && rf_req_fire && rf_busy && !(rf_rsp && refill_rsp_ready)) begin
            $display("[%0t] FAIL: refill accepted while a read is outstanding", $time);
            mdl_prot_err <= mdl_prot_err + 1;
        end
    end

    //-------------------------------------------------------------------------
    // Install W port model
    //-------------------------------------------------------------------------
    logic inst_go;
    assign inst_gnt = inst_go ? inst_valid : {N{1'b0}};

    always_ff @(posedge clk) begin
        if (!rst) begin
            for (int unsigned e = 0; e < N; e++) begin
                if (inst_gnt[e]) begin
                    for (int unsigned b = 0; b < 8; b++)
                        cam_line[inst_set[e]][inst_way[e][1]][8*(8*32'(inst_row[e]) + 32'(b)) +: 8]
                            <= inst_data[e][8*b +: 8];
                    if (inst_last[e]) begin
                        cam_tag[inst_set[e]][inst_way[e][1]]   <= dut.line_q[e][15:12];
                        cam_valid[inst_set[e]][inst_way[e][1]] <= 1'b1;
                        cam_dirty[inst_set[e]][inst_way[e][1]] <= pub_dirty[e];
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Reference model state
    //-------------------------------------------------------------------------
    logic [2:0]        m_state [N];
    logic [31:0]       m_line  [N];
    logic [1:0]        m_way   [N];
    logic [1:0]        m_wbidx [N];
    logic [CNTW-1:0]   m_capg  [N];
    logic [CNTW-1:0]   m_capr  [N];
    logic [N-1:0]      m_rdsent;
    logic [NW-1:0]     m_ldata [N];
    logic [N-1:0]      m_lfull;
    logic [CNTW-1:0]   m_irow  [N];
    logic [LBYTES-1:0] m_omask [N];
    logic [NW-1:0]     m_odata [N];
    logic [LQN-1:0]    m_wqv   [N];
    logic [3:0]        m_wtag  [N][LQN];
    logic [7:0]        m_wep   [N][LQN];
    logic [WIDXW-1:0]  m_wwidx [N][LQN];

    function automatic logic [IBITS-1:0] m_set_of(input logic [31:0] a);
        m_set_of = IBITS'(a >> OBITS);         // Set index of a TB line address
    endfunction

    task automatic mdl_reset();
        begin
            for (int unsigned e = 0; e < N; e++) begin
                m_state[e]  = ST_FREE;
                m_line[e]   = 32'd0;
                m_way[e]    = 2'd0;
                m_wbidx[e]  = 2'd0;
                m_capg[e]   = '0;
                m_capr[e]   = '0;
                m_rdsent[e] = 1'b0;
                m_ldata[e]  = '0;
                m_lfull[e]  = 1'b0;
                m_irow[e]   = '0;
                m_omask[e]  = '0;
                m_odata[e]  = '0;
                m_wqv[e]    = '0;
                for (int unsigned i = 0; i < LQN; i++) begin
                    m_wtag[e][i]  = 4'd0;
                    m_wep[e][i]   = 8'd0;
                    m_wwidx[e][i] = '0;
                end
            end
        end
    endtask

    // cycle accurate compare + advance (runs mid cycle, after the edge settled)
    task automatic mdl_cycle();
        logic [N-1:0]    free_m, g_resv, acc_m, acc_o, g_mrg, g_ovl;
        logic [N-1:0]    cap_req_p, rsp_match_p, rf_mask, g_rf, rd_own, inst_p, pub_p;
        logic [LQN-1:0]  live_e [N];
        logic [LQN-1:0]  stale_e [N];
        logic [LQN-1:0]  sel_e [N];
        logic [LQN-1:0]  clrv, wqv_n;
        logic            beat_full, rsp_fire, rf_req_v, resv_fire_m;
        logic [31:0]     rf_addr_p, exp_w;
        logic [1:0]      sel_i, di;
        logic [CNTW-1:0] capg_n, capr_n, irow_n, capr_cur, irow_cur;
        logic [2:0]      st_n;
        logic            dlive;
        begin
            //---- 1. predictions from the model state ------------------------
            free_m = '0;
            for (int unsigned e = 0; e < N; e++) free_m[e] = (m_state[e] == ST_FREE);

            for (int unsigned e = 0; e < N; e++) begin
                cap_req_p[e]   = ((m_state[e] == ST_RESV) || (m_state[e] == ST_CAP))
                                 && (m_capg[e] < CNTW'(ROWS));
                rsp_match_p[e] = cap_rsp_valid
                                 && ((m_state[e] == ST_RESV) || (m_state[e] == ST_CAP))
                                 && (m_capg[e] > m_capr[e])
                                 && (cap_rsp_way == m_way[e])
                                 && (cap_rsp_set == m_set_of(m_line[e]))
                                 && (cap_rsp_row == ROWW'(m_capr[e]));
                rf_mask[e] = (m_state[e] == ST_READ) && !m_rdsent[e];
                inst_p[e]  = (m_state[e] == ST_INST) && m_lfull[e];
                pub_p[e]   = inst_p[e] && inst_gnt[e] && (m_irow[e] == LAST_ROW);
                live_e[e]  = '0;
                for (int unsigned i = 0; i < LQN; i++)
                    live_e[e][i] = m_wqv[e][i] && lq_wait_pending[i]
                                   && (lq_wait_tag[i] == ares_pkg::tag_t'(m_wtag[e][i]))
                                   && (lq_wait_epoch[i] == m_wep[e][i]);
                stale_e[e] = m_wqv[e] & ~live_e[e];
                sel_e[e]   = (m_state[e] == ST_WAKE) ? (live_e[e] & (~live_e[e] + 1'b1))
                                                     : {LQN{1'b0}};
                acc_m[e]   = ((m_state[e] == ST_RESV) || (m_state[e] == ST_CAP) ||
                              (m_state[e] == ST_READ))
                             && (merge_is_store || ~(&m_wqv[e]));
                acc_o[e]   = (m_state[e] == ST_RESV) || (m_state[e] == ST_CAP) ||
                             (m_state[e] == ST_READ);
            end

            g_mrg = merge_sel & acc_m;
            g_ovl = ovl_sel   & acc_o;


            beat_full = (refill_beat_valid == {NBEAT{1'b1}});
            rsp_fire  = refill_rsp_valid && beat_full && (|m_rdsent);
            rf_req_v  = (|rf_mask) && ((~|m_rdsent) || rsp_fire);
            g_rf      = rf_mask & (~rf_mask + 1'b1);
            rd_own    = m_rdsent & (~m_rdsent + 1'b1);
            rf_addr_p = 32'd0;
            for (int unsigned e = 0; e < N; e++) if (g_rf[e]) rf_addr_p = m_line[e];

            //---- 2. compare the DUT against the model ----------------------
            chk(resv_ready == |free_m, "resv_ready mismatch");
            chk(merge_ready == (|g_mrg), "merge_ready mismatch");
            chk(ovl_ready == (|g_ovl), "ovl_ready mismatch");
            chk(refill_req_valid == rf_req_v, "refill_req_valid mismatch");
            chk(!rf_req_v || (refill_line_addr == rf_addr_p), "refill_line_addr mismatch");
            chk(refill_rsp_ready == rsp_fire, "refill_rsp_ready mismatch");

            for (int unsigned e = 0; e < N; e++) begin
                chk(busy[e] == (m_state[e] != ST_FREE), "busy mismatch");
                chk(lock_valid[e] == (m_state[e] != ST_FREE), "lock_valid mismatch");
                chk(lock_line_addr[e] == ((m_state[e] != ST_FREE) ? m_line[e] : 32'd0),
                    "lock_line_addr mismatch");
                chk(lock_way[e] == ((m_state[e] != ST_FREE) ? m_way[e] : 2'd0), "lock_way mismatch");
                chk(match_hit[e] == ((m_state[e] != ST_FREE) && (m_line[e] == match_line_addr)),
                    "match_hit mismatch");
                chk(cap_req_valid[e] == cap_req_p[e], "cap_req_valid mismatch");
                chk(cap_req_way[e] == m_way[e], "cap_req_way mismatch");
                chk(cap_req_row[e] == ROWW'(m_capg[e]), "cap_req_row mismatch");
                chk(wb_wr_valid[e] == rsp_match_p[e], "wb_wr_valid mismatch");
                chk(wb_wr_idx[e] == m_wbidx[e], "wb_wr_idx mismatch");
                chk(wb_wr_row[e] == ROWW'(m_capr[e]), "wb_wr_row mismatch");
                chk(!rsp_match_p[e] || (wb_wr_data[e] == cap_rsp_data), "wb_wr_data mismatch");
                chk(wb_wr_last[e] == (rsp_match_p[e] && (m_capr[e] == LAST_ROW)), "wb_wr_last mismatch");
                chk(inst_valid[e] == inst_p[e], "inst_valid mismatch");
                chk(inst_way[e] == m_way[e], "inst_way mismatch");
                chk(inst_set[e] == m_set_of(m_line[e]), "inst_set mismatch");
                chk(inst_row[e] == ROWW'(m_irow[e]), "inst_row mismatch");
                chk(inst_last[e] == (m_irow[e] == LAST_ROW), "inst_last mismatch");
                chk(inst_be[e] == 8'hFF, "inst_be must be FF");
                chk(pub_valid[e] == pub_p[e], "pub_valid mismatch");
                chk(pub_way[e] == m_way[e], "pub_way mismatch");
                chk(pub_tag[e] == m_line[e][31 -: TBITS], "pub_tag mismatch");
                chk(pub_dirty[e] == (|m_omask[e]), "pub_dirty mismatch");
                chk(wake_valid[e] == (|sel_e[e]), "wake_valid mismatch");
                if (|sel_e[e]) begin
                    exp_w = 32'd0;
                    sel_i = 2'd0;
                    for (int unsigned i = 0; i < LQN; i++)
                        if (sel_e[e][i]) begin
                            sel_i = 2'(i);
                            exp_w = tb_word(tb_merge(m_ldata[e], m_omask[e], m_odata[e]),
                                            m_wwidx[e][i]);
                        end
                    chk(wake_lq_idx[e] == sel_i, "wake_lq_idx mismatch");
                    chk(wake_word[e] == exp_w, "wake_word mismatch");
                end
                if (inst_p[e] && inst_gnt[e])
                    chk(inst_data[e] == tb_row(tb_merge(m_ldata[e], m_omask[e], m_odata[e]), m_irow[e]),
                        "install Row data mismatch");
                //-- deferred install image check (arrays updated by the edge) --
                if (pub_pend[e]) begin
                    chk(cam_line[pub_set[e]][pub_wayi[e]] == pub_lexp[e],
                        "installed cache line image mismatch");
                    chk(cam_tag[pub_set[e]][pub_wayi[e]] == pub_texp[e], "installed tag mismatch");
                    chk(cam_dirty[pub_set[e]][pub_wayi[e]] == pub_dexp[e], "installed dirty mismatch");
                    chk(cam_valid[pub_set[e]][pub_wayi[e]], "installed line must be valid");
                    pub_pend[e] = 1'b0;
                end
                if (pub_p[e]) begin
                    pub_pend[e] = 1'b1;
                    pub_set[e]  = m_set_of(m_line[e]);
                    pub_wayi[e] = m_way[e][1];
                    pub_lexp[e] = tb_merge(m_ldata[e], m_omask[e], m_odata[e]);
                    pub_texp[e] = m_line[e][15:12];
                    pub_dexp[e] = (|m_omask[e]);
                end
                //-- internal state (XMR, FREE-10 debug visibility) ----------
                chk(dut.state_q[e] == m_state[e], "state mismatch");
                chk(dut.line_q[e] == m_line[e], "internal line mismatch");
                chk(dut.way_q[e] == m_way[e], "internal way mismatch");
                chk(dut.wb_idx_q[e] == m_wbidx[e], "internal wb_idx mismatch");
                chk(dut.cap_gnt_q[e] == m_capg[e], "internal cap_gnt mismatch");
                chk(dut.cap_rsp_q[e] == m_capr[e], "internal cap_rsp mismatch");
                chk(dut.rd_sent_q[e] == m_rdsent[e], "internal rd_sent mismatch");
                chk(dut.line_data_q[e] == m_ldata[e], "internal refill line mismatch");
                chk(dut.line_full_q[e] == m_lfull[e], "internal line_full mismatch");
                chk(dut.inst_row_q[e] == m_irow[e], "internal inst_row mismatch");
                chk(dut.ovl_mask_q[e] == m_omask[e], "internal overlay mask mismatch");
                chk(dut.ovl_data_q[e] == m_odata[e], "internal overlay data mismatch");
                chk(dut.wq_v_q[e] == m_wqv[e], "internal waiter mask mismatch");
                for (int unsigned i = 0; i < LQN; i++) begin
                    chk(dut.wq_tag_q[e][i] == m_wtag[e][i], "internal waiter tag mismatch");
                    chk(dut.wq_epoch_q[e][i] == m_wep[e][i], "internal waiter epoch mismatch");
                    chk(dut.wq_widx_q[e][i] == m_wwidx[e][i], "internal waiter widx mismatch");
                end
            end

            //---- 3. advance the model --------------------------------------
            resv_fire_m = resv_valid && (|free_m);
            g_resv      = free_m & (~free_m + 1'b1);

            for (int unsigned e = 0; e < N; e++) begin
                if (resv_fire_m && g_resv[e]) begin
                    n_reserve = n_reserve + 1;
                    m_line[e]   = resv_line_addr;
                    m_way[e]    = resv_way;
                    m_wbidx[e]  = resv_wb_idx;
                    m_capg[e]   = '0;
                    m_capr[e]   = '0;
                    m_rdsent[e] = 1'b0;
                    m_ldata[e]  = '0;
                    m_lfull[e]  = 1'b0;
                    m_irow[e]   = '0;
                    if (resv_is_store) begin
                        m_omask[e] = ovl_mask_upd_tb('0, resv_store_widx, resv_store_mask);
                        m_odata[e] = ovl_data_upd_tb('0, resv_store_widx, resv_store_mask,
                                                     resv_store_data);
                    end else begin
                        m_omask[e] = '0;
                        m_odata[e] = '0;
                        m_wtag[e][resv_lq_idx]  = resv_lq_tag.slot_index;
                        m_wep[e][resv_lq_idx]   = resv_lq_epoch;
                        m_wwidx[e][resv_lq_idx] = resv_word_idx;
                    end
                end else begin
                    if (merge_valid && g_mrg[e] && !merge_is_store) begin
                        m_wtag[e][merge_lq_idx]  = merge_lq_tag.slot_index;
                        m_wep[e][merge_lq_idx]   = merge_lq_epoch;
                        m_wwidx[e][merge_lq_idx] = merge_word_idx;
                    end
                    if (merge_valid && g_mrg[e] && merge_is_store) begin
                        m_omask[e] = ovl_mask_upd_tb(m_omask[e], merge_store_widx, merge_store_mask);
                        m_odata[e] = ovl_data_upd_tb(m_odata[e], merge_store_widx, merge_store_mask,
                                                     merge_store_data);
                    end
                    if (ovl_valid && g_ovl[e]) begin
                        m_omask[e] = ovl_mask_upd_tb(m_omask[e], ovl_widx, ovl_mask);
                        m_odata[e] = ovl_data_upd_tb(m_odata[e], ovl_widx, ovl_mask, ovl_data);
                    end
                    capg_n = m_capg[e];
                    if (cap_gnt[e]) capg_n = capg_n + CNTW'(1'b1);
                    m_capg[e] = capg_n;
                    capr_cur = m_capr[e];          // pre-edge value for the FSM
                    capr_n = m_capr[e];
                    if (rsp_match_p[e] && (m_capr[e] != LAST_ROW)) capr_n = capr_n + CNTW'(1'b1);
                    m_capr[e] = capr_n;
                    if (rf_req_v && refill_req_ready && g_rf[e]) m_rdsent[e] = 1'b1;
                    if (rsp_fire && rd_own[e]) begin
                        m_ldata[e]  = refill_line_data;
                        m_lfull[e]  = 1'b1;
                        m_rdsent[e] = 1'b0;
                    end
                    irow_cur = m_irow[e];          // pre-edge value for the FSM
                    irow_n = m_irow[e];
                    if (inst_p[e] && inst_gnt[e] && (m_irow[e] != LAST_ROW))
                        irow_n = irow_n + CNTW'(1'b1);
                    m_irow[e] = irow_n;
                end

                //---- waiter set -------------------------------------------
                clrv = (m_state[e] == ST_WAKE)
                       ? (stale_e[e] | (wake_ready[e] ? sel_e[e] : {LQN{1'b0}}))
                       : {LQN{1'b0}};
                wqv_n = m_wqv[e] & ~clrv;
                if (merge_valid && g_mrg[e] && !merge_is_store) wqv_n[merge_lq_idx] = 1'b1;
                if (resv_fire_m && g_resv[e])
                    wqv_n = resv_is_store ? {LQN{1'b0}} : (LQN'(1) << resv_lq_idx);
                if (wake_valid[e] && wake_ready[e]) begin
                    di    = wake_lq_idx[e];
                    dlive = m_wqv[e][di] && lq_wait_pending[di]
                            && (lq_wait_tag[di] == ares_pkg::tag_t'(m_wtag[e][di]))
                            && (lq_wait_epoch[di] == m_wep[e][di]);
                    chk(dlive, "WAKE presented a stale waiter");
                    chk(wake_word[e] == tb_word(tb_merge(m_ldata[e], m_omask[e], m_odata[e]),
                                                m_wwidx[e][di]),
                        "delivered word mismatch");
                    wake_deliveries = wake_deliveries + 1;
                end
                m_wqv[e] = wqv_n;

                //---- next state -------------------------------------------
                st_n = m_state[e];
                case (m_state[e])
                    ST_FREE:  if (resv_fire_m && g_resv[e])
                                  st_n = resv_victim_dirty ? ST_RESV : ST_READ;
                    ST_RESV:  if (cap_gnt[e]) st_n = ST_CAP;
                    ST_CAP:   if (rsp_match_p[e] && (capr_cur == LAST_ROW)) st_n = ST_READ;
                    ST_READ:  if (rsp_fire && rd_own[e]) st_n = ST_INST;
                    ST_INST:  if (inst_p[e] && inst_gnt[e] && (irow_cur == LAST_ROW))
                                  st_n = ST_WAKE;
                    default:  if (m_wqv[e] == '0) st_n = ST_FREE;
                endcase
                m_state[e] = st_n;
            end

            //---- counters ---------------------------------------------------
            if (rf_req_fire) n_refill = n_refill + 1;
            for (int unsigned e = 0; e < N; e++) begin
                if (inst_p[e] && inst_gnt[e]) n_install = n_install + 1;
                if (pub_valid[e]) n_pub = n_pub + 1;
                if (rsp_match_p[e]) n_wb_row = n_wb_row + 1;
            end
        end
    endtask

    // The reference model runs once per cycle, mid cycle, after the DUT state
    // for the running cycle has settled: it compares every DUT output and the
    // internal registers, then advances one cycle with the observed handshakes.
    always @(negedge clk) begin
        if (!rst) mdl_cycle();
    end

    //=========================================================================
    // Coverage counters (FREE-10 / D-M2b-08)
    //=========================================================================
    logic [N_STATES-1:0] cov_st;
    logic [N_STATES*N_STATES-1:0] cov_tr;
    logic [2:0] cov_prev [N];
    int unsigned cov_st_n;
    int unsigned cov_tr_n;

    function automatic logic legal_tr(input logic [2:0] a, input logic [2:0] b);
        case (a)
            ST_FREE: legal_tr = (b == ST_FREE) || (b == ST_RESV) || (b == ST_READ);
            ST_RESV: legal_tr = (b == ST_RESV) || (b == ST_CAP);
            ST_CAP:  legal_tr = (b == ST_CAP)  || (b == ST_READ);
            ST_READ: legal_tr = (b == ST_READ) || (b == ST_INST);
            ST_INST: legal_tr = (b == ST_INST) || (b == ST_WAKE);
            default: legal_tr = (b == ST_WAKE) || (b == ST_FREE);
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned e = 0; e < N; e++) cov_prev[e] <= ST_FREE;
        end else begin
            for (int unsigned e = 0; e < N; e++) begin
                cov_st[dut.state_q[e]] <= 1'b1;
                cov_tr[int'(cov_prev[e]) * N_STATES + int'(dut.state_q[e])] <= 1'b1;
                cov_prev[e] <= dut.state_q[e];
            end
        end
    end

    //=========================================================================
    // Driver helpers
    //=========================================================================
    logic wake_hold;
    assign wake_ready = wake_valid & {N{~wake_hold}};

    //---- randomised phase bookkeeping
    int unsigned rnd_cycles;
    logic        d_resv_en;
    logic [31:0] d_resv_addr;
    logic [1:0]  d_resv_way;
    logic        d_resv_dirty;
    logic [1:0]  d_resv_wb;
    logic        d_resv_store;
    logic [1:0]  d_resv_lqidx;
    logic [3:0]  d_resv_tag;
    logic [7:0]  d_resv_ep;
    logic [WIDXW-1:0] d_resv_widx;
    logic [3:0]  d_resv_smask;
    logic [31:0] d_resv_sdata;
    logic [WIDXW-1:0] d_resv_swidx;
    logic        d_mrg_en;
    logic [N-1:0] d_mrg_sel;
    logic        d_mrg_store;
    logic [1:0]  d_mrg_lqidx;
    logic [3:0]  d_mrg_tag;
    logic [7:0]  d_mrg_ep;
    logic [WIDXW-1:0] d_mrg_widx;
    logic [3:0]  d_mrg_smask;
    logic [31:0] d_mrg_sdata;
    logic [WIDXW-1:0] d_mrg_swidx;
    logic        d_ovl_en;
    logic [N-1:0] d_ovl_sel;
    logic [WIDXW-1:0] d_ovl_widx;
    logic [3:0]  d_ovl_mask;
    logic [31:0] d_ovl_data;
    logic        d_cap_go;
    logic        d_inst_go;
    logic        d_wake_hold;
    int unsigned d_rf_lat;
    logic [N-1:0] d_wake_fill;
    logic [1:0]  d_wake_fill_idx [N];
    logic [WB_ENTRIES-1:0] wb_used;
    int unsigned wb_timer [WB_ENTRIES];

    // deferred install-image checks
    logic            pub_pend [N];
    logic [IBITS-1:0] pub_set [N];
    logic            pub_wayi [N];
    logic [NW-1:0]   pub_lexp [N];
    logic [TAGW-1:0] pub_texp [N];
    logic            pub_dexp [N];

    function automatic logic [1:0] first_free_wb();
        first_free_wb = 2'd0;
        for (int unsigned i = 0; i < WB_ENTRIES; i++)
            if (!wb_used[i]) first_free_wb = 2'(i);
    endfunction

    task automatic drv(); @(posedge clk); #1; endtask
    task automatic smp(); @(negedge clk); #2; endtask
    task automatic cyc(); begin smp(); drv(); end endtask

    task automatic lq_set(input logic [LQIW-1:0] i, input logic [3:0] t, input logic [7:0] ep,
                          input logic alive);
        begin
            lq_wait_pending[i] = alive;
            lq_wait_tag[i]     = ares_pkg::tag_t'(t);
            lq_wait_epoch[i]   = ep;
        end
    endtask

    task automatic idle_inputs();
        begin
            resv_valid        = 1'b0;
            resv_line_addr    = 32'd0;
            resv_way          = 2'd0;
            resv_victim_dirty = 1'b0;
            resv_wb_idx       = 2'd0;
            resv_is_store     = 1'b0;
            resv_lq_idx       = 2'd0;
            resv_lq_tag       = ares_pkg::tag_t'(4'd0);
            resv_lq_epoch     = 8'd0;
            resv_word_idx     = '0;
            resv_store_mask   = 4'd0;
            resv_store_data   = 32'd0;
            resv_store_widx   = '0;
            merge_valid       = 1'b0;
            merge_sel         = {N{1'b0}};
            merge_is_store    = 1'b0;
            merge_lq_idx      = 2'd0;
            merge_lq_tag      = ares_pkg::tag_t'(4'd0);
            merge_lq_epoch    = 8'd0;
            merge_word_idx    = '0;
            merge_store_mask  = 4'd0;
            merge_store_data  = 32'd0;
            merge_store_widx  = '0;
            ovl_valid         = 1'b0;
            ovl_sel           = {N{1'b0}};
            ovl_widx          = '0;
            ovl_mask          = 4'd0;
            ovl_data          = 32'd0;
            cap_go            = 1'b1;
            inst_go           = 1'b1;
            rf_lat            = 2;
            rf_partial        = 1'b0;
            rf_pmask          = {NBEAT{1'b0}};
            match_line_addr   = 32'hDEAD_BEEF;
        end
    endtask

    task automatic do_reset();
        begin
            idle_inputs();
            for (int unsigned i = 0; i < LQN; i++) lq_set(2'(i), 4'd0, 8'd0, 1'b0);
            rst = 1'b1;
            repeat (3) drv();
            rst = 1'b0;
            drv();
            chk(busy == '0, "reset: busy must be 0");
            chk(lock_valid == '0, "reset: lock_valid must be 0");
            chk(wake_valid == '0, "reset: wake_valid must be 0");
            chk(cap_req_valid == '0, "reset: cap_req_valid must be 0");
            chk(inst_valid == '0, "reset: inst_valid must be 0");
            chk(!refill_req_valid, "reset: refill_req_valid must be 0");
            chk(wb_wr_valid == '0, "reset: wb_wr_valid must be 0");
            chk(pub_valid == '0, "reset: pub_valid must be 0");
            chk(resv_ready, "reset: resv_ready must be 1");
            chk(!merge_ready && !ovl_ready, "reset: merge/ovl ready must be 0");
        end
    endtask

    // wait until every entry is FREE again
    task automatic drain_idle();
        int unsigned guard;
        begin
            idle_inputs();
            guard = 0;
            while (busy != '0 && guard < 200) begin
                cyc();
                guard = guard + 1;
            end
            chk(busy == '0, "drain_idle: entries did not return to FREE");
        end
    endtask

    //=========================================================================
    // Directed scenario helpers
    //=========================================================================
    logic        d_lq_do;
    logic [1:0]  d_lq_idx;
    logic        d_lq_alive;
    logic [3:0]  d_lq_tag;
    logic [7:0]  d_lq_ep;

    task automatic do_reserve(input logic [31:0] addr, input logic [1:0] way, input logic dirty,
                              input logic [1:0] wbidx, input logic is_store,
                              input logic [1:0] lqidx, input logic [3:0] lqtag, input logic [7:0] lqep,
                              input logic [WIDXW-1:0] widx,
                              input logic [3:0] smask, input logic [31:0] sdata,
                              input logic [WIDXW-1:0] swidx);
        begin
            resv_line_addr    = addr;
            resv_way          = way;
            resv_victim_dirty = dirty;
            resv_wb_idx       = wbidx;
            resv_is_store     = is_store;
            resv_lq_idx       = lqidx;
            resv_lq_tag       = ares_pkg::tag_t'(lqtag);
            resv_lq_epoch     = lqep;
            resv_word_idx     = widx;
            resv_store_mask   = smask;
            resv_store_data   = sdata;
            resv_store_widx   = swidx;
            resv_valid        = 1'b1;
            smp();
            chk(resv_valid && resv_ready, "reserve was not accepted");
            drv();
            resv_valid        = 1'b0;
        end
    endtask

    // one refill transaction: request handshake, single outstanding read, latch
    task automatic t_refill_response(input int unsigned entry, input logic [31:0] addr);
        int unsigned guard;
        begin
            chk(entry < N, "refill entry index out of range");
            if (!dut.rd_sent_q[entry]) begin
                smp();
                chk(refill_req_valid, "refill request must be presented");
                chk(refill_line_addr == addr, "refill line address mismatch");
                drv();
                chk(dut.rd_sent_q[entry] == 1'b1, "read ownership after the request handshake");
            end
            guard = 0;
            while (1) begin
                smp();
                if (refill_rsp_valid) break;
                chk(dut.state_q[entry] == ST_READ, "entry left READ_BEATS before the response");
                guard = guard + 1;
                chk(guard < 60, "refill response never arrived");
                drv();
            end
            chk(refill_beat_valid == {NBEAT{1'b1}}, "all beats must be valid with the response");
            chk(refill_rsp_ready, "complete line must be consumed");
            drv();
            chk(dut.line_data_q[entry] == mem_line(addr), "latched refill line mismatch");
            chk(dut.line_full_q[entry] == 1'b1, "refill line must be marked complete");
            chk(dut.state_q[entry] == ST_INST, "refill completion must enter INSTALL");
        end
    endtask

    // one install sweep of one entry against an expected merged line
    task automatic t_install(input int unsigned entry, input logic [1:0] way,
                             input logic [NW-1:0] refill, input logic [LBYTES-1:0] omask,
                             input logic [NW-1:0] odata, input logic dirty_exp,
                             input logic [31:0] addr);
        logic [NW-1:0] expm;
        begin
            expm = tb_merge(refill, omask, odata);
            for (int unsigned r = 0; r < ROWS; r++) begin
                smp();
                chk(inst_valid[entry], "install valid expected");
                chk(inst_way[entry] == way, "install way mismatch");
                chk(inst_set[entry] == m_set_of(addr), "install set mismatch");
                chk(inst_row[entry] == ROWW'(r), "install Row index mismatch");
                chk(inst_data[entry] == tb_row(expm, CNTW'(r)), "install Row data mismatch");
                chk(inst_be[entry] == 8'hFF, "install byte enable must be FF");
                chk(inst_last[entry] == (r == ROWS-1), "install_last mismatch");
                chk(pub_valid[entry] == (r == ROWS-1), "publish must happen with the last Row");
                if (r == ROWS-1) begin
                    chk(pub_way[entry] == way, "pub_way mismatch");
                    chk(pub_tag[entry] == addr[31 -: TBITS], "pub_tag mismatch");
                    chk(pub_dirty[entry] == dirty_exp, "pub_dirty mismatch");
                end
                drv();
            end
            chk(dut.state_q[entry] == ST_WAKE, "install completion must enter WAKE");
        end
    endtask

    // one WAKE handover: check the reported waiter and consume it
    task automatic t_wake_take(input int unsigned entry, input logic [1:0] idx_exp,
                               input logic [31:0] word_exp);
        begin
            smp();
            chk(wake_valid[entry], "wake_valid expected");
            chk(wake_lq_idx[entry] == idx_exp, "wake_lq_idx mismatch");
            chk(wake_word[entry] == word_exp, "wake_word mismatch");
            drv();
            // L06 consumed the handover: the LQ entry leaves the wait state
            lq_set(idx_exp, lq_wait_tag[idx_exp].slot_index, lq_wait_epoch[idx_exp], 1'b0);
        end
    endtask

    //=========================================================================
    // Randomised phase
    //=========================================================================
    task automatic rnd_decide();
        logic [31:0] a;
        logic [IBITS-1:0] s;
        logic w;
        logic [TAGW-1:0] tg;
        logic ok;
        int unsigned tries;
        int unsigned k;
        logic [LQN-1:0] eff_alive;
        logic [3:0] eff_tag [LQN];
        logic [7:0] eff_ep [LQN];
        logic [1:0] freewb;
        begin
            d_resv_en = 1'b0;
            d_mrg_en  = 1'b0;
            d_ovl_en  = 1'b0;
            d_lq_do   = 1'b0;
            for (int unsigned i = 0; i < N; i++) begin
                d_wake_fill[i] = 1'b0;
                if (wake_valid[i]) begin
                    d_wake_fill[i]     = 1'b1;            // L06 takes (or drops) the handover
                    d_wake_fill_idx[i] = wake_lq_idx[i];
                end
            end
            //---- WB allocator bookkeeping
            for (int unsigned i = 0; i < WB_ENTRIES; i++) begin
                if (wb_used[i]) begin
                    if (wb_timer[i] == 0) wb_used[i] = 1'b0;
                    else                  wb_timer[i] = wb_timer[i] - 1;
                end
            end
            if (resv_valid && resv_ready && resv_victim_dirty) begin
                wb_used[int'(resv_wb_idx)]  = 1'b1;
                wb_timer[int'(resv_wb_idx)] = ROWS + 3;
            end
            //---- LQ model churn: kill or reuse a slot with a fresh epoch
            for (int unsigned i = 0; i < LQN; i++) begin
                eff_alive[i] = lq_wait_pending[i];
                eff_tag[i]   = lq_wait_tag[i].slot_index;
                eff_ep[i]    = lq_wait_epoch[i];
            end
            if ($urandom_range(0, 99) < 30) begin
                k = $urandom_range(0, LQN - 1);
                d_lq_do  = 1'b1;
                d_lq_idx = 2'(k);
                if (lq_wait_pending[k] && ($urandom_range(0, 1) == 0)) begin
                    d_lq_alive = 1'b0;                 // kill
                    d_lq_tag   = lq_wait_tag[k].slot_index;
                    d_lq_ep    = lq_wait_epoch[k];
                end else begin
                    d_lq_alive = 1'b1;                 // reallocate: new tag + epoch
                    d_lq_tag   = 4'($urandom);
                    d_lq_ep    = 8'($urandom);
                end
                eff_alive[k] = d_lq_alive;
                eff_tag[k]   = d_lq_tag;
                eff_ep[k]    = d_lq_ep;
            end
            //---- reserve
            if ($urandom_range(0, 99) < 35) begin
                ok = 1'b0;
                for (tries = 0; (tries < 24) && !ok; tries++) begin
                    w  = ($urandom_range(0, 1) == 1);
                    s  = IBITS'($urandom_range(0, NSETS - 1));
                    tg = TAGW'($urandom_range(0, 15));
                    a  = tb_addr(tg, s);
                    ok = (tg != cam_tag[s][w]);                       // must miss
                    for (int unsigned q = 0; q < N; q++) begin
                        if (m_state[q] != ST_FREE) begin
                            if (m_line[q] == a) ok = 1'b0;            // same line tracked
                            if ((m_set_of(m_line[q]) == s) && (m_way[q] == (2'b01 << w)))
                                ok = 1'b0;                            // victim way locked
                        end
                    end
                end
                if (ok) begin
                    d_resv_en    = 1'b1;
                    d_resv_addr  = a;
                    d_resv_way   = (2'b01 << w);
                    d_resv_store = ($urandom_range(0, 2) == 0);
                    freewb       = first_free_wb();
                    d_resv_wb    = freewb;
                    d_resv_dirty = ($urandom_range(0, 1) == 1) && (|(~wb_used));
                    k = $urandom_range(0, LQN - 1);
                    if (!eff_alive[k] && ($urandom_range(0, 4) != 0)) begin
                        eff_alive[k] = 1'b1;
                        eff_tag[k]   = 4'($urandom);
                        eff_ep[k]    = 8'($urandom);
                    end
                    d_resv_lqidx = 2'(k);
                    d_resv_tag   = eff_tag[k];
                    d_resv_ep    = eff_ep[k];
                    d_resv_widx  = WIDXW'($urandom);
                    d_resv_smask = 4'($urandom);
                    if (d_resv_smask == 4'd0) d_resv_smask = 4'hF;
                    d_resv_sdata = 32'($urandom);
                    d_resv_swidx = WIDXW'($urandom);
                end
            end
            //---- merge into an in-flight entry (Load waiter or Store overlay)
            if ($urandom_range(0, 99) < 30) begin
                k = $urandom_range(0, N - 1);
                if (m_state[k] != ST_FREE) begin
                    d_mrg_en    = 1'b1;
                    d_mrg_sel   = (N'(1) << k);
                    d_mrg_store = ($urandom_range(0, 2) == 0);
                    d_mrg_smask = 4'($urandom);
                    if (d_mrg_smask == 4'd0) d_mrg_smask = 4'hF;
                    d_mrg_sdata = 32'($urandom);
                    d_mrg_swidx = WIDXW'($urandom);
                    d_mrg_widx  = WIDXW'($urandom);
                    k = $urandom_range(0, LQN - 1);
                    if (!eff_alive[k] && ($urandom_range(0, 4) != 0)) begin
                        eff_alive[k] = 1'b1;
                        eff_tag[k]   = 4'($urandom);
                        eff_ep[k]    = 8'($urandom);
                    end
                    d_mrg_lqidx = 2'(k);
                    d_mrg_tag   = eff_tag[k];
                    d_mrg_ep    = eff_ep[k];
                end
            end
            //---- overlay update (Store early takeover)
            if ($urandom_range(0, 99) < 25) begin
                k = $urandom_range(0, N - 1);
                if (m_state[k] != ST_FREE) begin
                    d_ovl_en   = 1'b1;
                    d_ovl_sel  = (N'(1) << k);
                    d_ovl_widx = WIDXW'($urandom);
                    d_ovl_mask = 4'($urandom);
                    if (d_ovl_mask == 4'd0) d_ovl_mask = 4'h5;
                    d_ovl_data = 32'($urandom);
                end
            end
            //---- channel backpressure
            d_cap_go     = ($urandom_range(0, 3) != 0);
            d_inst_go    = ($urandom_range(0, 3) != 0);
            d_wake_hold  = ($urandom_range(0, 3) == 0);
            d_rf_lat     = $urandom_range(1, 4);
        end
    endtask

    task automatic rnd_apply();
        begin
            if (d_lq_do) lq_set(d_lq_idx, d_lq_tag, d_lq_ep, d_lq_alive);
            for (int unsigned i = 0; i < N; i++)
                if (d_wake_fill[i])
                    lq_set(d_wake_fill_idx[i],
                           lq_wait_tag[d_wake_fill_idx[i]].slot_index,
                           lq_wait_epoch[d_wake_fill_idx[i]], 1'b0);

            resv_valid        = d_resv_en;
            resv_line_addr    = d_resv_addr;
            resv_way          = d_resv_way;
            resv_victim_dirty = d_resv_dirty;
            resv_wb_idx       = d_resv_wb;
            resv_is_store     = d_resv_store;
            resv_lq_idx       = d_resv_lqidx;
            resv_lq_tag       = ares_pkg::tag_t'(d_resv_tag);
            resv_lq_epoch     = d_resv_ep;
            resv_word_idx     = d_resv_widx;
            resv_store_mask   = d_resv_smask;
            resv_store_data   = d_resv_sdata;
            resv_store_widx   = d_resv_swidx;

            merge_valid      = d_mrg_en;
            merge_sel        = d_mrg_sel;
            merge_is_store   = d_mrg_store;
            merge_lq_idx     = d_mrg_lqidx;
            merge_lq_tag     = ares_pkg::tag_t'(d_mrg_tag);
            merge_lq_epoch   = d_mrg_ep;
            merge_word_idx   = d_mrg_widx;
            merge_store_mask = d_mrg_smask;
            merge_store_data = d_mrg_sdata;
            merge_store_widx = d_mrg_swidx;

            ovl_valid = d_ovl_en;
            ovl_sel   = d_ovl_sel;
            ovl_widx  = d_ovl_widx;
            ovl_mask  = d_ovl_mask;
            ovl_data  = d_ovl_data;

            cap_go    = d_cap_go;
            inst_go   = d_inst_go;
            wake_hold = d_wake_hold;
            rf_lat    = d_rf_lat;
            rf_partial = 1'b0;
        end
    endtask

    //=========================================================================
    // Test program
    //=========================================================================
    logic [31:0] A0, A1, A2, A3;
    logic [IBITS-1:0] S0, S1, S2, S3;
    logic [TAGW-1:0]  TG0, TG1, TG2, TG3;
    logic [WIDXW-1:0] W0;
    logic [NW-1:0]    exp_line, exp_line2;
    logic [LBYTES-1:0] exp_mask;
    logic [NW-1:0]    exp_odata;

    initial begin
        idle_inputs();
        mdl_reset();
        for (int unsigned i = 0; i < LQN; i++) lq_set(2'(i), 4'd0, 8'd0, 1'b0);
        checks = 0;
        errors = 0;
        wake_deliveries = 0;
        n_reserve = 0;
        n_refill = 0;
        n_install = 0;
        n_pub = 0;
        n_wb_row = 0;
        mdl_prot_err = 0;
        cov_st = '0;
        cov_tr = '0;
        cov_st_n = 0;
        cov_tr_n = 0;

        $display("== tb_mshr: LINE_BYTES=%0d ROWS=%0d LINE_BEATS=%0d MSHR=%0d LQ=%0d ==",
                 LBYTES, ROWS, NBEAT, N, LQN);
        chk((LBYTES == 16) || (LBYTES == 32) || (LBYTES == 64), "LINE_BYTES must be 16/32/64");
        chk(ROWS == LBYTES/8, "ROWS_PER_LINE must be LINE_BYTES/8");
        chk(NBEAT == LBYTES/16, "LINE_BEATS must be LINE_BYTES/16");

        //---- 0. reset ---------------------------------------------------
        do_reset();
        $display("[%0t] marker: reset ok", $time);

        //---- 1. Clean miss: Load waiter, refill, install, wake ----------
        S0  = IBITS'(5);
        TG0 = 4'h5;
        A0  = tb_addr(TG0, S0);
        W0  = WIDXW'(1);
        lq_set(0, 4'h3, 8'h11, 1'b1);
        do_reserve(A0, 2'b01, 1'b0, 2'd0, 1'b0, 2'd0, 4'h3, 8'h11, W0, 4'd0, 32'd0, '0);
        chk(lock_valid[0] && (lock_line_addr[0] == A0) && (lock_way[0] == 2'b01),
            "clean reserve must lock the Way");
        chk(dut.state_q[0] == ST_READ, "clean victim must enter READ_BEATS directly");
        chk(busy[0] && !busy[1], "busy view after one reserve");
        match_line_addr = A0;
        smp();
        chk(match_hit[0] && !match_hit[1], "match_hit on the tracked line only");
        drv();
        match_line_addr = 32'hDEAD_BEEF;
        t_refill_response(0, A0);
        exp_line = mem_line(A0);
        t_install(0, 2'b01, exp_line, '0, '0, 1'b0, A0);
        t_wake_take(0, 2'd0, tb_word(exp_line, W0));
        chk(dut.state_q[0] == ST_FREE && !busy[0] && !lock_valid[0],
            "WAKE -> FREE must release the Way lock");
        drain_idle();
        $display("[%0t] marker: clean miss flow ok", $time);

        //---- 2. Dirty victim capture + Store overlay --------------------
        S1  = IBITS'(9);
        TG1 = 4'h7;
        A1  = tb_addr(TG1, S1);
        exp_line = mem_line(tb_addr(cam_tag[S1][0], S1));      // victim image
        do_reserve(A1, 2'b01, 1'b1, 2'd1, 1'b1, 2'd0, 4'h0, 8'h0, '0,
                   4'b0110, 32'hDEAD_BEEF, WIDXW'(1));
        chk(dut.state_q[0] == ST_RESV, "dirty victim must enter RESERVE");
        chk(dut.cap_gnt_q[0] == '0, "victim capture starts at Row 0");
        // withhold the R grant: RESERVE -> RESERVE
        cap_go = 1'b0;
        smp();
        chk(cap_req_valid[0] && (cap_req_way[0] == 2'b01) && (cap_req_row[0] == ROWW'(0)),
            "RESERVE must already request the first victim Row");
        drv();
        chk(dut.state_q[0] == ST_RESV, "no R grant must keep the entry in RESERVE");
        // an overlay arriving in RESERVE is accepted (Store early takeover)
        ovl_valid = 1'b1;
        ovl_sel   = (N'(1) << 0);
        ovl_widx  = WIDXW'(2);
        ovl_mask  = 4'b1001;
        ovl_data  = 32'hA5A5_5A5A;
        smp();
        chk(ovl_ready, "overlay must be accepted in RESERVE");
        drv();
        ovl_valid = 1'b0;
        ovl_sel   = '0;
        // grant the victim Rows back to back
        cap_go = 1'b1;
        smp();
        chk(cap_req_row[0] == ROWW'(0), "Row 0 request before the first grant");
        drv();
        for (int unsigned r = 0; r < ROWS; r++) begin
            smp();
            chk(cap_rsp_valid, "capture response expected");
            chk(cap_rsp_row == ROWW'(r), "capture response Row order");
            chk(cap_rsp_way == 2'b01, "capture response way");
            chk(cap_rsp_set == S1, "capture response set");
            chk(wb_wr_valid[0], "victim Row must be handed to the WB");
            chk(wb_wr_idx[0] == 2'd1, "WB entry index mismatch");
            chk(wb_wr_row[0] == ROWW'(r), "WB Row index mismatch");
            chk(wb_wr_data[0] == mem_row(tb_addr(cam_tag[S1][0], S1), ROWW'(r)),
                "WB Row data must be the victim Row");
            chk(wb_wr_last[0] == (r == ROWS-1), "wb_wr_last only on the last Row");
            chk(dut.state_q[0] == ST_CAP, "entry must stay in VICTIM_CAPTURE");
            drv();
            if (r == ROWS-1)
                chk(dut.state_q[0] == ST_READ,
                    "READ_BEATS only after the last Row reached the WB");
        end
        // Store overlay: the reserve seeding plus the later ovl update
        exp_line2 = mem_line(A1);
        exp_mask  = ovl_mask_upd_tb(ovl_mask_upd_tb('0, WIDXW'(1), 4'b0110), WIDXW'(2), 4'b1001);
        exp_odata = ovl_data_upd_tb(ovl_data_upd_tb('0, WIDXW'(1), 4'b0110, 32'hDEAD_BEEF),
                                    WIDXW'(2), 4'b1001, 32'hA5A5_5A5A);
        t_refill_response(0, A1);
        t_install(0, 2'b01, exp_line2, exp_mask, exp_odata, 1'b1, A1);
        smp();
        chk(!wake_valid[0], "a Store reservation has no waiter");
        drv();
        chk(dut.state_q[0] == ST_FREE && !busy[0], "WAKE -> FREE without any waiter");
        chk(cam_line[S1][0] == tb_merge(exp_line2, exp_mask, exp_odata),
            "installed line image must merge the overlay bytes");
        chk(cam_dirty[S1][0], "a Store overlay install must publish Dirty");
        chk(cam_tag[S1][0] == TG1, "installed tag mismatch");
        drain_idle();
        $display("[%0t] marker: dirty victim + overlay ok", $time);

        //---- 3. two MSHRs, one refill port ------------------------------
        S2  = IBITS'(20);
        TG2 = 4'h2;
        A2  = tb_addr(TG2, S2);
        S3  = IBITS'(25);
        TG3 = 4'h8;
        A3  = tb_addr(TG3, S3);
        inst_go = 1'b0;                       // installs are checked explicitly
        lq_set(0, 4'h6, 8'h31, 1'b1);
        lq_set(1, 4'h7, 8'h32, 1'b1);
        do_reserve(A2, 2'b01, 1'b0, 2'd0, 1'b0, 2'd0, 4'h6, 8'h31, WIDXW'(0), 4'd0, 32'd0, '0);
        do_reserve(A3, 2'b10, 1'b0, 2'd0, 1'b0, 2'd1, 4'h7, 8'h32, WIDXW'(0), 4'd0, 32'd0, '0);
        chk((dut.state_q[0] == ST_READ) && (dut.state_q[1] == ST_READ), "both entries in READ");
        // both entries busy: no free MSHR
        resv_valid     = 1'b1;
        resv_line_addr = tb_addr(4'hE, IBITS'(2));
        smp();
        chk(!resv_ready, "resv_ready must be 0 while both entries are busy");
        drv();
        resv_valid = 1'b0;
        chk(busy == '1, "both entries must still be busy");
        // the lowest index owns the port; while one read is outstanding the
        // other entry must not present a request
        while (1) begin
            smp();
            if (refill_rsp_valid) break;
            chk(!refill_req_valid, "no second read while one is outstanding");
            drv();
        end
        chk(refill_req_valid, "second MSHR must request in the completion cycle");
        chk(refill_line_addr == A3, "second MSHR line address in the completion cycle");
        drv();
        chk(dut.state_q[0] == ST_INST, "entry 0 must enter INSTALL");
        chk(dut.rd_sent_q[1] == 1'b1, "entry 1 must own the refill read after the handover");
        while (1) begin smp(); if (refill_rsp_valid) break; drv(); end
        drv();
        chk(dut.line_data_q[1] == mem_line(A3), "entry 1 latched line");
        chk(dut.state_q[1] == ST_INST, "entry 1 must enter INSTALL");
        // now run both installs
        inst_go = 1'b1;
        drain_idle();
        chk(cam_line[S2][0] == mem_line(A2), "entry 0 installed line image");
        chk(cam_line[S3][1] == mem_line(A3), "entry 1 installed line image");
        chk((cam_tag[S2][0] == TG2) && (cam_tag[S3][1] == TG3), "installed tags");
        chk(!cam_dirty[S2][0] && !cam_dirty[S3][1], "clean installs must not be dirty");
        $display("[%0t] marker: refill arbitration ok", $time);

        //---- 4. four waiters, one stale ---------------------------------
        S0  = IBITS'(40);
        TG0 = 4'h1;
        A0  = tb_addr(TG0, S0);
        for (int unsigned q = 0; q < LQN; q++) lq_set(2'(q), 4'(q+1), 8'(8'h21 + q), 1'b1);
        rf_lat = 8;                            // room for the merges
        do_reserve(A0, 2'b10, 1'b0, 2'd0, 1'b0, 2'd0, 4'h1, 8'h21, WIDXW'(0), 4'd0, 32'd0, '0);
        for (int unsigned q = 1; q < LQN; q++) begin
            merge_valid    = 1'b1;
            merge_sel      = (N'(1) << 0);
            merge_is_store = 1'b0;
            merge_lq_idx   = 2'(q);
            merge_lq_tag   = ares_pkg::tag_t'(4'(q + 1));
            merge_lq_epoch = 8'(8'h21 + q);
            merge_word_idx = WIDXW'(q);
            smp();
            chk(merge_valid && merge_ready, "Load merge must be accepted");
            drv();
            merge_valid = 1'b0;
            merge_sel   = '0;
        end
        // waiter {slot 2, tag 3, epoch 0x23} is killed and the slot reused
        lq_set(2, 4'h7, 8'h25, 1'b1);
        rf_lat = 2;
        t_refill_response(0, A0);
        exp_line = mem_line(A0);
        t_install(0, 2'b10, exp_line, '0, '0, 1'b0, A0);
        t_wake_take(0, 2'd0, tb_word(exp_line, WIDXW'(0)));
        t_wake_take(0, 2'd1, tb_word(exp_line, WIDXW'(1)));
        smp();
        chk(wake_valid[0] && (wake_lq_idx[0] == 2'd3),
            "the stale waiter (reused slot) must be skipped, never delivered");
        chk(wake_word[0] == tb_word(exp_line, WIDXW'(3)), "third handover word");
        drv();
        chk(dut.state_q[0] == ST_FREE && !busy[0], "all waiters served -> FREE");
        chk(dut.wq_v_q[0] == '0, "stale waiter must be cleared, not kept");
        drain_idle();
        $display("[%0t] marker: multi-waiter + stale waiter ok", $time);

        //---- 5. overlay window frozen in INSTALL / WAKE ------------------
        S3  = IBITS'(60);
        TG3 = 4'h3;
        A3  = tb_addr(TG3, S3);
        lq_set(0, 4'h9, 8'h41, 1'b1);
        do_reserve(A3, 2'b01, 1'b0, 2'd0, 1'b0, 2'd0, 4'h9, 8'h41, WIDXW'(0), 4'd0, 32'd0, '0);
        t_refill_response(0, A3);
        smp();
        chk(inst_valid[0], "install must be active");
        merge_valid    = 1'b1;
        merge_sel      = (N'(1) << 0);
        merge_is_store = 1'b0;
        merge_lq_idx   = 2'd1;
        merge_lq_tag   = ares_pkg::tag_t'(4'hA);
        merge_lq_epoch = 8'h50;
        merge_word_idx = '0;
        ovl_valid = 1'b1;
        ovl_sel   = (N'(1) << 0);
        ovl_widx  = '0;
        ovl_mask  = 4'hF;
        ovl_data  = 32'hFFFF_FFFF;
        #1;
        chk(!merge_ready, "merge must be frozen during INSTALL");
        chk(!ovl_ready, "overlay must be frozen during INSTALL");
        merge_sel = (N'(1) << 1);
        #1;
        chk(!merge_ready, "merge into a FREE entry must not be accepted");
        drv();
        merge_valid = 1'b0;
        merge_sel   = '0;
        ovl_valid   = 1'b0;
        ovl_sel     = '0;
        for (int unsigned r = 1; r < ROWS; r++) begin smp(); drv(); end
        chk(dut.state_q[0] == ST_WAKE, "install done");
        merge_valid = 1'b1;
        merge_sel   = (N'(1) << 0);
        #1;
        chk(!merge_ready && !ovl_ready, "overlay window stays frozen during WAKE");
        drv();
        merge_valid = 1'b0;
        merge_sel   = '0;
        drain_idle();
        chk(cam_line[S3][0] == mem_line(A3), "no frozen-window update must reach the line");
        $display("[%0t] marker: frozen overlay window ok", $time);

        //---- 6. incomplete beat set must not be consumed -----------------
        S0  = IBITS'(70);
        TG0 = 4'hB;
        A0  = tb_addr(TG0, S0);
        lq_set(0, 4'hC, 8'h61, 1'b1);
        rf_partial = 1'b1;
        rf_pmask   = {NBEAT{1'b1}} ^ NBEAT'(1);
        do_reserve(A0, 2'b01, 1'b0, 2'd0, 1'b0, 2'd0, 4'hC, 8'h61, WIDXW'(0), 4'd0, 32'd0, '0);
        smp();
        chk(refill_req_valid && (refill_line_addr == A0), "refill request");
        drv();
        while (1) begin smp(); if (refill_rsp_valid) break; drv(); end
        for (int unsigned c = 0; c < 3; c++) begin
            chk(refill_rsp_valid, "response still pending");
            chk(!refill_rsp_ready, "an incomplete beat set must not be consumed");
            chk(dut.state_q[0] == ST_READ, "entry must stay in READ_BEATS");
            drv();
        end
        chk(dut.state_q[0] == ST_READ, "no INSTALL without all beats");
        rf_partial = 1'b0;
        #1;
        chk(refill_rsp_ready, "a complete beat set must be consumed");
        drv();
        chk(dut.state_q[0] == ST_INST, "complete response enters INSTALL");
        drain_idle();
        $display("[%0t] marker: incomplete beat negative ok", $time);

        //---- R. randomised phase ----------------------------------------
        for (int unsigned i = 0; i < WB_ENTRIES; i++) begin
            wb_used[i]  = 1'b0;
            wb_timer[i] = 0;
        end
        for (int unsigned i = 0; i < N; i++) begin
            d_wake_fill[i]     = 1'b0;
            d_wake_fill_idx[i] = 2'd0;
            pub_pend[i]        = 1'b0;
        end
        rnd_cycles = 0;
        $display("-- randomised phase: %0d cycles --", RAND_CYCLES);
        while (rnd_cycles < RAND_CYCLES) begin
            smp();                    // observe the running cycle
            rnd_decide();             // reference model is already advanced one cycle
            drv();                    // cross the clock edge
            rnd_apply();              // drive the next cycle
            rnd_cycles = rnd_cycles + 1;
        end
        idle_inputs();
        repeat (400) cyc();
        chk(busy == '0, "random drain: all entries must return to FREE");
        $display("[%0t] marker: randomised phase ok", $time);

        //---- coverage summary -------------------------------------------
        cov_st_n = 0;
        for (int unsigned i = 0; i < N_STATES; i++)
            if (cov_st[i]) cov_st_n = cov_st_n + 1;
        cov_tr_n = 0;
        for (int unsigned i = 0; i < N_STATES*N_STATES; i++)
            if (cov_tr[i] && legal_tr(3'(i / N_STATES), 3'(i % N_STATES)))
                cov_tr_n = cov_tr_n + 1;

        $display("-- reserves=%0d refills=%0d install_rows=%0d publishes=%0d wb_rows=%0d wakes=%0d checks=%0d --",
                 n_reserve, n_refill, n_install, n_pub, n_wb_row, wake_deliveries, checks);
        $display("mshr coverage: states %0d/%0d, transitions %0d/%0d",
                 cov_st_n, N_STATES, cov_tr_n, N_TRANS);

        chk(cov_st_n == N_STATES, "state coverage incomplete");
        chk(cov_tr_n == N_TRANS, "transition coverage incomplete");
        chk(mdl_prot_err == 0, "single outstanding read violated");
        chk(rnd_cycles >= 10000, "at least 10k randomised cycles");
        chk(n_reserve > 40, "coverage: enough reservations");
        chk(n_refill > 40, "coverage: enough refills");
        chk(n_pub > 40, "coverage: enough installs/publishes");
        chk(n_wb_row > 20, "coverage: enough victim Rows written to the WB");
        chk(wake_deliveries > 20, "coverage: enough WAKE handovers");

        if (errors != 0)
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        $display("ALL TESTS PASSED: %0d checks - LINE_BYTES=%0d ROWS=%0d: reset, clean miss (lock/refill beats/install/wake), dirty victim capture + WB Rows + last-Row gating, Store overlay early takeover + install byte merge, two MSHR refill arbitration, four waiters one per cycle, stale (reused slot) waiter never delivered, overlay window frozen in INSTALL/WAKE, incomplete beat negative, resv_ready/busy view, %0d randomised cycles against the reference model",
                 checks, LBYTES, ROWS, rnd_cycles);
        $finish;
    end

endmodule
