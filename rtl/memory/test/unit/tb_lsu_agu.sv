//=============================================================================
// ARES LSU - unit test: lsu_agu (L02)  Input Register + pipelined AGU
//-----------------------------------------------------------------------------
// Standalone self-checking bench (own clock/reset, independent top module, no
// DPI and no harness) for rtl/memory/lsu_agu.sv against LSU_INTERFACES.md
// section 1 and memory.md 3 / 3.1 / 6.2.
//
// Timing convention of the bench
//   All stimulus changes on the FALLING edge, so the DUT always samples a
//   stable value; the check of a registered output also happens on a falling
//   edge, half a cycle after the rising edge that produced it.
//
//     cycle k   : issue_valid/issue_req/issue_qidx/issue_kill driven
//     cycle k+1 : C1 input register + combinational address generation
//     cycle k+2 : registered AGU result, out_valid high for the whole cycle
//
//   A two-deep expectation pipe (pipe[0] = output expected in the current
//   cycle, pipe[1] = output expected in the next one) makes every issue -
//   killed, valid or absent - checked on the exact cycle it must appear, so
//   the idle cycles in between are proven to show out_valid = 0.
//
// Covered
//   * reset: out_valid = 0 during reset and in the first cycles after release
//   * empty pipeline (idle cycles) never produces a spurious out_valid
//   * all 8 Load/Store ops x every naturally aligned addr[1:0] pattern
//     (LB/LBU/SB cover all four low-bit patterns, LH/LHU/SH the even ones,
//     LW/SW the word ones): out_addr, out_size, out_byte_mask, aligned
//     out_store_data, out_is_unsigned/is_load/is_store, out_tag/out_qidx
//     NOTE: a misaligned half/word access is illegal in v1 (SPEC-A1 /
//     D-C0-01): driving one with out_valid would trip the DUT's own
//     a_natural_align assertion, so it is checked at model level only (see
//     the "model vs lsu_pkg" table, which does cover all 8 ops x 4 patterns).
//   * independent reference model cross-checked against the lsu_pkg helpers
//     for all 8 ops x all 4 addr[1:0] patterns
//   * address wraparound (src1 + imm mod 2^32) and negative immediates
//   * is_mmio window: 0xA000_0000 / 0xA0FF_FFFF inside, 0x9FFF_FFFF /
//     0xA100_0000 / 0x8000_0000 / 0x8010_0000 outside, classification of the
//     computed sum (not of src1), and an instance with overridden
//     MMIO_BASE/MMIO_MASK (0x4000_0000 / 0xF000_0000)
//   * kill priority: a killed issue produces no output at all, a kill without
//     an issue is harmless, and a kill between two valid issues neither
//     loses nor shifts the surviving outputs
//   * 20 consecutive issues (II = 1): exactly one output per cycle, counted
//   * 10000 random cycles with a fixed seed (random op/src1/src2/imm/qidx/tag/
//     kill, biased towards the MMIO window and the address wrap region)
//     compared field by field against the reference model; >= 2000 issues
//   * global liveness: the number of cycles with out_valid equals the number
//     of non-killed issues
//
// Build / run (Verilator 5.x, from the repository root; --timing is needed for
// the bench clock, -o is relative to --Mdir):
//   $ verilator --lint-only -Wall --assert --timing -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu_agu \
//       rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/lsu_agu.sv \
//       rtl/memory/test/unit/tb_lsu_agu.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu_agu \
//       --Mdir sim/build/unit/tb_lsu_agu -o tb_lsu_agu \
//       rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/lsu_agu.sv \
//       rtl/memory/test/unit/tb_lsu_agu.sv
//   $ sim/build/unit/tb_lsu_agu/tb_lsu_agu
//
// Free items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_lsu_agu;

    import ares_pkg::*;
    import lsu_pkg::*;

    //-------------------------------------------------------------------------
    // Clock / reset (standalone: own clock, no harness)
    //-------------------------------------------------------------------------
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    localparam int unsigned B2B_CYCLES = 20;
    localparam int unsigned RAND_CYCLES = 10000;
    localparam int unsigned SEED = 32'h5EED_00A6;

    // MMIO window of the default DUT instance (the module defaults are used on
    // purpose: this bench also proves the default parameter values).
    localparam logic [31:0] MMIO_BASE_D = 32'hA000_0000;
    localparam logic [31:0] MMIO_MASK_D = 32'hFF00_0000;

    //-------------------------------------------------------------------------
    // DUT 1 - default MMIO window
    //-------------------------------------------------------------------------
    logic        issue_valid;
    fu_req_t     issue_req;
    logic [2:0]  issue_qidx;
    logic        issue_kill;

    logic        out_valid;
    tag_t        out_tag;
    logic [2:0]  out_qidx;
    logic        out_is_load;
    logic        out_is_store;
    logic [31:0] out_addr;
    lsu_size_t   out_size;
    logic [3:0]  out_byte_mask;
    logic [31:0] out_store_data;
    logic        out_is_unsigned;
    logic        out_is_mmio;

    lsu_agu u_dut (
        .clk           (clk),
        .rst           (rst),
        .issue_valid   (issue_valid),
        .issue_req     (issue_req),
        .issue_qidx    (issue_qidx),
        .issue_kill    (issue_kill),
        .out_valid     (out_valid),
        .out_tag       (out_tag),
        .out_qidx      (out_qidx),
        .out_is_load   (out_is_load),
        .out_is_store  (out_is_store),
        .out_addr      (out_addr),
        .out_size      (out_size),
        .out_byte_mask (out_byte_mask),
        .out_store_data(out_store_data),
        .out_is_unsigned(out_is_unsigned),
        .out_is_mmio   (out_is_mmio)
    );

    //-------------------------------------------------------------------------
    // DUT 2 - overridden MMIO window (parameter coverage)
    //-------------------------------------------------------------------------
    localparam logic [31:0] ALT_BASE = 32'h4000_0000;
    localparam logic [31:0] ALT_MASK = 32'hF000_0000;

    logic        issue_valid2;
    fu_req_t     issue_req2;
    logic [2:0]  issue_qidx2;
    logic        issue_kill2;

    logic        out_valid2;
    tag_t        out_tag2;
    logic [2:0]  out_qidx2;
    logic        out_is_load2;
    logic        out_is_store2;
    logic [31:0] out_addr2;
    lsu_size_t   out_size2;
    logic [3:0]  out_byte_mask2;
    logic [31:0] out_store_data2;
    logic        out_is_unsigned2;
    logic        out_is_mmio2;

    lsu_agu #(
        .JYD_UNCACHED_WINDOWS (1'b1),
        .MMIO_BASE (ALT_BASE),
        .MMIO_MASK (ALT_MASK)
    ) u_dut_alt (
        .clk           (clk),
        .rst           (rst),
        .issue_valid   (issue_valid2),
        .issue_req     (issue_req2),
        .issue_qidx    (issue_qidx2),
        .issue_kill    (issue_kill2),
        .out_valid     (out_valid2),
        .out_tag       (out_tag2),
        .out_qidx      (out_qidx2),
        .out_is_load   (out_is_load2),
        .out_is_store  (out_is_store2),
        .out_addr      (out_addr2),
        .out_size      (out_size2),
        .out_byte_mask (out_byte_mask2),
        .out_store_data(out_store_data2),
        .out_is_unsigned(out_is_unsigned2),
        .out_is_mmio   (out_is_mmio2)
    );

    //-------------------------------------------------------------------------
    // Expectation / observation record
    //-------------------------------------------------------------------------
    typedef struct packed {
        logic        valid;
        logic [31:0] addr;
        logic [1:0]  size;
        logic [3:0]  mask;
        logic [31:0] sdata;
        logic        uns;
        logic        ld;
        logic        st;
        logic        mmio;
        logic [3:0]  tag;
        logic [2:0]  qidx;
    } agu_rec_t;

    function automatic agu_rec_t obs_main();
        agu_rec_t o;
        begin
            o.valid = out_valid;
            o.addr  = out_addr;
            o.size  = out_size;
            o.mask  = out_byte_mask;
            o.sdata = out_store_data;
            o.uns   = out_is_unsigned;
            o.ld    = out_is_load;
            o.st    = out_is_store;
            o.mmio  = out_is_mmio;
            o.tag   = out_tag.slot_index;
            o.qidx  = out_qidx;
            obs_main = o;
        end
    endfunction

    function automatic agu_rec_t obs_alt();
        agu_rec_t o;
        begin
            o.valid = out_valid2;
            o.addr  = out_addr2;
            o.size  = out_size2;
            o.mask  = out_byte_mask2;
            o.sdata = out_store_data2;
            o.uns   = out_is_unsigned2;
            o.ld    = out_is_load2;
            o.st    = out_is_store2;
            o.mmio  = out_is_mmio2;
            o.tag   = out_tag2.slot_index;
            o.qidx  = out_qidx2;
            obs_alt = o;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Independent reference model
    //
    // Written from the specification text (explicit per-op decoding), NOT by
    // calling the lsu_pkg helpers: the two are cross-checked against each
    // other below, so a wrong helper mapping in the DUT is caught even though
    // the DUT itself is required to use the helpers.
    //-------------------------------------------------------------------------
    function automatic agu_rec_t ref_agu(input logic v,
                                         input logic kill,
                                         input op_t op,
                                         input logic [31:0] src1,
                                         input logic [31:0] src2,
                                         input logic [31:0] imm,
                                         input logic [2:0] qidx,
                                         input logic [3:0] slot,
                                         input logic [31:0] mmio_base,
                                         input logic [31:0] mmio_mask);
        agu_rec_t    e;
        logic [31:0] a;
        logic [1:0]  sz;
        begin
            a = src1 + imm;                       // 32-bit wraparound
            e = '0;
            e.valid = v && !kill;
            e.addr  = a;
            e.qidx  = qidx;
            e.tag   = slot;

            unique case (op)
                OP_LB, OP_LBU, OP_SB: sz = 2'd0;
                OP_LH, OP_LHU, OP_SH: sz = 2'd1;
                default:              sz = 2'd2;
            endcase
            e.size = sz;
            e.ld   = (op == OP_LB) || (op == OP_LH) || (op == OP_LW)
                  || (op == OP_LBU) || (op == OP_LHU);
            e.st   = (op == OP_SB) || (op == OP_SH) || (op == OP_SW);
            e.uns  = (op == OP_LBU) || (op == OP_LHU);

            unique case (sz)
                2'd0: begin
                    e.mask  = 4'b0001 << a[1:0];
                    e.sdata = 32'({24'd0, src2[7:0]}) << (8 * a[1:0]);
                end
                2'd1: begin
                    e.mask  = 4'b0011 << a[1:0];
                    e.sdata = 32'({16'd0, src2[15:0]}) << (8 * a[1:0]);
                end
                default: begin
                    e.mask  = 4'b1111;
                    e.sdata = src2;
                end
            endcase

            e.mmio = ((a & mmio_mask) == (mmio_base & mmio_mask));
            // Independent range model for the explicitly enabled JYD profile.
            if (mmio_base == ALT_BASE)
                e.mmio |= (a >= 32'h8030_0000 && a <= 32'h8033_FFFF) ||
                          (a >= 32'h8040_0000 && a <= 32'h83FF_FFFF);
            ref_agu = e;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Helpers, bookkeeping, RNG
    //-------------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;
    string       ctx = "init";

    int unsigned n_issued = 0;      // non-killed issues on DUT 1
    int unsigned n_killed = 0;      // killed issues on DUT 1
    int unsigned n_outval = 0;      // sampled cycles with out_valid = 1
    int unsigned n_rand_issues = 0;

    task automatic err(input string msg);
        begin
            errors = errors + 1;
            if (errors <= 30) $display("[%0t] ERROR (%s): %s", $time, ctx, msg);
        end
    endtask

    task automatic check_rec(input agu_rec_t o, input agu_rec_t e);
        begin
            checks = checks + 1;
            if (o.valid !== e.valid) begin
                err($sformatf("out_valid=%0b expected %0b", o.valid, e.valid));
            end else if (o.valid) begin
                checks = checks + 10;
                if (o.addr  !== e.addr)  err($sformatf("out_addr=%08h expected %08h", o.addr, e.addr));
                if (o.size  !== e.size)  err($sformatf("out_size=%0d expected %0d", o.size, e.size));
                if (o.mask  !== e.mask)  err($sformatf("out_byte_mask=%04b expected %04b", o.mask, e.mask));
                if (o.sdata !== e.sdata) err($sformatf("out_store_data=%08h expected %08h", o.sdata, e.sdata));
                if (o.uns   !== e.uns)   err($sformatf("out_is_unsigned=%0b expected %0b", o.uns, e.uns));
                if (o.ld    !== e.ld)    err($sformatf("out_is_load=%0b expected %0b", o.ld, e.ld));
                if (o.st    !== e.st)    err($sformatf("out_is_store=%0b expected %0b", o.st, e.st));
                if (o.mmio  !== e.mmio)  err($sformatf("out_is_mmio=%0b expected %0b (addr=%08h)", o.mmio, e.mmio, o.addr));
                if (o.tag   !== e.tag)   err($sformatf("out_tag=%0h expected %0h", o.tag, e.tag));
                if (o.qidx  !== e.qidx)  err($sformatf("out_qidx=%0d expected %0d", o.qidx, e.qidx));
            end
        end
    endtask

    function automatic fu_req_t mk_req(input op_t op, input logic [31:0] s1,
                                       input logic [31:0] s2, input logic [31:0] im,
                                       input logic [3:0] slot);
        fu_req_t r;
        begin
            r = '0;
            r.tag.slot_index = slot;
            r.op   = op;
            r.src1 = s1;
            r.src2 = s2;
            r.imm  = im;
            mk_req = r;
        end
    endfunction

    function automatic op_t op_of_idx(input int unsigned i);
        case (i)
            0:       op_of_idx = OP_LB;
            1:       op_of_idx = OP_LH;
            2:       op_of_idx = OP_LW;
            3:       op_of_idx = OP_LBU;
            4:       op_of_idx = OP_LHU;
            5:       op_of_idx = OP_SB;
            6:       op_of_idx = OP_SH;
            default: op_of_idx = OP_SW;
        endcase
    endfunction

    function automatic logic [1:0] size_of_op(input op_t op);
        case (op)
            OP_LB, OP_LBU, OP_SB: size_of_op = 2'd0;
            OP_LH, OP_LHU, OP_SH: size_of_op = 2'd1;
            default:              size_of_op = 2'd2;
        endcase
    endfunction

    // SPEC-A1: only naturally aligned accesses are legal for half/word.
    function automatic logic align_ok(input logic [1:0] sz, input logic [1:0] low);
        align_ok = (sz == 2'd0) || ((sz == 2'd1) && (low[0] == 1'b0)) || (low == 2'b00);
    endfunction

    // src1 + imm == 0x8010_2000 + low, split so that the adder sees carries.
    task automatic addr_split(input logic [1:0] low,
                              output logic [31:0] s1, output logic [31:0] im);
        begin
            case (low)
                2'd0: begin s1 = 32'h8010_2000; im = 32'h0000_0000; end
                2'd1: begin s1 = 32'h8010_1FFF; im = 32'h0000_0002; end
                2'd2: begin s1 = 32'h8010_1FFE; im = 32'h0000_0004; end
                default: begin s1 = 32'h8010_0FFF; im = 32'h0000_1004; end
            endcase
        end
    endtask

    // Fixed-seed RNG: the seed is applied exactly once (Verilator treats the
    // $urandom argument as an input only), every draw afterwards uses
    // $urandom()/$urandom_range(), so a given seed reproduces exactly.
    int unsigned seed = SEED;

    task automatic rng_init();
        begin
            seed = SEED;
            void'($urandom(seed));
        end
    endtask

    function automatic logic [31:0] rnd32();
        rnd32 = $urandom();
    endfunction

    function automatic logic [2:0] rnd3();
        rnd3 = 3'($urandom_range(0, 7));
    endfunction

    function automatic logic [3:0] rnd4();
        rnd4 = 4'($urandom_range(0, 15));
    endfunction

    //-------------------------------------------------------------------------
    // Cycle stepping with the two-deep expectation pipe
    //-------------------------------------------------------------------------
    agu_rec_t pipe [2];             // pipe[0]: expected now, pipe[1]: expected next

    function automatic fu_req_t idle_req();
        idle_req = mk_req(OP_LW, 32'd0, 32'd0, 32'd0, 4'd0);
    endfunction

    task automatic step(input logic iv, input fu_req_t rq, input logic [2:0] qi, input logic ik);
        begin
            check_rec(obs_main(), pipe[0]);
            if (out_valid) n_outval = n_outval + 1;
            if (iv && !ik) n_issued = n_issued + 1;
            if (iv && ik)  n_killed = n_killed + 1;

            pipe[0] = pipe[1];
            pipe[1] = ref_agu(iv, ik, rq.op, rq.src1, rq.src2, rq.imm, qi,
                              rq.tag.slot_index, MMIO_BASE_D, MMIO_MASK_D);

            // Blocking drives are safe here: every stimulus change happens on a
            // falling edge, half a period away from the DUT's sampling edge.
            issue_valid = iv;
            issue_req   = rq;
            issue_qidx  = qi;
            issue_kill  = ik;

            @(negedge clk);
        end
    endtask

    task automatic idle_step();
        begin
            step(1'b0, idle_req(), 3'd0, 1'b0);
        end
    endtask

    // One isolated issue plus its two drain cycles: the result is compared in
    // the C2 cycle and both neighbouring cycles must show out_valid = 0.
    task automatic issue_check(input op_t op, input logic [31:0] s1, input logic [31:0] s2,
                               input logic [31:0] im, input logic [2:0] qi, input logic [3:0] slot,
                               input logic ik);
        begin
            step(1'b1, mk_req(op, s1, s2, im, slot), qi, ik);
            idle_step();
            idle_step();
        end
    endtask

    //-------------------------------------------------------------------------
    // DUT 2 (parameter override) single issue + one-cycle-pulse check
    //-------------------------------------------------------------------------
    task automatic alt_check(input op_t op, input logic [31:0] s1, input logic [31:0] s2,
                             input logic [31:0] im, input logic exp_mmio);
        agu_rec_t ea;
        agu_rec_t eza;
        begin
            ea  = ref_agu(1'b1, 1'b0, op, s1, s2, im, 3'd5, 4'd7, ALT_BASE, ALT_MASK);
            eza = '0;

            issue_valid2 = 1'b1;
            issue_req2   = mk_req(op, s1, s2, im, 4'd7);
            issue_qidx2  = 3'd5;
            issue_kill2  = 1'b0;

            idle_step();                     // C1: issue captured; DUT 1 idle
            issue_valid2 = 1'b0;
            idle_step();                     // C2: result registered
            checks = checks + 1;
            if (ea.mmio !== exp_mmio)
                err($sformatf("alt expectation table wrong: addr=%08h mmio=%0b expected %0b",
                              ea.addr, ea.mmio, exp_mmio));
            check_rec(obs_alt(), ea);
            idle_step();                     // C3: out_valid2 must be a one-cycle pulse
            check_rec(obs_alt(), eza);
            idle_step();                     // run-out
            issue_valid2 = 1'b0;
        end
    endtask

    //-------------------------------------------------------------------------
    // Stimulus
    //-------------------------------------------------------------------------
    op_t         op;
    logic [31:0] s1, s2, im;
    logic [2:0]  qi;
    logic [3:0]  slot;
    logic [1:0]  sz;
    logic [1:0]  low2;
    logic        iv, ik;
    agu_rec_t    e;
    agu_rec_t    pkg_rec;
    lsu_size_t   pkg_sz;
    int unsigned v0;
    int unsigned c;

    initial begin
        issue_valid  = 1'b0;
        issue_req    = '0;
        issue_qidx   = 3'd0;
        issue_kill   = 1'b0;
        issue_valid2 = 1'b0;
        issue_req2   = '0;
        issue_qidx2  = 3'd0;
        issue_kill2  = 1'b0;
        pipe[0]      = '0;
        pipe[1]      = '0;

        //---------------------------------------------------------------------
        // 1. Reset: out_valid must be low while rst is asserted and in the
        //    first cycles after release (the pipeline registers stayed clean)
        //---------------------------------------------------------------------
        ctx = "reset";
        @(negedge clk);
        repeat (4) idle_step();
        rst = 1'b0;
        idle_step();
        idle_step();

        //---------------------------------------------------------------------
        // 2. All 8 ops x every legal addr[1:0] pattern (byte ops cover all
        //    four low-bit values; the C2 cycle of every issue is compared)
        //---------------------------------------------------------------------
        ctx = "op x align";
        for (int unsigned oi = 0; oi < 8; oi++) begin
            op = op_of_idx(oi);
            sz = size_of_op(op);
            s2 = 32'hA5A5_5A5A + oi;          // distinctive byte lanes
            qi = oi[2:0];
            slot = oi[3:0];
            for (int unsigned low = 0; low < 4; low++) begin
                if (!align_ok(sz, low[1:0])) continue;
                addr_split(low[1:0], s1, im);
                issue_check(op, s1, s2, im, qi, slot, 1'b0);
            end
        end

        //---------------------------------------------------------------------
        // 3. Reference model vs the lsu_pkg helpers: all 8 ops x all four
        //    addr[1:0] patterns (the misaligned combinations exist only in
        //    this model-level table, never on the DUT - SPEC-A1)
        //---------------------------------------------------------------------
        ctx = "model vs lsu_pkg";
        for (int unsigned oi = 0; oi < 8; oi++) begin
            for (int unsigned low = 0; low < 4; low++) begin
                op   = op_of_idx(oi);
                low2 = low[1:0];
                s2   = 32'h1234_ABCD;
                e    = ref_agu(1'b1, 1'b0, op, 32'd0, s2, {30'd0, low2}, 3'd0, 4'd0,
                               MMIO_BASE_D, MMIO_MASK_D);

                pkg_sz       = lsu_op_size(op);
                pkg_rec      = '0;
                pkg_rec.valid = 1'b1;
                pkg_rec.addr  = {30'd0, low2};
                pkg_rec.size  = pkg_sz;
                pkg_rec.mask  = lsu_size_mask(low2, pkg_sz);
                pkg_rec.sdata = lsu_align_store_data(s2, low2, pkg_sz);
                pkg_rec.uns   = lsu_op_is_unsigned(op);
                pkg_rec.ld    = lsu_op_is_load(op);
                pkg_rec.st    = lsu_op_is_store(op);
                pkg_rec.mmio  = ((({30'd0, low2}) & MMIO_MASK_D) == (MMIO_BASE_D & MMIO_MASK_D));

                // Field-by-field comparison of the independent model against
                // the lsu_pkg helpers over the whole 8 x 4 table.
                check_rec(pkg_rec, e);
            end
        end

        //---------------------------------------------------------------------
        // 4. Address wraparound and negative immediates
        //---------------------------------------------------------------------
        ctx = "wraparound";
        issue_check(OP_LW,  32'hFFFF_FFF8, 32'h1122_3344, 32'h0000_0010, 3'd1, 4'd3, 1'b0); // -> 0x0000_0008
        issue_check(OP_LW,  32'hFFFF_FFFF, 32'h1122_3344, 32'h0000_0001, 3'd2, 4'd4, 1'b0); // -> 0x0000_0000
        issue_check(OP_SW,  32'h8000_0000, 32'hCAFE_F00D, 32'hFFFF_FFF0, 3'd0, 4'd5, 1'b0); // -> 0x7FFF_FFF0
        issue_check(OP_SB,  32'h0000_0003, 32'h0000_00AA, 32'hFFFF_FFFE, 3'd3, 4'd6, 1'b0); // -> 0x0000_0001
        issue_check(OP_LBU, 32'h7FFF_FFFF, 32'h0000_0000, 32'h0000_0000, 3'd4, 4'd7, 1'b0); // -> 0x7FFF_FFFF
        issue_check(OP_LB,  32'h0000_0002, 32'h0000_0000, 32'hFFFF_FFFF, 3'd5, 4'd8, 1'b0); // -> 0x0000_0001
        issue_check(OP_SH,  32'hFFFF_FFF0, 32'h0000_BEEF, 32'h0000_0012, 3'd6, 4'd9, 1'b0); // -> 0x0000_0002

        //---------------------------------------------------------------------
        // 5. MMIO window: inside / outside the default 0xA000_0000 window and
        //    classification of the computed sum (not of src1 alone)
        //---------------------------------------------------------------------
        ctx = "mmio window";
        issue_check(OP_LW, 32'h0000_0000, 32'h0000_0000, 32'hA000_0000, 3'd0, 4'd0, 1'b0); // inside
        issue_check(OP_LW, 32'h0000_0000, 32'h0000_0000, 32'hA000_0004, 3'd1, 4'd1, 1'b0); // inside
        issue_check(OP_LW, 32'h0000_0000, 32'h0000_0000, 32'hA0FF_FFFC, 3'd2, 4'd2, 1'b0); // inside
        issue_check(OP_LB, 32'h0000_0000, 32'h0000_0000, 32'hA0FF_FFFF, 3'd3, 4'd3, 1'b0); // inside (top byte)
        issue_check(OP_LH, 32'h0000_0000, 32'h0000_0000, 32'hA080_1234, 3'd4, 4'd4, 1'b0); // inside
        issue_check(OP_LB, 32'h0000_0000, 32'h0000_0000, 32'h9FFF_FFFF, 3'd5, 4'd5, 1'b0); // outside
        issue_check(OP_LW, 32'h0000_0000, 32'h0000_0000, 32'hA100_0000, 3'd6, 4'd6, 1'b0); // outside
        issue_check(OP_SW, 32'h0000_0000, 32'h0000_0000, 32'h8000_0000, 3'd7, 4'd7, 1'b0); // outside
        issue_check(OP_SW, 32'h0000_0000, 32'h0000_0000, 32'h8010_0000, 3'd0, 4'd8, 1'b0); // outside
        issue_check(OP_SW, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 3'd1, 4'd9, 1'b0); // outside
        issue_check(OP_LW, 32'h9FFF_0000, 32'h0000_0000, 32'h0001_0000, 3'd2, 4'd10, 1'b0); // sum -> 0xA000_0000
        issue_check(OP_LW, 32'hA001_0000, 32'h0000_0000, 32'hFFFF_0000, 3'd3, 4'd11, 1'b0); // sum -> 0xA000_0000
        issue_check(OP_LB, 32'h9FFF_FFFF, 32'h0000_0000, 32'h0000_0001, 3'd4, 4'd12, 1'b0); // sum -> 0xA000_0000
        issue_check(OP_LW, 32'hA000_0004, 32'h0000_0000, 32'hFFFF_0000, 3'd5, 4'd13, 1'b0); // sum -> 0x9FFF_0004

        ctx = "JYD uncached windows, boundaries and computed address";
        alt_check(OP_LW, 32'h8010_0000, 0, 0, 0);
        alt_check(OP_LW, 32'h802F_FFFC, 0, 0, 0);
        alt_check(OP_LW, 32'h8030_0000, 0, 0, 1);
        alt_check(OP_LW, 32'h8033_FFFC, 0, 0, 1);
        alt_check(OP_LW, 32'h8034_0000, 0, 0, 0);
        alt_check(OP_LW, 32'h803F_FFFC, 0, 4, 1);
        alt_check(OP_LW, 32'h83FF_FFFC, 0, 0, 1);
        alt_check(OP_LW, 32'h8400_0000, 0, 0, 0);
        alt_check(OP_SW, 32'h8030_0000, 32'hFEED_ABCD, 0, 1);

        //---------------------------------------------------------------------
        // 6. Kill priority and pipeline integrity under kill
        //---------------------------------------------------------------------
        ctx = "kill priority";
        issue_check(OP_LW, 32'h8010_3000, 32'hDEAD_BEEF, 32'h0000_0000, 3'd1, 4'd1, 1'b1); // no output
        step(1'b0, mk_req(OP_LW, 32'h8010_3004, 32'h0, 32'h0, 4'd2), 3'd2, 1'b1);         // kill, no issue
        idle_step();
        // valid, killed, valid back-to-back: the survivors must not move
        step(1'b1, mk_req(OP_LW, 32'h8010_3008, 32'h0, 32'h0, 4'd3), 3'd3, 1'b0);
        step(1'b1, mk_req(OP_LW, 32'h8010_300C, 32'h0, 32'h0, 4'd4), 3'd4, 1'b1);
        step(1'b1, mk_req(OP_LW, 32'h8010_3010, 32'h0, 32'h0, 4'd5), 3'd5, 1'b0);
        idle_step();
        idle_step();
        idle_step();

        //---------------------------------------------------------------------
        // 7. Back-to-back: 20 issues at II = 1, one output per cycle
        //---------------------------------------------------------------------
        ctx = "back-to-back";
        v0 = n_outval;
        for (int unsigned i = 0; i < B2B_CYCLES; i++) begin
            op   = i[0] ? OP_SW : OP_LW;
            s1   = 32'h8010_4000 + (i * 32'd4);
            im   = 32'h0000_0004;
            s2   = 32'h1000_0000 + i;
            qi   = i[2:0];
            slot = i[3:0];
            step(1'b1, mk_req(op, s1, s2, im, slot), qi, 1'b0);
        end
        idle_step();
        idle_step();
        checks = checks + 1;
        if ((n_outval - v0) != B2B_CYCLES)
            err($sformatf("back-to-back saw %0d out_valid cycles, expected %0d",
                          n_outval - v0, B2B_CYCLES));

        //---------------------------------------------------------------------
        // 8. Fixed-seed random stimulus against the reference model
        //---------------------------------------------------------------------
        ctx = "random";
        rng_init();
        for (c = 0; c < RAND_CYCLES; c++) begin
            iv = ($urandom_range(0, 99) < 80);
            ik = ($urandom_range(0, 99) < 20);
            op = op_of_idx($urandom_range(0, 7));
            sz = size_of_op(op);
            s1 = rnd32();
            im = rnd32();
            s2 = rnd32();

            // Bias towards the interesting regions: inside/near the MMIO
            // window on both boundaries and the address wrap region.
            case ($urandom_range(0, 7))
                0: begin
                    s1 = MMIO_BASE_D + $urandom_range(0, 32'h0002_0000);
                    im = rnd32();
                end
                1: begin
                    s1 = 32'hA0FF_0000 + $urandom_range(0, 32'h0002_0000);
                    im = rnd32();
                end
                2: begin
                    s1 = 32'h9FFE_0000 + $urandom_range(0, 32'h0004_0000);
                    im = rnd32();
                end
                3: begin
                    s1 = 32'hFFFF_FFF0 + $urandom_range(0, 32'h0000_001F);
                    im = rnd32();
                end
                default: ;
            endcase

            // SPEC-A1: only naturally aligned stimulus reaches the DUT (the
            // sum of two aligned terms stays aligned).
            if (sz == 2'd1) begin
                s1[0] = 1'b0;
                im[0] = 1'b0;
            end
            if (sz == 2'd2) begin
                s1[1:0] = 2'b00;
                im[1:0] = 2'b00;
            end

            qi   = rnd3();
            slot = rnd4();
            step(iv, mk_req(op, s1, s2, im, slot), qi, ik);
            if (iv && !ik) n_rand_issues = n_rand_issues + 1;
        end
        repeat (3) idle_step();

        //---------------------------------------------------------------------
        // 9. Parameter override: a second instance with a different window
        //---------------------------------------------------------------------
        ctx = "param override";
        checks = checks + 1;
        if (out_valid2 !== 1'b0)
            err("alt DUT produced an output although it was never issued to");
        alt_check(OP_LW, 32'h0000_0000, 32'h0, 32'h4000_0000, 1'b1);  // inside
        alt_check(OP_LW, 32'h0000_0000, 32'h0, 32'h4FFF_FFFC, 1'b1);  // inside
        alt_check(OP_LB, 32'h0000_0000, 32'h0, 32'h4FFF_FFFF, 1'b1);  // inside (top byte)
        alt_check(OP_LW, 32'h0000_0000, 32'h0, 32'h5000_0000, 1'b0);  // outside
        alt_check(OP_LB, 32'h0000_0000, 32'h0, 32'h3FFF_FFFF, 1'b0);  // outside
        alt_check(OP_LW, 32'h0000_0000, 32'h0, 32'hA000_0000, 1'b0);  // outside under alt params

        //---------------------------------------------------------------------
        // 10. Global liveness: one out_valid per non-killed issue
        //---------------------------------------------------------------------
        ctx = "liveness";
        checks = checks + 1;
        if (n_outval != n_issued)
            err($sformatf("observed %0d out_valid cycles for %0d non-killed issues",
                          n_outval, n_issued));

        if (errors != 0)
            $fatal(1, "tb_lsu_agu: %0d error(s) in %0d checks", errors, checks);

        $display("ALL TESTS PASSED: %0d checks - reset clean, 8 ops x legal addr[1:0] (all four low-bit patterns), model vs lsu_pkg, wraparound + negative imm, MMIO window in/out + computed-sum classification, MMIO_BASE/MASK override, kill priority, %0d-cycle back-to-back, %0d random cycles (%0d issues vs reference model)",
                 checks, B2B_CYCLES, RAND_CYCLES, n_rand_issues);
        $finish;
    end

endmodule
