//=============================================================================
// ARES backend - unit test: fu_alu / fu_smul / fu_mul / fu_div
//-----------------------------------------------------------------------------
// Purpose
//   Standalone self-checking test bench (own clock, no external image, no DPI
//   model) for the phase-C1 execution units.  It drives the exact request /
//   kill / completion contract of backend.md sections 10 / 11 and compares
//   every completion against independently written reference models.
//
//   Covered (plan sections 5.6 / 5.7, modules B10 / B12 / B13 / B14):
//     * fu_alu  : every RV32I ALU op (LUI, AUIPC, ADD/SUB/SLL/SLT/SLTU/XOR/
//                 SRL/SRA/OR/AND and all immediate forms, EBREAK) over a
//                 boundary operand table (shift 0/31, sign boundary, SUB
//                 overflow), plus 400 back-to-back II = 1 issues.
//     * fu_smul : all four independent-fit combinations over the 0x7FFF /
//                 0x8000 / 0xFFFF boundaries and 100000 random smul_eligible
//                 MUL pairs, each against the low 32 bits of a full 64-bit
//                 product; issued back-to-back (II = 1).
//     * fu_mul  : MUL/MULH/MULHSU/MULHU edge cases and 100000 random pairs
//                 against a 128-bit reference model, issued back-to-back so
//                 that II = 1 and the fixed MUL_LATENCY are checked directly.
//                 MUL_LATENCY comes from ares_pkg, so the bench covers both
//                 the default 3 and the menu-configurable 2.
//     * fu_div  : DIV/DIVU/REM/REMU edge cases (0, +-1, INT_MIN/-1, divisor 0)
//                 and 20000 random pairs against a reference model, can_accept
//                 handover on the final completion edge, kill abort followed by
//                 a new operation that completes correctly.
//     * kill    : kill in the same cycle as a completion (completion
//                 suppressed AND no completion afterwards) for ALU/SMUL/MUL,
//                 kill of one MUL pipeline stage while another operation is in
//                 flight, kill of an in-flight DIV, kill in the DIV completion
//                 cycle.
//     * reset   : no completion out of reset, can_accept high out of reset,
//                 completion_valid is a one-cycle pulse (checked after every
//                 single-operation test).
//
//   Randomisation is reproducible: the constant seed in rng_init() is applied
//   with $urandom(seed) exactly once (Verilator never updates that argument,
//   so repeating the call would return a constant) and every draw afterwards
//   uses $urandom() / $urandom_range().  The same binary therefore produces
//   the same stimulus on every run, and the bench self-checks that the RNG is
//   actually advancing.
//
// Lint / build / run (Verilator 5.x, from the repository root; the two long
// shell lines below continue with a trailing backslash):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD
//       -DCONFIG_SIMULATION --timing rtl/common/ares_pkg.sv
//       rtl/backend/fu_alu.sv rtl/backend/fu_smul.sv rtl/backend/fu_mul.sv
//       rtl/backend/fu_div.sv rtl/backend/test/unit/tb_fu_exec.sv
//       --top-module tb_fu_exec
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_fu_exec
//       --Mdir /tmp/obj_tb_fu_exec -o /tmp/tb_fu_exec rtl/common/ares_pkg.sv
//       rtl/backend/fu_alu.sv rtl/backend/fu_smul.sv rtl/backend/fu_mul.sv
//       rtl/backend/fu_div.sv rtl/backend/test/unit/tb_fu_exec.sv
//       && /tmp/tb_fu_exec
//   Add -DCONFIG_MUL_LATENCY=2 to both commands to check the 2-stage MUL.
//
// Free items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_fu_exec;

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Clock / reset (own clock: this bench is standalone)
    //-------------------------------------------------------------------------
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    //-------------------------------------------------------------------------
    // DUT ports, collected in per-unit arrays so that one set of tasks can
    // drive/check any of the four units.
    //-------------------------------------------------------------------------
    localparam logic [1:0] D_ALU  = 2'd0;
    localparam logic [1:0] D_SMUL = 2'd1;
    localparam logic [1:0] D_MUL  = 2'd2;
    localparam logic [1:0] D_DIV  = 2'd3;

    localparam int MUL_LAT       = MUL_LATENCY;   // 2 or 3, from the package
    localparam int DIV_MAX_WAIT  = 48;            // 16 iterations + margin
    localparam int ALU_MAX_WAIT  = 4;
    localparam int SMUL_MAX_WAIT = 4;
    localparam int MUL_MAX_WAIT  = MUL_LATENCY + 2;

    logic                   iv [4];
    fu_req_t                rq [4];
    logic [CIQ_ENTRIES-1:0] km [4];
    logic                   cv [4];
    fu_completion_t         cp [4];
    logic                   div_can_accept;

    fu_alu u_alu (
        .clk(clk), .rst(rst),
        .issue_valid(iv[D_ALU]), .issue_req(rq[D_ALU]), .kill_mask(km[D_ALU]),
        .completion_valid(cv[D_ALU]), .completion(cp[D_ALU]));

    fu_smul u_smul (
        .clk(clk), .rst(rst),
        .issue_valid(iv[D_SMUL]), .issue_req(rq[D_SMUL]), .kill_mask(km[D_SMUL]),
        .completion_valid(cv[D_SMUL]), .completion(cp[D_SMUL]));

    fu_mul u_mul (
        .clk(clk), .rst(rst),
        .issue_valid(iv[D_MUL]), .issue_req(rq[D_MUL]), .kill_mask(km[D_MUL]),
        .completion_valid(cv[D_MUL]), .completion(cp[D_MUL]));

    fu_div u_div (
        .clk(clk), .rst(rst),
        .issue_valid(iv[D_DIV]), .issue_req(rq[D_DIV]), .kill_mask(km[D_DIV]),
        .completion_valid(cv[D_DIV]), .completion(cp[D_DIV]),
        .can_accept(div_can_accept));

    //-------------------------------------------------------------------------
    // Check bookkeeping and fixed-seed RNG
    //-------------------------------------------------------------------------
    localparam int unsigned SEED = 32'h5EED_1234;

    int unsigned errors = 0;
    int unsigned checks = 0;
    int unsigned n_alu_rand  = 0;
    int unsigned n_smul_rand = 0;
    int unsigned n_mul_rand  = 0;
    int unsigned n_div_rand  = 0;
    int          div_lat_obs = 0;

    // Fixed-seed RNG.  Verilator takes the $urandom(seed) argument as an
    // input only (it never updates the variable), so repeating
    // $urandom(seed) would return the same value forever.  The constant seed
    // is therefore applied exactly once by rng_init() and every draw
    // afterwards uses $urandom() / $urandom_range(); for a given seed the
    // sequence is identical on every run of the built binary, so any failure
    // reproduces exactly.
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

    task automatic record_error(input string msg);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("[%0t] ERROR: %s", $time, msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // Reference models, written independently of the RTL (64/128-bit
    // arithmetic instead of the RTL's 32-bit datapaths / partial products).
    //-------------------------------------------------------------------------
    function automatic logic [31:0] alu_ref(input op_t op,
                                            input logic [31:0] a, b, im, pc);
        begin
            case (op)
                OP_LUI:            alu_ref = im;
                OP_AUIPC:          alu_ref = 32'(64'(pc) + 64'(im));
                OP_ADD, OP_ADDI:   alu_ref = 32'(64'(a) + 64'(b));
                OP_SUB:            alu_ref = 32'(64'(a) - 64'(b));
                OP_SLL, OP_SLLI:   alu_ref = 32'(64'(a) << b[4:0]);
                OP_SLT, OP_SLTI:   alu_ref = (64'($signed(a)) < 64'($signed(b)))
                                            ? 32'd1 : 32'd0;
                OP_SLTU, OP_SLTIU: alu_ref = (64'(a) < 64'(b)) ? 32'd1 : 32'd0;
                OP_XOR, OP_XORI:   alu_ref = a ^ b;
                OP_SRL, OP_SRLI:   alu_ref = 32'(64'(a) >> b[4:0]);
                OP_SRA, OP_SRAI:   alu_ref = 32'(64'($signed(a)) >>> b[4:0]);
                OP_OR,  OP_ORI:    alu_ref = a | b;
                OP_AND, OP_ANDI:   alu_ref = a & b;
                OP_EBREAK:         alu_ref = 32'(64'(pc) + 64'd4);
                default:           alu_ref = 32'hDEAD_BEEF;
            endcase
        end
    endfunction

    function automatic logic [63:0] mul_full(input op_t op,
                                             input logic [31:0] a, b);
        logic signed [127:0] wa;
        logic        [127:0] wb;
        logic        [127:0] wp;
        begin
            case (op)
                OP_MULHU: begin
                    wa = $signed({96'd0, a});
                    wb = {96'd0, b};
                end
                OP_MULHSU: begin
                    wa = $signed({{96{a[31]}}, a});
                    wb = {96'd0, b};
                end
                default: begin                       // OP_MUL / OP_MULH
                    wa = $signed({{96{a[31]}}, a});
                    wb = $signed({{96{b[31]}}, b});
                end
            endcase
            wp = wa * wb;                            // exact 128-bit product
            // Reference-model self-check: a product of two 32-bit values must
            // fit in 64 bits, so the upper half of the exact 128-bit product
            // must be all zeros (unsigned magnitude) or all ones (negative
            // two's complement value).
            if ((wp[127:64] !== 64'd0) && (wp[127:64] !== {64{1'b1}}))
                $fatal(1, "mul_full overflow: op=%0d a=%08x b=%08x hi=%08x_%08x lo=%08x_%08x",
                       op, a, b, wp[127:96], wp[95:64], wp[63:32], wp[31:0]);
            mul_full = wp[63:0];
        end
    endfunction

    function automatic logic [31:0] mul_ref(input op_t op,
                                            input logic [31:0] a, b);
        logic [63:0] p;
        begin
            p = mul_full(op, a, b);
            mul_ref = (op == OP_MUL) ? p[31:0] : p[63:32];
        end
    endfunction

    function automatic logic [31:0] div_ref(input op_t op,
                                            input logic [31:0] a, b);
        logic [31:0] q, r;
        logic signed [63:0] sa, sb;
        begin
            q = 32'hFFFF_FFFF;                       // divisor == 0: DIV/DIVU
            r = a;                                   // divisor == 0: REM/REMU
            if (b != 32'd0) begin
                if ((op == OP_DIVU) || (op == OP_REMU)) begin
                    q = a / b;
                    r = a % b;
                end else begin
                    sa = $signed({{32{a[31]}}, a});
                    sb = $signed({{32{b[31]}}, b});
                    q  = 32'(sa / sb);               // INT_MIN/-1 -> 0x8000_0000
                    r  = 32'(sa % sb);
                end
            end
            div_ref = ((op == OP_DIV) || (op == OP_DIVU)) ? q : r;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Stimulus tables / generators
    //-------------------------------------------------------------------------
    localparam int N_ALU_OPS = 22;
    localparam int N_VALS    = 12;
    localparam int N_SMUL_ED = 6;
    localparam int N_MUL_ED  = 10;
    localparam int N_DIV_ED  = 16;

    function automatic op_t alu_op_at(input int i);
        case (i)
            0:  alu_op_at = OP_LUI;
            1:  alu_op_at = OP_AUIPC;
            2:  alu_op_at = OP_ADD;
            3:  alu_op_at = OP_ADDI;
            4:  alu_op_at = OP_SUB;
            5:  alu_op_at = OP_SLL;
            6:  alu_op_at = OP_SLLI;
            7:  alu_op_at = OP_SLT;
            8:  alu_op_at = OP_SLTI;
            9:  alu_op_at = OP_SLTU;
            10: alu_op_at = OP_SLTIU;
            11: alu_op_at = OP_XOR;
            12: alu_op_at = OP_XORI;
            13: alu_op_at = OP_SRL;
            14: alu_op_at = OP_SRLI;
            15: alu_op_at = OP_SRA;
            16: alu_op_at = OP_SRAI;
            17: alu_op_at = OP_OR;
            18: alu_op_at = OP_ORI;
            19: alu_op_at = OP_AND;
            20: alu_op_at = OP_ANDI;
            default: alu_op_at = OP_EBREAK;
        endcase
    endfunction

    function automatic logic alu_is_imm(input op_t op);
        case (op)
            OP_ADDI, OP_SLTI, OP_SLTIU, OP_XORI, OP_ORI, OP_ANDI,
            OP_SLLI, OP_SRLI, OP_SRAI: alu_is_imm = 1'b1;
            default:                   alu_is_imm = 1'b0;
        endcase
    endfunction

    function automatic logic [31:0] val_at(input int i);
        case (i)
            0:  val_at = 32'h0000_0000;
            1:  val_at = 32'h0000_0001;
            2:  val_at = 32'h0000_001F;   // shift by 31
            3:  val_at = 32'h0000_0020;   // shift amount 0 (5-bit wrap)
            4:  val_at = 32'h7FFF_FFFF;
            5:  val_at = 32'h8000_0000;   // SLT/SLTU sign boundary
            6:  val_at = 32'h8000_0001;
            7:  val_at = 32'hFFFF_FFFF;
            8:  val_at = 32'hFFFF_FFFE;
            9:  val_at = 32'h0000_8000;
            10: val_at = 32'h5555_5555;
            default: val_at = 32'hAAAA_AAAA;
        endcase
    endfunction

    function automatic logic [31:0] smul_edge_at(input int i);
        case (i)
            0:  smul_edge_at = 32'h0000_0000;      // u16 fit
            1:  smul_edge_at = 32'h0000_0001;
            2:  smul_edge_at = 32'h0000_7FFF;      // s16 positive boundary
            3:  smul_edge_at = 32'h0000_FFFF;
            4:  smul_edge_at = 32'hFFFF_8000;      // s16 negative boundary
            default: smul_edge_at = 32'hFFFF_FFFF; // -1, s16 fit
        endcase
    endfunction

    function automatic logic [31:0] mul_edge_at(input int i);
        case (i)
            0:  mul_edge_at = 32'h0000_0000;
            1:  mul_edge_at = 32'h0000_0001;
            2:  mul_edge_at = 32'hFFFF_FFFF;
            3:  mul_edge_at = 32'h7FFF_FFFF;
            4:  mul_edge_at = 32'h8000_0000;
            5:  mul_edge_at = 32'h8000_0001;
            6:  mul_edge_at = 32'h0001_0000;
            7:  mul_edge_at = 32'h0000_8000;
            8:  mul_edge_at = 32'h5555_5555;
            default: mul_edge_at = 32'hAAAA_AAAA;
        endcase
    endfunction

    function automatic logic [31:0] div_edge(input int i, input int which);
        logic [31:0] a, b;
        begin
            case (i)
                0:  begin a = 32'h0000_0000; b = 32'h0000_0000; end // 0 / 0
                1:  begin a = 32'h8000_0000; b = 32'h0000_0000; end // INT_MIN / 0
                2:  begin a = 32'hFFFF_FFFF; b = 32'h0000_0000; end // -1 / 0
                3:  begin a = 32'h0000_0001; b = 32'h0000_0000; end // 1 / 0
                4:  begin a = 32'h0000_0005; b = 32'h0000_0001; end // 5 / 1
                5:  begin a = 32'h0000_0005; b = 32'hFFFF_FFFF; end // 5 / -1
                6:  begin a = 32'hFFFF_FFFB; b = 32'h0000_0001; end // -5 / 1
                7:  begin a = 32'hFFFF_FFFB; b = 32'hFFFF_FFFF; end // -5 / -1
                8:  begin a = 32'h7FFF_FFFF; b = 32'hFFFF_FFFF; end // MAX / -1
                9:  begin a = 32'h8000_0000; b = 32'hFFFF_FFFF; end // INT_MIN / -1
                10: begin a = 32'hFFFF_FFFB; b = 32'h0000_0003; end // -5 / 3
                11: begin a = 32'h0000_0005; b = 32'hFFFF_FFFD; end // 5 / -3
                12: begin a = 32'hFFFF_FFFB; b = 32'hFFFF_FFFD; end // -5 / -3
                13: begin a = 32'h8000_0000; b = 32'h0000_0002; end // INT_MIN / 2
                14: begin a = 32'h8000_0000; b = 32'hFFFF_FFFE; end // INT_MIN / -2
                default: begin
                    a = 32'hFFFF_FFFF; b = 32'h0000_0002;           // UINT_MAX / 2
                end
            endcase
            div_edge = (which != 0) ? b : a;
        end
    endfunction

    function automatic logic [31:0] rand_fit16();
        logic [15:0] lo;
        logic        neg;
        begin
            lo  = 16'($urandom());
            neg = 1'($urandom());
            // 50 % u16 fit (upper half zero), 50 % s16 fit (upper half sign);
            // both classes are smul_eligible (backend.md section 9.3).
            rand_fit16 = neg ? {{16{lo[15]}}, lo} : {16'd0, lo};
        end
    endfunction

    function automatic op_t rand_alu_op();
        rand_alu_op = alu_op_at($urandom_range(0, N_ALU_OPS - 1));
    endfunction

    function automatic op_t rand_mul_op();
        case ($urandom_range(0, 3))
            0:       rand_mul_op = OP_MUL;
            1:       rand_mul_op = OP_MULH;
            2:       rand_mul_op = OP_MULHSU;
            default: rand_mul_op = OP_MULHU;
        endcase
    endfunction

    function automatic op_t rand_div_op();
        case ($urandom_range(0, 3))
            0:       rand_div_op = OP_DIV;
            1:       rand_div_op = OP_DIVU;
            2:       rand_div_op = OP_REM;
            default: rand_div_op = OP_REMU;
        endcase
    endfunction

    function automatic logic [31:0] rand_div_operand();
        logic [15:0] lo;
        logic        sgn;
        logic        pick;
        begin
            case ($urandom_range(0, 5))
                0: rand_div_operand = rnd32();
                1: rand_div_operand = 32'($urandom_range(0, 3));   // 0..3, divisor 0
                2: begin
                    pick = 1'($urandom());
                    rand_div_operand = pick ? 32'hFFFF_FFFF : 32'h0000_0001;
                end
                3: rand_div_operand = 32'h8000_0000;
                4: rand_div_operand = val_at($urandom_range(0, N_VALS - 1));
                default: begin
                    lo  = 16'($urandom());
                    sgn = 1'($urandom());
                    rand_div_operand = sgn ? {{16{lo[15]}}, lo} : {16'd0, lo};
                end
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Driver / checker tasks.  Convention: every task runs on negedges; the
    // stimulus written at a negedge is latched by the next posedge, so the
    // completion of an operation issued at negedge N appears at negedge
    // N+latency (latency = 1 for ALU/SMUL, MUL_LATENCY for MUL).
    //-------------------------------------------------------------------------
    task automatic clear_all();
        for (int d = 0; d < 4; d++) begin
            iv[d] = 1'b0;
            rq[d] = '0;
            km[d] = '0;
        end
    endtask

    task automatic drive(input logic [1:0] d, input op_t op,
                         input logic [31:0] a, b, im, pc,
                         input logic [3:0] slot);
        begin
            rq[d] = '0;
            rq[d].tag.slot_index = slot;
            rq[d].op    = op;
            rq[d].src1  = a;
            rq[d].src2  = b;
            rq[d].imm   = im;
            rq[d].pc    = pc;
            iv[d]       = 1'b1;
        end
    endtask

    task automatic check_completion(input logic [1:0] d, input logic [3:0] slot,
                                    input logic [31:0] exp, input string what);
        begin
            checks = checks + 1;
            if (cp[d].tag.slot_index !== slot)
                record_error($sformatf("%s: tag %0d expected %0d",
                                       what, cp[d].tag.slot_index, slot));
            if (cp[d].result !== exp)
                record_error($sformatf("%s: result %08x expected %08x",
                                       what, cp[d].result, exp));
            if (cp[d].exception !== 1'b0)
                record_error($sformatf("%s: exception must be 0", what));
            if (cp[d].cause !== EXC_NONE)
                record_error($sformatf("%s: cause %08x must be EXC_NONE",
                                       what, cp[d].cause));
            if (cp[d].tval !== 32'd0)
                record_error($sformatf("%s: tval %08x must be 0", what, cp[d].tval));
        end
    endtask

    // One isolated operation: issue, wait for its single completion, verify
    // tag/result/sideband, then verify the pulse does not repeat.
    task automatic run_one(input logic [1:0] d, input op_t op,
                           input logic [31:0] a, b, im, pc,
                           input logic [3:0] slot, input logic [31:0] exp,
                           input int max_wait, input string what);
        int c;
        begin
            drive(d, op, a, b, im, pc, slot);
            if (cv[d]) $fatal(1, "%s: completion before the issue edge", what);
            @(negedge clk);                        // c = 1: one cycle after issue
            iv[d] = 1'b0;
            c = 1;
            while (!cv[d]) begin
                if (c >= max_wait)
                    $fatal(1, "%s: no completion after %0d cycles", what, c);
                @(negedge clk);
                c = c + 1;
            end
            check_completion(d, slot, exp, what);
            @(negedge clk);
            if (cv[d]) record_error($sformatf("%s: duplicate completion", what));
            @(negedge clk);
            if (cv[d]) record_error($sformatf("%s: late duplicate completion", what));
        end
    endtask

    // Divider variant: also checks the busy-side can_accept behaviour.  The
    // unit has no data fast path (documented FREE-05 choice), so can_accept
    // must be low from the cycle after issue until the final cycle, then high.
    task automatic run_one_div(input op_t op, input logic [31:0] a, b,
                               input logic [3:0] slot, input logic [31:0] exp,
                               input string what);
        int c;
        begin
            if (!div_can_accept) $fatal(1, "%s: can_accept low while idle", what);
            drive(D_DIV, op, a, b, 32'd0, 32'd0, slot);
            if (cv[D_DIV]) $fatal(1, "%s: completion before the issue edge", what);
            @(negedge clk);
            iv[D_DIV] = 1'b0;
            if (div_can_accept)
                record_error($sformatf("%s: can_accept high while busy", what));
            if (cv[D_DIV])
                record_error($sformatf("%s: completion in the issue cycle", what));
            c = 1;
            while (!cv[D_DIV]) begin
                if (c >= DIV_MAX_WAIT)
                    $fatal(1, "%s: divider timeout after %0d cycles", what, c);
                @(negedge clk);
                c = c + 1;
            end
            if (div_lat_obs == 0) div_lat_obs = c;
            if (!div_can_accept)
                record_error($sformatf("%s: can_accept low in the final cycle", what));
            check_completion(D_DIV, slot, exp, what);
            @(negedge clk);
            if (cv[D_DIV]) record_error($sformatf("%s: duplicate completion", what));
            @(negedge clk);
            if (cv[D_DIV]) record_error($sformatf("%s: late duplicate completion", what));
        end
    endtask

    // Back-to-back (II = 1) burst with a shift-register scoreboard: the op
    // issued 'lat' cycles ago is the one completing now.  kind selects the
    // generator: 0 = random ALU op, 1 = SMUL (fit16 MUL), 2 = full MUL.
    task automatic burst(input logic [1:0] d, input int lat, input int n, input int kind);
        logic [31:0] sb_res [0:3];
        logic [3:0]  sb_tag [0:3];
        logic [31:0] a, b, im, pc, exp;
        logic [3:0]  tag;
        op_t         op;
        begin
            for (int i = 0; i < 4; i++) begin
                sb_res[i] = 32'd0;
                sb_tag[i] = 4'd0;
            end
            for (int k = 0; k < n + lat; k++) begin
                // ---- check the completion of the op issued 'lat' cycles ago
                if (k >= lat) begin
                    checks = checks + 1;
                    if (!cv[d]) begin
                        record_error($sformatf("burst kind=%0d: missing completion at k=%0d",
                                               kind, k));
                    end else begin
                        if (cp[d].tag.slot_index !== sb_tag[lat-1])
                            record_error($sformatf("burst kind=%0d k=%0d: tag %0d expected %0d",
                                                   kind, k, cp[d].tag.slot_index,
                                                   sb_tag[lat-1]));
                        if (cp[d].result !== sb_res[lat-1])
                            record_error($sformatf("burst kind=%0d k=%0d: result %08x expected %08x",
                                                   kind, k, cp[d].result, sb_res[lat-1]));
                    end
                end else if (cv[d]) begin
                    record_error($sformatf("burst kind=%0d k=%0d: completion before any issue",
                                           kind, k));
                end
                // ---- drive the next request (or drain the pipeline)
                if (k < n) begin
                    case (kind)
                        0: begin                        // ALU, random op
                            op = rand_alu_op();
                            a  = rnd32();
                            b  = rnd32();
                            pc = 32'h8000_0000 + 32'(k * 4);
                            im = rnd32();
                            if (alu_is_imm(op)) b = im; // I-type operand B
                            exp = alu_ref(op, a, b, im, pc);
                            n_alu_rand = n_alu_rand + 1;
                        end
                        1: begin                        // SMUL, eligible operands
                            op = OP_MUL;
                            a  = rand_fit16();
                            b  = rand_fit16();
                            im = 32'd0;
                            pc = 32'd0;
                            exp = mul_full(OP_MUL, a, b)[31:0];
                            n_smul_rand = n_smul_rand + 1;
                        end
                        default: begin                  // full MUL pipeline
                            op = rand_mul_op();
                            a  = rnd32();
                            b  = rnd32();
                            im = 32'd0;
                            pc = 32'd0;
                            exp = mul_ref(op, a, b);
                            n_mul_rand = n_mul_rand + 1;
                        end
                    endcase
                    tag = 4'(k);
                    drive(d, op, a, b, im, pc, tag);
                end else begin
                    iv[d] = 1'b0;
                    tag   = 4'd0;
                    exp   = 32'd0;
                end
                for (int i = 3; i > 0; i--) begin
                    sb_res[i] = sb_res[i-1];
                    sb_tag[i] = sb_tag[i-1];
                end
                sb_res[0] = exp;
                sb_tag[0] = tag;
                @(negedge clk);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Test sequence
    //-------------------------------------------------------------------------
    initial begin
        op_t         op;
        logic [31:0] a, b, im, pc, exp;
        int          i, j, c;

        $display("tb_fu_exec: fu_alu / fu_smul / fu_mul / fu_div unit test (MUL_LATENCY=%0d)",
                 MUL_LAT);
        rng_init();
        clear_all();

        //---------------------------------------------------------------------
        // 0. Reset behaviour
        //---------------------------------------------------------------------
        rst = 1'b1;
        repeat (4) @(negedge clk);
        if (cv[D_ALU] || cv[D_SMUL] || cv[D_MUL] || cv[D_DIV])
            $fatal(1, "reset: completion_valid asserted during reset");
        if (!div_can_accept)
            $fatal(1, "reset: div can_accept low out of reset");
        rst = 1'b0;
        @(negedge clk);
        if (cv[D_ALU] || cv[D_SMUL] || cv[D_MUL] || cv[D_DIV])
            $fatal(1, "reset: completion_valid asserted after reset release");

        //---------------------------------------------------------------------
        // 1. Fixed-seed RNG health check (failures must reproduce)
        //---------------------------------------------------------------------
        begin
            int unsigned s1, s2, s3;
            s1 = $urandom();
            s2 = $urandom();
            s3 = $urandom();
            if ((s1 == s2) && (s2 == s3))
                $fatal(1, "RNG: urandom() is not advancing");
        end

        //---------------------------------------------------------------------
        // 2. fu_alu: every op over the full boundary operand cross product.
        //    imm is driven with the same value as src2 for I-type ops, so the
        //    stimulus is valid for either operand-presentation convention; the
        //    RTL's documented convention is imm (see its header).
        //---------------------------------------------------------------------
        for (i = 0; i < N_ALU_OPS; i++) begin
            op = alu_op_at(i);
            for (j = 0; j < N_VALS; j++) begin
                for (int k = 0; k < N_VALS; k++) begin
                    a   = val_at(j);
                    b   = val_at(k);
                    im  = b;
                    pc  = 32'h8000_0000 + 32'((j * N_VALS + k) * 4);
                    exp = alu_ref(op, a, b, im, pc);
                    run_one(D_ALU, op, a, b, im, pc, 4'(j + k), exp,
                            ALU_MAX_WAIT,
                            $sformatf("alu op%0d a%0d b%0d", i, j, k));
                end
            end
        end

        //---------------------------------------------------------------------
        // 3. fu_alu: II = 1 back-to-back issue (random ops/operands)
        //---------------------------------------------------------------------
        burst(D_ALU, 1, 400, 0);

        //---------------------------------------------------------------------
        // 4. fu_smul: four independent-fit combinations over the 0x7FFF /
        //    0x8000 / 0xFFFF boundaries (u16 x u16, u16 x s16, s16 x u16,
        //    s16 x s16)
        //---------------------------------------------------------------------
        for (i = 0; i < N_SMUL_ED; i++) begin
            for (j = 0; j < N_SMUL_ED; j++) begin
                a   = smul_edge_at(i);
                b   = smul_edge_at(j);
                exp = mul_full(OP_MUL, a, b)[31:0];
                run_one(D_SMUL, OP_MUL, a, b, 32'd0, 32'd0, 4'(i + j), exp,
                        SMUL_MAX_WAIT, $sformatf("smul fit%0d x fit%0d", i, j));
            end
        end

        //---------------------------------------------------------------------
        // 5. fu_smul: 100000 random eligible pairs, II = 1, against the low
        //    32 bits of the full 64-bit product
        //---------------------------------------------------------------------
        burst(D_SMUL, 1, 100000, 1);

        //---------------------------------------------------------------------
        // 6. fu_mul: directed edge cases for all four multiply ops
        //---------------------------------------------------------------------
        for (i = 0; i < 4; i++) begin
            case (i)
                0: op = OP_MUL;
                1: op = OP_MULH;
                2: op = OP_MULHSU;
                default: op = OP_MULHU;
            endcase
            for (j = 0; j < N_MUL_ED; j++) begin
                for (int k = 0; k < N_MUL_ED; k++) begin
                    a = mul_edge_at(j);
                    b = mul_edge_at(k);
                    run_one(D_MUL, op, a, b, 32'd0, 32'd0, 4'(j + k),
                            mul_ref(op, a, b), MUL_MAX_WAIT,
                            $sformatf("mul op%0d a%0d b%0d", i, j, k));
                end
            end
        end

        //---------------------------------------------------------------------
        // 7. fu_mul: 100000 random pairs, back-to-back (II = 1, fixed latency)
        //---------------------------------------------------------------------
        burst(D_MUL, MUL_LAT, 100000, 2);

        //---------------------------------------------------------------------
        // 8. Kill in the same cycle as the completion: ALU and SMUL.  The
        //    completion cycle of a latency-1 unit is the first negedge after
        //    the issue edge.
        //---------------------------------------------------------------------
        drive(D_ALU, OP_ADD, 32'h0000_0010, 32'h0000_0020, 32'd0, 32'd0, 4'd5);
        @(negedge clk);
        iv[D_ALU] = 1'b0;
        km[D_ALU][5] = 1'b1;
        #1;
        if (cv[D_ALU])
            record_error("alu kill: completion not suppressed in the kill cycle");
        @(negedge clk);
        km[D_ALU] = '0;
        if (cv[D_ALU]) record_error("alu kill: completion after the kill");
        for (i = 0; i < 4; i++) begin
            @(negedge clk);
            if (cv[D_ALU]) record_error("alu kill: late completion");
        end

        drive(D_SMUL, OP_MUL, 32'h0000_0003, 32'hFFFF_FFFB, 32'd0, 32'd0, 4'd6);
        @(negedge clk);
        iv[D_SMUL] = 1'b0;
        km[D_SMUL][6] = 1'b1;
        #1;
        if (cv[D_SMUL])
            record_error("smul kill: completion not suppressed in the kill cycle");
        @(negedge clk);
        km[D_SMUL] = '0;
        if (cv[D_SMUL]) record_error("smul kill: completion after the kill");
        for (i = 0; i < 4; i++) begin
            @(negedge clk);
            if (cv[D_SMUL]) record_error("smul kill: late completion");
        end

        //---------------------------------------------------------------------
        // 9. MUL: kill operation A (tag 3) while it is in the pipeline, with
        //    operation B (tag 7) issued on the next cycle.  Only A may be
        //    cleared; B must still complete with the correct result.
        //---------------------------------------------------------------------
        begin
            logic [31:0] aA, bA, aB, bB, expB;
            aA = 32'h1234_5678;
            bA = 32'h9ABC_DEF0;
            aB = 32'h0000_FFFF;
            bB = 32'h0001_0000;
            expB = mul_ref(OP_MUL, aB, bB);
            drive(D_MUL, OP_MUL, aA, bA, 32'd0, 32'd0, 4'd3);
            @(negedge clk);
            drive(D_MUL, OP_MUL, aB, bB, 32'd0, 32'd0, 4'd7);   // II = 1
            km[D_MUL][3] = 1'b1;                                // kill A only
            @(negedge clk);
            km[D_MUL] = '0;
            iv[D_MUL] = 1'b0;
            for (i = 2; i <= MUL_LAT + 3; i++) begin
                if (i == (MUL_LAT + 1)) begin
                    if (!cv[D_MUL])
                        record_error("mul kill: surviving operation did not complete");
                    else
                        check_completion(D_MUL, 4'd7, expB, "mul kill: surviving op");
                end else if (cv[D_MUL]) begin
                    record_error($sformatf("mul kill: unexpected completion at k=%0d", i));
                end
                @(negedge clk);
            end
        end

        //---------------------------------------------------------------------
        // 10. MUL: kill in the completion cycle
        //---------------------------------------------------------------------
        begin
            logic [31:0] aC, bC;
            aC = 32'hDEAD_BEEF;
            bC = 32'h0000_1000;
            drive(D_MUL, OP_MULHU, aC, bC, 32'd0, 32'd0, 4'd9);
            @(negedge clk);
            iv[D_MUL] = 1'b0;
            for (i = 1; i < MUL_LAT; i++) @(negedge clk);   // completion cycle
            km[D_MUL][9] = 1'b1;
            #1;
            if (cv[D_MUL])
                record_error("mul same-cycle kill: completion not suppressed");
            @(negedge clk);
            km[D_MUL] = '0;
            if (cv[D_MUL])
                record_error("mul same-cycle kill: completion after the kill");
            for (i = 0; i < 4; i++) begin
                @(negedge clk);
                if (cv[D_MUL]) record_error("mul same-cycle kill: late completion");
            end
        end

        //---------------------------------------------------------------------
        // 11. DIV edge cases: 0, +-1, INT_MIN/-1, divisor 0 (all four ops)
        //---------------------------------------------------------------------
        for (i = 0; i < N_DIV_ED; i++) begin
            a = div_edge(i, 0);
            b = div_edge(i, 1);
            for (j = 0; j < 4; j++) begin
                case (j)
                    0: op = OP_DIV;
                    1: op = OP_DIVU;
                    2: op = OP_REM;
                    default: op = OP_REMU;
                endcase
                run_one_div(op, a, b, 4'(i + j), div_ref(op, a, b),
                            $sformatf("div edge%0d op%0d", i, j));
            end
        end
        $display("tb_fu_exec: observed DIV latency = %0d cycles", div_lat_obs);

        //---------------------------------------------------------------------
        // 12. DIV random pairs (>= 20000) against the reference model
        //---------------------------------------------------------------------
        for (i = 0; i < 20000; i++) begin
            op = rand_div_op();
            a  = rand_div_operand();
            b  = rand_div_operand();
            run_one_div(op, a, b, 4'(i), div_ref(op, a, b),
                        $sformatf("div rand%0d", i));
            n_div_rand = n_div_rand + 1;
        end

        //---------------------------------------------------------------------
        // 13. DIV can_accept handover: the new request is latched on the same
        //     edge as the final completion of the previous operation.
        //---------------------------------------------------------------------
        begin
            logic [31:0] a1, b1, a2, b2;
            a1 = 32'h0000_00F0;
            b1 = 32'h0000_0007;                       // 240 / 7
            a2 = 32'hFFFF_FF00;
            b2 = 32'h0000_000B;                       // -256 / 11
            drive(D_DIV, OP_DIVU, a1, b1, 32'd0, 32'd0, 4'd4);
            @(negedge clk);
            iv[D_DIV] = 1'b0;
            c = 1;
            while (!cv[D_DIV]) begin
                if (c >= DIV_MAX_WAIT) $fatal(1, "div handover: first op timeout");
                @(negedge clk);
                c = c + 1;
            end
            if (!div_can_accept)
                record_error("div handover: can_accept low in the final cycle");
            check_completion(D_DIV, 4'd4, div_ref(OP_DIVU, a1, b1), "div handover op1");
            drive(D_DIV, OP_DIVU, a2, b2, 32'd0, 32'd0, 4'd5);   // same edge
            @(negedge clk);
            iv[D_DIV] = 1'b0;
            c = 1;
            while (!cv[D_DIV]) begin
                if (c >= DIV_MAX_WAIT) $fatal(1, "div handover: second op timeout");
                @(negedge clk);
                c = c + 1;
            end
            check_completion(D_DIV, 4'd5, div_ref(OP_DIVU, a2, b2), "div handover op2");
            @(negedge clk);
            if (cv[D_DIV]) record_error("div handover: extra completion");
        end

        //---------------------------------------------------------------------
        // 14. Kill of an in-flight DIV, then a new DIV that must complete
        //---------------------------------------------------------------------
        begin
            logic [31:0] a1, b1;
            a1 = 32'h0000_00F0;
            b1 = 32'h0000_0007;
            drive(D_DIV, OP_DIVU, a1, b1, 32'd0, 32'd0, 4'd1);
            @(negedge clk);
            iv[D_DIV] = 1'b0;
            repeat (4) @(negedge clk);                // in flight, mid-iteration
            km[D_DIV][1] = 1'b1;
            @(negedge clk);
            km[D_DIV] = '0;
            if (cv[D_DIV]) record_error("div kill: completion after the kill");
            if (!div_can_accept)
                record_error("div kill: can_accept not restored after the abort");
            for (i = 0; i < (DIV_MAX_WAIT - 8); i++) begin
                @(negedge clk);
                if (cv[D_DIV]) record_error("div kill: stale completion");
            end
            run_one_div(OP_DIV, 32'hFFFF_FF38, 32'h0000_0005, 4'd2,
                        div_ref(OP_DIV, 32'hFFFF_FF38, 32'h0000_0005),
                        "div after kill");
        end

        //---------------------------------------------------------------------
        // 15. Kill in the DIV completion cycle (uses the observed latency)
        //---------------------------------------------------------------------
        if (div_lat_obs > 1) begin
            logic [31:0] a1, b1;
            a1 = 32'h0000_0BB8;
            b1 = 32'h0000_000D;
            drive(D_DIV, OP_REMU, a1, b1, 32'd0, 32'd0, 4'd8);
            @(negedge clk);
            iv[D_DIV] = 1'b0;
            for (i = 1; i < div_lat_obs; i++) @(negedge clk);
            km[D_DIV][8] = 1'b1;
            #1;
            if (cv[D_DIV])
                record_error("div same-cycle kill: completion not suppressed");
            if (!div_can_accept)
                record_error("div same-cycle kill: can_accept low in the final cycle");
            @(negedge clk);
            km[D_DIV] = '0;
            if (cv[D_DIV])
                record_error("div same-cycle kill: completion after the kill");
            for (i = 0; i < 4; i++) begin
                @(negedge clk);
                if (cv[D_DIV]) record_error("div same-cycle kill: late completion");
            end
        end else begin
            $fatal(1, "div: observed latency %0d is not usable", div_lat_obs);
        end

        //---------------------------------------------------------------------
        // 16. Final report
        //---------------------------------------------------------------------
        if (n_smul_rand < 100000)
            $fatal(1, "coverage: only %0d random SMUL pairs", n_smul_rand);
        if (n_mul_rand < 100000)
            $fatal(1, "coverage: only %0d random MUL pairs", n_mul_rand);
        if (n_div_rand < 20000)
            $fatal(1, "coverage: only %0d random DIV pairs", n_div_rand);
        if (errors != 0)
            $fatal(1, "tb_fu_exec: %0d error(s) in %0d checks", errors, checks);

        $display("tb_fu_exec: %0d ALU random burst ops, %0d checks, %0d errors",
                 n_alu_rand, checks, errors);
        $display("ALL TESTS PASSED: fu_alu (all 22 RV32I ops over the boundary table, II=1 burst), fu_smul (4 fit classes + %0d random eligible pairs vs 64-bit reference), fu_mul (MUL/MULH/MULHSU/MULHU edge cases + %0d random pairs vs 128-bit reference at MUL_LATENCY=%0d, II=1), fu_div (%0d edge cases + %0d random pairs vs reference, can_accept handover, kill abort + restart), kill in the completion cycle (ALU/SMUL/MUL/DIV), MUL per-stage kill with a surviving op, reset and exactly-once completion checks",
                 n_smul_rand, n_mul_rand, MUL_LAT, N_DIV_ED * 4, n_div_rand);
        $finish;
    end

endmodule



