//=============================================================================
// ARES LSU - self-checking unit TB for L05 store_forward (C2 / M2a)
//-----------------------------------------------------------------------------
// DUT       : rtl/memory/store_forward.sv  (purely combinational, no clk/rst)
// Spec      : docs/microarch/memory.md 4.1 (dep_ready) and 4.2 (older store
//             mask + per-byte "closest older store" forwarding);
//             rtl/memory/LSU_INTERFACES.md section 2 (frozen ports/semantics).
// FREE items: FREE-02 (file organisation: unit TB under rtl/memory/test/unit),
//             FREE-04 (internal combinational structure is free - this TB only
//             checks the byte-selection contract, never the compare style).
//
// Method: the TB drives the DUT combinationally and, for every stimulus, checks
// the complete visible contract against an independent reference model:
//   fwd_mask   exact (case) equality
//   fwd_data   only on the lanes the reference forwards; lanes with fwd_mask=0
//              are architecturally don't-care because the LQ merges only the
//              fwd_mask=1 lanes (lsu_pkg::lsu_merge_extract), so constraining
//              them would over-constrain a legal implementation
//   dep_ready  exact (case) equality
// Case equality is used everywhere, therefore an X on any output is an error.
//
// Reference model (memory.md 4.2 item 2): walk the SQ ring from head to tail
// (oldest -> youngest); a store is a candidate iff
//   older_mask[i] && sq_occupied[i] && !sq_is_mmio[i] && sq_addr_valid[i]
// and it covers byte b of the load word iff
//   sq_byte_mask[i][b] && (sq_addr[i][31:2] == load_addr[31:2]).
// The last (youngest) match wins per byte (memory.md 4.2: the later matching
// store overrides the earlier one).  A byte is only reported when
// load_byte_mask requests it (LSU_INTERFACES section 2: fwd_mask is 0 outside
// load_byte_mask).
//
// Coverage
//   P0  reset / idle ...... clean X-free outputs; rst has no effect (no state);
//                           empty mask -> fwd_mask=0, dep_ready=1
//   P1  single store ...... SB/SH/SW x addr[1:0] x all 8 SQ slots x all 8 head
//                           positions, occupancy=8 (full ring)
//   P1b occupancy window .. head=6, occupancy=5 (slots 6,7,0,1,2): stores
//                           inside forward, a bit outside the window never does
//   P2  partial coverage .. only the covered bytes are reported
//   P3  age order ......... youngest older store wins per byte; ring wrap
//                           (head=6/occupancy=5 and head=7/occupancy=8)
//   P4  filtering ......... mmio / !sq_occupied / !sq_addr_valid never forward
//   P5  word address ...... sq_addr[31:2] != load_addr[31:2] -> no forward
//   P6  older_mask=0 ...... fwd_mask=0, dep_ready=1 (killed/empty older set)
//   P7  dep_ready ......... == "all masked stores have sq_addr_valid"
//   R1  random ............ 20000 fixed-seed samples, all four bytes requested
//   P8  load_byte_mask .... bytes outside load_byte_mask must never be
//                           reported; also exercises the DUT's own
//                           a_only_requested_bytes assertion (must not fire)
//   R2  random ............ 8000 fixed-seed samples, random partial load masks
//
// "Kill priority" / "same-cycle conflict" items of the generic unit checklist
// do not exist for this module (no clock, no kill port, no state).  Their
// analogues are covered by P4 (a store that is no longer forwarding-responsible
// - mmio, released, address not registered - must not forward) plus the mixed
// multi-store cases of P2/P3/P5/R1/R2.
//
// Build / run (repo root, explicit file list, one command per line):
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_store_forward --Mdir sim/build/unit/tb_store_forward -o tb_store_forward rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/store_forward.sv rtl/memory/test/unit/tb_store_forward.sv
//   (note: -o is resolved inside --Mdir, so '-o <name>' yields sim/build/unit/<TB>/<name>; a repo-root-relative -o path fails at link time)
//   $ sim/build/unit/tb_store_forward/tb_store_forward
//
// Lint (repo root):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module store_forward rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/store_forward.sv
//=============================================================================
`timescale 1ns/1ps

module tb_store_forward;
    import ares_pkg::*;
    import lsu_pkg::*;

    localparam int unsigned R1_SAMPLES = 20000;
    localparam int unsigned R2_SAMPLES =  8000;
    localparam int unsigned MAX_SHOWN  =    20;

    //---------------------------------------------------------------------
    // clock / reset (the DUT is combinational; the clock only sequences the
    // reset check - the bench stays a stand-alone unit TB)
    //---------------------------------------------------------------------
    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    //---------------------------------------------------------------------
    // DUT ports (names/widths exactly as frozen in LSU_INTERFACES.md section 2)
    //---------------------------------------------------------------------
    logic [31:0]      load_addr;
    logic [3:0]       load_byte_mask;
    logic [7:0]       older_mask;
    logic [7:0]       sq_occupied;
    logic [7:0]       sq_addr_valid;
    logic [7:0][31:0] sq_addr;
    logic [7:0][31:0] sq_data;
    logic [7:0][3:0]  sq_byte_mask;
    logic [7:0]       sq_is_mmio;
    logic [2:0]       sq_head_ptr;
    logic [3:0]       sq_occupancy;
    logic [3:0]       fwd_mask;
    logic [31:0]      fwd_data;
    logic             dep_ready;

    store_forward dut (.*);

    //---------------------------------------------------------------------
    // scoreboard / RNG
    //---------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;
    int unsigned shown  = 0;
    logic [31:0] rng    = 32'hA5A5_1E37;   // fixed seed (tool independent LCG)

    logic [3:0]  exp_mask_g;
    logic [31:0] exp_data_g;
    logic        exp_ready_g;

    // xorshift32 - deterministic across simulators/tools
    function automatic logic [31:0] rnd();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    function automatic int unsigned rnd_below(input int unsigned n);
        return rnd() % n;
    endfunction

    function automatic logic [1:0] rnd_low2();
        return rnd()[1:0];
    endfunction

    // four word addresses (two pairs sharing a word) + a far one
    function automatic logic [31:0] word_of(input int unsigned i);
        case (i)
            0:       word_of = 32'h0000_1000;
            1:       word_of = 32'h0000_1004;   // same word as index 0
            2:       word_of = 32'h0000_2000;
            default: word_of = 32'hDEAD_B000;
        endcase
    endfunction

    // consecutive occupancy window head..head+occ-1 (mod 8)
    function automatic logic [7:0] occ_window(input logic [2:0] head,
                                              input int unsigned occ);
        logic [7:0] m;
        m = 8'd0;
        for (int unsigned k = 0; k < 8; k++)
            if (k < occ)
                m[(head + 3'(k)) & 3'd7] = 1'b1;
        return m;
    endfunction

    //---------------------------------------------------------------------
    // reference model
    //---------------------------------------------------------------------
    function automatic logic [7:0] ref_eligible();
        logic [7:0] e;
        e = 8'd0;
        for (int unsigned i = 0; i < 8; i++)
            e[i] = older_mask[i] && sq_occupied[i] && !sq_is_mmio[i]
                   && sq_addr_valid[i];
        return e;
    endfunction

    // per-byte reference: hit (and its byte data), oldest -> youngest with
    // last-match-wins, then gated by load_byte_mask
    function automatic logic ref_byte(input int unsigned b,
                                      output logic [7:0] bdata);
        logic [7:0]  elig;
        logic [7:0]  d;
        logic        hit;
        int unsigned occ;
        elig = ref_eligible();
        occ  = {28'b0, sq_occupancy};
        hit  = 1'b0;
        d    = 8'd0;
        for (int unsigned k = 0; k < 8; k++) begin
            logic [2:0] idx;
            idx = (sq_head_ptr + 3'(k)) & 3'd7;
            if ((k < occ) && elig[idx] && sq_byte_mask[idx][b]
                && (sq_addr[idx][31:2] == load_addr[31:2])) begin
                hit = 1'b1;
                d   = sq_data[idx][8*b +: 8];
            end
        end
        bdata = d;
        return hit && load_byte_mask[b];
    endfunction

    //---------------------------------------------------------------------
    // stimulus helpers
    //---------------------------------------------------------------------
    task automatic clear_all();
        load_addr      = 32'd0;
        load_byte_mask = 4'hF;
        older_mask     = 8'd0;
        sq_occupied    = 8'd0;
        sq_addr_valid  = 8'd0;
        sq_is_mmio     = 8'd0;
        sq_head_ptr    = 3'd0;
        sq_occupancy   = 4'd0;
        for (int unsigned i = 0; i < 8; i++) begin
            sq_addr[i]      = 32'd0;
            sq_data[i]      = 32'd0;
            sq_byte_mask[i] = 4'd0;
        end
    endtask

    // place a store in slot i: occupied + older_mask bit set as well
    task automatic put_store(input int unsigned i,
                             input logic [31:0] waddr,
                             input logic [3:0]  bmask,
                             input logic [31:0] data,
                             input logic        mmio,
                             input logic        avalid);
        sq_addr[i]       = waddr;
        sq_byte_mask[i]  = bmask;
        sq_data[i]       = data;
        sq_is_mmio[i]    = mmio;
        sq_addr_valid[i] = avalid;
        sq_occupied[i]   = 1'b1;
        older_mask[i]    = 1'b1;
    endtask

    task automatic print_stim(input string tag);
        $display("    STIM[%s] load_addr=%08x load_byte_mask=%b",
                 tag, load_addr, load_byte_mask);
        $display("         older_mask=%b occupied=%b addr_valid=%b is_mmio=%b head=%0d occupancy=%0d",
                 older_mask, sq_occupied, sq_addr_valid, sq_is_mmio,
                 sq_head_ptr, sq_occupancy);
        $display("         byte_mask=%b %b %b %b %b %b %b %b",
                 sq_byte_mask[0], sq_byte_mask[1], sq_byte_mask[2],
                 sq_byte_mask[3], sq_byte_mask[4], sq_byte_mask[5],
                 sq_byte_mask[6], sq_byte_mask[7]);
        $display("         sq_addr=%08x %08x %08x %08x %08x %08x %08x %08x",
                 sq_addr[0], sq_addr[1], sq_addr[2], sq_addr[3],
                 sq_addr[4], sq_addr[5], sq_addr[6], sq_addr[7]);
        $display("         sq_data=%08x %08x %08x %08x %08x %08x %08x %08x",
                 sq_data[0], sq_data[1], sq_data[2], sq_data[3],
                 sq_data[4], sq_data[5], sq_data[6], sq_data[7]);
    endtask

    // settle the combinational DUT, compare against the reference model
    task automatic check(input string tag);
        int unsigned i;
        logic [7:0]  bd;
        begin
            #1;   // let the combinational DUT settle
            exp_mask_g  = 4'd0;
            exp_data_g  = 32'd0;
            exp_ready_g = (((~older_mask) | sq_addr_valid) == 8'hFF);
            for (i = 0; i < 4; i++) begin
                if (ref_byte(i, bd)) begin
                    exp_mask_g[i]        = 1'b1;
                    exp_data_g[8*i +: 8] = bd;
                end
            end
            checks++;
            if (fwd_mask !== exp_mask_g) begin
                errors++;
                if (shown < MAX_SHOWN) begin
                    shown++;
                    $display("  MISMATCH [%s] fwd_mask=%b expected=%b",
                             tag, fwd_mask, exp_mask_g);
                    print_stim(tag);
                end
            end
            if (dep_ready !== exp_ready_g) begin
                errors++;
                if (shown < MAX_SHOWN) begin
                    shown++;
                    $display("  MISMATCH [%s] dep_ready=%b expected=%b",
                             tag, dep_ready, exp_ready_g);
                    print_stim(tag);
                end
            end
            for (i = 0; i < 4; i++) begin
                if (exp_mask_g[i]
                    && (fwd_data[8*i +: 8] !== exp_data_g[8*i +: 8])) begin
                    errors++;
                    if (shown < MAX_SHOWN) begin
                        shown++;
                        $display("  MISMATCH [%s] fwd_data lane %0d=%02x expected=%02x (fwd_mask=%b exp=%b)",
                                 tag, i, fwd_data[8*i +: 8],
                                 exp_data_g[8*i +: 8], fwd_mask, exp_mask_g);
                        print_stim(tag);
                    end
                end
            end
        end
    endtask

    task automatic phase_report(input string name,
                                input int unsigned c0,
                                input int unsigned e0);
        $display("[%-22s] %6d checks, %0d errors", name, checks - c0, errors - e0);
    endtask

    //---------------------------------------------------------------------
    // directed cases
    //---------------------------------------------------------------------
    // P1: one store, every slot / head / lane / size combination
    task automatic p1_single(input logic [2:0] head,
                             input int unsigned slot,
                             input logic [1:0]  low,
                             input lsu_size_t   size);
        begin
            clear_all();
            sq_occupied  = 8'hFF;          // full ring
            sq_addr_valid= 8'hFF;
            sq_head_ptr  = head;
            sq_occupancy = 4'd8;
            put_store(slot, 32'h0000_1000,
                      lsu_size_mask(low, size),
                      lsu_align_store_data(32'hA5B6_C7D8, low, size),
                      1'b0, 1'b1);
            load_addr      = 32'h0000_1000 | {30'd0, low};
            load_byte_mask = 4'hF;
            check($sformatf("P1/h%0d/s%0d/low%0d", head, slot, low));
        end
    endtask

    //---------------------------------------------------------------------
    // main sequence
    //---------------------------------------------------------------------
    initial begin
        int unsigned c0;
        int unsigned e0;
        int unsigned h;
        int unsigned slot;
        int unsigned i;
        int unsigned lw;
        logic [1:0]  llow;
        logic [7:0]  win;

        $display("tb_store_forward: L05 byte-wise store forwarding unit TB");

        //-----------------------------------------------------------------
        // P0: reset / idle
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        clear_all();
        rst = 1'b1;
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);
        if (rst !== 1'b0)
            $fatal(1, "tb_store_forward: reset did not release");
        clear_all();
        check("P0/idle");                       // empty older set
        rst = 1'b1;                             // no rst port: still functional
        clear_all();
        put_store(0, 32'h0000_1000, 4'hF, 32'hDEAD_BEEF, 1'b0, 1'b1);
        load_addr      = 32'h0000_1000;
        load_byte_mask = 4'hF;
        check("P0/rst-active");
        rst = 1'b0;
        clear_all();                            // garbage SQ, empty mask
        for (i = 0; i < 8; i++) begin
            sq_addr[i]      = 32'h0000_1000;
            sq_data[i]      = 32'hFFFF_FFFF;
            sq_byte_mask[i] = 4'hF;
            sq_addr_valid[i]= 1'b0;
            sq_is_mmio[i]   = 1'b1;
        end
        sq_occupied  = 8'hFF;
        sq_occupancy = 4'd8;
        load_addr      = 32'h0000_1000;
        load_byte_mask = 4'hF;
        check("P0/mask0");
        phase_report("P0 reset/idle", c0, e0);

        //-----------------------------------------------------------------
        // P1: single store, full coverage, SB/SH/SW x addr[1:0]
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        for (h = 0; h < 8; h++)
            for (slot = 0; slot < 8; slot++) begin
                for (i = 0; i < 4; i++)
                    p1_single(h[2:0], slot, i[1:0], LSZ_BYTE);
                p1_single(h[2:0], slot, 2'd0, LSZ_HALF);
                p1_single(h[2:0], slot, 2'd2, LSZ_HALF);
                p1_single(h[2:0], slot, 2'd0, LSZ_WORD);
            end
        phase_report("P1 single/full", c0, e0);

        //-----------------------------------------------------------------
        // P1b: occupancy window (head=6, occupancy=5 -> slots 6,7,0,1,2)
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        win = occ_window(3'd6, 5);
        // oldest / middle / youngest store of the window
        for (slot = 0; slot < 8; slot++) begin
            if (win[slot]) begin
                clear_all();
                sq_occupied   = win;
                sq_addr_valid = 8'hFF;
                sq_head_ptr   = 3'd6;
                sq_occupancy  = 4'd5;
                put_store(slot, 32'h0000_1000, 4'hF, 32'h1122_3344 + slot,
                          1'b0, 1'b1);
                load_addr      = 32'h0000_1000;
                load_byte_mask = 4'hF;
                check($sformatf("P1b/in%0d", slot));
            end
        end
        // a masked+occupied+ready slot outside the occupancy window never
        // forwards (stale mask bit the LQ has not cleared yet)
        clear_all();
        sq_occupied   = win | 8'h08;            // slot 3 occupied but outside
        sq_addr_valid = 8'hFF;
        sq_head_ptr   = 3'd6;
        sq_occupancy  = 4'd5;
        put_store(3, 32'h0000_1000, 4'hF, 32'hDEAD_BEEF, 1'b0, 1'b1);
        load_addr      = 32'h0000_1000;
        load_byte_mask = 4'hF;
        check("P1b/outside-window");
        phase_report("P1b occupancy window", c0, e0);

        //-----------------------------------------------------------------
        // P2: partial byte coverage
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        for (i = 0; i < 5; i++) begin
            clear_all();
            sq_occupied   = 8'hFF;
            sq_addr_valid = 8'hFF;
            sq_occupancy  = 4'd8;
            case (i)
                0: begin // single SH at lane 0
                    put_store(1, 32'h0000_1000, 4'b0011, 32'h0000_BEEF, 1'b0, 1'b1);
                    load_addr = 32'h0000_1000;
                end
                1: begin // single SB at lane 3
                    put_store(1, 32'h0000_1000, 4'b1000, 32'hAB00_0000, 1'b0, 1'b1);
                    load_addr = 32'h0000_1000;
                end
                2: begin // two stores, disjoint bytes: 0100 (older) + 1011
                    put_store(0, 32'h0000_1000, 4'b0100, 32'h0000_FF00, 1'b0, 1'b1);
                    put_store(1, 32'h0000_1000, 4'b1011, 32'h1122_0033, 1'b0, 1'b1);
                    load_addr = 32'h0000_1000;
                end
                3: begin // non-contiguous byte enables
                    put_store(2, 32'h0000_1000, 4'b0101, 32'hAABB_CCDD, 1'b0, 1'b1);
                    load_addr = 32'h0000_1000;
                end
                default: begin // same word, load's own lane differs: the word
                               // address alone decides coverage (memory.md 4.2)
                    put_store(4, 32'h0000_1000, 4'b0001, 32'h0000_00AA, 1'b0, 1'b1);
                    load_addr = 32'h0000_1002;
                end
            endcase
            load_byte_mask = 4'hF;
            check($sformatf("P2/partial%0d", i));
        end
        phase_report("P2 partial coverage", c0, e0);

        //-----------------------------------------------------------------
        // P3: age order, per-byte closest older store, ring wrap
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        // all three slots of the window write all four bytes: youngest wins
        clear_all();
        sq_occupied = occ_window(3'd0, 3); sq_addr_valid = 8'hFF;
        sq_head_ptr = 3'd0; sq_occupancy = 4'd3;
        put_store(0, 32'h0000_1000, 4'hF, 32'h1111_1111, 1'b0, 1'b1);
        put_store(1, 32'h0000_1000, 4'hF, 32'h2222_2222, 1'b0, 1'b1);
        put_store(2, 32'h0000_1000, 4'hF, 32'h3333_3333, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P3/head0-occ3");

        // wrap: head=6, occupancy=5 -> k0..k4 = 6,7,0,1,2 (2 is youngest)
        clear_all();
        sq_occupied = occ_window(3'd6, 5); sq_addr_valid = 8'hFF;
        sq_head_ptr = 3'd6; sq_occupancy = 4'd5;
        put_store(6, 32'h0000_1000, 4'hF, 32'hAAAA_AAAA, 1'b0, 1'b1);
        put_store(7, 32'h0000_1000, 4'hF, 32'hBBBB_BBBB, 1'b0, 1'b1);
        put_store(0, 32'h0000_1000, 4'hF, 32'hCCCC_CCCC, 1'b0, 1'b1);
        put_store(1, 32'h0000_1000, 4'hF, 32'hDDDD_DDDD, 1'b0, 1'b1);
        put_store(2, 32'h0000_1000, 4'hF, 32'hEEEE_EEEE, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P3/wrap-occ5");

        // wrap + per byte: byte0 -> slot 0 (younger than slot 6),
        //                 byte1 -> slot 2
        clear_all();
        sq_occupied = occ_window(3'd6, 5); sq_addr_valid = 8'hFF;
        sq_head_ptr = 3'd6; sq_occupancy = 4'd5;
        put_store(6, 32'h0000_1000, 4'b0001, 32'hAABB_CCDD, 1'b0, 1'b1);
        put_store(0, 32'h0000_1000, 4'b0001, 32'h1122_3344, 1'b0, 1'b1);
        put_store(2, 32'h0000_1000, 4'b0010, 32'h5566_7788, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P3/wrap-perbyte");

        // wrap + younger store covers fewer bytes: byte0 from the younger
        // slot 1, byte1 stays with the older slot 6
        clear_all();
        sq_occupied = occ_window(3'd6, 5); sq_addr_valid = 8'hFF;
        sq_head_ptr = 3'd6; sq_occupancy = 4'd5;
        put_store(6, 32'h0000_1000, 4'b0011, 32'hAAAA_BBBB, 1'b0, 1'b1);
        put_store(1, 32'h0000_1000, 4'b0001, 32'hCCCC_DDDD, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P3/wrap-subset");

        // wrap across the whole ring: head=7, occupancy=8, slot 6 is the
        // youngest (k7) and must beat slot 7 (k0)
        clear_all();
        sq_occupied = occ_window(3'd7, 8); sq_addr_valid = 8'hFF;
        sq_head_ptr = 3'd7; sq_occupancy = 4'd8;
        put_store(7, 32'h0000_1000, 4'hF, 32'h7777_7777, 1'b0, 1'b1);
        put_store(6, 32'h0000_1000, 4'hF, 32'h6666_6666, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P3/head7-full");
        phase_report("P3 age order/wrap", c0, e0);

        //-----------------------------------------------------------------
        // P4: mmio / not occupied / address not registered
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        // mmio store covering the same word must not forward; the older
        // cacheable store still does
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(1, 32'h0000_1000, 4'hF, 32'hCAFE_0001, 1'b0, 1'b1);
        put_store(2, 32'h0000_1000, 4'hF, 32'h0BAD_0002, 1'b1, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/mmio+cacheable");

        // mmio only (address ready) -> nothing forwarded, dep_ready = 1
        clear_all();
        sq_occupied = 8'hFF; sq_occupied[2] = 1'b1;
        sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(2, 32'h0000_1000, 4'hF, 32'h0BAD_0002, 1'b1, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/mmio-only");

        // mmio and address not ready -> dep_ready = 0 as well
        clear_all();
        sq_occupied[2] = 1'b1;
        sq_occupancy = 4'd8;
        put_store(2, 32'h0000_1000, 4'hF, 32'h0BAD_0002, 1'b1, 1'b0);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/mmio-noready");

        // slot released (taken over): mask bit set, address ready, no forward
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(1, 32'h0000_1000, 4'hF, 32'hCAFE_0003, 1'b0, 1'b1);
        sq_occupied[1] = 1'b0;                 // released, mask bit still set
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/not-occupied");

        // released and not ready
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(1, 32'h0000_1000, 4'hF, 32'hCAFE_0004, 1'b0, 1'b1);
        sq_occupied[1] = 1'b0;
        sq_addr_valid[1] = 1'b0;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/not-occupied-noready");

        // address/data not registered yet -> no forward, dep_ready = 0
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(1, 32'h0000_1000, 4'hF, 32'hCAFE_0005, 1'b0, 1'b1);
        sq_addr_valid[1] = 1'b0;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P4/not-registered");
        phase_report("P4 store filtering", c0, e0);

        //-----------------------------------------------------------------
        // P5: word address mismatch (sq_addr[31:2] != load_addr[31:2])
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_2000, 4'hF, 32'h1234_5678, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P5/other-word");

        // adjacent word (0x1000 vs 0x1004) must not alias
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1004, 4'hF, 32'h1234_5678, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P5/next-word");

        // same word, different own lane: address[1:0] is not compared
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'b0001, 32'h0000_00AA, 1'b0, 1'b1);
        load_addr = 32'h0000_1003; load_byte_mask = 4'hF;
        check("P5/same-word-lane");
        phase_report("P5 word address", c0, e0);

        //-----------------------------------------------------------------
        // P6: older_mask = 0 (no older store is still responsible)
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        clear_all();
        sq_occupied  = 8'hFF;
        sq_occupancy = 4'd8;
        for (i = 0; i < 8; i++) begin
            sq_addr[i]      = 32'h0000_1000;
            sq_data[i]      = 32'hDEAD_0000 + i;
            sq_byte_mask[i] = 4'hF;
            sq_addr_valid[i]= (i != 3);          // one not ready: still no dep
            sq_is_mmio[i]   = (i == 5);
        end
        older_mask = 8'd0;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P6/mask0");
        phase_report("P6 older_mask=0", c0, e0);

        //-----------------------------------------------------------------
        // P7: dep_ready = all masked stores have sq_addr_valid
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        // masked and ready -> ready
        clear_all();
        sq_occupied[0] = 1'b1; sq_occupied[1] = 1'b1;
        older_mask = 8'b0000_0011; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/masked-ready");

        // one masked store not ready -> not ready
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_addr_valid[1] = 1'b0;
        older_mask = 8'b0000_0011;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/masked-notready");

        // not-ready bits outside the mask do not matter
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_addr_valid[7] = 1'b0; sq_addr_valid[4] = 1'b0;
        older_mask = 8'b0000_0001;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/outside-mask");

        // full mask, all ready
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        older_mask = 8'hFF;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/full-ready");

        // full mask, one not ready
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_addr_valid[5] = 1'b0;
        older_mask = 8'hFF;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/full-notready");

        // mmio in the mask with a ready address still satisfies dep_ready
        // (frozen formula only looks at sq_addr_valid)
        clear_all();
        sq_occupied[2] = 1'b1; older_mask[2] = 1'b1; sq_addr_valid[2] = 1'b1;
        sq_is_mmio[2]  = 1'b1;
        sq_occupancy = 4'd8;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/mmio-ready");

        // stale mask bit on a released slot does not change the formula
        clear_all();
        sq_occupied[3] = 1'b1; older_mask[3] = 1'b1; sq_addr_valid[3] = 1'b1;
        sq_occupancy = 4'd8;
        sq_occupied[3] = 1'b0;
        load_addr = 32'h0000_1000; load_byte_mask = 4'hF;
        check("P7/stale-ready");
        phase_report("P7 dep_ready", c0, e0);

        //-----------------------------------------------------------------
        // R1: fixed-seed random, all four bytes requested
        //     (random SQ window/occupancy/head, masks, mmio, addr_valid,
        //      older_mask including stale bits, random load word)
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        for (i = 0; i < R1_SAMPLES; i++) begin
            clear_all();
            lw  = rnd_below(9);                 // 0..8: empty .. full
            win = occ_window(rnd_below(8)[2:0], lw);
            sq_head_ptr  = rnd_below(8)[2:0];
            sq_occupancy = lw[3:0];
            sq_occupied  = win;
            for (int unsigned s = 0; s < 8; s++) begin
                if (win[s]) begin
                    llow = rnd_low2();
                    sq_addr[s]       = word_of(rnd_below(4)) | {30'd0, llow};
                    sq_byte_mask[s]  = rnd()[3:0];
                    sq_data[s]       = rnd();
                    sq_is_mmio[s]    = (rnd_below(4) == 0);
                    sq_addr_valid[s] = (rnd_below(8) != 0);
                    older_mask[s]    = (rnd_below(8) != 0);
                end
            end
            // occasionally leave a stale mask bit behind (slot already free)
            if (rnd_below(8) == 0) older_mask[rnd_below(8)[2:0]] = 1'b1;
            llow = rnd_low2();
            load_addr      = word_of(rnd_below(4)) | {30'd0, llow};
            load_byte_mask = 4'hF;
            check("R1/random-full");
        end
        phase_report("R1 random (all bytes)", c0, e0);

        //-----------------------------------------------------------------
        // P8: load_byte_mask restriction
        //     fwd_mask outside load_byte_mask must stay 0 - this also drives
        //     the DUT's own a_only_requested_bytes assertion, which must not
        //     fire (LSU_INTERFACES section 2 / section 8 item 5).
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        $display("[P8] load_byte_mask restriction: fwd_mask outside load_byte_mask must stay 0 (drives the DUT's own a_only_requested_bytes assertion)");
        // SW then LB of the same word: only byte 0 may be reported
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'hF, 32'h4433_2211, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'b0001;
        check("P8/sw-then-lb");

        // SH at lane 2, load byte at lane 3
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'b1100, 32'h8877_0000, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'b1000;
        check("P8/sh-lane2-lb-lane3");

        // no overlap between the store bytes and the requested bytes
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'b0011, 32'h0000_2211, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'b0100;
        check("P8/no-overlap");

        // load requests nothing
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'hF, 32'h4433_2211, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'b0000;
        check("P8/empty-request");

        // partial overlap, two stores: only the requested byte is reported
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(0, 32'h0000_1000, 4'b0011, 32'h0000_2211, 1'b0, 1'b1);
        put_store(1, 32'h0000_1000, 4'b1100, 32'h8877_0000, 1'b0, 1'b1);
        load_addr = 32'h0000_1000; load_byte_mask = 4'b1010;
        check("P8/partial-overlap");

        // unsigned half load after a word store
        clear_all();
        sq_occupied = 8'hFF; sq_addr_valid = 8'hFF;
        sq_occupancy = 4'd8;
        put_store(2, 32'h0000_1000, 4'hF, 32'h4433_2211, 1'b0, 1'b1);
        load_addr = 32'h0000_1002; load_byte_mask = 4'b1100;
        check("P8/word-then-lhu");
        phase_report("P8 load_byte_mask", c0, e0);

        //-----------------------------------------------------------------
        // R2: fixed-seed random with random (partial) load_byte_mask
        //-----------------------------------------------------------------
        c0 = checks; e0 = errors;
        $display("[R2] fixed-seed random, random partial load_byte_mask (%0d samples)", R2_SAMPLES);
        for (i = 0; i < R2_SAMPLES; i++) begin
            clear_all();
            lw  = rnd_below(9);
            win = occ_window(rnd_below(8)[2:0], lw);
            sq_head_ptr  = rnd_below(8)[2:0];
            sq_occupancy = lw[3:0];
            sq_occupied  = win;
            for (int unsigned s = 0; s < 8; s++) begin
                if (win[s]) begin
                    llow = rnd_low2();
                    sq_addr[s]       = word_of(rnd_below(4)) | {30'd0, llow};
                    sq_byte_mask[s]  = rnd()[3:0];
                    sq_data[s]       = rnd();
                    sq_is_mmio[s]    = (rnd_below(4) == 0);
                    sq_addr_valid[s] = (rnd_below(8) != 0);
                    older_mask[s]    = (rnd_below(8) != 0);
                end
            end
            if (rnd_below(8) == 0) older_mask[rnd_below(8)[2:0]] = 1'b1;
            llow = rnd_low2();
            load_addr      = word_of(rnd_below(4)) | {30'd0, llow};
            load_byte_mask = rnd()[3:0];
            check("R2/random-partial");
        end
        phase_report("R2 random (partial lbm)", c0, e0);

        //-----------------------------------------------------------------
        // summary
        //-----------------------------------------------------------------
        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - reset/idle clean, SB/SH/SW x addr[1:0] x 8 slots x 8 heads, partial byte coverage, ring wrap (head=6/occ=5, head=7/occ=8) youngest-wins, mmio/released/not-registered filtering, word-address filter, older_mask=0, dep_ready formula, load_byte_mask restriction, fixed-seed random %0d+%0d samples 0 mismatch",
                     checks, R1_SAMPLES, R2_SAMPLES);
            $finish;
        end else begin
            $display("TEST FAILED: %0d errors in %0d checks (first %0d mismatches shown above)",
                     errors, checks, shown);
            $fatal(1, "tb_store_forward: %0d mismatches", errors);
        end
    end

endmodule
