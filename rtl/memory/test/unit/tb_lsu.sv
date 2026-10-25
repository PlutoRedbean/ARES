`timescale 1ns/1ps
//=============================================================================
// ARES LSU integration self-check: lsu_top (C2 M2a minimal read/write loop)
//-----------------------------------------------------------------------------
// Standalone, self-checking bench (own clock, no DPI model, no harness).
//
// DUT: rtl/memory/lsu_top.sv with the M2a staging path (AGU -> LQ/SQ ->
// line_adapter single-beat channel -> behavioural 128-bit memory model) plus
// the MMIO single-outstanding channel (behavioural device model).
//
// What is checked
//   * every live load/store gets EXACTLY ONE completion, and no killed
//     operation ever completes (memory.md 6.8 / 7.4)
//   * every load result equals the reference byte merge of
//     {older stores still visible in the SQ} over {memory snapshot at issue},
//     for LB/LH/LW/LBU/LHU at all four byte offsets (memory.md 4.2)
//   * store execution completions are zero-returning single events, the
//     2-wide store_commit_ok/commit_fire handshake accepts SPEC stores in SQ
//     order, and after the run the memory image equals the architectural image
//     (every committed store reached memory through the drain path)
//   * kill (flush) is a young contiguous suffix: killed ops never complete,
//     surviving ops keep their progress, credits come back
//   * the killed-in-AGU + same-slot-reallocation hazard (a stale AGU result
//     must never be written into a freshly allocated entry)
//   * MMIO: a committed store drains through the device channel and takes over
//     only on the write response; an MMIO load waits for the commit head, then
//     completes with the device word; lsu_mmio_order_idle is 0 while a
//     committed MMIO transaction is outstanding (memory.md 3.1)
//   * reset leaves the LSU empty and credits full
//
// Build + run (repository root; "--Mdir <abs dir> -o <name>" because verilator
// runs the generated make with the Mdir as its working directory):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu
//       --Mdir sim/build/unit/tb_lsu -o tb_lsu
//       rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/star.sv
//       rtl/memory/test/unit/tb_lsu.sv && sim/build/unit/tb_lsu/tb_lsu
//   (or simply: make unit-lsu)
//
// Spec sources: memory.md 3 / 3.1 / 4 / 5 / 6.7 / 7 / 8, plan 5.10 / 5.11.
// FREE items: FREE-10 (verification environment structure).
//=============================================================================
module tb_lsu;
    import ares_pkg::*;
    import lsu_pkg::*;

    //-------------------------------------------------------------------------
    // Clock / reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    integer errors = 0;
    integer checks = 0;

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic        lsu_can_accept;
    logic [2:0]  load_credit;
    logic [3:0]  store_credit;
    logic        issue_valid;
    fu_req_t     issue_req;
    logic        completion_valid;
    fu_completion_t completion;
    logic [CIQ_ENTRIES-1:0] kill_mask;
    logic        load_head_valid;
    tag_t        load_head_tag;
    logic [1:0]  store_commit_valid;
    tag_t        store_commit_tag [2];
    logic [1:0]  store_commit_ok;
    logic [1:0]  commit_fire;
    logic        lsu_mmio_order_idle;
    logic        lsu_fence_idle;
    logic        mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    logic [31:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0] mem_wr_be;
    logic        mem_wr_valid, mem_wr_ready;
    logic        mmio_req_valid, mmio_req_ready, mmio_write;
    logic [31:0] mmio_addr, mmio_wdata;
    logic [3:0]  mmio_wstrb;
    logic        mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_rsp_data;
    logic [2:0]  dbg_lq_used;
    logic [3:0]  dbg_sq_used;

    localparam logic [31:0] MMIO_BASE = 32'hA000_0000;
    localparam logic [31:0] MEM_BASE  = 32'h8010_0000;
    localparam int unsigned BEATS     = 4096;    // 64 KiB

    lsu_top #(
        .MMIO_BASE (MMIO_BASE),
        .MMIO_MASK (32'hFF00_0000)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .lsu_can_accept      (lsu_can_accept),
        .load_credit         (load_credit),
        .store_credit        (store_credit),
        .issue_valid         (issue_valid),
        .issue_req           (issue_req),
        .completion_valid    (completion_valid),
        .completion          (completion),
        .kill_mask           (kill_mask),
        .load_head_valid     (load_head_valid),
        .load_head_tag       (load_head_tag),
        .store_commit_valid  (store_commit_valid),
        .store_commit_tag    (store_commit_tag),
        .store_commit_ok     (store_commit_ok),
        .commit_fire         (commit_fire),
        .lsu_mmio_order_idle (lsu_mmio_order_idle),
        .lsu_fence_idle      (lsu_fence_idle),
        .mem_rd_valid        (mem_rd_valid),
        .mem_rd_ready        (mem_rd_ready),
        .mem_rd_addr         (mem_rd_addr),
        .mem_rsp_valid       (mem_rsp_valid),
        .mem_rsp_ready       (mem_rsp_ready),
        .mem_rsp_data        (mem_rsp_data),
        .mem_wr_valid        (mem_wr_valid),
        .mem_wr_ready        (mem_wr_ready),
        .mem_wr_addr         (mem_wr_addr),
        .mem_wr_data         (mem_wr_data),
        .mem_wr_be           (mem_wr_be),
        .mmio_req_valid      (mmio_req_valid),
        .mmio_req_ready      (mmio_req_ready),
        .mmio_write          (mmio_write),
        .mmio_addr           (mmio_addr),
        .mmio_wdata          (mmio_wdata),
        .mmio_wstrb          (mmio_wstrb),
        .mmio_rsp_valid      (mmio_rsp_valid),
        .mmio_rsp_ready      (mmio_rsp_ready),
        .mmio_rsp_data       (mmio_rsp_data),
        .dbg_lq_used         (dbg_lq_used),
        .dbg_sq_used         (dbg_sq_used)
    );

    //-------------------------------------------------------------------------
    // Behavioural 128-bit memory model (memory.md 6.7 timing: a read returns
    // two cycles after the handshake, registered; a beat write is applied at
    // the handshake edge and is ordered before a same-edge read sample)
    //-------------------------------------------------------------------------
    logic [127:0] mem  [0:BEATS-1];   // physical memory (driven by the DUT)
    logic [127:0] arch [0:BEATS-1];   // architectural image (updated at commit)

    /* verilator lint_off UNUSEDSIGNAL */  // only the beat index matters here
    function automatic int unsigned bidx(input logic [31:0] a);
        bidx = int'(a[15:4]);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic logic [31:0] mem_word(input logic [31:0] a);
        mem_word = mem[bidx(a)][32*a[3:2] +: 32];
    endfunction

    // Architectural word: with the M2b write-back DCache, physical memory only
    // matches the architectural image after the dirty lines were written back,
    // so the reference snapshot must come from the commit-time image.
    function automatic logic [31:0] arch_word(input logic [31:0] a);
        arch_word = arch[bidx(a)][32*a[3:2] +: 32];
    endfunction

    task automatic beat_write(input logic [31:0] a, input logic [127:0] d, input logic [15:0] be);
        for (int unsigned b = 0; b < 16; b++)
            if (be[b]) mem[bidx(a)][8*b +: 8] = d[8*b +: 8];
    endtask

    logic        rd_busy;
    logic [31:0] rd_addr_q;
    logic        rsp_valid_q;
    logic [127:0] rsp_data_q;
    wire rd_accept = mem_rd_valid && mem_rd_ready;
    wire rsp_fire  = rsp_valid_q && mem_rsp_ready;

    assign mem_wr_ready  = 1'b1;   // the model never back-pressures writes
    assign mem_rd_ready  = !rd_busy && (!rsp_valid_q || mem_rsp_ready);
    assign mem_rsp_valid = rsp_valid_q;
    assign mem_rsp_data  = rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_busy     <= 1'b0;
            rd_addr_q   <= 32'd0;
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 128'd0;
        end else begin
            if (mem_wr_valid && mem_wr_ready)
                beat_write(mem_wr_addr, mem_wr_data, mem_wr_be);
            if (rsp_fire)
                rsp_valid_q <= 1'b0;
            if (rd_busy) begin
                rsp_data_q  <= mem[bidx(rd_addr_q)];
                rsp_valid_q <= 1'b1;
                rd_busy     <= 1'b0;
            end else if (rd_accept) begin
                rd_busy   <= 1'b1;
                rd_addr_q <= mem_rd_addr;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Behavioural MMIO device (word-register file inside the window).  The
    // response is asserted one cycle after the request handshake, exactly like
    // tb_mmio_if: the write side effect happens at the handshake.
    //-------------------------------------------------------------------------
    logic [7:0]  dev [0:1023];
    logic        dev_rsp_valid;
    logic [31:0] dev_rdata;

    assign mmio_req_ready = !dev_rsp_valid || mmio_rsp_ready;
    assign mmio_rsp_valid = dev_rsp_valid;
    assign mmio_rsp_data  = dev_rdata;
    assign mmio_rsp_ready = 1'b1;

    wire mmio_req_fire = mmio_req_valid && mmio_req_ready;

    // Every device access must target the parameterised MMIO window.
    always_ff @(posedge clk) begin
        if (!rst && mmio_req_valid && ((mmio_addr & 32'hFF00_0000) != 32'hA000_0000))
            $fatal(1, "tb_lsu: MMIO request outside the device window: 0x%08x", mmio_addr);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dev_rsp_valid <= 1'b0;
            dev_rdata     <= 32'd0;
        end else begin
            if (mmio_rsp_valid && mmio_rsp_ready)
                dev_rsp_valid <= 1'b0;
            if (mmio_req_fire) begin
                dev_rsp_valid <= 1'b1;
                if (mmio_write) begin
                    for (int unsigned b = 0; b < 4; b++)
                        if (mmio_wstrb[b])
                            dev[mmio_addr[9:0] + 10'(b)] <= mmio_wdata[8*b +: 8];
                    dev_rdata <= 32'd0;
                end else begin
                    dev_rdata <= {dev[{mmio_addr[9:2], 2'b11}],
                                  dev[{mmio_addr[9:2], 2'b10}],
                                  dev[{mmio_addr[9:2], 2'b01}],
                                  dev[{mmio_addr[9:2], 2'b00}]};
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // Program (issued in order; program order == memory order)
    //-------------------------------------------------------------------------
    localparam int unsigned MAXOPS = 1024;

    op_t         p_op       [MAXOPS];
    logic        p_is_store [MAXOPS];
    logic        p_is_mmio  [MAXOPS];
    logic [31:0] p_addr     [MAXOPS];
    logic [31:0] p_src2     [MAXOPS];
    logic [31:0] p_adata    [MAXOPS];   // AGU-aligned store data
    logic [31:0] p_expect   [MAXOPS];   // expected result (MMIO loads only)
    logic        p_expect_en[MAXOPS];
    logic [3:0]  p_mask     [MAXOPS];
    lsu_size_t   p_size     [MAXOPS];
    logic        p_uns      [MAXOPS];
    int unsigned p_count    = 0;

    logic        r_issued [MAXOPS];
    logic        r_done   [MAXOPS];
    logic        r_killed [MAXOPS];
    tag_t        r_tag    [MAXOPS];
    logic [31:0] r_snap   [MAXOPS];   // memory word snapshot taken at issue
    int unsigned r_issue_ptr  = 0;
    int unsigned r_retire_ptr = 0;
    logic [15:0] tag_busy     = 16'd0;

    //-------------------------------------------------------------------------
    // Stimulus control
    //-------------------------------------------------------------------------
    logic        c_kill_enable = 1'b0;
    logic        c_issue_enable = 1'b1;
    int unsigned cycle_count = 0;
    int unsigned n_completions = 0;
    int unsigned n_kills = 0;

    task automatic chk(input logic cond, input string msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %s", $time, msg);
            end
        end
    endtask

    // Find a live (issued, not retired) operation with this tag.
    function automatic int unsigned find_live(input tag_t t);
        int unsigned i;
        begin
            find_live = MAXOPS;
            for (i = r_retire_ptr; i < r_issue_ptr; i++)
                if (r_issued[i] && !r_killed[i] && (r_tag[i].slot_index == t.slot_index))
                    find_live = i;
        end
    endfunction

    // Reference load value: byte-wise merge of the closest older store over
    // the memory snapshot taken when the load was issued.
    /* verilator lint_off UNUSEDSIGNAL */  // indices into a 1024-entry model
    function automatic logic [31:0] expected_load(input int unsigned li);
        logic [31:0] merged;
        int unsigned best;
        logic found;
        begin
            merged = 32'd0;
            for (int unsigned b = 0; b < 4; b++) begin
                found = 1'b0;
                best  = 0;
                for (int unsigned k = 0; k < li; k++) begin
                    if (r_issued[k] && p_is_store[k] && !r_killed[k] && !p_is_mmio[k]
                        && p_mask[k][b] && (p_addr[k][31:2] == p_addr[li][31:2])) begin
                        found = 1'b1;
                        best  = k;
                    end
                end
                merged[8*b +: 8] = found ? p_adata[best][8*b +: 8] : r_snap[li][8*b +: 8];
            end
            expected_load = lsu_merge_extract(merged, 4'd0, 32'd0, p_uns[li],
                                              p_addr[li][1:0], p_size[li]);
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    //-------------------------------------------------------------------------
    // Cycle driver
    //-------------------------------------------------------------------------
    task automatic observe();
        int unsigned idx;
        begin
            if (completion_valid) begin
                idx = find_live(completion.tag);
                n_completions = n_completions + 1;
                chk(idx != MAXOPS, "completion for an unknown or already retired tag");
                if (idx != MAXOPS) begin
                    chk(!r_killed[idx], "killed operation produced a completion");
                    chk(!r_done[idx], "operation produced more than one completion");
                    chk(!completion.exception && (completion.cause == EXC_NONE)
                        && (completion.tval == 32'd0),
                        "unexpected exception/tval on an LSU completion");
                    r_done[idx]   = 1'b1;
                    if (p_expect_en[idx])
                        chk(completion.result == p_expect[idx], "MMIO load result mismatch");
                    else if (!p_is_store[idx]) begin
                        if (completion.result !== expected_load(idx)) begin
                            $display("LOAD MISMATCH li=%0d op=%0d addr=%08x exp=%08x got=%08x snap=%08x",
                                     idx, p_op[idx], p_addr[idx], expected_load(idx),
                                     completion.result, r_snap[idx]);
                            $display("  CACHE set=%0d way0 tag=%05x v=%b d=%b | way1 tag=%05x v=%b d=%b | lru=%0d | DC own=%b st=%b idx=%0d | MSHR st=%0d/%0d line=%08x/%08x way=%b%b",
                                p_addr[idx][11:5],
                                dut.u_dcache.u_arrays.g_way[0].tag_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.g_way[0].line_valid_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.g_way[0].dirty_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.g_way[1].tag_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.g_way[1].line_valid_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.g_way[1].dirty_mem[p_addr[idx][11:5]],
                                dut.u_dcache.u_arrays.lru_mem[p_addr[idx][11:5]],
                                dut.u_dcache.own_valid, dut.u_dcache.own_store, dut.u_dcache.own_idx,
                                dut.u_mshr.state_q[0], dut.u_mshr.state_q[1],
                                dut.u_mshr.line_q[0], dut.u_mshr.line_q[1],
                                dut.u_mshr.way_q[0], dut.u_mshr.way_q[1]);
                            $display("  ROW responses valid=%b set=%0d/%0d row=%0d/%0d data=%016x/%016x",
                                dut.u_dcache.u_arrays.rd_rsp_valid,
                                dut.u_dcache.u_arrays.rd_rsp_set[0],
                                dut.u_dcache.u_arrays.rd_rsp_set[1],
                                dut.u_dcache.u_arrays.rd_rsp_row[0],
                                dut.u_dcache.u_arrays.rd_rsp_row[1],
                                dut.u_dcache.u_arrays.rd_rsp_data[0],
                                dut.u_dcache.u_arrays.rd_rsp_data[1]);
                        end
                        chk(completion.result == expected_load(idx), "cacheable load result mismatch");
                    end
                end
            end
        end
    endtask

    task automatic driver();
        logic [9:0]  li;          // programme index (MAXOPS = 1024)
        int unsigned lane;
        logic        head_ok;
        logic [15:0] mask;
        logic [3:0]  free_idx;
        logic        tag_found;
        begin
            //-----------------------------------------------------------------
            // default drives
            //-----------------------------------------------------------------
            issue_valid        = 1'b0;
            issue_req          = '0;
            kill_mask          = 16'd0;
            store_commit_valid = 2'd0;
            store_commit_tag[0]= '0;
            store_commit_tag[1]= '0;
            commit_fire        = 2'd0;
            load_head_valid    = 1'b0;
            load_head_tag      = '0;

            //-----------------------------------------------------------------
            // commit head visibility (an EXEC load at the commit head)
            //-----------------------------------------------------------------
            if ((r_retire_ptr < r_issue_ptr) && r_issued[r_retire_ptr]
                && !p_is_store[r_retire_ptr] && !r_killed[r_retire_ptr]) begin
                load_head_valid = 1'b1;
                load_head_tag   = r_tag[r_retire_ptr];
            end

            //-----------------------------------------------------------------
            // kill: young contiguous suffix (never the two commit candidates)
            //-----------------------------------------------------------------
            if (c_kill_enable && (kill_countdown == 0)
                && (r_issue_ptr > r_retire_ptr + 2)) begin
                int unsigned kp;
                kp = r_retire_ptr + 2 + $urandom_range(r_issue_ptr - r_retire_ptr - 3, 0);
                mask = 16'd0;
                for (int unsigned k = kp; k < r_issue_ptr; k++) begin
                    if (r_issued[k] && !r_killed[k]) begin
                        mask[r_tag[k].slot_index] = 1'b1;
                        r_killed[k] = 1'b1;
                    end
                end
                kill_mask     = mask;
                n_kills       = n_kills + 1;
                kill_countdown = $urandom_range(60, 10);
            end else if (kill_countdown > 0) begin
                kill_countdown = kill_countdown - 1;
            end

            //-----------------------------------------------------------------
            // issue (can_accept must be evaluated for the actual operation)
            //
            // plan 5.6: a recovery (kill) cycle inhibits any new issue_valid,
            // exactly like be_issue_sched does.  Without this a load could be
            // accepted in the very cycle an older store leaves the SQ, which
            // the real backend can never produce.
            //-----------------------------------------------------------------
            if (c_issue_enable && (r_issue_ptr < p_count) && (kill_mask == 16'd0)) begin
                li = 10'(r_issue_ptr);
                free_idx = 4'd0;
                tag_found = 1'b0;
                for (int unsigned t = 0; t < 16; t++) begin
                    if (!tag_busy[t] && !tag_found) begin
                        free_idx  = 4'(t);
                        tag_found = 1'b1;
                    end
                end
                if (tag_found) begin
                    issue_req          = '0;
                    issue_req.tag      = tag_t'({free_idx});
                    issue_req.op       = p_op[li];
                    issue_req.src1     = p_addr[li];
                    issue_req.src2     = p_src2[li];
                    issue_req.imm      = 32'd0;
                    #1;   // let lsu_can_accept settle for this operation
                    // memory.md 3: the scheduler checks the port AND the
                    // type-specific credit before it raises issue_valid.
                    // lsu_can_accept itself is only "some capacity is free".
                    if (lsu_can_accept
                        && (p_is_store[li] ? (store_credit != 4'd0)
                                           : (load_credit  != 3'd0))) begin
                        issue_valid        = 1'b1;
                        r_issued[li]       = 1'b1;
                        r_tag[li]          = issue_req.tag;
                        tag_busy[free_idx] = 1'b1;
                        r_snap[li]         = p_is_store[li] ? 32'd0 : arch_word(p_addr[li]);
                        r_issue_ptr        = r_issue_ptr + 1;
                    end
                end
            end

            //-----------------------------------------------------------------
            // commit: at most two lanes, strict prefix
            //-----------------------------------------------------------------
            if ((r_retire_ptr < r_issue_ptr) && r_issued[r_retire_ptr]) begin
                if (r_killed[r_retire_ptr]) begin
                    tag_busy[r_tag[r_retire_ptr].slot_index] = 1'b0;
                    r_retire_ptr = r_retire_ptr + 1;
                end else if (r_done[r_retire_ptr]) begin
                    if (p_is_store[r_retire_ptr]) begin
                        store_commit_valid[0] = 1'b1;
                        store_commit_tag[0]   = r_tag[r_retire_ptr];
                        #1;
                        if (store_commit_ok[0]) begin
                            commit_fire[0] = 1'b1;
                            lane = 0;
                        end else begin
                            lane = 2;
                        end
                    end else begin
                        commit_fire[0] = 1'b1;
                        lane = 0;
                    end

                    if (lane == 0) begin
                        // architectural update of the committed store
                        if (p_is_store[r_retire_ptr] && !p_is_mmio[r_retire_ptr])
                            for (int unsigned b = 0; b < 4; b++)
                                if (p_mask[r_retire_ptr][b])
                                    arch[bidx(p_addr[r_retire_ptr])][8*(4*(p_addr[r_retire_ptr][3:2])+b) +: 8]
                                        = p_adata[r_retire_ptr][8*b +: 8];
                        tag_busy[r_tag[r_retire_ptr].slot_index] = 1'b0;
                        r_retire_ptr = r_retire_ptr + 1;

                        // lane 1 (prefix: only after lane 0 committed)
                        if ((r_retire_ptr < r_issue_ptr) && r_issued[r_retire_ptr]
                            && !r_killed[r_retire_ptr] && r_done[r_retire_ptr]) begin
                            head_ok = 1'b0;
                            if (p_is_store[r_retire_ptr]) begin
                                store_commit_valid[1] = 1'b1;
                                store_commit_tag[1]   = r_tag[r_retire_ptr];
                                #1;
                                if (store_commit_ok[1]) begin
                                    commit_fire[1] = 1'b1;
                                    head_ok = 1'b1;
                                end
                            end else begin
                                commit_fire[1] = 1'b1;
                                head_ok = 1'b1;
                            end
                            if (head_ok) begin
                                if (p_is_store[r_retire_ptr] && !p_is_mmio[r_retire_ptr])
                                    for (int unsigned b = 0; b < 4; b++)
                                        if (p_mask[r_retire_ptr][b])
                                            arch[bidx(p_addr[r_retire_ptr])][8*(4*(p_addr[r_retire_ptr][3:2])+b) +: 8]
                                                = p_adata[r_retire_ptr][8*b +: 8];
                                tag_busy[r_tag[r_retire_ptr].slot_index] = 1'b0;
                                r_retire_ptr = r_retire_ptr + 1;
                            end
                        end
                    end
                end
            end
        end
    endtask

    // Single-cycle events must not stay asserted after the sampling edge: a
    // monitor that re-evaluates a combinational function of the flops (e.g.
    // the SQ's commit authorization) would otherwise see "commit_fire with the
    // *next* commit pointer" and flag a false protocol violation.
    task automatic clear_pulses();
        begin
            issue_valid        = 1'b0;
            issue_req          = '0;
            kill_mask          = 16'd0;
            store_commit_valid = 2'd0;
            store_commit_tag[0]= '0;
            store_commit_tag[1]= '0;
            commit_fire        = 2'd0;
        end
    endtask

    task automatic step();
        begin
            @(negedge clk);
            if (!rst) begin
                cycle_count = cycle_count + 1;
                observe();
                driver();
            end
            @(posedge clk);
            #1;
            clear_pulses();
        end
    endtask

    task automatic run_until_retired(input int unsigned budget);
        int unsigned guard;
        begin
            guard = 0;
            while ((r_retire_ptr < p_count) && (guard < budget)) begin
                step();
                guard = guard + 1;
            end
            if (r_retire_ptr != p_count) begin
                $display("STUCK: retire=%0d issue=%0d p_count=%0d lq=%0d sq=%0d lc=%0d sc=%0d idle=%b",
                         r_retire_ptr, r_issue_ptr, p_count, dbg_lq_used, dbg_sq_used,
                         load_credit, store_credit, lsu_mmio_order_idle);
                for (int unsigned k = r_retire_ptr; k < r_issue_ptr; k++)
                    $display("  op[%0d] store=%b done=%b killed=%b tag=%0d addr=%08x mmio=%b",
                             k, p_is_store[k], r_done[k], r_killed[k],
                             r_tag[k].slot_index, p_addr[k], p_is_mmio[k]);
                $display("  DC: own=%b store=%b idx=%0d psw=%b way=%b set=%0d row=%0d | MSHR: st=%0d/%0d line=%08x/%08x way=%b%b wake=%b%b waiter=%b%b | WB: st=%0d/%0d | SQ: occ=%0d cmt=%0d head=%0d drainv=%b | LQ: alive=%b infl=%b resv=%b",
                    dut.u_dcache.own_valid, dut.u_dcache.own_store, dut.u_dcache.own_idx,
                    dut.u_dcache.psw_valid, dut.u_dcache.psw_way, dut.u_dcache.psw_set,
                    dut.u_dcache.psw_row,
                    dut.u_mshr.state_q[0], dut.u_mshr.state_q[1],
                    dut.u_mshr.line_q[0], dut.u_mshr.line_q[1],
                    dut.u_mshr.way_q[0], dut.u_mshr.way_q[1],
                    dut.u_mshr.wake_valid[0], dut.u_mshr.wake_valid[1],
                    dut.u_mshr.wq_v_q[0], dut.u_mshr.wq_v_q[1],
                    dut.u_wb.state_q[0], dut.u_wb.state_q[1],
                    dut.u_sq.occupancy_r, dut.u_sq.committed_cnt_r, dut.u_sq.sq_head_ptr,
                    dut.u_sq.drain_valid,
                    {dut.u_lq.e_alive[3], dut.u_lq.e_alive[2], dut.u_lq.e_alive[1], dut.u_lq.e_alive[0]},
                    {dut.u_lq.e_lk_inflight[3], dut.u_lq.e_lk_inflight[2], dut.u_lq.e_lk_inflight[1], dut.u_lq.e_lk_inflight[0]},
                    {dut.u_lq.e_result_vld[3], dut.u_lq.e_result_vld[2], dut.u_lq.e_result_vld[1], dut.u_lq.e_result_vld[0]});
            end
            chk(r_retire_ptr == p_count, "program did not retire within the cycle budget");
        end
    endtask

    task automatic run_idle(input int unsigned n);
        begin
            repeat (n) step();
        end
    endtask

    //-------------------------------------------------------------------------
    // Program builders
    //-------------------------------------------------------------------------
    task automatic prog_reset();
        begin
            p_count = 0;
            r_issue_ptr = 0;
            r_retire_ptr = 0;
            for (int unsigned i = 0; i < MAXOPS; i++) begin
                p_op[i] = OP_LW; p_is_store[i] = 1'b0; p_is_mmio[i] = 1'b0;
                p_addr[i] = 32'd0; p_src2[i] = 32'd0; p_adata[i] = 32'd0;
                p_mask[i] = 4'd0; p_size[i] = LSZ_WORD; p_uns[i] = 1'b0;
                p_expect_en[i] = 1'b0; p_expect[i] = 32'd0;
                r_issued[i] = 1'b0; r_done[i] = 1'b0; r_killed[i] = 1'b0;
                r_tag[i] = '0; r_snap[i] = 32'd0;
            end
            tag_busy = 16'd0;
        end
    endtask

    task automatic add_load(input op_t op, input logic [31:0] addr);
        begin
            p_op[p_count]    = op;
            p_is_store[p_count] = 1'b0;
            p_size[p_count]  = lsu_op_size(op);
            p_uns[p_count]   = lsu_op_is_unsigned(op);
            p_mask[p_count]  = lsu_size_mask(addr[1:0], lsu_op_size(op));
            p_addr[p_count]  = addr;
            p_count = p_count + 1;
        end
    endtask

    task automatic add_store(input op_t op, input logic [31:0] addr, input logic [31:0] data);
        begin
            p_op[p_count]    = op;
            p_is_store[p_count] = 1'b1;
            p_size[p_count]  = lsu_op_size(op);
            p_uns[p_count]   = 1'b0;
            p_mask[p_count]  = lsu_size_mask(addr[1:0], lsu_op_size(op));
            p_addr[p_count]  = addr;
            p_src2[p_count]  = data;
            p_adata[p_count] = lsu_align_store_data(data, addr[1:0], lsu_op_size(op));
            p_count = p_count + 1;
        end
    endtask

    task automatic add_mmio_load(input op_t op, input logic [31:0] addr, input logic [31:0] exp_data);
        begin
            add_load(op, addr);
            p_is_mmio[p_count-1]   = 1'b1;
            p_expect_en[p_count-1] = 1'b1;
            p_expect[p_count-1]    = exp_data;
        end
    endtask

    task automatic add_mmio_store(input op_t op, input logic [31:0] addr, input logic [31:0] data);
        begin
            add_store(op, addr, data);
            p_is_mmio[p_count-1] = 1'b1;
        end
    endtask

    //-------------------------------------------------------------------------
    // Phases
    //-------------------------------------------------------------------------
    int unsigned kill_countdown = 0;
    logic        mmio_saw_busy;

    task automatic poke(input logic [31:0] addr, input logic [31:0] data);
        begin
            mem[bidx(addr)][32*addr[3:2] +: 32]  = data;
            arch[bidx(addr)][32*addr[3:2] +: 32] = data;
        end
    endtask

    // NOTE (M2b): the behavioural "poke" writes memory behind the DUT, so a
    // write-back cache would shadow it if the line were already cached.  The
    // poked phases therefore run before any phase that leaves dirty lines in
    // the cache, and every phase after them uses the LSU/reference model only.
    task automatic test_reset();
        begin
            chk(load_credit == 3'd4, "reset: load_credit is not 4");
            chk(store_credit == 4'd8, "reset: store_credit is not 8");
            chk(dbg_lq_used == 3'd0, "reset: LQ is not empty");
            chk(dbg_sq_used == 4'd0, "reset: SQ is not empty");
            chk(!completion_valid, "reset: completion_valid is asserted");
            chk(lsu_mmio_order_idle, "reset: lsu_mmio_order_idle is not 1");
            chk(lsu_fence_idle, "reset: lsu_fence_idle is not 1");
        end
    endtask

    // Forwarding / merge / extension directed programme.
    task automatic test_forwarding();
        logic [31:0] w0, w1;
        begin
            prog_reset();
            w0 = MEM_BASE + 32'h0000_0000;
            w1 = MEM_BASE + 32'h0000_0004;
            poke(w0, 32'h1122_3344);
            poke(w1, 32'h5566_7788);

            add_store(OP_SB, w0 + 32'd1, 32'h0000_00AA);   // mem word0 byte1
            add_load (OP_LW, w0);                          // expect 0x1122AA44
            add_store(OP_SH, w0 + 32'd2, 32'h0000_BEEF);   // bytes 2..3
            add_load (OP_LW, w0);                          // expect 0xBEEFAA44
            add_store(OP_SB, w0 + 32'd3, 32'h0000_0080);
            add_load (OP_LB, w0 + 32'd3);                  // sign extend 0xFFFFFF80
            add_load (OP_LBU, w0 + 32'd3);                 // 0x00000080
            add_store(OP_SW, w1, 32'hDEAD_BEEF);
            add_load (OP_LH, w1 + 32'd2);                  // 0xFFFFDEAD (sign)
            add_load (OP_LHU, w1 + 32'd2);                 // 0x0000DEAD
            add_load (OP_LW, w1);                          // 0xDEADBEEF
            add_load (OP_LW, w0);                          // 0xBEEFAA44 persists

            c_kill_enable = 1'b0;
            run_until_retired(4000);
            run_idle(40);
            chk(store_credit == 4'd8, "forwarding: SQ did not drain back to empty");
            chk(load_credit == 3'd4, "forwarding: LQ did not drain back to empty");
        end
    endtask

    // Kill (flush) of a young suffix, never touching the commit prefix.
    task automatic test_kill();
        begin
            prog_reset();
            build_random(120);
            c_kill_enable = 1'b1;
            kill_countdown = 12;
            run_until_retired(20000);
            c_kill_enable = 1'b0;
            run_idle(40);
            chk(n_kills > 3, "kill phase did not actually inject flushes");
            chk(store_credit == 4'd8, "kill: SQ credit did not recover");
            chk(load_credit == 3'd4, "kill: LQ credit did not recover");
        end
    endtask

    // A killed load whose AGU result arrives in the same cycle its LQ slot is
    // reallocated: the stale result must never reach the new entry.
    task automatic test_stale_agu();
        logic [31:0] addr_a, addr_b;
        logic [31:0] val_a, val_b;
        int unsigned got;
        begin
            addr_a = MEM_BASE + 32'h0000_0040;
            addr_b = MEM_BASE + 32'h0000_0080;
            val_a  = 32'hAAAA_AAAA;
            val_b  = 32'h5555_5555;
            poke(addr_a, val_a);
            poke(addr_b, val_b);

            // cycle 0: issue load A (tag 0)
            @(negedge clk);
            issue_valid = 1'b1;
            issue_req   = '0;
            issue_req.tag  = tag_t'(4'd0);
            issue_req.op   = OP_LW;
            issue_req.src1 = addr_a;
            @(posedge clk); #1;

            // cycle 1: kill A
            @(negedge clk);
            issue_valid = 1'b0;
            kill_mask   = 16'h0001;
            @(posedge clk); #1;

            // cycle 2: reallocate the same tag/slot for load B
            @(negedge clk);
            kill_mask   = 16'd0;
            issue_valid = 1'b1;
            issue_req   = '0;
            issue_req.tag  = tag_t'(4'd0);
            issue_req.op   = OP_LW;
            issue_req.src1 = addr_b;
            @(posedge clk); #1;
            issue_valid = 1'b0;

            got = 0;
            for (int unsigned c = 0; c < 300; c++) begin
                @(negedge clk);
                if (completion_valid) begin
                    got = got + 1;
                    $display("STALE-AGU completion tag=%0d result=%08x (val_a=%08x val_b=%08x)",
                             completion.tag.slot_index, completion.result, val_a, val_b);
                    chk(completion.result == val_b,
                        "stale AGU result was written into a reallocated LQ entry");
                end
            end
            chk(got == 1, "reallocated load did not produce exactly one completion");
            kill_mask = 16'd0;
            run_idle(10);
        end
    endtask

    // MMIO: committed store drains through the device channel, MMIO load waits
    // for the commit head, lsu_mmio_order_idle tracks the outstanding device
    // transaction.
    task automatic test_mmio();
        begin
            prog_reset();
            add_mmio_store(OP_SW, MMIO_BASE + 32'h0000_0010, 32'hCAFE_BABE);
            add_mmio_load (OP_LW, MMIO_BASE + 32'h0000_0010, 32'hCAFE_BABE);
            add_mmio_store(OP_SB, MMIO_BASE + 32'h0000_0011, 32'h0000_0055);
            add_mmio_load (OP_LW, MMIO_BASE + 32'h0000_0010, 32'hCAFE_55BE);

            c_kill_enable = 1'b0;
            run_until_retired(4000);
            run_idle(40);
            chk(mmio_saw_busy, "MMIO: lsu_mmio_order_idle never went low");
            chk(lsu_mmio_order_idle, "MMIO: lsu_mmio_order_idle did not return to 1");
        end
    endtask

    // Random mixed load/store stream with random flushes.
    task automatic test_random();
        begin
            prog_reset();
            build_random(400);
            c_kill_enable = 1'b1;
            kill_countdown = 20;
            run_until_retired(40000);
            c_kill_enable = 1'b0;
            run_idle(60);
            chk(store_credit == 4'd8, "random: SQ credit did not recover");
            chk(load_credit == 3'd4, "random: LQ credit did not recover");
        end
    endtask

    // Random programme generator (all cacheable, naturally aligned).
    task automatic build_random(input int unsigned n);
        logic [31:0] a;
        logic [31:0] base;
        op_t         op;
        int unsigned pick;
        begin
            for (int unsigned i = 0; i < n; i++) begin
                // Span enough lines to exercise hits, capacity/conflict misses,
                // dirty victim writebacks and MSHR merges (M2b).
                base = MEM_BASE + 32'(4 * $urandom_range(255, 0));
                pick = $urandom_range(9, 0);
                case (pick)
                    0: begin op = OP_SB; a = base + 32'($urandom_range(3, 0)); end
                    1: begin op = OP_SH; a = base + 32'(2 * $urandom_range(1, 0)); end
                    2: begin op = OP_SW; a = base; end
                    3: begin op = OP_LB; a = base + 32'($urandom_range(3, 0)); end
                    4: begin op = OP_LH; a = base + 32'(2 * $urandom_range(1, 0)); end
                    5: begin op = OP_LW; a = base; end
                    6: begin op = OP_LBU; a = base + 32'($urandom_range(3, 0)); end
                    7: begin op = OP_LHU; a = base + 32'(2 * $urandom_range(1, 0)); end
                    8: begin op = OP_SW; a = base; end
                    default: begin op = OP_LW; a = base; end
                endcase
                if (lsu_op_is_store(op)) begin
                    add_store(op, a, $urandom);
                end else begin
                    add_load(op, a);
                end
            end
        end
    endtask

    // DCache directed sequence (M2b): cold store miss (reserve + overlay),
    // install, store hit + pending write, same-line load merge, dirty victim
    // eviction (writeback) and refill.  Load values are checked by the common
    // reference model, the writeback by the final image check.
    task automatic test_dcache();
        logic [31:0] a0, a0b, a2, a3;
        begin
            prog_reset();
            a0  = MEM_BASE + 32'h0000_1000;
            a0b = a0 + 32'(DCACHE_NUM_SETS * LINE_BYTES);   // same set, other tag
            a2  = a0 + 32'd4;
            a3  = a0 + 32'd8;

            add_store(OP_SW, a2,  32'h1111_2222);   // cold store miss -> overlay
            add_load (OP_LW, a2);                   // install -> 0x11112222
            add_store(OP_SW, a3,  32'h3333_4444);   // store hit -> pending write
            add_load (OP_LW, a3);                   // hit -> 0x33334444
            add_load (OP_LW, a0);                   // same line, MSHR/hit path
            add_store(OP_SW, a0b, 32'h5555_6666);   // dirty victim -> WB entry
            add_load (OP_LW, a0b);                  // refill after writeback
            add_load (OP_LW, a0);                   // original line still readable

            c_kill_enable = 1'b0;
            run_until_retired(20000);
            run_idle(200);
            chk(store_credit == 4'd8, "dcache: SQ did not drain back to empty");
            chk(load_credit == 3'd4, "dcache: LQ did not drain back to empty");
        end
    endtask

    // After the run every dirty line must leave the write-back cache before the
    // physical image can be compared with the architectural image: read-walk
    // each set twice (both ways) in an untouched region, so every resident dirty
    // line is evicted (and written back) and the walk lines end up clean.
    task automatic drain_cache();
        begin
            // Four read misses per Set in an untouched region (same Set = same
            // addr[11:5], different tag needs bit12+; k*0x1000 walks four tags).
            // Four allocations per Set always displace both previous occupants
            // (2-way), so every dirty line leaves the cache and is written back;
            // the walk lines themselves end up clean.
            for (int unsigned s = 0; s < DCACHE_NUM_SETS; s++) begin
                for (int unsigned k = 0; k < 4; k++) begin
                    add_load(OP_LW, MEM_BASE + 32'h0000_4000 + 32'(k * 32'h1000)
                                  + 32'(s * LINE_BYTES));
                end
            end
            c_kill_enable = 1'b0;
            run_until_retired(400000);
            run_idle(400);
        end
    endtask

    //-------------------------------------------------------------------------
    // Main sequence
    //-------------------------------------------------------------------------
    initial begin
        // quiet start
        issue_valid = 1'b0; issue_req = '0; kill_mask = 16'd0;
        store_commit_valid = 2'd0; store_commit_tag[0] = '0; store_commit_tag[1] = '0;
        commit_fire = 2'd0; load_head_valid = 1'b0; load_head_tag = '0;

        for (int unsigned b = 0; b < BEATS; b++) begin
            mem[b]  = 128'd0;
            arch[b] = 128'd0;
        end
        for (int unsigned b = 0; b < 1024; b++) dev[b] = 8'd0;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        #1;
        test_reset();
        rst = 1'b0;
        @(posedge clk); #1;

        test_forwarding();
        test_stale_agu();   // pokes memory: must run before the cache gets dirty
        test_kill();
        test_mmio();
        test_dcache();
        test_random();
        drain_cache();

        //---------------------------------------------------------------------
        // Final image check: every committed store reached memory, and no
        // killed store ever did.
        //---------------------------------------------------------------------
        begin
            int unsigned mismatches;
            mismatches = 0;
            for (int unsigned b = 0; b < BEATS; b++)
                if (mem[b] !== arch[b]) begin
                    if (mismatches < 4)
                        $display("IMAGE MISMATCH beat=%0d addr=%08x mem=%032x arch=%032x | CACHE set=%0d way0 tag=%05x v=%b d=%b way1 tag=%05x v=%b d=%b | WB st=%0d/%0d",
                             b, {16'h8010, b[15:0], 4'b0}, mem[b], arch[b], b[11:5],
                             dut.u_dcache.u_arrays.g_way[0].tag_mem[b[11:5]],
                             dut.u_dcache.u_arrays.g_way[0].line_valid_mem[b[11:5]],
                             dut.u_dcache.u_arrays.g_way[0].dirty_mem[b[11:5]],
                             dut.u_dcache.u_arrays.g_way[1].tag_mem[b[11:5]],
                             dut.u_dcache.u_arrays.g_way[1].line_valid_mem[b[11:5]],
                             dut.u_dcache.u_arrays.g_way[1].dirty_mem[b[11:5]],
                             dut.u_wb.state_q[0], dut.u_wb.state_q[1]);
                    mismatches = mismatches + 1;
                end
            chk(mismatches == 0, "physical memory image differs from the architectural image");
            $display("tb_lsu: completion events=%0d kills=%0d cycles=%0d mismatched beats=%0d",
                     n_completions, n_kills, cycle_count, mismatches);
        end

        if (errors != 0)
            $fatal(1, "tb_lsu: %0d of %0d checks FAILED", errors, checks);

        $display("ALL TESTS PASSED: %0d checks - lsu_top M2a closed loop (exactly-once completions, forwarding/merge/extension for all load sizes, 2-wide store commit + drain, kill suffix suppression, stale-AGU reallocation hazard, MMIO store/load and lsu_mmio_order_idle, final memory image)", checks);
        $finish;
    end

    // Watchdog: never let a deadlock look like a pass.
    initial begin
        #20_000_000;
        $fatal(1, "tb_lsu: watchdog timeout");
    end

`ifdef CONFIG_SIMULATION
    // lsu_mmio_order_idle low while a device transaction is outstanding.
    always_ff @(posedge clk) begin
        if (rst) mmio_saw_busy <= 1'b0;
        else if (!lsu_mmio_order_idle) mmio_saw_busy <= 1'b1;
    end
`endif

endmodule
