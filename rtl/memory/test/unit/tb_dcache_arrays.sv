`timescale 1ns/1ps
//=============================================================================
// ARES LSU - self-checking unit bench for the L07 DCache arrays
//-----------------------------------------------------------------------------
// DUT : rtl/memory/dcache_arrays.sv (per-Way 1R1W Row Data RAM + Tag / Valid /
//       Dirty metadata + per-Set LRU).
// Spec: docs/microarch/memory.md 6.1 (geometry, 1R1W per Way, separate
//       metadata, 1-bit LRU) and 6.3 (RAM ports, reset of the directory only);
//       rtl/memory/LSU_INTERFACES.md section 9 (frozen interface) and section 8
//       (verification requirements).
// FREE items: FREE-10 (verification environment internal structure).
//
// Structure (independent top, own clock/reset, no DPI, no harness):
//   * an INDEPENDENT reference array model (row data, tag, line_valid, dirty
//     per Way / Set and the LRU bit per Set) that is updated on the same edge
//     as the DUT,
//   * a registered golden comparator: every read request records the expected
//     one-cycle-later response from the reference arrays (pre-edge content) and
//     the next cycle compares the whole response bus (valid/set/row/data/tag/
//     line_valid/dirty),
//   * directed phases: reset, full write-then-read, partial byte enables, two
//     Way independence (same Set/Row in the same cycle, cross-Way parallel
//     read and write), metadata field enables, LRU write/read,
//     reset-preserves-Data/Tag,
//   * a fixed-seed randomised phase (RAND_CYCLES cycles) driving every port
//     with the reference model comparison on every cycle.  A same-Way same-Row
//     read/write couple is never generated: memory.md 6.3 forbids it (the L06
//     hazard check must prevent it).
//
// Build / run (repository root, LINE_BYTES = 32 by default; the bench is also
// compiled with -DCONFIG_LINE_BYTES=16 / 64):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     --top-module tb_dcache_arrays --Mdir sim/build/unit/tb_dcache_arrays \
//     -o tb_dcache_arrays rtl/common/ares_pkg.sv rtl/memory/dcache_arrays.sv \
//     rtl/memory/test/unit/tb_dcache_arrays.sv
//   sim/build/unit/tb_dcache_arrays/tb_dcache_arrays
//   (-o is resolved against --Mdir by Verilator 5.x, so the output name must be
//    given relative to the Mdir.)
//=============================================================================
module tb_dcache_arrays;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Geometry / configuration
    //-------------------------------------------------------------------------
    localparam int unsigned NUM_WAYS    = DCACHE_NUM_WAYS;
    localparam int unsigned NUM_SETS    = DCACHE_NUM_SETS;
    localparam int unsigned INDEX_BITS  = DCACHE_INDEX_BITS;
    localparam int unsigned TAG_BITS    = DCACHE_TAG_BITS;
    localparam int unsigned ROWS        = ROWS_PER_LINE;
    localparam int unsigned ROW_BITS    = $clog2(ROWS);
    localparam int unsigned WAY_BITS    = $clog2(NUM_WAYS);
    localparam int unsigned RAND_CYCLES = 6000;
    localparam int unsigned RNG_SEED    = 32'hD0C0_1234;

    //-------------------------------------------------------------------------
    // Clock / reset
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    localparam int unsigned WATCHDOG_CYCLES = 400000;
    initial begin
        repeat (WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1, "TB FAILED: watchdog timeout after %0d cycles", WATCHDOG_CYCLES);
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic [NUM_WAYS-1:0]                               rd_valid;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0]               rd_set;
    logic [NUM_WAYS-1:0][ROW_BITS-1:0]                 rd_row;
    logic [NUM_WAYS-1:0]                               rd_rsp_valid;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0]               rd_rsp_set;
    logic [NUM_WAYS-1:0][ROW_BITS-1:0]                 rd_rsp_row;
    logic [NUM_WAYS-1:0][63:0]                         rd_rsp_data;
    logic [NUM_WAYS-1:0][TAG_BITS-1:0]                 rd_rsp_tag;
    logic [NUM_WAYS-1:0]                               rd_rsp_line_valid;
    logic [NUM_WAYS-1:0]                               rd_rsp_dirty;
    logic [NUM_WAYS-1:0]                               wr_valid;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0]               wr_set;
    logic [NUM_WAYS-1:0][ROW_BITS-1:0]                 wr_row;
    logic [NUM_WAYS-1:0][63:0]                         wr_data;
    logic [NUM_WAYS-1:0][7:0]                          wr_be;
    logic [NUM_WAYS-1:0]                               meta_valid;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0]               meta_set;
    logic [NUM_WAYS-1:0][TAG_BITS-1:0]                 meta_tag;
    logic [NUM_WAYS-1:0]                               meta_tag_en;
    logic [NUM_WAYS-1:0]                               meta_line_valid_en;
    logic [NUM_WAYS-1:0]                               meta_line_valid;
    logic [NUM_WAYS-1:0]                               meta_dirty_en;
    logic [NUM_WAYS-1:0]                               meta_dirty;
    logic                                              lru_valid;
    logic [INDEX_BITS-1:0]                             lru_set;
    logic                                              lru_way;
    logic [INDEX_BITS-1:0]                             lru_rd_set;
    logic                                              lru_rd_last_way;

    dcache_arrays dut (.*);

    //=========================================================================
    // Independent reference storage model
    //=========================================================================
    logic [63:0]         m_data  [NUM_WAYS][NUM_SETS][ROWS];
    logic [TAG_BITS-1:0] m_tag   [NUM_WAYS][NUM_SETS];
    logic                m_lv    [NUM_WAYS][NUM_SETS];
    logic                m_dirty [NUM_WAYS][NUM_SETS];
    logic                m_lru   [NUM_SETS];

    // Data pattern used by the directed phases (never 0 for a written row).
    function automatic logic [63:0] pat_row(input logic [WAY_BITS-1:0] way,
                                            input logic [INDEX_BITS-1:0] set_i,
                                            input logic [ROW_BITS-1:0] row);
        logic [63:0] x;
        begin
            x = 64'hA5A5_5A5A_0000_0000 + (64'(way) << 40) + (64'(set_i) << 16)
                + 64'(row);
            pat_row = x ^ 64'h1234_5678_9ABC_DEF0;
        end
    endfunction

    function automatic logic [TAG_BITS-1:0] pat_tag(input logic [WAY_BITS-1:0] way,
                                                    input logic [INDEX_BITS-1:0] set_i);
        pat_tag = TAG_BITS'((set_i * 32'd37) + (way * 32'd131) + 32'd7);
    endfunction

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

    // drv(): just after a rising edge - new stimulus is applied here.
    // smp(): mid-cycle - the values the next rising edge will sample.
    task automatic drv(); @(posedge clk); #1; endtask
    task automatic smp(); @(negedge clk); #2; endtask

    task automatic idle_inputs();
        begin
            rd_valid          = '0;
            wr_valid          = '0;
            meta_valid        = '0;
            meta_tag_en       = '0;
            meta_line_valid_en= '0;
            meta_dirty_en     = '0;
            lru_valid         = 1'b0;
            rd_set            = '0;
            rd_row            = '0;
            wr_set            = '0;
            wr_row            = '0;
            wr_data           = '0;
            wr_be             = '0;
            meta_set          = '0;
            meta_tag          = '0;
            meta_line_valid   = '0;
            meta_dirty        = '0;
            lru_set           = '0;
            lru_way           = 1'b0;
            lru_rd_set        = '0;
        end
    endtask

    // Reset and mirror the DUT reset in the model: only line_valid / dirty /
    // LRU are cleared, the Data and Tag arrays survive (SPEC-D9).
    task automatic do_reset();
        begin
            idle_inputs();
            rst = 1'b1;
            repeat (3) drv();
            for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                for (int unsigned s = 0; s < NUM_SETS; s++) begin
                    m_lv[w][s]    = 1'b0;
                    m_dirty[w][s] = 1'b0;
                end
            end
            for (int unsigned s = 0; s < NUM_SETS; s++) m_lru[s] = 1'b0;
            rst = 1'b0;
            drv();
            chk(rd_rsp_valid == '0, "reset: rd_rsp_valid must be 0");
            chk(lru_rd_last_way == 1'b0, "reset: lru_rd_last_way must be 0");
        end
    endtask

    // One-cycle Row write on one Way (the model applies enabled bytes only).
    task automatic wr_row_op(input logic [WAY_BITS-1:0] way,
                             input logic [INDEX_BITS-1:0] set_i,
                             input logic [ROW_BITS-1:0] row,
                             input logic [63:0] data,
                             input logic [7:0] be);
        begin
            wr_valid[way] = 1'b1;
            wr_set[way]   = set_i;
            wr_row[way]   = row;
            wr_data[way]  = data;
            wr_be[way]    = be;
            for (int unsigned b = 0; b < 8; b++)
                if (be[b]) m_data[way][set_i][row][8*b +: 8] = data[8*b +: 8];
            drv();
            wr_valid[way] = 1'b0;
            wr_be[way]    = 8'h00;
        end
    endtask

    // One-cycle metadata write on one Way with independent field enables.
    task automatic meta_wr_op(input logic [WAY_BITS-1:0] way,
                              input logic [INDEX_BITS-1:0] set_i,
                              input logic tag_en, input logic [TAG_BITS-1:0] tag,
                              input logic lv_en, input logic lv,
                              input logic dirty_en, input logic dirty);
        begin
            meta_valid[way]         = 1'b1;
            meta_set[way]           = set_i;
            meta_tag[way]           = tag;
            meta_tag_en[way]        = tag_en;
            meta_line_valid[way]    = lv;
            meta_line_valid_en[way] = lv_en;
            meta_dirty[way]         = dirty;
            meta_dirty_en[way]      = dirty_en;
            if (tag_en)   m_tag[way][set_i]   = tag;
            if (lv_en)    m_lv[way][set_i]    = lv;
            if (dirty_en) m_dirty[way][set_i] = dirty;
            drv();
            meta_valid[way]         = 1'b0;
            meta_tag_en[way]        = 1'b0;
            meta_line_valid_en[way] = 1'b0;
            meta_dirty_en[way]      = 1'b0;
        end
    endtask

    // One-cycle LRU write.
    task automatic lru_wr_op(input logic [INDEX_BITS-1:0] set_i, input logic way);
        begin
            lru_valid = 1'b1;
            lru_set   = set_i;
            lru_way   = way;
            m_lru[set_i] = way;
            drv();
            lru_valid = 1'b0;
        end
    endtask

    // Read one Way / Set / Row and compare the complete response against the
    // reference arrays captured before the request edge.
    task automatic rd_op(input logic [WAY_BITS-1:0] way,
                         input logic [INDEX_BITS-1:0] set_i,
                         input logic [ROW_BITS-1:0] row);
        logic [63:0]         e_data;
        logic [TAG_BITS-1:0] e_tag;
        logic                e_lv;
        logic                e_dirty;
        begin
            e_data  = m_data[way][set_i][row];
            e_tag   = m_tag[way][set_i];
            e_lv    = m_lv[way][set_i];
            e_dirty = m_dirty[way][set_i];

            rd_set[way]   = set_i;
            rd_row[way]   = row;
            rd_valid[way] = 1'b1;
            // the response is registered: in the request cycle it must still be
            // the previous cycle's value (0 for every caller of this task)
            chk(!rd_rsp_valid[way], "read response raised in the request cycle");
            drv();
            rd_valid[way] = 1'b0;
            smp();
            chk(rd_rsp_valid[way], "read response missing one cycle after the request");
            chk(rd_rsp_set[way]        == set_i, "rd_rsp_set mismatch");
            chk(rd_rsp_row[way]        == row,   "rd_rsp_row mismatch");
            chk(rd_rsp_data[way]       == e_data, "rd_rsp_data mismatch");
            chk(rd_rsp_tag[way]        == e_tag,  "rd_rsp_tag mismatch");
            chk(rd_rsp_line_valid[way] == e_lv,   "rd_rsp_line_valid mismatch");
            chk(rd_rsp_dirty[way]      == e_dirty, "rd_rsp_dirty mismatch");
            drv();
            smp();
            chk(!rd_rsp_valid[way], "read response lasted more than one cycle");
        end
    endtask

    //=========================================================================
    // Randomised phase
    //=========================================================================
    logic [NUM_WAYS-1:0]                 e_v;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0] e_set;
    logic [NUM_WAYS-1:0][ROW_BITS-1:0]   e_row;
    logic [NUM_WAYS-1:0][63:0]           e_data;
    logic [NUM_WAYS-1:0][TAG_BITS-1:0]   e_tag;
    logic [NUM_WAYS-1:0]                 e_lv;
    logic [NUM_WAYS-1:0]                 e_dirty;

    int unsigned n_rd, n_wr, n_wr_part, n_meta, n_lru;

    task automatic gen_random_inputs();
        logic [INDEX_BITS-1:0] s_a, s_b;
        logic [ROW_BITS-1:0]   r_a, r_b;
        logic [7:0]            be;
        int unsigned           m;
        begin
            idle_inputs();
            for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                s_a = INDEX_BITS'($urandom_range(0, NUM_SETS - 1));
                r_a = ROW_BITS'($urandom_range(0, ROWS - 1));
                s_b = INDEX_BITS'($urandom_range(0, NUM_SETS - 1));
                r_b = ROW_BITS'($urandom_range(0, ROWS - 1));

                rd_valid[w] = ($urandom_range(0, 1) == 0);
                rd_set[w]   = s_a;
                rd_row[w]   = r_a;

                wr_valid[w] = ($urandom_range(0, 1) == 0);
                wr_set[w]   = s_b;
                wr_row[w]   = r_b;
                wr_data[w]  = {$urandom, $urandom};
                be          = 8'($urandom);
                if (be == 8'h00) be = 8'h01 << $urandom_range(0, 7);
                wr_be[w]    = be;

                // memory.md 6.3 forbids a read and a write of the same Way /
                // Set / Row in the same cycle: never generate it.
                if (wr_valid[w] && rd_valid[w] && (wr_set[w] == rd_set[w])
                    && (wr_row[w] == rd_row[w])) begin
                    if ($urandom_range(0, 1) == 0) wr_valid[w] = 1'b0;
                    else                           rd_valid[w] = 1'b0;
                end

                meta_valid[w]         = ($urandom_range(0, 3) == 0);
                meta_set[w]           = s_a;
                meta_tag[w]           = TAG_BITS'($urandom);
                meta_line_valid[w]    = ($urandom_range(0, 1) == 1);
                meta_dirty[w]         = ($urandom_range(0, 1) == 1);
                m                     = $urandom_range(0, 6);
                meta_tag_en[w]        = meta_valid[w] && ((m == 0) || (m == 3) || (m >= 5));
                meta_line_valid_en[w] = meta_valid[w] && ((m == 1) || (m == 3) || (m == 4) || (m >= 5));
                meta_dirty_en[w]      = meta_valid[w] && ((m == 2) || (m == 3) || (m == 4));
                if (meta_valid[w] && !meta_tag_en[w] && !meta_line_valid_en[w]
                    && !meta_dirty_en[w])
                    meta_tag_en[w] = 1'b1;   // a meta request must enable one field
            end

            lru_valid  = ($urandom_range(0, 1) == 0);
            lru_set    = INDEX_BITS'($urandom_range(0, NUM_SETS - 1));
            lru_way    = ($urandom_range(0, 1) == 1);
            lru_rd_set = INDEX_BITS'($urandom_range(0, NUM_SETS - 1));
        end
    endtask

    //=========================================================================
    // Test program
    //=========================================================================
    int unsigned rand_cycles;

    initial begin
        logic [63:0]                 keep_data;
        logic [TAG_BITS-1:0]         keep_tag;
        logic [7:0]                  be_pat [8];
        logic [WAY_BITS-1:0]         way;
        logic [INDEX_BITS-1:0]       set_i;
        logic [ROW_BITS-1:0]         row;

        idle_inputs();
        checks = 0;
        errors = 0;
        rand_cycles = 0;
        n_rd = 0; n_wr = 0; n_wr_part = 0; n_meta = 0; n_lru = 0;
        e_v = '0;
        void'($urandom(RNG_SEED));

        $display("== tb_dcache_arrays: NUM_WAYS=%0d NUM_SETS=%0d ROWS=%0d TAG_BITS=%0d LINE_BYTES=%0d ==",
                 NUM_WAYS, NUM_SETS, ROWS, TAG_BITS, LINE_BYTES);

        //---- 0. geometry + reset --------------------------------------------
        chk(NUM_WAYS == 2, "NUM_WAYS must be 2");
        chk(NUM_SETS == DCACHE_SIZE_BYTES / (NUM_WAYS * LINE_BYTES), "NUM_SETS geometry");
        chk((LINE_BYTES == 16) || (LINE_BYTES == 32) || (LINE_BYTES == 64),
            "LINE_BYTES must be 16/32/64");
        do_reset();
        $display("[%0t] marker: reset ok", $time);

        //---- 1. write every Row of every Way, then read it back ------------
        for (int unsigned s = 0; s < NUM_SETS; s++) begin
            for (int unsigned r = 0; r < ROWS; r++) begin
                wr_valid = '1;
                for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                    wr_set[w]  = INDEX_BITS'(s);
                    wr_row[w]  = ROW_BITS'(r);
                    wr_data[w] = pat_row(WAY_BITS'(w), INDEX_BITS'(s), ROW_BITS'(r));
                    wr_be[w]   = 8'hFF;
                    for (int unsigned b = 0; b < 8; b++)
                        m_data[w][s][r][8*b +: 8] =
                            pat_row(WAY_BITS'(w), INDEX_BITS'(s), ROW_BITS'(r))[8*b +: 8];
                end
                if (r == 0) begin
                    // metadata write in the same cycle as a Row write
                    meta_valid = '1;
                    for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                        meta_set[w]           = INDEX_BITS'(s);
                        meta_tag[w]           = pat_tag(WAY_BITS'(w), INDEX_BITS'(s));
                        meta_tag_en[w]        = 1'b1;
                        meta_line_valid[w]    = (w == 0);
                        meta_line_valid_en[w] = 1'b1;
                        meta_dirty[w]         = (((s + w) % 2) != 0);
                        meta_dirty_en[w]      = 1'b1;
                        m_tag[w][s]   = pat_tag(WAY_BITS'(w), INDEX_BITS'(s));
                        m_lv[w][s]    = (w == 0);
                        m_dirty[w][s] = (((s + w) % 2) != 0);
                    end
                end
                drv();
                wr_valid           = '0;
                meta_valid         = '0;
                meta_tag_en        = '0;
                meta_line_valid_en = '0;
                meta_dirty_en      = '0;
                n_wr = n_wr + NUM_WAYS;
            end
        end
        for (int unsigned s = 0; s < NUM_SETS; s++)
            for (int unsigned r = 0; r < ROWS; r++)
                for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                    rd_op(WAY_BITS'(w), INDEX_BITS'(s), ROW_BITS'(r));
                    n_rd = n_rd + 1;
                end
        $display("[%0t] marker: full write-then-read ok (%0d rows)", $time,
                 NUM_SETS * ROWS * NUM_WAYS);

        //---- 2. partial byte enables ---------------------------------------
        be_pat[0] = 8'h01; be_pat[1] = 8'h80; be_pat[2] = 8'hF0; be_pat[3] = 8'h0F;
        be_pat[4] = 8'hAA; be_pat[5] = 8'h55; be_pat[6] = 8'hC3; be_pat[7] = 8'h3C;
        for (int unsigned k = 0; k < 16; k++) begin
            way   = WAY_BITS'(k % NUM_WAYS);
            set_i = INDEX_BITS'((k * 37) % NUM_SETS);
            row   = ROW_BITS'((k * 5) % ROWS);
            wr_row_op(way, set_i, row, {32'hFEDC_BA98, 32'h7654_3210} ^ 64'(k),
                      be_pat[k % 8]);
            n_wr_part = n_wr_part + 1;
            rd_op(way, set_i, row);
            n_rd = n_rd + 1;
        end
        $display("[%0t] marker: partial byte enables ok", $time);

        //---- 3. two Way independence ---------------------------------------
        // same Set / Row in both Ways in the same cycle
        set_i = INDEX_BITS'(5);
        row   = ROW_BITS'(0);
        wr_valid = '1;
        for (int unsigned w = 0; w < NUM_WAYS; w++) begin
            wr_set[w]  = set_i;
            wr_row[w]  = row;
            wr_data[w] = pat_row(WAY_BITS'(w), set_i, row) ^ 64'hFFFF_0000_FFFF_0000;
            wr_be[w]   = 8'hFF;
            for (int unsigned b = 0; b < 8; b++)
                m_data[w][set_i][row][8*b +: 8] = wr_data[w][8*b +: 8];
        end
        drv();
        wr_valid = '0;
        rd_op(WAY_BITS'(0), set_i, row);  n_rd = n_rd + 1;
        rd_op(WAY_BITS'(1), set_i, row);  n_rd = n_rd + 1;
        chk(m_data[0][set_i][row] != m_data[1][set_i][row],
            "two Way independence: both Ways must keep different data");

        // read Way 0 while writing Way 1 in the same cycle (different Ways may
        // operate in parallel, memory.md 6.3)
        set_i = INDEX_BITS'(9);
        row   = ROW_BITS'(ROWS - 1);
        rd_set[0]   = set_i;
        rd_row[0]   = row;
        rd_valid[0] = 1'b1;
        keep_data   = m_data[0][set_i][row];
        wr_valid[1] = 1'b1;
        wr_set[1]   = set_i;
        wr_row[1]   = row;
        wr_data[1]  = 64'h0123_4567_89AB_CDEF;
        wr_be[1]    = 8'hFF;
        for (int unsigned b = 0; b < 8; b++)
            m_data[1][set_i][row][8*b +: 8] = wr_data[1][8*b +: 8];
        chk(!rd_rsp_valid[0], "parallel rd/wr: response before the request edge");
        drv();
        rd_valid[0] = 1'b0;
        wr_valid[1] = 1'b0;
        smp();
        chk(rd_rsp_valid[0] && (rd_rsp_data[0] == keep_data),
            "parallel rd/wr: Way 0 read must be unaffected by the Way 1 write");
        chk(!rd_rsp_valid[1], "parallel rd/wr: Way 1 must not produce a response");
        drv();
        smp();
        chk(!rd_rsp_valid[0], "parallel rd/wr: response not a single cycle");
        rd_op(WAY_BITS'(1), set_i, row);  n_rd = n_rd + 1;
        $display("[%0t] marker: two Way independence ok", $time);

        //---- 4. metadata field enables + LRU --------------------------------
        set_i = INDEX_BITS'(77 % NUM_SETS);
        meta_wr_op(WAY_BITS'(0), set_i, 1'b1, pat_tag(WAY_BITS'(0), set_i),
                   1'b0, 1'b1, 1'b0, 1'b1);
        rd_op(WAY_BITS'(0), set_i, ROW_BITS'(0));  n_rd = n_rd + 1;
        meta_wr_op(WAY_BITS'(0), set_i, 1'b0, pat_tag(WAY_BITS'(0), set_i),
                   1'b1, 1'b1, 1'b0, 1'b0);
        rd_op(WAY_BITS'(0), set_i, ROW_BITS'(1 % ROWS));  n_rd = n_rd + 1;
        meta_wr_op(WAY_BITS'(0), set_i, 1'b0, pat_tag(WAY_BITS'(0), set_i),
                   1'b0, 1'b0, 1'b1, 1'b1);
        rd_op(WAY_BITS'(0), set_i, ROW_BITS'(2 % ROWS));  n_rd = n_rd + 1;
        meta_wr_op(WAY_BITS'(1), set_i, 1'b1, pat_tag(WAY_BITS'(1), set_i),
                   1'b1, 1'b0, 1'b1, 1'b0);
        rd_op(WAY_BITS'(1), set_i, ROW_BITS'(3 % ROWS));  n_rd = n_rd + 1;
        n_meta = n_meta + 4;

        // LRU: write several Sets, verify the combinational read of the whole
        // bank.
        for (int unsigned k = 0; k < 8; k++) begin
            set_i = INDEX_BITS'((k * 11) % NUM_SETS);
            lru_wr_op(set_i, k[0]);
            n_lru = n_lru + 1;
        end
        for (int unsigned k = 0; k < 8; k++) begin
            set_i      = INDEX_BITS'((k * 11) % NUM_SETS);
            lru_rd_set = set_i;
            smp();
            chk(lru_rd_last_way == m_lru[set_i], "LRU read mismatch after write");
            drv();
        end
        // same-cycle LRU write + read: the combinational read returns the
        // pre-edge value (the write takes effect at the edge)
        set_i = INDEX_BITS'(3);
        lru_valid  = 1'b1;
        lru_set    = set_i;
        lru_way    = 1'b1;
        lru_rd_set = set_i;
        #1;   // settle: lru_rd_last_way must reflect the new lru_rd_set
        chk(m_lru[set_i] == 1'b0, "LRU same-cycle test setup: Set must start at 0");
        chk(lru_rd_last_way == 1'b0, "LRU read must be the pre-edge value while writing");
        drv();
        lru_valid = 1'b0;
        m_lru[set_i] = 1'b1;
        smp();
        chk(lru_rd_last_way == 1'b1, "LRU write did not take effect at the edge");
        drv();
        n_lru = n_lru + 1;
        $display("[%0t] marker: metadata / LRU ok", $time);

        //---- 5. reset preserves Data / Tag, clears valid / dirty / LRU ------
        set_i = INDEX_BITS'(11);
        row   = ROW_BITS'(0);
        keep_data = m_data[0][set_i][row];
        keep_tag  = m_tag[0][set_i];
        do_reset();
        lru_rd_set = set_i;
        smp();
        chk(lru_rd_last_way == 1'b0, "reset must clear the LRU bits");
        drv();
        rd_op(WAY_BITS'(0), set_i, row);  n_rd = n_rd + 1;
        chk(rd_rsp_data[0] == keep_data, "reset must NOT clear the Data array");
        chk(rd_rsp_tag[0] == keep_tag,   "reset must NOT clear the Tag array");
        chk(rd_rsp_line_valid[0] == 1'b0, "reset must clear line_valid");
        chk(rd_rsp_dirty[0] == 1'b0,      "reset must clear dirty");
        $display("[%0t] marker: reset semantics ok", $time);

        //---- 6. randomised phase -------------------------------------------
        $display("-- randomised phase: %0d cycles --", RAND_CYCLES);
        gen_random_inputs();
        #1;   // let the combinational LRU read settle after the stimulus change
        for (int unsigned c = 0; c < RAND_CYCLES; c++) begin
            // (a) compare the response registered one cycle ago
            for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                chk(rd_rsp_valid[w] == e_v[w], "random: rd_rsp_valid != delayed rd_valid");
                if (e_v[w]) begin
                    chk(rd_rsp_set[w]        == e_set[w],   "random: rd_rsp_set mismatch");
                    chk(rd_rsp_row[w]        == e_row[w],   "random: rd_rsp_row mismatch");
                    chk(rd_rsp_data[w]       == e_data[w],  "random: rd_rsp_data mismatch");
                    chk(rd_rsp_tag[w]        == e_tag[w],   "random: rd_rsp_tag mismatch");
                    chk(rd_rsp_line_valid[w] == e_lv[w],    "random: rd_rsp_line_valid mismatch");
                    chk(rd_rsp_dirty[w]      == e_dirty[w], "random: rd_rsp_dirty mismatch");
                    n_rd = n_rd + 1;
                end
            end
            // (b) combinational LRU read against the pre-edge model
            chk(lru_rd_last_way == m_lru[lru_rd_set],
                $sformatf("random: LRU read mismatch (dut=%b model=%b rd_set=%0d)",
                          lru_rd_last_way, m_lru[lru_rd_set], lru_rd_set));

            // (c) expected response for the next cycle (pre-edge array state)
            for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                e_v[w]     = rd_valid[w];
                e_set[w]   = rd_set[w];
                e_row[w]   = rd_row[w];
                e_data[w]  = m_data[w][rd_set[w]][rd_row[w]];
                e_tag[w]   = m_tag[w][rd_set[w]];
                e_lv[w]    = m_lv[w][rd_set[w]];
                e_dirty[w] = m_dirty[w][rd_set[w]];
            end

            // (d) apply this edge's writes to the model
            for (int unsigned w = 0; w < NUM_WAYS; w++) begin
                if (wr_valid[w]) begin
                    for (int unsigned b = 0; b < 8; b++)
                        if (wr_be[w][b])
                            m_data[w][wr_set[w]][wr_row[w]][8*b +: 8] = wr_data[w][8*b +: 8];
                    n_wr = n_wr + 1;
                    if (wr_be[w] != 8'hFF) n_wr_part = n_wr_part + 1;
                end
                if (meta_valid[w]) begin
                    if (meta_tag_en[w])        m_tag[w][meta_set[w]]   = meta_tag[w];
                    if (meta_line_valid_en[w]) m_lv[w][meta_set[w]]    = meta_line_valid[w];
                    if (meta_dirty_en[w])      m_dirty[w][meta_set[w]] = meta_dirty[w];
                    n_meta = n_meta + 1;
                end
            end
            if (lru_valid) begin
                m_lru[lru_set] = lru_way;
                n_lru = n_lru + 1;
            end

            // (e) cross the edge and drive the next random cycle
            drv();
            gen_random_inputs();
            #1;   // settle the combinational outputs before the next check
            rand_cycles = rand_cycles + 1;
        end

        //---- 7. drain -------------------------------------------------------
        idle_inputs();
        repeat (4) drv();
        chk(rd_rsp_valid == '0, "drain: rd_rsp_valid still set");
        chk(rand_cycles >= 5000, "coverage: at least 5k randomised cycles");
        chk(n_rd > 1000, "coverage: read operations");
        chk(n_wr > 1000, "coverage: write operations");
        chk(n_wr_part > 100, "coverage: partial byte-enable writes");
        chk(n_meta > 500, "coverage: metadata writes");
        chk(n_lru > 500, "coverage: LRU writes");

        $display("-- rd=%0d wr=%0d (partial %0d) meta=%0d lru=%0d random_cycles=%0d checks=%0d --",
                 n_rd, n_wr, n_wr_part, n_meta, n_lru, rand_cycles, checks);
        if (errors != 0)
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        $display("ALL TESTS PASSED: %0d checks - LINE_BYTES=%0d ROWS=%0d: reset (directory only), full write-then-read of every Way/Set/Row, partial byte enables, two Way independence, metadata field enables, LRU write/read, reset preserves Data/Tag, %0d-cycles fixed-seed random against the reference array model",
                 checks, LINE_BYTES, ROWS, rand_cycles);
        $finish;
    end

endmodule
