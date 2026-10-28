//=============================================================================
// ARES backend - fu_alu: RV32I integer ALU execution port (ALU0 / ALU1)
//-----------------------------------------------------------------------------
// Purpose
//   Single-outstanding-operation RV32I integer ALU, latency = 1, II = 1,
//   can_accept = 1 (the issue scheduler may send a request every cycle; the FU
//   latches it at the clock edge and never asks for a ready handshake).
//   Every operation routed to an ALU port is computed combinationally and
//   registered into one completion register; no exception is ever generated
//   (exception = 0, cause = EXC_NONE, tval = 0).
//
//   Operand convention (I-type): the second operand of an immediate-form op is
//   taken from issue_req.imm (canonical RV32 operand B for I-type); the
//   register-register forms take issue_req.src2, and every shift amount is the
//   low five bits of that second operand - so SLL/SRL/SRA use src2[4:0] and
//   SLLI/SRLI/SRAI use imm[4:0].  src2 is ignored for I-type operations
//   because be_operand_read (B08, C1 integration) drives src2 = 0 for an
//   unused source; the decoded immediate arrives on imm (be_issue_sched
//   assigns fu_req.imm = cand[i].imm).
//
// Spec sources
//   docs/microarch/backend.md section 9.1   ALU0 / ALU1 definition
//   docs/microarch/backend.md section 9     FU latency / II / can_accept table
//   docs/microarch/backend.md section 10    guaranteed-accept request + kill
//   docs/microarch/backend.md section 11    completion protocol invariants
//   docs/implementation_plan.md sections 5.6 / 5.7, module B10
//
// FREE items exercised
//   FREE-02  file organisation / internal partitioning
//   FREE-04  combinational structure
//   FREE-11  internal pipeline register placement and naming
//
// Verification
//   rtl/backend/test/unit/tb_fu_exec.sv (directed + randomised, fixed seed);
//   lint and run commands are recorded in that test bench header.
//=============================================================================
module fu_alu (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // BRU/LSU/CSR-only fu_req_t fields are not read by an ALU
    input  ares_pkg::fu_req_t                issue_req,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion
);

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Second operand: register value for R-type, immediate for I-type.
    //-------------------------------------------------------------------------
    logic [31:0] op_b;
    always_comb begin
        case (issue_req.op)
            OP_ADDI, OP_SLTI, OP_SLTIU, OP_XORI, OP_ORI, OP_ANDI,
            OP_SLLI, OP_SRLI, OP_SRAI: op_b = issue_req.imm;
            default:                   op_b = issue_req.src2;
        endcase
    end

    //-------------------------------------------------------------------------
    // ARES custom-0 CRC8 step.  Matches CoreMark crcu8():
    //   x16 = (data & 1) ^ (crc & 1);
    //   data >>= 1;
    //   if (x16) { crc ^= 0x4002; carry = 1; } else carry = 0;
    //   crc >>= 1;
    //   if (carry) crc |= 0x8000; else crc &= 0x7fff;
    // Unrolled 8 times; latency 1, same as the other ALU operations.
    //-------------------------------------------------------------------------
    function automatic logic [15:0] crc8_step(input logic [7:0] data,
                                              input logic [15:0] crc_in);
        logic [15:0] c;
        logic        x16;
        c = crc_in;
        for (int i = 0; i < 8; i++) begin
            x16 = data[i] ^ c[0];
            c   = c ^ (x16 ? 16'h4002 : 16'h0000);
            c   = c >> 1;
            if (x16) c[15] = 1'b1;
        end
        return c;
    endfunction

    //-------------------------------------------------------------------------
    // RV32I datapath (backend.md section 9.1).
    //-------------------------------------------------------------------------
    logic [31:0] alu_result;
    always_comb begin
        case (issue_req.op)
            OP_LUI:            alu_result = issue_req.imm;
            OP_AUIPC:          alu_result = issue_req.pc + issue_req.imm;
            OP_ADD, OP_ADDI:   alu_result = issue_req.src1 + op_b;
            OP_SUB:            alu_result = issue_req.src1 - op_b;
            OP_SLL, OP_SLLI:   alu_result = issue_req.src1 << op_b[4:0];
            OP_SLT, OP_SLTI:   alu_result = ($signed(issue_req.src1) < $signed(op_b))
                                          ? 32'd1 : 32'd0;
            OP_SLTU, OP_SLTIU: alu_result = (issue_req.src1 < op_b) ? 32'd1 : 32'd0;
            OP_XOR, OP_XORI:   alu_result = issue_req.src1 ^ op_b;
            OP_SRL, OP_SRLI:   alu_result = issue_req.src1 >> op_b[4:0];
            OP_SRA, OP_SRAI:   alu_result = $signed(issue_req.src1) >>> op_b[4:0];
            OP_OR,  OP_ORI:    alu_result = issue_req.src1 | op_b;
            OP_AND, OP_ANDI:   alu_result = issue_req.src1 & op_b;
            OP_CRC8:           alu_result = {16'd0, crc8_step(issue_req.src1[7:0],
                                                              issue_req.src2[15:0])};
            // EBREAK never writes a register; the BRU-facing value is pc+4.
            OP_EBREAK:         alu_result = issue_req.pc + 32'd4;
            default:           alu_result = 32'd0;   // never routed here
        endcase
    end

    //-------------------------------------------------------------------------
    // Single in-flight operation register (latency 1).
    // A kill clears the operation and, combinationally, suppresses the
    // completion of the very cycle the kill hits (kill wins over completion).
    //-------------------------------------------------------------------------
    logic        op_valid;
    tag_t        op_tag;
    logic [31:0] op_result;

    wire op_kill = kill_mask[op_tag.slot_index];

    always_ff @(posedge clk) begin
        if (rst) begin
            op_valid  <= 1'b0;
            op_tag    <= '0;
            op_result <= 32'd0;
        end else begin
            // The operation is held for exactly one cycle, so the next value
            // of op_valid is simply issue_valid: a completed (or killed)
            // operation leaves the register.  The kill needs no separate
            // clear here - it suppresses the completion combinationally in the
            // same cycle and the operation is gone one cycle later.
            op_valid <= issue_valid;
            if (issue_valid) begin
                op_tag    <= issue_req.tag;
                op_result <= alu_result;
            end
        end
    end

    assign completion_valid = op_valid && !op_kill;

    always_comb begin
        completion           = '0;
        completion.tag       = op_tag;
        completion.result    = op_result;
        completion.exception = 1'b0;
        completion.cause     = EXC_NONE;
        completion.tval      = 32'd0;
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol invariants (backend.md section 11)
    //-------------------------------------------------------------------------
    a_kill_wins: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> !kill_mask[completion.tag.slot_index]);

    a_no_completion_without_op: assert property (@(posedge clk) disable iff (rst)
        completion_valid |-> op_valid);
`endif

endmodule
