//=============================================================================
// ARES - Backend: CSR functional unit, B15
//-----------------------------------------------------------------------------
// Purpose
//   Execute the six Zicsr operations plus ECALL/MRET with latency = 1 and
//   II = 1: latch the request, read the old CSR value in the following cycle,
//   return it as the ordinary completion result, and drive the write value
//   (new = src / old | src / old & ~src) as the CSR sideband that the
//   completion network registers into the CIQ entry.  ECALL registers a
//   synchronous exception instead.  This unit never writes the CSR file: the
//   architectural write happens on the exclusive commit edge
//   (backend.md section 16.2).
//
// Spec sources (authoritative)
//   backend.md section 11    - completion protocol (one completion per accepted
//                              non-killed operation, >= 1 cycle after issue,
//                              single-cycle pulse, kill wins in the same cycle)
//                              and 11.8: CSR returns the OLD value as the
//                              ordinary result plus a local csr_write_data
//                              sideband; the generic completion format is
//                              unchanged.
//   backend.md section 16.2  - CSR Unit: read old value one cycle after issue,
//                              new = src / (old|src) / (old&~src); the write
//                              itself is done by Commit; immediate operand is
//                              the zero-extended uimm[4:0] and does not read a
//                              GPR; rd=x0 CSRRW[I] still writes.
//   backend.md section 16.3  - CSR/ECALL/MRET are serializing; the serializing
//                              gate is outside this unit.
//   backend.md section 17.1  - ECALL completes as DONE + exception(cause=11,
//                              tval=0); MRET is a normal completion.
//   plan section 5.15        - same contract table.
//
// Port/field notes
//   * csr_raddr is the REGISTERED request address and is driven combinationally
//     into the CSR file during the completion cycle; csr_rdata is captured as
//     the old value in that same cycle.
//   * csr_write_en is decode-side state that lives in the CIQ entry and is
//     applied by the commit stage; the value computed here does not depend on
//     it, but the bit is latched and used by the protocol assertion below so
//     the operation state stays complete.
//   * rd=x0 is handled by the commit stage (the GPR write enable), not here;
//     CSRRW[I] always computes a new value, CSRRS/CSRRC[I] always read.
//
// FREE items exercised: FREE-01 (ares_pkg::op_t encodings), FREE-02 (file layout),
// FREE-04 (shared read-modify-write datapath), FREE-10 (verification
// environment).
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */  // CSR FU reads only its own subset of the shared ares_pkg::fu_req_t
module fu_csr (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             issue_valid,
    input  ares_pkg::fu_req_t                issue_req,
    input  logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic [11:0]                      csr_raddr,
    input  logic [31:0]                      csr_rdata,
    output logic                             completion_valid,
    output ares_pkg::fu_completion_t         completion,
    output logic [31:0]                      csr_write_data
);
/* verilator lint_on UNUSEDSIGNAL */
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // In-flight operation (latency = 1, II = 1)
    //-------------------------------------------------------------------------
    logic        op_valid;
    tag_t        op_tag;
    op_t         op_code;
    logic [11:0] op_addr;
    logic        op_write_en;
    logic [31:0] op_src;      // src1, or zero-extended uimm[4:0] for *I forms

    wire op_killed = op_valid && kill_mask[op_tag.slot_index];

    // Immediate forms take the zero-extended uimm[4:0] from the request imm.
    wire issue_imm_form = (issue_req.op == OP_CSRRWI)
                       || (issue_req.op == OP_CSRRSI)
                       || (issue_req.op == OP_CSRRCI);

    always_ff @(posedge clk) begin
        if (rst) begin
            op_valid <= 1'b0;
        end else begin
            // Guaranteed accept, with a same-cycle kill dropping the operation
            // so it can never emit a completion for a killed CIQ entry.
            op_valid <= issue_valid && !kill_mask[issue_req.tag.slot_index];
        end
    end

    always_ff @(posedge clk) begin
        if (issue_valid) begin
            op_tag      <= issue_req.tag;
            op_code     <= issue_req.op;
            op_addr     <= issue_req.csr_addr;
            op_write_en <= issue_req.csr_write_en;
            op_src      <= issue_imm_form ? {27'h0, issue_req.imm[4:0]}
                                          : issue_req.src1;
        end
    end

    //-------------------------------------------------------------------------
    // Read-modify-write classification and new-value datapath
    //-------------------------------------------------------------------------
    wire is_csrrw = (op_code == OP_CSRRW) || (op_code == OP_CSRRWI);
    wire is_csrrs = (op_code == OP_CSRRS) || (op_code == OP_CSRRSI);
    wire is_csrrc = (op_code == OP_CSRRC) || (op_code == OP_CSRRCI);
    wire is_ecall = (op_code == OP_ECALL);
    wire is_mret  = (op_code == OP_MRET);

    // New value written into the CSR file by the commit stage.  It is computed
    // for every Zicsr form; csr_write_en only decides whether commit uses it.
    logic [31:0] new_value;
    always_comb begin
        if (is_csrrw) begin
            new_value = op_src;
        end else if (is_csrrs) begin
            new_value = csr_rdata | op_src;
        end else if (is_csrrc) begin
            new_value = csr_rdata & ~op_src;
        end else begin
            new_value = 32'h0;
        end
    end

    //-------------------------------------------------------------------------
    // Completion / sideband
    //-------------------------------------------------------------------------
    always_comb begin
        csr_raddr        = op_addr;

        completion_valid = op_valid && !op_killed;
        completion       = '0;
        completion.tag   = op_tag;
        completion.result= 32'h0;
        completion.exception = 1'b0;
        completion.cause = EXC_NONE;
        completion.tval  = 32'h0;
        csr_write_data   = 32'h0;

        if (is_ecall) begin
            // backend.md section 17.1: DONE + exception(cause=11, tval=0).
            completion.exception = 1'b1;
            completion.cause     = EXC_ECALL_M;
            completion.tval      = 32'h0;
            completion.result    = 32'h0;
            csr_write_data       = 32'h0;
        end else if (is_mret) begin
            // MRET retires normally; MIE/MPIE/MPP are updated by the commit
            // stage through csr_file.mret_we.
            completion.result    = 32'h0;
            csr_write_data       = 32'h0;
        end else begin
            // Zicsr: old value is the GPR write value.
            completion.result    = csr_rdata;
            csr_write_data       = new_value;
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol assertions (backend.md sections 11 / 16.2 / 17.1)
    //-------------------------------------------------------------------------
    a_write_en_is_csr_op: assert property (@(posedge clk) disable iff (rst)
        (op_valid && op_write_en)
        |-> (op_code == OP_CSRRW) || (op_code == OP_CSRRS) || (op_code == OP_CSRRC)
         || (op_code == OP_CSRRWI) || (op_code == OP_CSRRSI) || (op_code == OP_CSRRCI));

    a_ecall_only_exception: assert property (@(posedge clk) disable iff (rst)
        completion_valid && completion.exception |-> (op_code == OP_ECALL));

    a_ecall_fields: assert property (@(posedge clk) disable iff (rst)
        completion_valid && (op_code == OP_ECALL)
        |-> (completion.cause == EXC_ECALL_M) && (completion.tval == 32'h0)
            && (completion.result == 32'h0) && (csr_write_data == 32'h0));

    a_mret_fields: assert property (@(posedge clk) disable iff (rst)
        completion_valid && (op_code == OP_MRET)
        |-> !completion.exception && (completion.result == 32'h0)
            && (csr_write_data == 32'h0));

    a_zicsr_old_value: assert property (@(posedge clk) disable iff (rst)
        completion_valid && (is_csrrw || is_csrrs || is_csrrc)
        |-> (completion.result == csr_rdata));

    a_csrrw_new: assert property (@(posedge clk) disable iff (rst)
        completion_valid && is_csrrw |-> (csr_write_data == op_src));

    a_csrrs_new: assert property (@(posedge clk) disable iff (rst)
        completion_valid && is_csrrs |-> (csr_write_data == (csr_rdata | op_src)));

    a_csrrc_new: assert property (@(posedge clk) disable iff (rst)
        completion_valid && is_csrrc |-> (csr_write_data == (csr_rdata & ~op_src)));

    a_kill_priority: assert property (@(posedge clk) disable iff (rst)
        (op_valid && kill_mask[op_tag.slot_index]) |-> !completion_valid);

    a_issue_completes: assert property (@(posedge clk) disable iff (rst)
        (issue_valid && !kill_mask[issue_req.tag.slot_index])
        |=> (completion_valid || kill_mask[$past(issue_req.tag.slot_index)]));
`endif

endmodule
