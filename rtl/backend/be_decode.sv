//=============================================================================
// ARES core - backend instruction decode, one dispatch lane (B02)
//-----------------------------------------------------------------------------
// Purpose: purely combinational decoder for a single IQ lane.  be_dispatch
// instantiates ares_pkg::DECODE_WIDTH (=2) copies, one per dispatch slot.  The module
// turns the raw instruction word of an ares_pkg::iq_entry_t into every non-dependency
// field of ares_pkg::queue_entry_t, classifies the *actual* control flow and cross-checks
// the frontend predecode.  Encodings outside RV32IM + Zicsr + ECALL/EBREAK/MRET
// raise decode_err instead of silently becoming a NOP (D-C0-01); v1 has no
// illegal-instruction trap, so dispatch must drop the candidate instead.
//
// Spec sources:
//   backend.md 5                  Decode / Dispatch: decoded fields, serializing
//                                 gate inputs, dependency-binding inputs
//   backend.md 16.2               CSR decode: csr_addr / csr_write_en truth
//                                 table, zero-extended uimm, rd=x0 / rs1=x0
//   frontend_backend_contract.md 2.1
//                                 cfi_type / is_cfi must be cross-checked
//                                 against inst, need_redirect implies a CFI
//   docs/c0_decisions.md D-C0-01  unsupported encoding -> decode_err (no NOP,
//                                 no architectural trap), EBREAK retires
//   docs/c0_decisions.md D-C0-09  ECALL / MRET are not CFI events
//   docs/c0_decisions.md D-C0-13  ares_pkg::HAS_MISA/ares_pkg::HAS_MTVAL/ares_pkg::HAS_MCYCLE default 0: an
//                                 access to those CSR addresses is an error
//   docs/implementation_plan.md 6.1 / B02
//
// Contract notes (checked by rtl/backend/test/unit/tb_decode.sv):
//   * valid = iq.valid.  An invalid lane drives decode_err = 0 and every other
//     output to all-zero / OP_ILLEGAL whatever iq holds, so no consumer ever
//     sees an X from a dead slot.
//   * For a valid lane rd / rs1 / rs2 are the raw instruction fields, even when
//     the operand is unused: rd_wen / src*_used say whether they count and
//     consumers filter rd != x0 themselves.  rd_wen stays 1 when rd == x0.
//   * is_branch is the CIQ control-transfer flag, so it equals is_cfi
//     (backend.md 15.2 checkpoints JAL / JALR, not only conditional branches).
//   * FENCE is recognised (op = OP_FENCE, is_fence = 1) but unsupported in v1
//     and therefore also raises decode_err; unrecognised encodings use
//     OP_ILLEGAL.
//
// FREE items exercised: FREE-02 (module / file organisation), FREE-04
// (combinational structure: flat parallel case decode, no priority chain).
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */  // decode only reads inst/valid/cfi fields of iq
module be_decode (
    input  ares_pkg::iq_entry_t    iq,
    output logic         decode_err,
    output logic         valid,
    output ares_pkg::fu_type_t     fu_type,
    output ares_pkg::op_t          op,
    output logic [4:0]   rd,
    output logic         rd_wen,
    output logic [4:0]   rs1,
    output logic         src1_used,
    output logic [4:0]   rs2,
    output logic         src2_used,
    output logic [31:0]  imm,
    output logic [11:0]  csr_addr,
    output logic         csr_write_en,
    output logic         is_serializing,
    output logic         is_cfi,
    output logic         is_branch,
    output ares_pkg::cfi_type_t    actual_cfi_type,
    output logic         is_load,
    output logic         is_store,
    output logic         is_csr,
    output logic         is_fence
);
/* verilator lint_on UNUSEDSIGNAL */
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Instruction fields.  Pure wiring; everything below is combinational.
    //-------------------------------------------------------------------------
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;
    logic [11:0] funct12;

    assign opcode  = iq.inst[6:0];
    assign funct3  = iq.inst[14:12];
    assign funct7  = iq.inst[31:25];
    assign funct12 = iq.inst[31:20];

    //-------------------------------------------------------------------------
    // Immediate generation (backend.md 5, plan 6.1/B02)
    //   I : sign-extended inst[31:20]              (loads, OP-IMM, JALR)
    //   S : sign-extended inst[31:25,11:7]         (stores)
    //   B : sign-extended inst[31,7,30:25,11:8,0]  (branches)
    //   U : inst[31:12] followed by 12 zero bits   (LUI, AUIPC)
    //   J : sign-extended inst[31,19:12,20,30:21,0] (JAL)
    //   Zicsr immediate forms use the zero-extended uimm[4:0] (backend.md 16.2)
    //-------------------------------------------------------------------------
    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_u;
    logic [31:0] imm_j;
    logic [31:0] imm_uimm;

    assign imm_i    = {{20{iq.inst[31]}}, iq.inst[31:20]};
    assign imm_s    = {{20{iq.inst[31]}}, iq.inst[31:25], iq.inst[11:7]};
    assign imm_b    = {{19{iq.inst[31]}}, iq.inst[31], iq.inst[7],
                       iq.inst[30:25], iq.inst[11:8], 1'b0};
    assign imm_u    = {iq.inst[31:12], 12'b0};
    assign imm_j    = {{11{iq.inst[31]}}, iq.inst[31], iq.inst[19:12],
                       iq.inst[20], iq.inst[30:21], 1'b0};
    assign imm_uimm = {27'b0, iq.inst[19:15]};

    //-------------------------------------------------------------------------
    // CFI classification helpers.  The class must match the frontend predecode
    // exactly (contract 2.1): link registers are x1/x5 (ra / t0).
    //-------------------------------------------------------------------------
    logic rd_is_link;
    logic rs1_is_link;

    assign rd_is_link  = (iq.inst[11:7]  == 5'd1) || (iq.inst[11:7]  == 5'd5);
    assign rs1_is_link = (iq.inst[19:15] == 5'd1) || (iq.inst[19:15] == 5'd5);

    //-------------------------------------------------------------------------
    // CSR address legality (backend.md 16.1, D-C0-13).  The optional groups
    // are gated by the frozen package switches; with the v1 defaults all four
    // of their addresses are unsupported accesses -> decode_err.
    //-------------------------------------------------------------------------
    function automatic logic csr_legal(input logic [11:0] addr);
        begin
            case (addr)
                12'h300, 12'h304, 12'h305, 12'h340,
                12'h341, 12'h342, 12'h344, 12'hF14: csr_legal = 1'b1;
                12'h301: csr_legal = HAS_MISA;
                12'h343: csr_legal = HAS_MTVAL;
                12'hB00, 12'hB80: csr_legal = HAS_MCYCLE;
                default: csr_legal = 1'b0;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Decode.  Every output is assigned in every path: the defaults below are
    // the "invalid lane / unsupported encoding" value of each field.
    //-------------------------------------------------------------------------
    logic legal;    // current encoding maps to a v1-supported instruction

    always_comb begin
        //---- defaults: invalid lane and every error path --------------------
        decode_err      = 1'b0;         // never set for an invalid lane
        valid           = iq.valid;
        fu_type         = FU_ALU0;
        op              = OP_ILLEGAL;
        rd              = 5'd0;
        rd_wen          = 1'b0;
        rs1             = 5'd0;
        src1_used       = 1'b0;
        rs2             = 5'd0;
        src2_used       = 1'b0;
        imm             = 32'd0;
        csr_addr        = 12'd0;
        csr_write_en    = 1'b0;
        is_serializing  = 1'b0;
        is_cfi          = 1'b0;
        is_branch       = 1'b0;
        actual_cfi_type = CFI_NONE;
        is_load         = 1'b0;
        is_store        = 1'b0;
        is_csr          = 1'b0;
        is_fence        = 1'b0;
        legal           = 1'b0;

        if (iq.valid) begin
            // The register fields are the raw encoding fields; src*_used and
            // rd_wen decide whether a consumer may use them.
            rd  = iq.inst[11:7];
            rs1 = iq.inst[19:15];
            rs2 = iq.inst[24:20];

            case (opcode)
                //---- U-type ------------------------------------------------
                7'h37: begin                        // LUI
                    op      = OP_LUI;
                    fu_type = FU_ALU0;
                    rd_wen  = 1'b1;
                    imm     = imm_u;
                end
                7'h17: begin                        // AUIPC
                    op      = OP_AUIPC;
                    fu_type = FU_ALU0;
                    rd_wen  = 1'b1;
                    imm     = imm_u;
                end

                //---- jumps -------------------------------------------------
                7'h6F: begin                        // JAL
                    op              = OP_JAL;
                    fu_type         = FU_BRU;
                    rd_wen          = 1'b1;
                    imm             = imm_j;
                    actual_cfi_type = rd_is_link ? CFI_CALL : CFI_DIRECT_JUMP;
                    is_cfi          = 1'b1;
                    is_branch       = 1'b1;
                end
                7'h67: begin                        // JALR
                    op              = OP_JALR;
                    fu_type         = FU_BRU;
                    rd_wen          = 1'b1;
                    src1_used       = 1'b1;
                    imm             = imm_i;
                    actual_cfi_type = rd_is_link ? CFI_CALL
                                    : (rs1_is_link ? CFI_RETURN
                                                   : CFI_INDIRECT_JUMP);
                    is_cfi          = 1'b1;
                    is_branch       = 1'b1;
                end

                //---- conditional branches ----------------------------------
                7'h63: begin
                    legal = 1'b1;
                    case (funct3)
                        3'd0: op = OP_BEQ;
                        3'd1: op = OP_BNE;
                        3'd4: op = OP_BLT;
                        3'd5: op = OP_BGE;
                        3'd6: op = OP_BLTU;
                        3'd7: op = OP_BGEU;
                        default: legal = 1'b0;      // funct3 2/3: not in v1
                    endcase
                    if (legal) begin
                        fu_type         = FU_BRU;
                        imm             = imm_b;
                        src1_used       = 1'b1;
                        src2_used       = 1'b1;
                        is_cfi          = 1'b1;
                        is_branch       = 1'b1;
                        actual_cfi_type = CFI_COND_BRANCH;
                    end else begin
                        op         = OP_ILLEGAL;
                        decode_err = 1'b1;
                    end
                end

                //---- loads -------------------------------------------------
                7'h03: begin
                    legal = 1'b1;
                    case (funct3)
                        3'd0: op = OP_LB;
                        3'd1: op = OP_LH;
                        3'd2: op = OP_LW;
                        3'd4: op = OP_LBU;
                        3'd5: op = OP_LHU;
                        default: legal = 1'b0;      // funct3 3/6/7: not in v1
                    endcase
                    if (legal) begin
                        fu_type   = FU_LSU;
                        rd_wen    = 1'b1;
                        src1_used = 1'b1;
                        is_load   = 1'b1;
                        imm       = imm_i;
                    end else begin
                        op         = OP_ILLEGAL;
                        decode_err = 1'b1;
                    end
                end

                //---- stores ------------------------------------------------
                7'h23: begin
                    legal = 1'b1;
                    case (funct3)
                        3'd0: op = OP_SB;
                        3'd1: op = OP_SH;
                        3'd2: op = OP_SW;
                        default: legal = 1'b0;      // funct3 3..7: not in v1
                    endcase
                    if (legal) begin
                        fu_type   = FU_LSU;
                        src1_used = 1'b1;
                        src2_used = 1'b1;
                        is_store  = 1'b1;
                        imm       = imm_s;
                    end else begin
                        op         = OP_ILLEGAL;
                        decode_err = 1'b1;
                    end
                end

                //---- OP-IMM ------------------------------------------------
                7'h13: begin
                    legal = 1'b1;
                    case (funct3)
                        3'd0: op = OP_ADDI;
                        3'd2: op = OP_SLTI;
                        3'd3: op = OP_SLTIU;
                        3'd4: op = OP_XORI;
                        3'd6: op = OP_ORI;
                        3'd7: op = OP_ANDI;
                        3'd1: begin
                            // RV32I SLLI only exists with funct7 = 0000000
                            if (funct7 == 7'b0000000) op = OP_SLLI;
                            else legal = 1'b0;
                        end
                        3'd5: op = iq.inst[30] ? OP_SRAI : OP_SRLI;
                        default: legal = 1'b0;
                    endcase
                    if (legal) begin
                        fu_type   = FU_ALU0;
                        rd_wen    = 1'b1;
                        src1_used = 1'b1;
                        imm       = imm_i;
                    end else begin
                        op         = OP_ILLEGAL;
                        decode_err = 1'b1;
                    end
                end

                //---- OP ----------------------------------------------------
                7'h33: begin
                    legal = 1'b1;
                    case (funct7)
                        7'b0000000: begin
                            case (funct3)
                                3'd0: op = OP_ADD;
                                3'd1: op = OP_SLL;
                                3'd2: op = OP_SLT;
                                3'd3: op = OP_SLTU;
                                3'd4: op = OP_XOR;
                                3'd5: op = OP_SRL;
                                3'd6: op = OP_OR;
                                default: op = OP_AND;       // 3'd7
                            endcase
                            fu_type = FU_ALU0;
                        end
                        7'b0100000: begin
                            case (funct3)
                                3'd0: op = OP_SUB;
                                3'd5: op = OP_SRA;
                                default: legal = 1'b0;
                            endcase
                            fu_type = FU_ALU0;
                        end
                        7'b0000001: begin               // M extension
                            case (funct3)
                                3'd0: begin op = OP_MUL;    fu_type = FU_MUL; end
                                3'd1: begin op = OP_MULH;   fu_type = FU_MUL; end
                                3'd2: begin op = OP_MULHSU; fu_type = FU_MUL; end
                                3'd3: begin op = OP_MULHU;  fu_type = FU_MUL; end
                                3'd4: begin op = OP_DIV;    fu_type = FU_DIV; end
                                3'd5: begin op = OP_DIVU;   fu_type = FU_DIV; end
                                3'd6: begin op = OP_REM;    fu_type = FU_DIV; end
                                default: begin op = OP_REMU; fu_type = FU_DIV; end
                            endcase
                        end
                        default: legal = 1'b0;
                    endcase
                    if (legal) begin
                        rd_wen    = 1'b1;
                        src1_used = 1'b1;
                        src2_used = 1'b1;
                    end else begin
                        op         = OP_ILLEGAL;
                        decode_err = 1'b1;
                    end
                end

                //---- SYSTEM / Zicsr ----------------------------------------
                7'h73: begin
                    case (funct3)
                        3'd0: begin
                            case (funct12)
                                12'h000: begin              // ECALL
                                    op             = OP_ECALL;
                                    fu_type        = FU_CSR;
                                    is_serializing = 1'b1;
                                end
                                12'h001: begin              // EBREAK
                                    // Retires normally (D-C0-01): no exception,
                                    // no CSR access, no serialization.
                                    op      = OP_EBREAK;
                                    fu_type = FU_ALU0;
                                end
                                12'h302: begin              // MRET
                                    op             = OP_MRET;
                                    fu_type        = FU_CSR;
                                    is_serializing = 1'b1;
                                end
                                default: decode_err = 1'b1; // WFI/SRET/...
                            endcase
                        end
                        3'd1, 3'd2, 3'd3: begin         // CSRRW / CSRRS / CSRRC
                            if (csr_legal(funct12)) begin
                                op             = (funct3 == 3'd1) ? OP_CSRRW
                                               : (funct3 == 3'd2) ? OP_CSRRS
                                                                  : OP_CSRRC;
                                fu_type        = FU_CSR;
                                rd_wen         = 1'b1;
                                src1_used      = 1'b1;
                                is_csr         = 1'b1;
                                is_serializing = 1'b1;
                                csr_addr       = funct12;
                                // CSRRW always writes; CSRRS/CSRRC only when
                                // the encoded rs1 is not x0 (backend.md 16.2)
                                csr_write_en   = (funct3 == 3'd1) ? 1'b1
                                               : (iq.inst[19:15] != 5'd0);
                            end else begin
                                decode_err = 1'b1;  // unsupported CSR access
                            end
                        end
                        3'd5, 3'd6, 3'd7: begin         // CSRRWI / CSRRSI / CSRRCI
                            if (csr_legal(funct12)) begin
                                op             = (funct3 == 3'd5) ? OP_CSRRWI
                                               : (funct3 == 3'd6) ? OP_CSRRSI
                                                                  : OP_CSRRCI;
                                fu_type        = FU_CSR;
                                rd_wen         = 1'b1;
                                src1_used      = 1'b0;  // uimm, no GPR read
                                is_csr         = 1'b1;
                                is_serializing = 1'b1;
                                csr_addr       = funct12;
                                csr_write_en   = (funct3 == 3'd5) ? 1'b1
                                               : (iq.inst[19:15] != 5'd0);
                                imm            = imm_uimm;
                            end else begin
                                decode_err = 1'b1;
                            end
                        end
                        default: decode_err = 1'b1;     // funct3 = 4 and reserved
                    endcase
                end

                //---- FENCE / FENCE.I: recognised, unsupported in v1 ---------
                7'h0F: begin
                    op         = OP_FENCE;
                    is_fence   = 1'b1;
                    decode_err = 1'b1;
                end

                //---- everything else ---------------------------------------
                default: decode_err = 1'b1;
            endcase

            //-----------------------------------------------------------------
            // Predecode cross-check (contract 2.1).  Never evaluated for an
            // invalid lane, so a dead slot can never raise decode_err.
            //-----------------------------------------------------------------
            if ((is_cfi != iq.is_cfi)
                || (is_cfi && (actual_cfi_type != iq.cfi_type))
                || (iq.need_redirect && !is_cfi)) begin
                decode_err = 1'b1;
            end
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Simulation-only invariants of the decoded fields.  They hold by
    // construction and guard the consumers that drop a decode_err candidate.
    //-------------------------------------------------------------------------
    always_comb begin
        if (valid && !decode_err) begin
            assert (op != OP_ILLEGAL)
                else $error("be_decode: supported encoding produced OP_ILLEGAL");
            assert (is_branch == is_cfi)
                else $error("be_decode: is_branch must equal is_cfi");
            assert (is_cfi == (actual_cfi_type != CFI_NONE))
                else $error("be_decode: is_cfi must match actual_cfi_type");
            assert (!is_fence)
                else $error("be_decode: FENCE must raise decode_err");
            assert (!(is_load && is_store))
                else $error("be_decode: load and store are mutually exclusive");
        end
    end
`endif

endmodule
