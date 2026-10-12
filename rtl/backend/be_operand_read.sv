//=============================================================================
// ARES backend - Operand Read (B08)
//-----------------------------------------------------------------------------
// Resolves the sources of the four oldest CIQ candidates (backend.md 8.4):
//
//   | source state                                  | ready | data          |
//   |-----------------------------------------------|-------|---------------|
//   | unused or x0                                  | 1     | 0             |
//   | no dependency (src_dep_valid = 0)             | 1     | Architectural |
//   |                                               |       | RF            |
//   | dependency on DONE && !exception producer     | 1     | CIQ result    |
//   | dependency on WAIT/EXEC producer              | 0     | -             |
//   | dependency on an exception producer or on an  | 0     | -             |
//   | invalid slot (protocol error)                 |       |               |
//
// There is no RF fallback for an invalid producer slot: that is a protocol
// error and is reported on dep_error for the assertions (backend.md 8.4).
// Ready checks and the RF/result selection run in parallel; only the final
// arbitration depends on control state.
//
// FREE items: FREE-04 (parallel 8-source resolve, no serial chain).
//=============================================================================
module be_operand_read (
    //---- four oldest WAIT candidates (issue_ptr + 0..3) --------------------
    input  queue_entry_t cand [ISSUE_WIDTH_MAX],

    //---- CIQ entry array for producer result reads -------------------------
    input  queue_entry_t entry [CIQ_ENTRIES],

    //---- GPR read ports (2 per candidate) ----------------------------------
    output logic [4:0]   gpr_raddr [GPR_READ_PORTS],
    input  logic [31:0]  gpr_rdata [GPR_READ_PORTS],

    //---- resolved operands --------------------------------------------------
    output logic [31:0]  src1 [ISSUE_WIDTH_MAX],
    output logic [31:0]  src2 [ISSUE_WIDTH_MAX],
    output logic         src_ready [ISSUE_WIDTH_MAX],

    //---- protocol error: a live dependency points at an invalid slot -------
    output logic         dep_error
);
    import ares_pkg::*;

    logic        rdy1 [ISSUE_WIDTH_MAX];
    logic        rdy2 [ISSUE_WIDTH_MAX];
    logic        err1 [ISSUE_WIDTH_MAX];
    logic        err2 [ISSUE_WIDTH_MAX];

    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            gpr_raddr[2*i]   = cand[i].rs1;
            gpr_raddr[2*i+1] = cand[i].rs2;
        end
    end

    always_comb begin
        dep_error = 1'b0;
        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            // Only a live WAIT candidate can be a real consumer; entries that
            // are EXEC/DONE/FREE are not checked (their operands were already
            // consumed at issue).
            if (!(cand[i].valid && (cand[i].state == ENTRY_WAIT))) begin
                src1[i] = 32'd0;
                src2[i] = 32'd0;
                rdy1[i] = 1'b1;
                rdy2[i] = 1'b1;
                err1[i] = 1'b0;
                err2[i] = 1'b0;
                continue;
            end

            //---- source 1 ---------------------------------------------------
            rdy1[i] = 1'b1;
            err1[i] = 1'b0;
            if (!cand[i].src1_used || (cand[i].rs1 == 5'd0)) begin
                src1[i] = 32'd0;
            end else if (!cand[i].src1_dep_valid) begin
                src1[i] = gpr_rdata[2*i];
            end else begin
                src1[i] = entry[cand[i].src1_dep_tag.slot_index].result;
                if (!entry[cand[i].src1_dep_tag.slot_index].valid) begin
                    rdy1[i] = 1'b0;
                    err1[i] = 1'b1;
                end else begin
                    rdy1[i] = (entry[cand[i].src1_dep_tag.slot_index].state == ENTRY_DONE)
                              && !entry[cand[i].src1_dep_tag.slot_index].exception;
                end
            end

            //---- source 2 ---------------------------------------------------
            rdy2[i] = 1'b1;
            err2[i] = 1'b0;
            if (!cand[i].src2_used || (cand[i].rs2 == 5'd0)) begin
                src2[i] = 32'd0;
            end else if (!cand[i].src2_dep_valid) begin
                src2[i] = gpr_rdata[2*i+1];
            end else begin
                src2[i] = entry[cand[i].src2_dep_tag.slot_index].result;
                if (!entry[cand[i].src2_dep_tag.slot_index].valid) begin
                    rdy2[i] = 1'b0;
                    err2[i] = 1'b1;
                end else begin
                    rdy2[i] = (entry[cand[i].src2_dep_tag.slot_index].state == ENTRY_DONE)
                              && !entry[cand[i].src2_dep_tag.slot_index].exception;
                end
            end

            src_ready[i] = rdy1[i] && rdy2[i];
            dep_error    = dep_error || err1[i] || err2[i];
        end
    end
endmodule
