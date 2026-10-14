`timescale 1ns / 1ps

//=============================================================================
// ARES core verification - self-checking unit test for be_decode.sv (B02)
//-----------------------------------------------------------------------------
// Standalone, purely combinational check of one decode lane against
// backend.md 5 / 16.2, frontend_backend_contract.md 2.1, docs/c0_decisions.md
// D-C0-01 / D-C0-09 / D-C0-13 and docs/implementation_plan.md 6.1 (B02):
//
//   * hand-assembled bit-exact encodings for every RV32IM instruction, every
//     Zicsr form, ECALL / EBREAK / MRET and FENCE
//   * op / fu_type / rd / rd_wen / rs / src_used / imm / csr_addr /
//     csr_write_en / is_serializing / is_cfi / is_branch / is_load / is_store /
//     is_csr / is_fence against explicit expected values (rd / rs1 / rs2 are
//     checked against the raw instruction fields, the contract for valid lanes)
//   * immediate generation for all five formats, including negative sign
//     extension (I/S/B/J) and the Zicsr uimm[4:0] zero extension
//   * CFI classification for JAL / JALR with rd and rs1 = x1/x5 and for every
//     branch, plus the predecode cross-check (is_cfi / cfi_type)
//   * decode_err for unknown opcodes, FENCE, unsupported funct3/funct7
//     combinations and unsupported CSR addresses (HAS_MISA/HAS_MTVAL/
//     HAS_MCYCLE are 0, so 0x301/0x343/0xB00/0xB80 must fail)
//   * an invalid lane: decode_err = 0 and every output defined (0 / OP_ILLEGAL)
//     even with hostile iq contents
//   * a randomised cross-check against an independent reference decoder, with
//     the fixed seed SEED so every failure reproduces exactly
//
// Harness: standalone top (own clock, no DPI, no test image).  Build/run:
//   <tool> --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_decode \
//       --Mdir /tmp/obj_tb_decode -o /tmp/tb_decode \
//       rtl/common/ares_pkg.sv rtl/backend/be_decode.sv \
//       rtl/backend/test/unit/tb_decode.sv && /tmp/tb_decode
//
// FREE items exercised: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_decode;
    import ares_pkg::*;
    import fe_pkg::*;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    iq_entry_t   iq;
    logic        decode_err;
    logic        valid;
    fu_type_t    fu_type;
    op_t         op;
    logic [4:0]  rd;
    logic        rd_wen;
    logic [4:0]  rs1;
    logic        src1_used;
    logic [4:0]  rs2;
    logic        src2_used;
    logic [31:0] imm;
    logic [11:0] csr_addr;
    logic        csr_write_en;
    logic        is_serializing;
    logic        is_cfi;
    logic        is_branch;
    cfi_type_t   actual_cfi_type;
    logic        is_load;
    logic        is_store;
    logic        is_csr;
    logic        is_fence;

    be_decode dut (
        .iq             (iq),
        .decode_err     (decode_err),
        .valid          (valid),
        .fu_type        (fu_type),
        .op             (op),
        .rd             (rd),
        .rd_wen         (rd_wen),
        .rs1            (rs1),
        .src1_used      (src1_used),
        .rs2            (rs2),
        .src2_used      (src2_used),
        .imm            (imm),
        .csr_addr       (csr_addr),
        .csr_write_en   (csr_write_en),
        .is_serializing (is_serializing),
        .is_cfi         (is_cfi),
        .is_branch      (is_branch),
        .actual_cfi_type(actual_cfi_type),
        .is_load        (is_load),
        .is_store       (is_store),
        .is_csr         (is_csr),
        .is_fence       (is_fence)
    );

    //-------------------------------------------------------------------------
    // Clock.  be_decode is combinational; the clock gives this standalone bench
    // a timebase (and keeps it a normal Verilator top with --timing).
    //-------------------------------------------------------------------------
    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // Bookkeeping / seed
    //-------------------------------------------------------------------------
    int unsigned errors;
    int unsigned checks;
    int unsigned seed_echo;

    localparam int unsigned SEED       = 32'hC0FFEE01;  // fixed: reproducible
    localparam int unsigned RAND_ITERS = 3000;

    //-------------------------------------------------------------------------
    // Expected decode result.  rd / rs1 / rs2 are not stored here: for a valid
    // lane the contract is "raw instruction field", so the checker compares
    // them against inst[11:7] / inst[19:15] / inst[24:20] directly.
    //-------------------------------------------------------------------------
    typedef struct packed {
        op_t         op;
        fu_type_t    fu;
        logic        rd_wen;
        logic        src1_used;
        logic        src2_used;
        logic [31:0] imm;
        logic [11:0] csr_addr;
        logic        csr_write_en;
        logic        is_serializing;
        logic        is_cfi;
        logic        is_branch;
        cfi_type_t   cfi_type;
        logic        is_load;
        logic        is_store;
        logic        is_csr;
        logic        is_fence;
        logic        err;
    } exp_t;

    exp_t e;    // scratch expectation used by the directed phases

    //-------------------------------------------------------------------------
    // Expectation builders
    //-------------------------------------------------------------------------
    function automatic exp_t exp_zero();
        exp_t z;
        begin
            z         = '0;
            z.op      = OP_ILLEGAL;
            z.fu      = FU_ALU0;
            z.cfi_type = CFI_NONE;
            return z;
        end
    endfunction

    function automatic exp_t exp_err(input op_t o);
        exp_t z;
        begin
            z     = exp_zero();
            z.op  = o;
            z.err = 1'b1;
            return z;
        end
    endfunction

    function automatic exp_t exp_upper(input op_t o, input logic [31:0] im);
        exp_t z;
        begin
            z        = exp_zero();
            z.op     = o;
            z.fu     = FU_ALU0;
            z.rd_wen = 1'b1;
            z.imm    = im;
            return z;
        end
    endfunction

    function automatic exp_t exp_ri(input op_t o, input logic [31:0] im);
        exp_t z;
        begin
            z           = exp_zero();
            z.op        = o;
            z.fu        = FU_ALU0;
            z.rd_wen    = 1'b1;
            z.src1_used = 1'b1;
            z.imm       = im;
            return z;
        end
    endfunction

    function automatic exp_t exp_rr(input op_t o, input fu_type_t f);
        exp_t z;
        begin
            z           = exp_zero();
            z.op        = o;
            z.fu        = f;
            z.rd_wen    = 1'b1;
            z.src1_used = 1'b1;
            z.src2_used = 1'b1;
            return z;
        end
    endfunction

    function automatic exp_t exp_jump(input op_t o, input logic [31:0] im,
                                      input cfi_type_t ct);
        exp_t z;
        begin
            z            = exp_zero();
            z.op         = o;
            z.fu         = FU_BRU;
            z.rd_wen     = 1'b1;
            z.src1_used  = (o == OP_JALR) ? 1'b1 : 1'b0;
            z.imm        = im;
            z.is_cfi     = 1'b1;
            z.is_branch  = 1'b1;
            z.cfi_type   = ct;
            return z;
        end
    endfunction

    function automatic exp_t exp_branch(input op_t o, input logic [31:0] im);
        exp_t z;
        begin
            z           = exp_zero();
            z.op        = o;
            z.fu        = FU_BRU;
            z.src1_used = 1'b1;
            z.src2_used = 1'b1;
            z.imm       = im;
            z.is_cfi    = 1'b1;
            z.is_branch = 1'b1;
            z.cfi_type  = CFI_COND_BRANCH;
            return z;
        end
    endfunction

    function automatic exp_t exp_load(input op_t o, input logic [31:0] im);
        exp_t z;
        begin
            z           = exp_zero();
            z.op        = o;
            z.fu        = FU_LSU;
            z.rd_wen    = 1'b1;
            z.src1_used = 1'b1;
            z.is_load   = 1'b1;
            z.imm       = im;
            return z;
        end
    endfunction

    function automatic exp_t exp_store(input op_t o, input logic [31:0] im);
        exp_t z;
        begin
            z           = exp_zero();
            z.op        = o;
            z.fu        = FU_LSU;
            z.src1_used = 1'b1;
            z.src2_used = 1'b1;
            z.is_store  = 1'b1;
            z.imm       = im;
            return z;
        end
    endfunction

    function automatic exp_t exp_csr_reg(input op_t o, input logic [11:0] a,
                                         input logic we);
        exp_t z;
        begin
            z              = exp_zero();
            z.op           = o;
            z.fu           = FU_CSR;
            z.rd_wen       = 1'b1;
            z.src1_used    = 1'b1;
            z.is_csr       = 1'b1;
            z.is_serializing = 1'b1;
            z.csr_addr     = a;
            z.csr_write_en = we;
            return z;
        end
    endfunction

    function automatic exp_t exp_csr_imm(input op_t o, input logic [11:0] a,
                                         input logic [4:0] u, input logic we);
        exp_t z;
        begin
            z              = exp_zero();
            z.op           = o;
            z.fu           = FU_CSR;
            z.rd_wen       = 1'b1;
            z.src1_used    = 1'b0;
            z.is_csr       = 1'b1;
            z.is_serializing = 1'b1;
            z.csr_addr     = a;
            z.csr_write_en = we;
            z.imm          = {27'b0, u};
            return z;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Checkers
    //-------------------------------------------------------------------------
    task automatic fail2(input string name, input string field,
                         input logic [31:0] got, input logic [31:0] want);
        begin
            errors = errors + 1;
            $display("FAIL [%s]: %s = 0x%08x (%0d), expected 0x%08x (%0d)",
                     name, field, got, got, want, want);
        end
    endtask

    /* verilator lint_off UNUSEDSIGNAL */  // only inst[24:20]/[19:15]/[11:7] feed the rd/rs checks
    task automatic chk_valid(input string name, input logic [31:0] inst,
                             input exp_t want);
        begin
            checks = checks + 1;
            if (valid !== 1'b1)
                fail2(name, "valid", 32'(valid), 32'd1);
            if (op !== want.op)
                fail2(name, "op", 32'(op), 32'(want.op));
            if (fu_type !== want.fu)
                fail2(name, "fu_type", 32'(fu_type), 32'(want.fu));
            if (rd !== inst[11:7])
                fail2(name, "rd", {27'b0, rd}, {27'b0, inst[11:7]});
            if (rd_wen !== want.rd_wen)
                fail2(name, "rd_wen", 32'(rd_wen), 32'(want.rd_wen));
            if (rs1 !== inst[19:15])
                fail2(name, "rs1", {27'b0, rs1}, {27'b0, inst[19:15]});
            if (src1_used !== want.src1_used)
                fail2(name, "src1_used", 32'(src1_used), 32'(want.src1_used));
            if (rs2 !== inst[24:20])
                fail2(name, "rs2", {27'b0, rs2}, {27'b0, inst[24:20]});
            if (src2_used !== want.src2_used)
                fail2(name, "src2_used", 32'(src2_used), 32'(want.src2_used));
            if (imm !== want.imm)
                fail2(name, "imm", imm, want.imm);
            if (csr_addr !== want.csr_addr)
                fail2(name, "csr_addr", {20'b0, csr_addr}, {20'b0, want.csr_addr});
            if (csr_write_en !== want.csr_write_en)
                fail2(name, "csr_write_en", 32'(csr_write_en), 32'(want.csr_write_en));
            if (is_serializing !== want.is_serializing)
                fail2(name, "is_serializing", 32'(is_serializing), 32'(want.is_serializing));
            if (is_cfi !== want.is_cfi)
                fail2(name, "is_cfi", 32'(is_cfi), 32'(want.is_cfi));
            if (is_branch !== want.is_branch)
                fail2(name, "is_branch", 32'(is_branch), 32'(want.is_branch));
            if (actual_cfi_type !== want.cfi_type)
                fail2(name, "actual_cfi_type", 32'(actual_cfi_type), 32'(want.cfi_type));
            if (is_load !== want.is_load)
                fail2(name, "is_load", 32'(is_load), 32'(want.is_load));
            if (is_store !== want.is_store)
                fail2(name, "is_store", 32'(is_store), 32'(want.is_store));
            if (is_csr !== want.is_csr)
                fail2(name, "is_csr", 32'(is_csr), 32'(want.is_csr));
            if (is_fence !== want.is_fence)
                fail2(name, "is_fence", 32'(is_fence), 32'(want.is_fence));
            if (decode_err !== want.err)
                fail2(name, "decode_err", 32'(decode_err), 32'(want.err));
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // An invalid lane: decode_err = 0 and every output at its defined zero
    // (op = OP_ILLEGAL), whatever iq holds.
    task automatic chk_invalid(input string name);
        begin
            checks = checks + 1;
            if (valid !== 1'b0)              fail2(name, "valid", 32'(valid), 32'd0);
            if (decode_err !== 1'b0)         fail2(name, "decode_err", 32'(decode_err), 32'd0);
            if (op !== OP_ILLEGAL)           fail2(name, "op", 32'(op), 32'(OP_ILLEGAL));
            if (fu_type !== FU_ALU0)         fail2(name, "fu_type", 32'(fu_type), 32'(FU_ALU0));
            if (rd !== 5'd0)                 fail2(name, "rd", {27'b0, rd}, 32'd0);
            if (rd_wen !== 1'b0)             fail2(name, "rd_wen", 32'(rd_wen), 32'd0);
            if (rs1 !== 5'd0)                fail2(name, "rs1", {27'b0, rs1}, 32'd0);
            if (src1_used !== 1'b0)          fail2(name, "src1_used", 32'(src1_used), 32'd0);
            if (rs2 !== 5'd0)                fail2(name, "rs2", {27'b0, rs2}, 32'd0);
            if (src2_used !== 1'b0)          fail2(name, "src2_used", 32'(src2_used), 32'd0);
            if (imm !== 32'd0)               fail2(name, "imm", imm, 32'd0);
            if (csr_addr !== 12'd0)          fail2(name, "csr_addr", {20'b0, csr_addr}, 32'd0);
            if (csr_write_en !== 1'b0)       fail2(name, "csr_write_en", 32'(csr_write_en), 32'd0);
            if (is_serializing !== 1'b0)     fail2(name, "is_serializing", 32'(is_serializing), 32'd0);
            if (is_cfi !== 1'b0)             fail2(name, "is_cfi", 32'(is_cfi), 32'd0);
            if (is_branch !== 1'b0)          fail2(name, "is_branch", 32'(is_branch), 32'd0);
            if (actual_cfi_type !== CFI_NONE) fail2(name, "actual_cfi_type", 32'(actual_cfi_type), 32'(CFI_NONE));
            if (is_load !== 1'b0)            fail2(name, "is_load", 32'(is_load), 32'd0);
            if (is_store !== 1'b0)           fail2(name, "is_store", 32'(is_store), 32'd0);
            if (is_csr !== 1'b0)             fail2(name, "is_csr", 32'(is_csr), 32'd0);
            if (is_fence !== 1'b0)           fail2(name, "is_fence", 32'(is_fence), 32'd0);
        end
    endtask

    //-------------------------------------------------------------------------
    // Stimulus.  drive() uses the predecode of rtl/backend/test/fe_stub.sv
    // (contract 2.1); drive_pre() forces the predecode fields for the negative
    // cross-check tests.
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // predecode reads opcode + register fields only
    function automatic cfi_type_t classify(input logic [31:0] inst);
        logic [4:0] drd;
        logic [4:0] srs;
        begin
            drd = inst[11:7];
            srs = inst[19:15];
            case (inst[6:0])
                7'h6F:   classify = ((drd == 5'd1) || (drd == 5'd5))
                                    ? CFI_CALL : CFI_DIRECT_JUMP;
                7'h67:   classify = ((drd == 5'd1) || (drd == 5'd5)) ? CFI_CALL
                                  : (((srs == 5'd1) || (srs == 5'd5))
                                     ? CFI_RETURN : CFI_INDIRECT_JUMP);
                7'h63:   classify = CFI_COND_BRANCH;
                default: classify = CFI_NONE;
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic drive(input logic [31:0] inst, input logic vld = 1'b1);
        begin
            iq             = '0;
            iq.inst        = inst;
            iq.valid       = vld;
            iq.cfi_type    = classify(inst);
            iq.is_cfi      = (classify(inst) != CFI_NONE);
        end
    endtask

    task automatic drive_pre(input logic [31:0] inst, input cfi_type_t ct,
                             input logic iscfi);
        begin
            iq              = '0;
            iq.inst         = inst;
            iq.valid        = 1'b1;
            iq.cfi_type     = ct;
            iq.is_cfi       = iscfi;
        end
    endtask

    //-------------------------------------------------------------------------
    // Independent reference decoder + reference CSR legality, used by the
    // randomised phase (deliberately written separately from be_decode.sv).
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // each reference immediate reads only its own bits
    function automatic logic [31:0] r_imm_i(input logic [31:0] i);
        r_imm_i = {{20{i[31]}}, i[31:20]};
    endfunction
    function automatic logic [31:0] r_imm_s(input logic [31:0] i);
        r_imm_s = {{20{i[31]}}, i[31:25], i[11:7]};
    endfunction
    function automatic logic [31:0] r_imm_b(input logic [31:0] i);
        r_imm_b = {{19{i[31]}}, i[31], i[7], i[30:25], i[11:8], 1'b0};
    endfunction
    function automatic logic [31:0] r_imm_u(input logic [31:0] i);
        r_imm_u = {i[31:12], 12'b0};
    endfunction
    function automatic logic [31:0] r_imm_j(input logic [31:0] i);
        r_imm_j = {{11{i[31]}}, i[31], i[19:12], i[20], i[30:21], 1'b0};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic logic r_csr_legal(input logic [11:0] a);
        begin
            r_csr_legal = 1'b1;
            case (a)
                12'h300, 12'h304, 12'h305, 12'h340,
                12'h341, 12'h342, 12'h344, 12'hF14: r_csr_legal = 1'b1;
                12'h301: r_csr_legal = HAS_MISA;
                12'h343: r_csr_legal = HAS_MTVAL;
                12'hB00, 12'hB80: r_csr_legal = HAS_MCYCLE;
                default: r_csr_legal = 1'b0;
            endcase
        end
    endfunction

    function automatic exp_t ref_decode(input logic [31:0] inst);
        logic [6:0]  opc;
        logic [2:0]  f3;
        logic [6:0]  f7;
        logic [11:0] f12;
        logic [4:0]  drd;
        logic [4:0]  srs1;
        logic        rd_link;
        logic        rs1_link;
        logic        ok;
        exp_t        z;
        begin
            opc      = inst[6:0];
            f3       = inst[14:12];
            f7       = inst[31:25];
            f12      = inst[31:20];
            drd      = inst[11:7];
            srs1     = inst[19:15];
            rd_link  = (drd == 5'd1) || (drd == 5'd5);
            rs1_link = (srs1 == 5'd1) || (srs1 == 5'd5);
            z        = exp_zero();

            case (opc)
                7'h37: begin
                    z.op = OP_LUI; z.fu = FU_ALU0; z.rd_wen = 1'b1;
                    z.imm = r_imm_u(inst);
                end
                7'h17: begin
                    z.op = OP_AUIPC; z.fu = FU_ALU0; z.rd_wen = 1'b1;
                    z.imm = r_imm_u(inst);
                end
                7'h6F: begin
                    z.op = OP_JAL; z.fu = FU_BRU; z.rd_wen = 1'b1;
                    z.imm = r_imm_j(inst);
                    z.is_cfi = 1'b1; z.is_branch = 1'b1;
                    z.cfi_type = rd_link ? CFI_CALL : CFI_DIRECT_JUMP;
                end
                7'h67: begin
                    z.op = OP_JALR; z.fu = FU_BRU; z.rd_wen = 1'b1;
                    z.src1_used = 1'b1; z.imm = r_imm_i(inst);
                    z.is_cfi = 1'b1; z.is_branch = 1'b1;
                    z.cfi_type = rd_link ? CFI_CALL
                               : (rs1_link ? CFI_RETURN : CFI_INDIRECT_JUMP);
                end
                7'h63: begin
                    ok = 1'b1;
                    case (f3)
                        3'd0: z.op = OP_BEQ;
                        3'd1: z.op = OP_BNE;
                        3'd4: z.op = OP_BLT;
                        3'd5: z.op = OP_BGE;
                        3'd6: z.op = OP_BLTU;
                        3'd7: z.op = OP_BGEU;
                        default: ok = 1'b0;
                    endcase
                    if (ok) begin
                        z.fu = FU_BRU; z.src1_used = 1'b1; z.src2_used = 1'b1;
                        z.imm = r_imm_b(inst);
                        z.is_cfi = 1'b1; z.is_branch = 1'b1;
                        z.cfi_type = CFI_COND_BRANCH;
                    end else begin
                        z.op = OP_ILLEGAL; z.err = 1'b1;
                    end
                end
                7'h03: begin
                    ok = 1'b1;
                    case (f3)
                        3'd0: z.op = OP_LB;
                        3'd1: z.op = OP_LH;
                        3'd2: z.op = OP_LW;
                        3'd4: z.op = OP_LBU;
                        3'd5: z.op = OP_LHU;
                        default: ok = 1'b0;
                    endcase
                    if (ok) begin
                        z.fu = FU_LSU; z.rd_wen = 1'b1; z.src1_used = 1'b1;
                        z.is_load = 1'b1; z.imm = r_imm_i(inst);
                    end else begin
                        z.op = OP_ILLEGAL; z.err = 1'b1;
                    end
                end
                7'h23: begin
                    ok = 1'b1;
                    case (f3)
                        3'd0: z.op = OP_SB;
                        3'd1: z.op = OP_SH;
                        3'd2: z.op = OP_SW;
                        default: ok = 1'b0;
                    endcase
                    if (ok) begin
                        z.fu = FU_LSU; z.src1_used = 1'b1; z.src2_used = 1'b1;
                        z.is_store = 1'b1; z.imm = r_imm_s(inst);
                    end else begin
                        z.op = OP_ILLEGAL; z.err = 1'b1;
                    end
                end
                7'h13: begin
                    ok = 1'b1;
                    case (f3)
                        3'd0: z.op = OP_ADDI;
                        3'd2: z.op = OP_SLTI;
                        3'd3: z.op = OP_SLTIU;
                        3'd4: z.op = OP_XORI;
                        3'd6: z.op = OP_ORI;
                        3'd7: z.op = OP_ANDI;
                        3'd1: if (f7 == 7'b0000000) z.op = OP_SLLI; else ok = 1'b0;
                        3'd5: z.op = inst[30] ? OP_SRAI : OP_SRLI;
                        default: ok = 1'b0;
                    endcase
                    if (ok) begin
                        z.fu = FU_ALU0; z.rd_wen = 1'b1; z.src1_used = 1'b1;
                        z.imm = r_imm_i(inst);
                    end else begin
                        z.op = OP_ILLEGAL; z.err = 1'b1;
                    end
                end
                7'h33: begin
                    ok = 1'b1;
                    case (f7)
                        7'b0000000: begin
                            z.fu = FU_ALU0;
                            case (f3)
                                3'd0: z.op = OP_ADD;
                                3'd1: z.op = OP_SLL;
                                3'd2: z.op = OP_SLT;
                                3'd3: z.op = OP_SLTU;
                                3'd4: z.op = OP_XOR;
                                3'd5: z.op = OP_SRL;
                                3'd6: z.op = OP_OR;
                                default: z.op = OP_AND;
                            endcase
                        end
                        7'b0100000: begin
                            z.fu = FU_ALU0;
                            case (f3)
                                3'd0: z.op = OP_SUB;
                                3'd5: z.op = OP_SRA;
                                default: ok = 1'b0;
                            endcase
                        end
                        7'b0000001: begin
                            case (f3)
                                3'd0: begin z.op = OP_MUL;    z.fu = FU_MUL; end
                                3'd1: begin z.op = OP_MULH;   z.fu = FU_MUL; end
                                3'd2: begin z.op = OP_MULHSU; z.fu = FU_MUL; end
                                3'd3: begin z.op = OP_MULHU;  z.fu = FU_MUL; end
                                3'd4: begin z.op = OP_DIV;    z.fu = FU_DIV; end
                                3'd5: begin z.op = OP_DIVU;   z.fu = FU_DIV; end
                                3'd6: begin z.op = OP_REM;    z.fu = FU_DIV; end
                                default: begin z.op = OP_REMU; z.fu = FU_DIV; end
                            endcase
                        end
                        default: ok = 1'b0;
                    endcase
                    if (ok) begin
                        z.rd_wen = 1'b1; z.src1_used = 1'b1; z.src2_used = 1'b1;
                    end else begin
                        z.op = OP_ILLEGAL; z.fu = FU_ALU0; z.err = 1'b1;
                    end
                end
                7'h73: begin
                    case (f3)
                        3'd0: begin
                            case (f12)
                                12'h000: begin
                                    z.op = OP_ECALL; z.fu = FU_CSR;
                                    z.is_serializing = 1'b1;
                                end
                                12'h001: begin
                                    z.op = OP_EBREAK; z.fu = FU_ALU0;
                                end
                                12'h302: begin
                                    z.op = OP_MRET; z.fu = FU_CSR;
                                    z.is_serializing = 1'b1;
                                end
                                default: z.err = 1'b1;
                            endcase
                        end
                        3'd1, 3'd2, 3'd3: begin
                            if (r_csr_legal(f12)) begin
                                z.op = (f3 == 3'd1) ? OP_CSRRW
                                     : (f3 == 3'd2) ? OP_CSRRS : OP_CSRRC;
                                z.fu = FU_CSR; z.rd_wen = 1'b1;
                                z.src1_used = 1'b1; z.is_csr = 1'b1;
                                z.is_serializing = 1'b1; z.csr_addr = f12;
                                z.csr_write_en = (f3 == 3'd1) ? 1'b1
                                               : (srs1 != 5'd0);
                            end else begin
                                z.err = 1'b1;
                            end
                        end
                        3'd5, 3'd6, 3'd7: begin
                            if (r_csr_legal(f12)) begin
                                z.op = (f3 == 3'd5) ? OP_CSRRWI
                                     : (f3 == 3'd6) ? OP_CSRRSI : OP_CSRRCI;
                                z.fu = FU_CSR; z.rd_wen = 1'b1;
                                z.is_csr = 1'b1; z.is_serializing = 1'b1;
                                z.csr_addr = f12;
                                z.csr_write_en = (f3 == 3'd5) ? 1'b1
                                               : (srs1 != 5'd0);
                                z.imm = {27'b0, srs1};
                            end else begin
                                z.err = 1'b1;
                            end
                        end
                        default: z.err = 1'b1;
                    endcase
                end
                7'h0F: begin
                    z.op = OP_FENCE; z.is_fence = 1'b1; z.err = 1'b1;
                end
                default: z.err = 1'b1;
            endcase
            ref_decode = z;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Randomised instruction generator (bias towards v1-legal encodings, with
    // a steady tail of unsupported ones).
    //-------------------------------------------------------------------------
    function automatic logic [11:0] rand_csr();
        begin
            case ($urandom_range(0, 11))
                0:  rand_csr = 12'h300;
                1:  rand_csr = 12'h304;
                2:  rand_csr = 12'h305;
                3:  rand_csr = 12'h340;
                4:  rand_csr = 12'h341;
                5:  rand_csr = 12'h342;
                6:  rand_csr = 12'h344;
                7:  rand_csr = 12'hF14;
                8:  rand_csr = 12'h301;   // optional -> unsupported (HAS_*=0)
                9:  rand_csr = 12'h343;
                10: rand_csr = 12'hB00;
                default: rand_csr = 12'hB80;
            endcase
        end
    endfunction

    function automatic logic [31:0] rand_inst();
        logic [6:0]  opc;
        logic [2:0]  f3;
        logic [6:0]  f7;
        logic [11:0] csr;
        logic [4:0]  drd;
        logic [4:0]  srs1;
        logic [4:0]  srs2;
        logic [31:0] w;
        int unsigned pick;
        begin
            drd  = 5'($urandom_range(0, 31));
            srs1 = 5'($urandom_range(0, 31));
            srs2 = 5'($urandom_range(0, 31));
            f3   = 3'($urandom_range(0, 7));
            f7   = 7'($urandom_range(0, 127));
            csr  = 12'($urandom_range(0, 4095));
            pick = $urandom_range(0, 99);

            if (pick < 8) begin
                // Unconstrained word: reaches the unsupported encodings.
                rand_inst = $urandom();
            end else begin
                if (pick < 30)       opc = 7'h33;
                else if (pick < 46)  opc = 7'h13;
                else if (pick < 56)  opc = 7'h03;
                else if (pick < 64)  opc = 7'h23;
                else if (pick < 72)  opc = 7'h63;
                else if (pick < 80)  opc = 7'h73;
                else if (pick < 84)  opc = 7'h6F;
                else if (pick < 88)  opc = 7'h67;
                else if (pick < 91)  opc = 7'h37;
                else if (pick < 94)  opc = 7'h17;
                else if (pick < 96)  opc = 7'h0F;
                else                 opc = 7'($urandom_range(0, 127));

                case (opc)
                    7'h33: if ($urandom_range(0, 3) != 0) begin
                        if ((f3 == 3'd0) || (f3 == 3'd5)) f7 = 7'b0100000;
                        else if ($urandom_range(0, 1) == 1) f7 = 7'b0000001;
                        else                              f7 = 7'b0000000;
                    end
                    7'h13: begin
                        if (f3 == 3'd1)
                            f7 = ($urandom_range(0, 3) == 0) ? f7 : 7'b0000000;
                        else if (f3 == 3'd5)
                            f7 = ($urandom_range(0, 1) == 1) ? 7'b0100000 : 7'b0000000;
                        else
                            f7 = 7'b0000000;
                    end
                    7'h03: if ($urandom_range(0, 3) != 0) begin
                        case ($urandom_range(0, 4))
                            0: f3 = 3'd0;
                            1: f3 = 3'd1;
                            2: f3 = 3'd2;
                            3: f3 = 3'd4;
                            default: f3 = 3'd5;
                        endcase
                    end
                    7'h23: if ($urandom_range(0, 3) != 0)
                        f3 = 3'($urandom_range(0, 2));
                    7'h63: if ($urandom_range(0, 3) != 0) begin
                        case ($urandom_range(0, 5))
                            0: f3 = 3'd0;
                            1: f3 = 3'd1;
                            2: f3 = 3'd4;
                            3: f3 = 3'd5;
                            4: f3 = 3'd6;
                            default: f3 = 3'd7;
                        endcase
                    end
                    7'h73: if ($urandom_range(0, 3) != 0) begin
                        if ($urandom_range(0, 2) == 0) begin
                            f3 = 3'd0;
                            case ($urandom_range(0, 2))
                                0:       csr = 12'h000;     // ECALL
                                1:       csr = 12'h001;     // EBREAK
                                default: csr = 12'h302;     // MRET
                            endcase
                        end else begin
                            case ($urandom_range(0, 5))
                                0: f3 = 3'd1;
                                1: f3 = 3'd2;
                                2: f3 = 3'd3;
                                3: f3 = 3'd5;
                                4: f3 = 3'd6;
                                default: f3 = 3'd7;
                            endcase
                            if ($urandom_range(0, 3) != 0) csr = rand_csr();
                        end
                    end
                    default: ;  // 6F / 67 / 37 / 17 / 0F: random fields are fine
                endcase

                w = {f7, srs2, srs1, f3, drd, opc};
                if (opc == 7'h73) w[31:20] = csr;   // funct12 / csr_addr
                rand_inst = w;
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // Test sequence
    //-------------------------------------------------------------------------
    int unsigned i;

    initial begin
        errors = 0;
        checks = 0;
        iq     = '0;

        //---------------------------------------------------------------------
        // 1. Invalid lane: decode_err stays 0 and every output is a defined
        //    constant, even when iq carries hostile/garbage data.
        //---------------------------------------------------------------------
        drive(32'h0000_0000, 1'b0);
        #1; chk_invalid("invalid lane (all zero)");
        iq.inst          = 32'hFFFF_FFFF;
        iq.cfi_type      = CFI_CALL;
        iq.is_cfi        = 1'b1;
        iq.pc            = 32'hDEAD_BEEF;
        #1; chk_invalid("invalid lane (hostile iq)");

        //---------------------------------------------------------------------
        // 2. U-type
        //---------------------------------------------------------------------
        drive(32'h123452B7); #1;    // lui x5, 0x12345
        chk_valid("lui x5,0x12345", 32'h123452B7, exp_upper(OP_LUI, 32'h12345000));
        drive(32'hFFFFF397); #1;    // auipc x7, 0xFFFFF
        chk_valid("auipc x7,0xFFFFF", 32'hFFFFF397, exp_upper(OP_AUIPC, 32'hFFFFF000));
        drive(32'h800000B7); #1;    // lui x1, 0x80000  (U-type is not sign extended)
        chk_valid("lui x1,0x80000", 32'h800000B7, exp_upper(OP_LUI, 32'h80000000));

        //---------------------------------------------------------------------
        // 3. JAL / JALR, including every CFI class and a negative J immediate
        //---------------------------------------------------------------------
        drive(32'h7FC000EF); #1;    // jal x1, 2044
        chk_valid("jal x1,2044 (CALL)", 32'h7FC000EF, exp_jump(OP_JAL, 32'd2044, CFI_CALL));
        drive(32'hFFDFF2EF); #1;    // jal x5, -4
        chk_valid("jal x5,-4 (CALL)", 32'hFFDFF2EF, exp_jump(OP_JAL, 32'hFFFF_FFFC, CFI_CALL));
        drive(32'h0100036F); #1;    // jal x6, 16
        chk_valid("jal x6,16 (DIRECT_JUMP)", 32'h0100036F, exp_jump(OP_JAL, 32'd16, CFI_DIRECT_JUMP));
        drive(32'h801FF06F); #1;    // jal x0, -2048
        chk_valid("jal x0,-2048 (DIRECT_JUMP)", 32'h801FF06F, exp_jump(OP_JAL, 32'hFFFFF800, CFI_DIRECT_JUMP));
        drive(32'hFF8100E7); #1;    // jalr x1, -8(x2)
        chk_valid("jalr x1,x2,-8 (CALL)", 32'hFF8100E7, exp_jump(OP_JALR, 32'hFFFFFFF8, CFI_CALL));
        drive(32'h00C302E7); #1;    // jalr x5, 12(x6)
        chk_valid("jalr x5,x6,12 (CALL)", 32'h00C302E7, exp_jump(OP_JALR, 32'd12, CFI_CALL));
        drive(32'h800083E7); #1;    // jalr x7, -2048(x1)
        chk_valid("jalr x7,x1,-2048 (RETURN)", 32'h800083E7, exp_jump(OP_JALR, 32'hFFFFF800, CFI_RETURN));
        drive(32'h00428467); #1;    // jalr x8, 4(x5)
        chk_valid("jalr x8,x5,4 (RETURN)", 32'h00428467, exp_jump(OP_JALR, 32'd4, CFI_RETURN));
        drive(32'h000504E7); #1;    // jalr x9, 0(x10)
        chk_valid("jalr x9,x10,0 (INDIRECT)", 32'h000504E7, exp_jump(OP_JALR, 32'd0, CFI_INDIRECT_JUMP));
        drive(32'h00000067); #1;    // jalr x0, 0(x0)
        chk_valid("jalr x0,x0,0 (INDIRECT)", 32'h00000067, exp_jump(OP_JALR, 32'd0, CFI_INDIRECT_JUMP));

        //---------------------------------------------------------------------
        // 4. Conditional branches (all six funct3 codes)
        //---------------------------------------------------------------------
        drive(32'h00208863); #1;    // beq x1, x2, 16
        chk_valid("beq x1,x2,16", 32'h00208863, exp_branch(OP_BEQ, 32'd16));
        drive(32'hFE419CE3); #1;    // bne x3, x4, -8
        chk_valid("bne x3,x4,-8", 32'hFE419CE3, exp_branch(OP_BNE, 32'hFFFF_FFF8));
        drive(32'h7E62CE63); #1;    // blt x5, x6, 2044
        chk_valid("blt x5,x6,2044", 32'h7E62CE63, exp_branch(OP_BLT, 32'd2044));
        drive(32'h8083D0E3); #1;    // bge x7, x8, -2048
        chk_valid("bge x7,x8,-2048", 32'h8083D0E3, exp_branch(OP_BGE, 32'hFFFFF800));
        drive(32'h00A4E463); #1;    // bltu x9, x10, 8
        chk_valid("bltu x9,x10,8", 32'h00A4E463, exp_branch(OP_BLTU, 32'd8));
        drive(32'h00C5F063); #1;    // bgeu x11, x12, 0
        chk_valid("bgeu x11,x12,0", 32'h00C5F063, exp_branch(OP_BGEU, 32'd0));
        drive(32'h802080E3); #1;    // beq x1, x2, -2048
        chk_valid("beq x1,x2,-2048", 32'h802080E3, exp_branch(OP_BEQ, 32'hFFFFF800));

        //---------------------------------------------------------------------
        // 5. Loads / stores (I-type and S-type immediates, incl. negative)
        //---------------------------------------------------------------------
        drive(32'hFFF30283); #1;    // lb x5, -1(x6)
        chk_valid("lb x5,-1(x6)", 32'hFFF30283, exp_load(OP_LB, 32'hFFFF_FFFF));
        drive(32'h00441383); #1;    // lh x7, 4(x8)
        chk_valid("lh x7,4(x8)", 32'h00441383, exp_load(OP_LH, 32'd4));
        drive(32'h7FF52483); #1;    // lw x9, 2047(x10)
        chk_valid("lw x9,2047(x10)", 32'h7FF52483, exp_load(OP_LW, 32'd2047));
        drive(32'h80064583); #1;    // lbu x11, -2048(x12)
        chk_valid("lbu x11,-2048(x12)", 32'h80064583, exp_load(OP_LBU, 32'hFFFFF800));
        drive(32'h00075683); #1;    // lhu x13, 0(x14)
        chk_valid("lhu x13,0(x14)", 32'h00075683, exp_load(OP_LHU, 32'd0));
        drive(32'h00002083); #1;    // lw x0, 0(x1) - writes are filtered by rd==x0
        chk_valid("lw x0,0(x1)", 32'h00002083, exp_load(OP_LW, 32'd0));
        drive(32'h00110223); #1;    // sb x1, 4(x2)
        chk_valid("sb x1,4(x2)", 32'h00110223, exp_store(OP_SB, 32'd4));
        drive(32'hFE321F23); #1;    // sh x3, -2(x4)
        chk_valid("sh x3,-2(x4)", 32'hFE321F23, exp_store(OP_SH, 32'hFFFF_FFFE));
        drive(32'h06532223); #1;    // sw x5, 100(x6)
        chk_valid("sw x5,100(x6)", 32'h06532223, exp_store(OP_SW, 32'd100));
        drive(32'h8021A023); #1;    // sw x2, -2048(x3)
        chk_valid("sw x2,-2048(x3)", 32'h8021A023, exp_store(OP_SW, 32'hFFFFF800));

        //---------------------------------------------------------------------
        // 6. OP-IMM (all nine)
        //---------------------------------------------------------------------
        drive(32'hFFF10093); #1;    // addi x1, x2, -1
        chk_valid("addi x1,x2,-1", 32'hFFF10093, exp_ri(OP_ADDI, 32'hFFFF_FFFF));
        drive(32'h00522193); #1;    // slti x3, x4, 5
        chk_valid("slti x3,x4,5", 32'h00522193, exp_ri(OP_SLTI, 32'd5));
        drive(32'hFFF33293); #1;    // sltiu x5, x6, -1
        chk_valid("sltiu x5,x6,-1", 32'hFFF33293, exp_ri(OP_SLTIU, 32'hFFFF_FFFF));
        drive(32'h7FF44393); #1;    // xori x7, x8, 0x7FF
        chk_valid("xori x7,x8,0x7FF", 32'h7FF44393, exp_ri(OP_XORI, 32'h7FF));
        drive(32'h80056493); #1;    // ori x9, x10, -2048
        chk_valid("ori x9,x10,-2048", 32'h80056493, exp_ri(OP_ORI, 32'hFFFFF800));
        drive(32'h12367593); #1;    // andi x11, x12, 0x123
        chk_valid("andi x11,x12,0x123", 32'h12367593, exp_ri(OP_ANDI, 32'h123));
        drive(32'h01F71693); #1;    // slli x13, x14, 31
        chk_valid("slli x13,x14,31", 32'h01F71693, exp_ri(OP_SLLI, 32'h0000_001F));
        drive(32'h00185793); #1;    // srli x15, x16, 1
        chk_valid("srli x15,x16,1", 32'h00185793, exp_ri(OP_SRLI, 32'h0000_0001));
        drive(32'h41F95893); #1;    // srai x17, x18, 31
        // I-type immediate: inst[31:20] = 0x41F, sign bit 0 -> 0x0000041F
        chk_valid("srai x17,x18,31", 32'h41F95893, exp_ri(OP_SRAI, 32'h0000_041F));

        //---------------------------------------------------------------------
        // 7. OP (all ten)
        //---------------------------------------------------------------------
        drive(32'h003100B3); #1;    // add x1, x2, x3
        chk_valid("add x1,x2,x3", 32'h003100B3, exp_rr(OP_ADD, FU_ALU0));
        drive(32'h40628233); #1;    // sub x4, x5, x6
        chk_valid("sub x4,x5,x6", 32'h40628233, exp_rr(OP_SUB, FU_ALU0));
        drive(32'h009413B3); #1;    // sll x7, x8, x9
        chk_valid("sll x7,x8,x9", 32'h009413B3, exp_rr(OP_SLL, FU_ALU0));
        drive(32'h00C5A533); #1;    // slt x10, x11, x12
        chk_valid("slt x10,x11,x12", 32'h00C5A533, exp_rr(OP_SLT, FU_ALU0));
        drive(32'h00F736B3); #1;    // sltu x13, x14, x15
        chk_valid("sltu x13,x14,x15", 32'h00F736B3, exp_rr(OP_SLTU, FU_ALU0));
        drive(32'h0128C833); #1;    // xor x16, x17, x18
        chk_valid("xor x16,x17,x18", 32'h0128C833, exp_rr(OP_XOR, FU_ALU0));
        drive(32'h015A59B3); #1;    // srl x19, x20, x21
        chk_valid("srl x19,x20,x21", 32'h015A59B3, exp_rr(OP_SRL, FU_ALU0));
        drive(32'h418BDB33); #1;    // sra x22, x23, x24
        chk_valid("sra x22,x23,x24", 32'h418BDB33, exp_rr(OP_SRA, FU_ALU0));
        drive(32'h01BD6CB3); #1;    // or x25, x26, x27
        chk_valid("or x25,x26,x27", 32'h01BD6CB3, exp_rr(OP_OR, FU_ALU0));
        drive(32'h01EEFE33); #1;    // and x28, x29, x30
        chk_valid("and x28,x29,x30", 32'h01EEFE33, exp_rr(OP_AND, FU_ALU0));

        //---------------------------------------------------------------------
        // 8. M extension (all eight, FU_MUL / FU_DIV)
        //---------------------------------------------------------------------
        drive(32'h023100B3); #1;    // mul x1, x2, x3
        chk_valid("mul x1,x2,x3", 32'h023100B3, exp_rr(OP_MUL, FU_MUL));
        drive(32'h02629233); #1;    // mulh x4, x5, x6
        chk_valid("mulh x4,x5,x6", 32'h02629233, exp_rr(OP_MULH, FU_MUL));
        drive(32'h029423B3); #1;    // mulhsu x7, x8, x9
        chk_valid("mulhsu x7,x8,x9", 32'h029423B3, exp_rr(OP_MULHSU, FU_MUL));
        drive(32'h02C5B533); #1;    // mulhu x10, x11, x12
        chk_valid("mulhu x10,x11,x12", 32'h02C5B533, exp_rr(OP_MULHU, FU_MUL));
        drive(32'h02F746B3); #1;    // div x13, x14, x15
        chk_valid("div x13,x14,x15", 32'h02F746B3, exp_rr(OP_DIV, FU_DIV));
        drive(32'h0328D833); #1;    // divu x16, x17, x18
        chk_valid("divu x16,x17,x18", 32'h0328D833, exp_rr(OP_DIVU, FU_DIV));
        drive(32'h035A69B3); #1;    // rem x19, x20, x21
        chk_valid("rem x19,x20,x21", 32'h035A69B3, exp_rr(OP_REM, FU_DIV));
        drive(32'h038BFB33); #1;    // remu x22, x23, x24
        chk_valid("remu x22,x23,x24", 32'h038BFB33, exp_rr(OP_REMU, FU_DIV));

        //---------------------------------------------------------------------
        // 9. SYSTEM: ECALL / EBREAK / MRET (D-C0-01, D-C0-09)
        //---------------------------------------------------------------------
        e = exp_zero(); e.op = OP_ECALL; e.fu = FU_CSR; e.is_serializing = 1'b1;
        drive(32'h00000073); #1;
        chk_valid("ecall", 32'h00000073, e);

        e = exp_zero(); e.op = OP_EBREAK; e.fu = FU_ALU0;
        drive(32'h00100073); #1;
        chk_valid("ebreak (retires, no err)", 32'h00100073, e);

        e = exp_zero(); e.op = OP_MRET; e.fu = FU_CSR; e.is_serializing = 1'b1;
        drive(32'h30200073); #1;
        chk_valid("mret", 32'h30200073, e);

        //---------------------------------------------------------------------
        // 10. Zicsr: all six forms, the csr_write_en truth table (backend.md
        //     16.2) and every required CSR address
        //---------------------------------------------------------------------
        drive(32'h300110F3); #1;    // csrrw x1, mstatus(0x300), x2
        chk_valid("csrrw x1,mstatus,x2 (we=1)", 32'h300110F3,
                  exp_csr_reg(OP_CSRRW, 12'h300, 1'b1));
        drive(32'h30401073); #1;    // csrrw x0, mie(0x304), x0
        chk_valid("csrrw x0,mie,x0 (we=1, rd_wen=1)", 32'h30401073,
                  exp_csr_reg(OP_CSRRW, 12'h304, 1'b1));
        drive(32'h300010F3); #1;    // csrrw x1, mstatus, x0
        chk_valid("csrrw x1,mstatus,x0 (we=1)", 32'h300010F3,
                  exp_csr_reg(OP_CSRRW, 12'h300, 1'b1));
        drive(32'h300021F3); #1;    // csrrs x3, mstatus, x0
        chk_valid("csrrs x3,mstatus,x0 (we=0)", 32'h300021F3,
                  exp_csr_reg(OP_CSRRS, 12'h300, 1'b0));
        drive(32'hF146A673); #1;    // csrrs x12, mhartid(0xF14), x13
        chk_valid("csrrs x12,mhartid,x13 (we=1)", 32'hF146A673,
                  exp_csr_reg(OP_CSRRS, 12'hF14, 1'b1));
        drive(32'h3052B273); #1;    // csrrc x4, mtvec(0x305), x5
        chk_valid("csrrc x4,mtvec,x5 (we=1)", 32'h3052B273,
                  exp_csr_reg(OP_CSRRC, 12'h305, 1'b1));
        drive(32'h34403773); #1;    // csrrc x14, mip(0x344), x0
        chk_valid("csrrc x14,mip,x0 (we=0)", 32'h34403773,
                  exp_csr_reg(OP_CSRRC, 12'h344, 1'b0));
        drive(32'h340FD373); #1;    // csrrwi x6, mscratch(0x340), 31
        chk_valid("csrrwi x6,mscratch,31 (we=1, uimm)", 32'h340FD373,
                  exp_csr_imm(OP_CSRRWI, 12'h340, 5'd31, 1'b1));
        drive(32'h341053F3); #1;    // csrrwi x7, mepc(0x341), 0
        chk_valid("csrrwi x7,mepc,0 (we=1)", 32'h341053F3,
                  exp_csr_imm(OP_CSRRWI, 12'h341, 5'd0, 1'b1));
        drive(32'h34206473); #1;    // csrrsi x8, mcause(0x342), 0
        chk_valid("csrrsi x8,mcause,0 (we=0)", 32'h34206473,
                  exp_csr_imm(OP_CSRRSI, 12'h342, 5'd0, 1'b0));
        drive(32'h3441E4F3); #1;    // csrrsi x9, mip(0x344), 3
        chk_valid("csrrsi x9,mip,3 (we=1)", 32'h3441E4F3,
                  exp_csr_imm(OP_CSRRSI, 12'h344, 5'd3, 1'b1));
        drive(32'h30086173); #1;    // csrrsi x2, mstatus, 16 (uimm zero-extended)
        chk_valid("csrrsi x2,mstatus,16 (uimm zext)", 32'h30086173,
                  exp_csr_imm(OP_CSRRSI, 12'h300, 5'd16, 1'b1));
        drive(32'hF1407573); #1;    // csrrci x10, mhartid(0xF14), 0
        chk_valid("csrrci x10,mhartid,0 (we=0)", 32'hF1407573,
                  exp_csr_imm(OP_CSRRCI, 12'hF14, 5'd0, 1'b0));
        drive(32'h3052F5F3); #1;    // csrrci x11, mtvec(0x305), 5
        chk_valid("csrrci x11,mtvec,5 (we=1)", 32'h3052F5F3,
                  exp_csr_imm(OP_CSRRCI, 12'h305, 5'd5, 1'b1));
        drive(32'h342871F3); #1;    // csrrci x3, mcause, 16
        chk_valid("csrrci x3,mcause,16 (uimm zext)", 32'h342871F3,
                  exp_csr_imm(OP_CSRRCI, 12'h342, 5'd16, 1'b1));

        //---------------------------------------------------------------------
        // 11. decode_err cases
        //---------------------------------------------------------------------
        drive(32'h0000007F); #1;    // unknown opcode 0x7f
        chk_valid("unknown opcode 0x7f", 32'h0000007F, exp_err(OP_ILLEGAL));
        drive(32'h0000000B); #1;    // unknown opcode 0x0b (custom-0)
        chk_valid("unknown opcode 0x0b", 32'h0000000B, exp_err(OP_ILLEGAL));
        drive(32'h10500073); #1;    // WFI: SYSTEM funct3=0, funct12=0x105
        chk_valid("WFI (unsupported SYSTEM)", 32'h10500073, exp_err(OP_ILLEGAL));
        drive(32'h10200073); #1;    // SRET
        chk_valid("SRET (unsupported SYSTEM)", 32'h10200073, exp_err(OP_ILLEGAL));
        drive(32'h00004073); #1;    // SYSTEM funct3=4
        chk_valid("SYSTEM funct3=4", 32'h00004073, exp_err(OP_ILLEGAL));
        drive(32'h0020A263); #1;    // BRANCH funct3=2
        chk_valid("BRANCH funct3=2", 32'h0020A263, exp_err(OP_ILLEGAL));
        drive(32'h0020B263); #1;    // BRANCH funct3=3
        chk_valid("BRANCH funct3=3", 32'h0020B263, exp_err(OP_ILLEGAL));
        drive(32'h00033283); #1;    // LOAD funct3=3 (LD)
        chk_valid("LOAD funct3=3", 32'h00033283, exp_err(OP_ILLEGAL));
        drive(32'h00036283); #1;    // LOAD funct3=6
        chk_valid("LOAD funct3=6", 32'h00036283, exp_err(OP_ILLEGAL));
        drive(32'h00037283); #1;    // LOAD funct3=7
        chk_valid("LOAD funct3=7", 32'h00037283, exp_err(OP_ILLEGAL));
        drive(32'h00533023); #1;    // STORE funct3=3 (SD)
        chk_valid("STORE funct3=3", 32'h00533023, exp_err(OP_ILLEGAL));
        drive(32'h00534023); #1;    // STORE funct3=4
        chk_valid("STORE funct3=4", 32'h00534023, exp_err(OP_ILLEGAL));
        drive(32'h41F71693); #1;    // SLLI with funct7=0100000
        chk_valid("SLLI funct7!=0", 32'h41F71693, exp_err(OP_ILLEGAL));
        drive(32'h403110B3); #1;    // OP funct7=0100000, funct3=1
        chk_valid("OP funct7=0100000 funct3=1", 32'h403110B3, exp_err(OP_ILLEGAL));
        drive(32'h043100B3); #1;    // OP funct7=0000010
        chk_valid("OP funct7=0000010", 32'h043100B3, exp_err(OP_ILLEGAL));

        // FENCE is recognised but unsupported in v1 (D-C0-01)
        e = exp_zero(); e.op = OP_FENCE; e.is_fence = 1'b1; e.err = 1'b1;
        drive(32'h0000000F); #1;
        chk_valid("FENCE", 32'h0000000F, e);
        drive(32'h0000100F); #1;    // FENCE.I
        chk_valid("FENCE.I", 32'h0000100F, e);

        // Unsupported CSR addresses (D-C0-13): the required set is legal, the
        // optional set is legal only when its switch is on (it is off in v1).
        drive(32'h306110F3); #1;    // csrrw x1, 0x306, x2
        chk_valid("csrrw unsupported CSR 0x306", 32'h306110F3, exp_err(OP_ILLEGAL));
        drive(32'h301120F3); #1;    // csrrs x1, misa(0x301), x2
        chk_valid("csrrs misa (HAS_MISA=0)", 32'h301120F3,
                  HAS_MISA ? exp_csr_reg(OP_CSRRS, 12'h301, 1'b1) : exp_err(OP_ILLEGAL));
        drive(32'h343120F3); #1;    // csrrs x1, mtval(0x343), x2
        chk_valid("csrrs mtval (HAS_MTVAL=0)", 32'h343120F3,
                  HAS_MTVAL ? exp_csr_reg(OP_CSRRS, 12'h343, 1'b1) : exp_err(OP_ILLEGAL));
        drive(32'hB00120F3); #1;    // csrrs x1, mcycle(0xB00), x2
        chk_valid("csrrs mcycle (HAS_MCYCLE=0)", 32'hB00120F3,
                  HAS_MCYCLE ? exp_csr_reg(OP_CSRRS, 12'hB00, 1'b1) : exp_err(OP_ILLEGAL));
        drive(32'hB80120F3); #1;    // csrrs x1, mcycleh(0xB80), x2
        chk_valid("csrrs mcycleh (HAS_MCYCLE=0)", 32'hB80120F3,
                  HAS_MCYCLE ? exp_csr_reg(OP_CSRRS, 12'hB80, 1'b1) : exp_err(OP_ILLEGAL));
        drive(32'h7FF2D0F3); #1;    // csrrwi x1, 0x7FF, 5
        chk_valid("csrrwi unsupported CSR 0x7FF", 32'h7FF2D0F3, exp_err(OP_ILLEGAL));

        //---------------------------------------------------------------------
        // 12. Predecode cross-check (contract 2.1).  A mismatch is a decode_err.
        //---------------------------------------------------------------------
        e = exp_ri(OP_ADDI, 32'd1); e.err = 1'b1;
        drive_pre(32'h00100093, CFI_COND_BRANCH, 1'b1);
        #1; chk_valid("predecode: addi marked as CFI", 32'h00100093, e);

        e = exp_jump(OP_JAL, 32'd16, CFI_DIRECT_JUMP); e.err = 1'b1;
        drive_pre(32'h0100036F, CFI_NONE, 1'b0);
        #1; chk_valid("predecode: jal not marked CFI", 32'h0100036F, e);
        drive_pre(32'h0100036F, CFI_COND_BRANCH, 1'b1);
        #1; chk_valid("predecode: jal wrong CFI class", 32'h0100036F, e);

        e = exp_jump(OP_JALR, 32'hFFFFF800, CFI_RETURN); e.err = 1'b1;
        drive_pre(32'h800083E7, CFI_INDIRECT_JUMP, 1'b1);
        #1; chk_valid("predecode: jalr wrong CFI class", 32'h800083E7, e);

        // Legal combination: JALR decoded with its true CFI class.
        e = exp_jump(OP_JALR, 32'hFFFFF800, CFI_RETURN);
        drive_pre(32'h800083E7, CFI_RETURN, 1'b1);
        #1; chk_valid("predecode: jalr CFI_RETURN (ok)", 32'h800083E7, e);

        //---------------------------------------------------------------------
        // 13. Randomised cross-check against the reference decoder.
        //---------------------------------------------------------------------
        seed_echo = $urandom(SEED);
        $display("tb_decode: randomised phase, seed=0x%08x (first value 0x%08x, %0d iterations)",
                 SEED, seed_echo, RAND_ITERS);
        for (i = 0; i < RAND_ITERS; i = i + 1) begin
            logic [31:0] rinst;
            rinst = rand_inst();
            drive(rinst);
            #1;
            chk_valid($sformatf("random #%0d inst=0x%08x", i, rinst),
                      rinst, ref_decode(rinst));
        end

        //---------------------------------------------------------------------
        // Summary
        //---------------------------------------------------------------------
        if (errors == 0) begin
            $display("ALL TESTS PASSED: be_decode RV32IM+Zicsr+SYSTEM decode (%0d checks: every instruction op/fu/rd/rd_wen/rs/src_used/imm/csr_addr/csr_write_en/is_serializing/is_cfi/is_branch/is_load/is_store/is_csr/is_fence, all five immediate formats, CFI classes for JAL/JALR/branches, CSR write-enable truth table, decode_err cases, invalid lane, fixed seed 0x%08x)",
                     checks, SEED);
            $finish;
        end else begin
            $fatal(1, "tb_decode: %0d field mismatches in %0d checks", errors, checks);
        end
    end

endmodule
