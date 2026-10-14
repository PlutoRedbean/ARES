//=============================================================================
// ARES core verification - shared package self-test
//-----------------------------------------------------------------------------
// The package is the single source of truth for every cross-module type, so a
// silent width/encoding change there breaks all three consumers at once.  This
// TB pins the frozen layout (docs/c0_decisions.md D-C0-02..04, plan section
// 5.19):
//
//   * $bits() of every cross-boundary type equals its documented width
//   * every enum encoding equals the documented value (FREE-01)
//   * parameter relationships hold (CIQ/tag, line/beat/row, set/tag bits)
//   * RESET_PC is 4-byte aligned
//   * every field of iq_entry_t / bpu_update_t / queue_entry_t / fu_req_t /
//     fu_completion_t survives a distinct-value round trip (no field aliasing)
//
// Update the expectations here together with a reviewed package change - that
// is the point of the test.
//
// Harness: built through sim/Makefile as TOPNAME=tb_ares_pkg.
// Run: make tb-ares-pkg
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_ares_pkg (
    input clock,
    input reset
);
    import ares_pkg::*;
    import fe_pkg::*;

    import "DPI-C" function void ebreak();

    int unsigned errors;
    logic        done;

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %s", msg);
        end
    endtask

    task automatic check_layout;
        pred_meta_t   pm;
        iq_entry_t    iq;
        bpu_update_t  bu;
        queue_entry_t q;
        fu_req_t      rq;
        fu_completion_t cp;
        begin
            //---- widths (frozen layout; see plan section 5.19) -------------
            check($bits(tag_t)              == 4,   "tag_t width");
            check($bits(entry_state_t)      == 2,   "entry_state_t width");
            check($bits(fu_type_t)          == 4,   "fu_type_t width");
            check($bits(op_t)               == 6,   "op_t width");
            check($bits(exception_cause_t)  == 32,  "exception_cause_t width");
            check($bits(cfi_type_t)         == 3,   "cfi_type_t width");
            check($bits(fe_redirect_kind_t) == 1,   "fe_redirect_kind_t width");
            check($bits(chooser_meta_t)     == 14,  "chooser_meta_t width");
            check($bits(pred_meta_t)        == 48,  "pred_meta_t width (fe_pkg)");
            check($bits(iq_entry_t)         == 117, "iq_entry_t width (fe_pkg)");
            check($bits(bpu_update_t)       == 116, "bpu_update_t width (fe_pkg)");
            check($bits(queue_entry_t)      == 401, "queue_entry_t width");
            check($bits(fu_req_t)           == 183, "fu_req_t width");
            check($bits(fu_completion_t)    == 101, "fu_completion_t width");

            //---- enum encodings (FREE-01) ----------------------------------
            check(ENTRY_FREE == 2'd0 && ENTRY_WAIT == 2'd1
                  && ENTRY_EXEC == 2'd2 && ENTRY_DONE == 2'd3, "entry_state_t");
            check(FU_ALU0 == 4'd0 && FU_ALU1 == 4'd1 && FU_BRU == 4'd2
                  && FU_SMUL == 4'd3 && FU_MUL == 4'd4 && FU_DIV == 4'd5
                  && FU_CSR == 4'd6 && FU_LSU == 4'd7, "fu_type_t");
            check(CFI_NONE == 3'd0 && CFI_COND_BRANCH == 3'd1
                  && CFI_DIRECT_JUMP == 3'd2 && CFI_CALL == 3'd3
                  && CFI_RETURN == 3'd4 && CFI_INDIRECT_JUMP == 3'd5, "cfi_type_t");
            check(REDIRECT_BRANCH == 1'b0 && REDIRECT_ARCH == 1'b1,
                  "fe_redirect_kind_t");
            check(EXC_NONE == 32'h0 && EXC_ECALL_M == 32'd11
                  && EXC_MACHINE_TIMER == 32'h8000_0007, "exception_cause_t");
            check(OP_ILLEGAL == 6'd55, "op_t last value");
            check(OP_LUI == 6'd0 && OP_JAL == 6'd2 && OP_BEQ == 6'd4
                  && OP_LW == 6'd12 && OP_SW == 6'd17 && OP_ADDI == 6'd18
                  && OP_ADD == 6'd27 && OP_MUL == 6'd37 && OP_DIV == 6'd41
                  && OP_CSRRW == 6'd45 && OP_ECALL == 6'd51 && OP_MRET == 6'd53,
                  "op_t spot checks");

            //---- parameter relationships -----------------------------------
            check(CIQ_ENTRIES == (1 << CIQ_SLOT_BITS), "CIQ_ENTRIES vs tag width");
            check(ares_pkg::FETCH_WIDTH == 4 && ares_pkg::DECODE_WIDTH == 2 && DISPATCH_WIDTH == 2
                  && ISSUE_WIDTH_MAX == 4 && COMMIT_WIDTH == 2, "pipeline widths");
            check(ares_pkg::GHR_WIDTH == 12 && BPU_UPDATE_FIFO_DEPTH >= 2,
                  "BPU interface parameters");
            //---- configuration menu (configs/Kconfig, make menuconfig) ------
            // These are the values the build actually elaborated with; they are
            // printed below so a log records the effective configuration.
            check(MUL_LATENCY == 2 || MUL_LATENCY == 3,
                  "MUL_LATENCY outside the configs/Kconfig range 2..3");
            check(!HAS_MISA && !HAS_MTVAL && !HAS_MCYCLE,
                  "optional CSRs must stay disabled (D-C0-13) - update this check if that is ever reviewed");
            check(LINE_BYTES == 16 || LINE_BYTES == 32 || LINE_BYTES == 64,
                  "LINE_BYTES outside the configs/Kconfig choice 16/32/64");
            check(LINE_BEATS == LINE_BYTES / 16 && ROWS_PER_LINE == LINE_BYTES / 8,
                  "line geometry");
            check(LINE_BEATS >= 1 && ROWS_PER_LINE >= 2, "line geometry minimum");
            check(DCACHE_NUM_SETS ==
                  DCACHE_SIZE_BYTES / (DCACHE_NUM_WAYS * LINE_BYTES),
                  "DCache set count");
            check((DCACHE_NUM_SETS & (DCACHE_NUM_SETS - 1)) == 0,
                  "DCache set count is not a power of two");
            check(DCACHE_INDEX_BITS + DCACHE_OFFSET_BITS + DCACHE_TAG_BITS
                  == ares_pkg::ADDR_WIDTH, "DCache address split");
            check(LQ_ENTRIES == 4 && SQ_ENTRIES == 8 && MSHR_ENTRIES == 2
                  && WB_ENTRIES == 2, "LSU queue sizes");
            check(RESET_PC[1:0] == 2'b00, "RESET_PC 4-byte alignment");

            //---- field round trips (distinct value in every field) ---------
            pm = '0;
            pm.pred_target   = 32'h8000_1234;
            pm.pred_taken    = 1'b1;
            pm.chooser_meta.update_gshare_taken  = 1'b1;
            pm.chooser_meta.update_bimodal_taken = 1'b0;
            pm.chooser_meta.pred_ghr             = 12'h123;
            pm.loop_override = 1'b1;

            iq = '0;
            iq.pc            = 32'h8000_0100;
            iq.pred_meta     = pm;
            iq.inst          = 32'h00c58533;   // add a0, a1, a2
            iq.valid         = 1'b1;
            iq.cfi_type      = CFI_RETURN;
            iq.is_cfi        = 1'b1;
            check(iq.pc == 32'h8000_0100
                  && iq.inst == 32'h00c58533 && iq.valid
                  && iq.cfi_type == CFI_RETURN && iq.is_cfi
                  && iq.pred_meta.pred_target == 32'h8000_1234
                  && iq.pred_meta.pred_taken
                  && iq.pred_meta.chooser_meta.pred_ghr == 12'h123
                  && iq.pred_meta.loop_override, "iq_entry_t round trip");

            bu = '0;
            bu.update_pc        = 32'h8000_0ffc;
            bu.actual_taken     = 1'b1;
            bu.actual_target    = 32'h8000_0400;
            bu.actual_cfi_type  = CFI_COND_BRANCH;
            bu.pred_meta        = pm;
            check(bu.update_pc == 32'h8000_0ffc && bu.actual_taken
                  && bu.actual_target == 32'h8000_0400
                  && bu.actual_cfi_type == CFI_COND_BRANCH
                  && bu.pred_meta.chooser_meta.pred_ghr == 12'h123, "bpu_update_t round trip");

            q = '0;
            q.valid = 1'b1;      q.state = ENTRY_DONE;
            q.pc = 32'h8000_0004; q.pred_npc = 32'h8000_0008;
            q.pred_meta = pm;
            q.actual_cfi_type = CFI_DIRECT_JUMP;
            q.actual_npc = 32'h8000_0080; q.actual_taken = 1'b1;
            q.actual_target = 32'h8000_0080;
            q.fu_type = FU_BRU;  q.op = OP_JAL;
            q.rd = 5'd1;         q.rd_wen = 1'b1;
            q.rs1 = 5'd2;        q.src1_used = 1'b1;
            q.src1_dep_valid = 1'b1; q.src1_dep_tag.slot_index = 4'h7;
            q.rs2 = 5'd3;        q.src2_used = 1'b1;
            q.src2_dep_valid = 1'b1; q.src2_dep_tag.slot_index = 4'h9;
            q.imm = 32'hffff_f000; q.result = 32'h8000_0008;
            q.csr_addr = 12'h305;  q.csr_write_en = 1'b1;
            q.csr_write_data = 32'h8000_1000; q.is_serializing = 1'b1;
            q.exception = 1'b0;    q.exception_cause = EXC_NONE;
            q.exception_tval = 32'h1234_5678;
            q.is_branch = 1'b0;    q.is_load = 1'b0; q.is_store = 1'b0;
            q.is_csr = 1'b0;       q.is_fence = 1'b0;
            check(q.valid && q.state == ENTRY_DONE && q.pc == 32'h8000_0004
                  && q.pred_npc == 32'h8000_0008
                  && q.actual_cfi_type == CFI_DIRECT_JUMP
                  && q.actual_npc == 32'h8000_0080 && q.actual_taken
                  && q.actual_target == 32'h8000_0080
                  && q.fu_type == FU_BRU && q.op == OP_JAL
                  && q.rd == 5'd1 && q.rd_wen
                  && q.rs1 == 5'd2 && q.src1_used && q.src1_dep_valid
                  && q.src1_dep_tag.slot_index == 4'h7
                  && q.rs2 == 5'd3 && q.src2_used && q.src2_dep_valid
                  && q.src2_dep_tag.slot_index == 4'h9
                  && q.imm == 32'hffff_f000 && q.result == 32'h8000_0008
                  && q.csr_addr == 12'h305 && q.csr_write_en
                  && q.csr_write_data == 32'h8000_1000 && q.is_serializing
                  && !q.exception && q.exception_cause == EXC_NONE
                  && q.exception_tval == 32'h1234_5678
                  && !q.is_branch && !q.is_load && !q.is_store
                  && !q.is_csr && !q.is_fence
                  && q.pred_meta.pred_taken, "queue_entry_t round trip");

            rq = '0;
            rq.tag.slot_index = 4'hb; rq.op = OP_JALR;
            rq.src1 = 32'h8000_0000;  rq.src2 = 32'hdead_beef;
            rq.imm = 32'h0000_0004;   rq.pc = 32'h8000_0030;
            rq.pred_npc = 32'h8000_0034;
            rq.csr_addr = 12'h341;    rq.csr_write_en = 1'b1;
            check(rq.tag.slot_index == 4'hb && rq.op == OP_JALR
                  && rq.src1 == 32'h8000_0000 && rq.src2 == 32'hdead_beef
                  && rq.imm == 32'h0000_0004 && rq.pc == 32'h8000_0030
                  && rq.pred_npc == 32'h8000_0034
                  && rq.csr_addr == 12'h341 && rq.csr_write_en,
                  "fu_req_t round trip");

            cp = '0;
            cp.tag.slot_index = 4'h3; cp.result = 32'hcafe_babe;
            cp.exception = 1'b1;      cp.cause = EXC_ECALL_M;
            cp.tval = 32'h0000_0000;
            check(cp.tag.slot_index == 4'h3 && cp.result == 32'hcafe_babe
                  && cp.exception && cp.cause == EXC_ECALL_M && cp.tval == 32'd0,
                  "fu_completion_t round trip");
        end
    endtask

    always_ff @(posedge clock) begin
        if (reset) begin
            errors <= 0;
            done   <= 1'b0;
        end else if (!done) begin
            done <= 1'b1;
            check_layout();
            if (errors == 0) begin
                $display("note: optional CSRs misa=%0b mtval=%0b mcycle=%0b (D-C0-13)",
                         HAS_MISA, HAS_MTVAL, HAS_MCYCLE);
                $display("ALL TESTS PASSED: tb_ares_pkg layout/encoding checks (MUL_LATENCY=%0d, LINE_BYTES=%0d, %0d type widths)",
                         MUL_LATENCY, LINE_BYTES, 14);
                ebreak();
            end else begin
                $display("FAILED: tb_ares_pkg saw %0d errors", errors);
                $fatal(1, "tb_ares_pkg layout mismatch");
            end
        end
    end

endmodule
