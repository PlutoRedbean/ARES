`timescale 1ns/1ps
//=============================================================================
// ARES LSU - self-checking unit bench for the L09 writeback buffer
//-----------------------------------------------------------------------------
// DUT : rtl/memory/wb_buffer.sv (2-entry dirty victim writeback buffer).
// Spec: docs/microarch/memory.md 6.6 (WB entry state, capture, release after
//       the last accepted beat) and 6.7 (16B beats); docs/m2b_decisions.md
//       D-M2b-03 (release without waiting for the physical write);
//       rtl/memory/LSU_INTERFACES.md section 11 (frozen interface) and
//       section 8 / D-M2b-08 (state and transition coverage).
// FREE items: FREE-10 (verification environment internal structure).
//
// Structure (independent top, own clock/reset, no DPI, no harness):
//   * an INDEPENDENT reference model of the two entries (state, line address,
//     assembled line data, captured-row bitmap) that re-implements the frozen
//     FSM: FREE -> CAPTURING -> READY -> DRAINING -> FREE,
//   * a per-cycle golden comparator for free_mask / busy / wb_req_valid /
//     wb_line_addr / wb_line_data / vis_query_block and for the DUT entry state
//     (read through a hierarchical reference), so no debug port is added,
//   * directed phases: reset, allocate, row capture (out of order), READY
//     arbitration with a stalled wb_req_ready, DRAINING, wb_done release,
//     two-entry parallel capture and lowest-index arbitration, free_mask
//     "no borrow" of the wb_done release, visibility window, reset,
//   * a fixed-seed randomised phase (RAND_CYCLES cycles) driving every port
//     with legal stimulus only, plus SV state / transition coverage counters
//     (4 states, 4 transitions; the run fails if the coverage is not 100%).
//
// Build / run (repository root, LINE_BYTES = 32 by default):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     --top-module tb_wb_buffer --Mdir sim/build/unit/tb_wb_buffer \
//     -o tb_wb_buffer rtl/common/ares_pkg.sv rtl/memory/wb_buffer.sv \
//     rtl/memory/test/unit/tb_wb_buffer.sv
//   sim/build/unit/tb_wb_buffer/tb_wb_buffer
//   (-o is resolved against --Mdir by Verilator 5.x, so the output name must be
//    given relative to the Mdir.)
//=============================================================================
module tb_wb_buffer;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Configuration / geometry
    //-------------------------------------------------------------------------
    localparam int unsigned ENTRIES     = WB_ENTRIES;
    localparam int unsigned ROWS        = ROWS_PER_LINE;
    localparam int unsigned ROW_BITS    = $clog2(ROWS);
    localparam int unsigned LDATA_W     = 8 * LINE_BYTES;
    localparam int unsigned RAND_CYCLES = 4000;
    localparam int unsigned RNG_SEED    = 32'hB0B0_2024;
    localparam int unsigned ENT_BITS    = $clog2(ENTRIES);
    localparam int unsigned N_STATES    = 4;
    localparam int unsigned N_TRANS     = 4;

    localparam logic [1:0] WB_FREE      = 2'd0;
    localparam logic [1:0] WB_CAPTURING = 2'd1;
    localparam logic [1:0] WB_READY     = 2'd2;
    localparam logic [1:0] WB_DRAINING  = 2'd3;

    //-------------------------------------------------------------------------
    // Clock / reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    localparam int unsigned WATCHDOG_CYCLES = 200000;
    initial begin
        repeat (WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1, "TB FAILED: watchdog timeout after %0d cycles", WATCHDOG_CYCLES);
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic                     alloc_valid;
    logic [1:0]               alloc_idx;
    logic [31:0]              alloc_line_addr;
    logic [ENTRIES-1:0]       free_mask;
    logic                     cap_wr_valid;
    logic [1:0]               cap_wr_idx;
    logic [ROW_BITS-1:0]      cap_wr_row;
    logic [63:0]              cap_wr_data;
    logic                     cap_wr_last;
    logic                     wb_req_valid;
    logic                     wb_req_ready;
    logic [31:0]              wb_line_addr;
    logic [LDATA_W-1:0]       wb_line_data;
    logic                     wb_done;
    logic [31:0]              vis_query_line_addr;
    logic                     vis_query_block;
    logic [ENTRIES-1:0]       busy;

    wb_buffer dut (.*);

    //=========================================================================
    // Independent reference model
    //=========================================================================
    logic [1:0]         m_state [ENTRIES];
    logic [31:0]        m_addr  [ENTRIES];
    logic [LDATA_W-1:0] m_data  [ENTRIES];
    logic [ROWS-1:0]    m_rowv  [ENTRIES];

    //=========================================================================
    // Checking / stimulus helpers
    //=========================================================================
    int unsigned checks;
    int unsigned errors;

    task automatic chk(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 40) $display("[%0t] FAIL: %s", $time, msg);
            end
        end
    endtask

    task automatic drv(); @(posedge clk); #1; endtask
    task automatic smp(); @(negedge clk); #2; endtask

    function automatic logic is_legal_edge(input logic [1:0] from, input logic [1:0] to);
        is_legal_edge = (from == to)
                     || ((from == WB_FREE)      && (to == WB_CAPTURING))
                     || ((from == WB_CAPTURING) && (to == WB_READY))
                     || ((from == WB_READY)     && (to == WB_DRAINING))
                     || ((from == WB_DRAINING)  && (to == WB_FREE));
    endfunction

    function automatic logic [63:0] pat_row(input logic [1:0] idx, input logic [ROW_BITS-1:0] row);
        logic [63:0] x;
        begin
            x = 64'hC0DE_0000_5A00_0000 ^ (64'(idx) << 32) ^ (64'(row) << 8);
            pat_row = x ^ 64'h0F0F_0F0F_1234_5678;
        end
    endfunction

    //---- state / transition coverage counters (D-M2b-08) --------------------
    int unsigned cov_state [N_STATES];
    int unsigned cov_trans [N_STATES][N_STATES];
    logic [1:0]  prev_state [ENTRIES];

    //---- one clock cycle: sample the outputs, compare against the reference
    //     model, then apply this cycle's inputs to the model and cross the edge
    task automatic check_cycle();
        logic [ENTRIES-1:0] free_v, ready_v, drain_v, sel;
        logic               any_ready, any_drain, req_v, e_vis;
        logic [31:0]        e_addr;
        logic [LDATA_W-1:0] e_data;
        begin
            free_v = '0; ready_v = '0; drain_v = '0;
            for (int unsigned w = 0; w < ENTRIES; w++) begin
                free_v[w]  = (m_state[w] == WB_FREE);
                ready_v[w] = (m_state[w] == WB_READY);
                drain_v[w] = (m_state[w] == WB_DRAINING);
            end
            any_ready = |ready_v;
            any_drain = |drain_v;
            req_v     = any_ready && !any_drain;
            sel       = '0;
            for (int unsigned w = ENTRIES; w > 0; w--)
                if (ready_v[w-1]) sel = ENTRIES'(1'b1) << (w-1);

            chk(free_mask == free_v, "free_mask != cycle-start free entries");
            chk(busy == ~free_v, "busy != ~free_mask");
            chk(wb_req_valid == req_v, "wb_req_valid != READY entry available");

            if (req_v) begin
                e_addr = 32'd0;
                e_data = '0;
                for (int unsigned w = 0; w < ENTRIES; w++) begin
                    e_addr |= {32{sel[w]}} & m_addr[w];
                    e_data |= {LDATA_W{sel[w]}} & m_data[w];
                end
                chk(wb_line_addr == e_addr, "wb_line_addr != lowest READY entry");
                chk(wb_line_data == e_data, "wb_line_data != lowest READY entry");
            end

            e_vis = 1'b0;
            for (int unsigned w = 0; w < ENTRIES; w++)
                if (!free_v[w] && (m_addr[w] == vis_query_line_addr)) e_vis = 1'b1;
            chk(vis_query_block == e_vis, "vis_query_block != owned line match");

            for (int unsigned w = 0; w < ENTRIES; w++) begin
                chk(dut.state_q[w] == m_state[w], "DUT entry state != reference model");
                cov_state[dut.state_q[w]] = cov_state[dut.state_q[w]] + 1;
                if (dut.state_q[w] != prev_state[w]) begin
                    chk(is_legal_edge(prev_state[w], dut.state_q[w]),
                        "illegal WB FSM transition");
                    cov_trans[prev_state[w]][dut.state_q[w]] =
                        cov_trans[prev_state[w]][dut.state_q[w]] + 1;
                end
                prev_state[w] = dut.state_q[w];
            end
        end
    endtask

    task automatic model_step(input logic alloc_v, input logic [1:0] alloc_i,
                              input logic [31:0] alloc_a,
                              input logic cap_v, input logic [1:0] cap_i,
                              input logic [ROW_BITS-1:0] cap_r, input logic [63:0] cap_d,
                              input logic cap_last, input logic dn);
        logic [ENTRIES-1:0] ready_v, drain_v, sel;
        logic any_ready, any_drain, req_v;
        begin
            ready_v = '0; drain_v = '0;
            for (int unsigned w = 0; w < ENTRIES; w++) begin
                ready_v[w] = (m_state[w] == WB_READY);
                drain_v[w] = (m_state[w] == WB_DRAINING);
            end
            any_ready = |ready_v;
            any_drain = |drain_v;
            req_v     = any_ready && !any_drain;
            sel       = '0;
            for (int unsigned w = ENTRIES; w > 0; w--)
                if (ready_v[w-1]) sel = ENTRIES'(1'b1) << (w-1);

            for (int unsigned w = 0; w < ENTRIES; w++) begin
                case (m_state[w])
                    WB_FREE: begin
                        if (alloc_v && (alloc_i == 2'(w))) begin
                            m_state[w] = WB_CAPTURING;
                            m_addr[w]  = alloc_a;
                            m_data[w]  = '0;
                            m_rowv[w]  = '0;
                        end
                    end
                    WB_CAPTURING: begin
                        if (cap_v && (cap_i == 2'(w))) begin
                            m_data[w][64*cap_r +: 64] = cap_d;
                            m_rowv[w][cap_r]          = 1'b1;
                            if (cap_last) m_state[w] = WB_READY;
                        end
                    end
                    WB_READY: begin
                        if (req_v && sel[w] && wb_req_ready) m_state[w] = WB_DRAINING;
                    end
                    WB_DRAINING: begin
                        if (dn) m_state[w] = WB_FREE;
                    end
                    default: m_state[w] = WB_FREE;
                endcase
            end
        end
    endtask

    // One full cycle with wb_done = dn; inputs for the cycle must be set first.
    task automatic step(input logic dn);
        begin
            wb_done = dn;
            smp();
            check_cycle();
            model_step(alloc_valid, alloc_idx, alloc_line_addr,
                       cap_wr_valid, cap_wr_idx, cap_wr_row, cap_wr_data,
                       cap_wr_last, dn);
            drv();
        end
    endtask

    task automatic idle_inputs();
        begin
            alloc_valid         = 1'b0;
            alloc_idx           = 2'd0;
            alloc_line_addr     = 32'd0;
            cap_wr_valid        = 1'b0;
            cap_wr_idx          = 2'd0;
            cap_wr_row          = '0;
            cap_wr_data         = 64'd0;
            cap_wr_last         = 1'b0;
            wb_req_ready        = 1'b0;
            wb_done             = 1'b0;
            vis_query_line_addr = 32'hDEAD_0000;
        end
    endtask

    //=========================================================================
    // Randomised phase
    //=========================================================================
    int unsigned alloc_seq;
    int unsigned n_alloc, n_cap, n_grant, n_done;

    function automatic logic [31:0] rand_line_addr();
        begin
            rand_line_addr = 32'h4000_0000 | (32'(alloc_seq) * 32'(LINE_BYTES));
            alloc_seq = alloc_seq + 1;
        end
    endfunction

    task automatic gen_stimulus();
        logic [ENTRIES-1:0] free_v, cap_v;
        logic [1:0]         idx;
        logic [ROW_BITS-1:0] r;
        int unsigned        k;
        begin
            idle_inputs();
            free_v = '0; cap_v = '0;
            for (int unsigned w = 0; w < ENTRIES; w++) begin
                free_v[w] = (m_state[w] == WB_FREE);
                cap_v[w]  = (m_state[w] == WB_CAPTURING);
            end

            wb_req_ready = ($urandom_range(0, 2) != 0);

            if ((|free_v) && ($urandom_range(0, 2) == 0)) begin
                k = $urandom_range(0, ENTRIES - 1);
                for (int unsigned w = 0; w < ENTRIES; w++) begin
                    idx = 2'((k + w) % ENTRIES);
                    if (|(free_v & (ENTRIES'(1'b1) << idx))) begin
                        alloc_valid     = 1'b1;
                        alloc_idx       = idx;
                        alloc_line_addr = rand_line_addr();
                        break;
                    end
                end
            end

            if (|cap_v) begin
                k = $urandom_range(0, ENTRIES - 1);
                for (int unsigned w = 0; w < ENTRIES; w++) begin
                    idx = 2'((k + w) % ENTRIES);
                    if (|(cap_v & (ENTRIES'(1'b1) << idx))) begin
                        r = ROW_BITS'($urandom_range(0, ROWS - 1));
                        // finish the entry as soon as the last missing Row is
                        // written, otherwise pick any open Row
                        if ((m_rowv[idx[ENT_BITS-1:0]] | (ROWS'(1) << r)) == {ROWS{1'b1}}) begin
                            cap_wr_valid = 1'b1;
                            cap_wr_idx   = idx;
                            cap_wr_row   = r;
                            cap_wr_data  = pat_row(idx, r);
                            cap_wr_last  = 1'b1;
                        end else if ($urandom_range(0, 2) != 0) begin
                            cap_wr_valid = 1'b1;
                            cap_wr_idx   = idx;
                            cap_wr_row   = r;
                            cap_wr_data  = pat_row(idx, r);
                            cap_wr_last  = 1'b0;
                        end
                        break;
                    end
                end
            end

            case ($urandom_range(0, 3))
                0:       vis_query_line_addr = m_addr[0];
                1:       vis_query_line_addr = m_addr[1];
                2:       vis_query_line_addr = 32'hDEAD_0000;
                default: vis_query_line_addr = m_addr[$urandom_range(0, ENTRIES - 1)] ^ 32'h4;
            endcase
        end
    endtask

    //=========================================================================
    // Test program
    //=========================================================================
    initial begin
        logic [ENTRIES-1:0] exp_free;
        logic [31:0]        addr_a, addr_b;
        logic [LDATA_W-1:0] line_a;
        int unsigned        st_hit, tr_hit;
        logic               dn;
        logic               any_drain;
        logic [ROW_BITS-1:0] r;

        idle_inputs();
        checks = 0;
        errors = 0;
        alloc_seq = 0;
        n_alloc = 0; n_cap = 0; n_grant = 0; n_done = 0;
        for (int unsigned i = 0; i < N_STATES; i++) begin
            cov_state[i] = 0;
            for (int unsigned j = 0; j < N_STATES; j++) cov_trans[i][j] = 0;
        end
        for (int unsigned w = 0; w < ENTRIES; w++) begin
            m_state[w]  = WB_FREE;
            m_addr[w]   = 32'd0;
            m_data[w]   = '0;
            m_rowv[w]   = '0;
            prev_state[w] = WB_FREE;
        end
        void'($urandom(RNG_SEED));

        $display("== tb_wb_buffer: WB_ENTRIES=%0d ROWS=%0d LINE_BYTES=%0d ==",
                 ENTRIES, ROWS, LINE_BYTES);

        //---- 0. reset -------------------------------------------------------
        chk(ENTRIES == 2, "WB_ENTRIES must be 2");
        rst = 1'b1;
        repeat (3) drv();
        rst = 1'b0;
        drv();
        chk(free_mask == {ENTRIES{1'b1}}, "reset: free_mask must be all ones");
        chk(busy == '0, "reset: busy must be 0");
        chk(!wb_req_valid, "reset: wb_req_valid must be 0");
        chk(!vis_query_block, "reset: vis_query_block must be 0");
        for (int unsigned w = 0; w < ENTRIES; w++)
            chk(dut.state_q[w] == WB_FREE, "reset: entry must be FREE");
        $display("[%0t] marker: reset ok", $time);

        //---- 1. allocate entry 1, capture the Rows out of order -------------
        addr_a = 32'h0000_2000;
        alloc_valid     = 1'b1;
        alloc_idx       = 2'd1;
        alloc_line_addr = addr_a;
        step(1'b0);
        alloc_valid = 1'b0;
        n_alloc = n_alloc + 1;
        chk(free_mask == 2'b01, "alloc: entry 1 must be busy, entry 0 free");
        chk(busy == 2'b10, "alloc: busy must mark entry 1");
        chk(dut.state_q[1] == WB_CAPTURING, "alloc: entry 1 must be CAPTURING");
        vis_query_line_addr = addr_a;
        step(1'b0);
        chk(vis_query_block, "CAPTURING entry must block its own line");
        vis_query_line_addr = addr_a ^ 32'h4;
        step(1'b0);
        chk(!vis_query_block, "a different line must not be blocked");

        // capture rows from the last to the first (Row addressing check)
        line_a = '0;
        for (int unsigned i = 0; i < ROWS; i++) begin
            r = ROW_BITS'(ROWS - 1 - i);
            cap_wr_valid = 1'b1;
            cap_wr_idx   = 2'd1;
            cap_wr_row   = r;
            cap_wr_data  = pat_row(2'd1, r);
            cap_wr_last  = (i == ROWS - 1);
            line_a[64*r +: 64] = pat_row(2'd1, r);
            step(1'b0);
            cap_wr_valid = 1'b0;
            cap_wr_last  = 1'b0;
            n_cap = n_cap + 1;
        end
        chk(dut.state_q[1] == WB_READY, "cap_wr_last must move the entry to READY");
        $display("[%0t] marker: allocate + capture ok", $time);

        //---- 2. READY arbitration with a stalled wb_req_ready ---------------
        wb_req_ready = 1'b0;
        for (int unsigned i = 0; i < 3; i++) begin
            step(1'b0);
            chk(wb_req_valid, "READY entry must drive wb_req_valid");
        end
        chk(wb_line_addr == addr_a, "READY entry must present its line address");
        chk(wb_line_data == line_a, "READY entry must present the assembled line");
        chk(free_mask == 2'b01, "free_mask must stay cycle-start based while stalled");

        //---- 3. hand over to the Line Adapter (READY -> DRAINING) -----------
        wb_req_ready = 1'b1;
        step(1'b0);
        n_grant = n_grant + 1;
        wb_req_ready = 1'b0;
        chk(dut.state_q[1] == WB_DRAINING, "handshake must move the entry to DRAINING");
        chk(!wb_req_valid, "DRAINING entry must not re-present the request");
        chk(busy == 2'b10, "DRAINING entry is still busy");
        vis_query_line_addr = addr_a;
        step(1'b0);
        chk(vis_query_block, "DRAINING entry must still block its line");
        chk(free_mask == 2'b01, "DRAINING entry is not free");

        //---- 4. wb_done releases the entry without waiting for the bus ------
        step(1'b1);
        n_done = n_done + 1;
        chk(dut.state_q[1] == WB_FREE, "wb_done must return the entry to FREE");
        chk(free_mask == 2'b11, "released entry must be free on the next cycle");
        chk(busy == '0, "released entry must not be busy");
        step(1'b0);
        chk(!vis_query_block || (vis_query_line_addr != addr_a),
            "released line must not block any more");
        $display("[%0t] marker: READY / DRAINING / wb_done ok", $time);

        //---- 5. two entries: parallel capture + lowest-index arbitration ----
        addr_a = 32'h0000_3000;
        addr_b = 32'h0000_4000;
        // entry 0 and entry 1 captured in parallel (different Rows per cycle)
        alloc_valid = 1'b1; alloc_idx = 2'd0; alloc_line_addr = addr_a;
        step(1'b0);
        alloc_valid = 1'b1; alloc_idx = 2'd1; alloc_line_addr = addr_b;
        step(1'b0);
        alloc_valid = 1'b0;
        n_alloc = n_alloc + 2;
        for (int unsigned i = 0; i < ROWS; i++) begin
            cap_wr_valid = 1'b1;
            cap_wr_idx   = 2'd0;
            cap_wr_row   = ROW_BITS'(i);
            cap_wr_data  = pat_row(2'd0, ROW_BITS'(i));
            cap_wr_last  = (i == ROWS - 1);
            step(1'b0);
            cap_wr_valid = 1'b1;
            cap_wr_idx   = 2'd1;
            cap_wr_row   = ROW_BITS'(i);
            cap_wr_data  = pat_row(2'd1, ROW_BITS'(i));
            cap_wr_last  = (i == ROWS - 1);
            step(1'b0);
            cap_wr_valid = 1'b0;
            cap_wr_last  = 1'b0;
            n_cap = n_cap + 2;
        end
        chk((dut.state_q[0] == WB_READY) && (dut.state_q[1] == WB_READY),
            "both entries must reach READY");
        wb_req_ready = 1'b0;
        vis_query_line_addr = addr_b;
        step(1'b0);
        chk(wb_line_addr == addr_a, "lowest index READY entry must win the arbiter");
        chk(vis_query_block, "entry 1 must still block even while entry 0 wins");

        // serve entry 0 while entry 1 stays READY
        wb_req_ready = 1'b1;
        step(1'b0);
        n_grant = n_grant + 1;
        wb_req_ready = 1'b0;
        chk(dut.state_q[0] == WB_DRAINING, "entry 0 must be DRAINING");
        step(1'b0);
        chk(!wb_req_valid, "no second writeback while one entry is DRAINING");
        chk(busy == 2'b11, "entry 1 must stay busy/READY while entry 0 drains");
        step(1'b1);
        n_done = n_done + 1;
        chk(dut.state_q[0] == WB_FREE, "entry 0 released by wb_done");
        chk(dut.state_q[1] == WB_READY, "entry 1 still READY");
        step(1'b0);
        chk(wb_req_valid, "entry 1 must be presented after entry 0 released");
        chk(wb_line_addr == addr_b, "entry 1 line address must be presented");
        $display("[%0t] marker: two-entry arbitration ok", $time);

        //---- 6. free_mask must not borrow the wb_done release ---------------
        // Entry 1 is READY: serve it while entry 0 stays FREE.
        wb_req_ready = 1'b1;
        step(1'b0);
        n_grant = n_grant + 1;
        wb_req_ready = 1'b0;
        chk(dut.state_q[1] == WB_DRAINING, "entry 1 must be DRAINING");
        chk(free_mask == 2'b01, "entry 0 must be the only free entry");

        // In the wb_done cycle free_mask still reports the draining entry as
        // busy (cycle-start value), so the releasing entry cannot be picked in
        // that cycle.  The only legal allocation is the genuinely free entry 0.
        alloc_valid     = 1'b1;
        alloc_idx       = 2'd0;
        alloc_line_addr = 32'h0000_5000;
        wb_done         = 1'b1;
        smp();
        exp_free = '0;
        for (int unsigned w = 0; w < ENTRIES; w++) exp_free[w] = (m_state[w] == WB_FREE);
        chk(free_mask == exp_free, "free_mask must not borrow the wb_done release");
        chk(free_mask == 2'b01, "draining entry must still read as busy in the wb_done cycle");
        check_cycle();
        model_step(alloc_valid, alloc_idx, alloc_line_addr, cap_wr_valid,
                   cap_wr_idx, cap_wr_row, cap_wr_data, cap_wr_last, 1'b1);
        drv();
        n_done  = n_done + 1;
        n_alloc = n_alloc + 1;
        alloc_valid = 1'b0;
        wb_done     = 1'b0;
        chk(dut.state_q[1] == WB_FREE, "wb_done must release entry 1");
        chk(dut.state_q[0] == WB_CAPTURING, "entry 0 allocated in the wb_done cycle");
        chk(free_mask == 2'b10, "released entry must be free on the next cycle");

        // entry 1 is allocatable one cycle after the release
        alloc_valid     = 1'b1;
        alloc_idx       = 2'd1;
        alloc_line_addr = 32'h0000_6000;
        step(1'b0);
        alloc_valid = 1'b0;
        n_alloc = n_alloc + 1;
        chk(dut.state_q[1] == WB_CAPTURING, "entry 1 allocatable one cycle after release");

        // capture both entries in parallel and drain them back to FREE
        for (int unsigned i = 0; i < ROWS; i++) begin
            cap_wr_valid = 1'b1;
            cap_wr_idx   = 2'd0;
            cap_wr_row   = ROW_BITS'(i);
            cap_wr_data  = pat_row(2'd0, ROW_BITS'(i));
            cap_wr_last  = (i == ROWS - 1);
            step(1'b0);
            cap_wr_idx   = 2'd1;
            cap_wr_row   = ROW_BITS'(i);
            cap_wr_data  = pat_row(2'd1, ROW_BITS'(i));
            step(1'b0);
            n_cap = n_cap + 2;
        end
        cap_wr_valid = 1'b0; cap_wr_last = 1'b0;
        for (int unsigned k = 0; k < ENTRIES; k++) begin
            wb_req_ready = 1'b1;
            step(1'b0);
            n_grant = n_grant + 1;
            wb_req_ready = 1'b0;
            step(1'b1);
            n_done = n_done + 1;
        end
        chk((dut.state_q[0] == WB_FREE) && (dut.state_q[1] == WB_FREE),
            "both entries must be FREE after draining");
        $display("[%0t] marker: free_mask no-borrow ok", $time);

        //---- 7. randomised phase -------------------------------------------
        $display("-- randomised phase: %0d cycles --", RAND_CYCLES);
        gen_stimulus();
        for (int unsigned c = 0; c < RAND_CYCLES; c++) begin
            any_drain = 1'b0;
            for (int unsigned w = 0; w < ENTRIES; w++)
                any_drain = any_drain || (m_state[w] == WB_DRAINING);
            dn = any_drain && ($urandom_range(0, 2) == 0);
            if (dn) n_done = n_done + 1;
            if (alloc_valid) n_alloc = n_alloc + 1;
            if (cap_wr_valid) n_cap = n_cap + 1;
            if (wb_req_valid && wb_req_ready) n_grant = n_grant + 1;
            step(dn);
            gen_stimulus();
        end

        //---- 8. drain -------------------------------------------------------
        idle_inputs();
        repeat (4) step(1'b0);

        //---- 9. coverage report --------------------------------------------
        st_hit = 0;
        tr_hit = 0;
        for (int unsigned i = 0; i < N_STATES; i++) if (cov_state[i] > 0) st_hit = st_hit + 1;
        for (int unsigned i = 0; i < N_STATES; i++)
            for (int unsigned j = 0; j < N_STATES; j++)
                if (cov_trans[i][j] > 0) tr_hit = tr_hit + 1;

        chk(alloc_seq > 0, "coverage: allocations exercised");
        chk(n_cap > 100, "coverage: row captures exercised");
        chk(n_grant > 100, "coverage: writeback handovers exercised");
        chk(n_done > 100, "coverage: wb_done releases exercised");

        $display("wb_buffer coverage: states %0d/%0d, transitions %0d/%0d",
                 st_hit, N_STATES, tr_hit, N_TRANS);
        $display("-- alloc=%0d cap=%0d grant=%0d done=%0d checks=%0d --",
                 n_alloc, n_cap, n_grant, n_done, checks);

        if ((st_hit != N_STATES) || (tr_hit != N_TRANS))
            $fatal(1, "TB FAILED: FSM coverage incomplete (%0d/%0d states, %0d/%0d transitions)",
                   st_hit, N_STATES, tr_hit, N_TRANS);
        if (errors != 0)
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        $display("ALL TESTS PASSED: %0d checks - LINE_BYTES=%0d ROWS=%0d: reset FREEs all entries, allocate, out-of-order Row capture, READY arbitration (stalled and granted), DRAINING + wb_done release, two-entry parallel capture with lowest-index arbitration, free_mask no-borrow, visibility window, %0d random cycles, FSM coverage 100%%",
                 checks, LINE_BYTES, ROWS, RAND_CYCLES);
        $finish;
    end

endmodule
