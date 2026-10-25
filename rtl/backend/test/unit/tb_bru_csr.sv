`timescale 1ns/1ps
//=============================================================================
// ARES - Backend unit test: fu_bru (B11) + csr_file (B16) + fu_csr (B15)
//-----------------------------------------------------------------------------
// Standalone, self-checking bench (own clock, no DPI model, no test image).
// Every stimulus is driven on a falling edge and sampled 1 ns after the next
// rising edge, so the DUT sees stable inputs and the checks see settled
// combinational outputs.
//
// Coverage
//   fu_bru (backend.md 9.2 / 10 / 11 / 15.1, contract section 4)
//     * all six conditional branches taken AND not taken, including the
//       sign/zero-extension boundaries (0xFFFFFFFF vs 0/1)
//     * actual_target is the immediate target even for a NOT-taken branch and
//       is never mixed with actual_npc
//     * JAL / JALR targets, negative immediates, JALR bit-0 clearing, wrap
//     * completion.result = pc+4, no exception, latency >= 1 cycle, single
//       cycle pulse
//     * pred_npc equal (no recovery) and unequal (recovery with
//       recovery_branch_tag + redirect_pc) for branches and jumps
//     * kill in the completion cycle -> no completion (kill wins over the
//       completion) and no recovery afterwards; kill in the issue cycle -> the
//       operation is dropped and never completes or recovers.  The BRU recovery
//       is intentionally NOT kill-gated (C1 loop-break fix documented in
//       fu_bru.sv), so this bench only ever kills a non-recovering operation.
//     * 800-case fixed-seed randomised cross-check against a reference model
//
//   csr_file (backend.md 16.1)
//     * reset values (mstatus.MIE/MPIE = 0, MPP = 2'b11, mie/mepc/mcause/
//       mscratch = 0, mtvec = RESET_MTVEC with MODE forced 00 - the bench
//       deliberately passes an unaligned RESET_MTVEC)
//     * mstatus MIE[3]/MPIE[7] R/W with everything else ignored, mie
//       MSIE[3]/MTIE[7]/MEIE[11] only, mtvec MODE forced 00, mepc[1:0] forced
//       00, mscratch/mcause full 32-bit R/W, mip software writes ignored and
//       MSIP/MTIP/MEIP following software_irq/timer_irq/external_irq,
//       mhartid read-only HART_ID (0 in this instance)
//     * raddr_ok = 1 for the eight required addresses and 0 for 0x301/0x343/
//       0xB00/0xB80 (HAS_* are 0) and for other unknown addresses
//     * trap_we and mret_we mstatus transitions plus the trap > mret > normal
//       write priority
//     * 200-case fixed-seed randomised write/readback against a reference model
//
//   fu_csr (backend.md 11.8 / 16.2 / 16.3 / 17.1)
//     * FENCE/FENCE.I no-op completion with zero result/write sideband
//     * all six Zicsr forms: old value as completion.result, new value
//       (src / old|src / old&~src) as csr_write_data, register vs zero-extended
//       uimm[4:0] operand selection, src=0 (rs1=x0 / uimm=0) cases including
//       the write-enable rules, rd=x0 (the unit has no rd port - the GPR write
//       enable is commit-side, noted here because CSRRW[I] still computes a
//       write)
//     * the registered csr_raddr is stable during the issue cycle, driven into
//       the real csr_file in the completion cycle, and the file value is
//       captured as the old value (integration)
//     * a CSRRW through this unit does NOT modify the CSR file (commit does)
//     * ECALL: exception=1, cause=EXC_ECALL_M, tval=0, result=0,
//       csr_write_data=0; MRET: normal completion, all-zero sidebands
//     * kill in the completion cycle and in the issue cycle -> no completion
//
// Harness: this file is its own top module (no sim/ main.cpp, no +PROGRAM).
// Build + run (from the repository root), one command:
//   cmd:  verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD
//         -DCONFIG_SIMULATION --top-module tb_bru_csr --Mdir /tmp/obj_tb_bru_csr
//         -o /tmp/tb_bru_csr rtl/common/ares_pkg.sv rtl/backend/fu_bru.sv
//         rtl/backend/csr_file.sv rtl/backend/fu_csr.sv
//         rtl/backend/test/unit/tb_bru_csr.sv && /tmp/tb_bru_csr
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_bru_csr;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Clock, reset, scoreboard
    //-------------------------------------------------------------------------
    logic clk;
    logic rst;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic check(input logic cond, input string msg);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("[%0t] FAIL: %s", $time, msg);
        end
    endtask

    // Fixed-seed random stream: every call advances the state from the
    // constant seed, so any failure reproduces exactly.
    int unsigned rnd_state = 32'hC0FF_EE01;
    function automatic logic [31:0] rnd32;
        begin
            rnd_state = $urandom(rnd_state);
            rnd32     = rnd_state;
        end
    endfunction

    //-------------------------------------------------------------------------
    // DUT signal declarations
    //-------------------------------------------------------------------------
    // fu_bru
    logic                   bru_issue_valid;
    fu_req_t                bru_issue_req;
    logic [CIQ_ENTRIES-1:0] bru_kill_mask;
    logic                   bru_completion_valid;
    fu_completion_t         bru_completion;
    logic [31:0]            bru_actual_npc;
    logic                   bru_actual_taken;
    logic [31:0]            bru_actual_target;
    logic                   bru_recovery_valid;
    tag_t                   bru_recovery_branch_tag;
    logic [31:0]            bru_redirect_pc;

    // csr_file (directed stimulus)
    logic        timer_irq;
    logic        software_irq;
    logic        external_irq;
    logic [11:0] csr_raddr_direct;
    logic        csr_read_sel;          // 0 = direct reads, 1 = fu_csr read port
    logic [31:0] csr_rdata;
    logic        csr_raddr_ok;
    logic        csr_we;
    logic [11:0] csr_waddr;
    logic [31:0] csr_wdata;
    logic        csr_trap_we;
    logic [31:0] csr_trap_mepc;
    logic [31:0] csr_trap_mcause;
    logic        csr_mret_we;
    logic        csr_mstatus_mie;
    logic        csr_mie_msie;
    logic        csr_mie_mtie;
    logic        csr_mie_meie;
    logic        csr_mip_msip;
    logic        csr_mip_mtip;
    logic        csr_mip_meip;
    logic [31:0] csr_mtvec;
    logic [31:0] csr_mepc;

    // fu_csr
    logic                   fu_csr_issue_valid;
    fu_req_t                fu_csr_issue_req;
    logic [CIQ_ENTRIES-1:0] fu_csr_kill_mask;
    logic [11:0]            fu_csr_raddr;
    logic [31:0]            fu_csr_rdata_tb;   // TB-provided old value
    logic                   fu_csr_completion_valid;
    fu_completion_t         fu_csr_completion;
    logic [31:0]            fu_csr_write_data;

    // The CSR unit's registered read address is wired straight into the CSR
    // file when csr_read_sel = 1 (integration test), otherwise the bench drives
    // the address itself.
    wire [11:0] csr_raddr = csr_read_sel ? fu_csr_raddr : csr_raddr_direct;
    wire [31:0] fu_csr_rdata = csr_read_sel ? csr_rdata : fu_csr_rdata_tb;

    //-------------------------------------------------------------------------
    // DUTs
    //-------------------------------------------------------------------------
    fu_bru dut_bru (
        .clk                 (clk),
        .rst                 (rst),
        .issue_valid         (bru_issue_valid),
        .issue_req           (bru_issue_req),
        .kill_mask           (bru_kill_mask),
        .completion_valid    (bru_completion_valid),
        .completion          (bru_completion),
        .actual_npc          (bru_actual_npc),
        .actual_taken        (bru_actual_taken),
        .actual_target       (bru_actual_target),
        .recovery_valid      (bru_recovery_valid),
        .recovery_branch_tag (bru_recovery_branch_tag),
        .redirect_pc         (bru_redirect_pc)
    );

    // RESET_MTVEC is deliberately NOT 4-byte aligned: the bench proves that the
    // reset value and every later write force MODE[1:0] = 00.
    csr_file #(.RESET_MTVEC(32'h8000_0002)) dut_csr (
        .clk           (clk),
        .rst           (rst),
        .timer_irq     (timer_irq),
        .software_irq  (software_irq),
        .external_irq  (external_irq),
        .raddr         (csr_raddr),
        .rdata         (csr_rdata),
        .raddr_ok      (csr_raddr_ok),
        .we            (csr_we),
        .waddr         (csr_waddr),
        .wdata         (csr_wdata),
        .trap_we       (csr_trap_we),
        .trap_mepc     (csr_trap_mepc),
        .trap_mcause   (csr_trap_mcause),
        .mret_we       (csr_mret_we),
        .mstatus_mie   (csr_mstatus_mie),
        .mie_msie      (csr_mie_msie),
        .mie_mtie      (csr_mie_mtie),
        .mie_meie      (csr_mie_meie),
        .mip_msip      (csr_mip_msip),
        .mip_mtip      (csr_mip_mtip),
        .mip_meip      (csr_mip_meip),
        .mtvec         (csr_mtvec),
        .mepc          (csr_mepc)
    );

    fu_csr dut_fu_csr (
        .clk              (clk),
        .rst              (rst),
        .issue_valid      (fu_csr_issue_valid),
        .issue_req        (fu_csr_issue_req),
        .kill_mask        (fu_csr_kill_mask),
        .csr_raddr        (fu_csr_raddr),
        .csr_rdata        (fu_csr_rdata),
        .completion_valid (fu_csr_completion_valid),
        .completion       (fu_csr_completion),
        .csr_write_data   (fu_csr_write_data)
    );

    //-------------------------------------------------------------------------
    // Helpers
    //-------------------------------------------------------------------------
    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MISA     = 12'h301;
    localparam logic [11:0] CSR_MIE      = 12'h304;
    localparam logic [11:0] CSR_MTVEC    = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;
    localparam logic [11:0] CSR_MCAUSE   = 12'h342;
    localparam logic [11:0] CSR_MTVAL    = 12'h343;
    localparam logic [11:0] CSR_MIP      = 12'h344;
    localparam logic [11:0] CSR_MCYCLE   = 12'hB00;
    localparam logic [11:0] CSR_MCYCLEH  = 12'hB80;
    localparam logic [11:0] CSR_MHARTID  = 12'hF14;

    // mstatus read image: MPP fixed 2'b11, MPIE[7], MIE[3], nothing else.
    function automatic logic [31:0] mstatus_image(input logic mie, input logic mpie);
        begin
            mstatus_image = {19'h0, 2'b11, 3'h0, mpie, 3'h0, mie, 3'h0};
        end
    endfunction

    function automatic logic [31:0] mie_image(input logic msie, input logic mtie, input logic meie);
        begin
            mie_image       = 32'h0;
            mie_image[3]    = msie;
            mie_image[7]    = mtie;
            mie_image[11]   = meie;
        end
    endfunction

    function automatic logic [31:0] mip_image(input logic msip, input logic mtip, input logic meip);
        begin
            mip_image       = 32'h0;
            mip_image[3]    = msip;
            mip_image[7]    = mtip;
            mip_image[11]   = meip;
        end
    endfunction

    function automatic tag_t mk_tag(input logic [3:0] idx);
        tag_t t;
        begin
            t.slot_index = idx;
            mk_tag       = t;
        end
    endfunction

    function automatic fu_req_t mk_bru_req(input tag_t tag, input op_t op, input logic [31:0] pc, src1, src2, imm, input logic [31:0] pred_npc);
        fu_req_t r;
        begin
            r = '0;
            r.tag           = tag;
            r.op            = op;
            r.pc            = pc;
            r.src1          = src1;
            r.src2          = src2;
            r.imm           = imm;
            r.pred_npc      = pred_npc;
            mk_bru_req      = r;
        end
    endfunction

    //-------------------------------------------------------------------------
    // fu_bru: one operation end to end (issue, completion, recovery sideband,
    // then the single-cycle check)
    //-------------------------------------------------------------------------
    task automatic bru_case(input op_t         op, input logic [31:0] pc, input logic [31:0] src1, input logic [31:0] src2, input logic [31:0] imm, input logic [31:0] pred_npc, input logic        exp_taken, input logic [31:0] exp_target, input logic [31:0] exp_npc, input tag_t        tag, input string       name);
        logic exp_recovery;
        begin
            exp_recovery = (exp_npc != pred_npc);

            @(negedge clk);
            check(!bru_completion_valid, $sformatf("%s: BRU idle before issue", name));
            bru_issue_valid = 1'b1;
            bru_issue_req   = mk_bru_req(tag, op, pc, src1, src2, imm, pred_npc);
            bru_kill_mask   = '0;
            #1;
            check(!bru_completion_valid, $sformatf("%s: no completion in the issue cycle", name));

            @(posedge clk); #1;
            bru_issue_valid = 1'b0;
            bru_issue_req   = '0;

            check(bru_completion_valid, $sformatf("%s: completion_valid", name));
            check(bru_completion.tag.slot_index == tag.slot_index,
                  $sformatf("%s: completion tag exp=%0d got=%0d", name, tag.slot_index,
                            bru_completion.tag.slot_index));
            check(bru_completion.result == pc + 32'd4,
                  $sformatf("%s: result exp=%h got=%h", name, pc + 32'd4, bru_completion.result));
            check(!bru_completion.exception && (bru_completion.cause == EXC_NONE)
                  && (bru_completion.tval == 32'h0),
                  $sformatf("%s: BRU never raises an exception", name));
            check(bru_actual_taken == exp_taken,
                  $sformatf("%s: actual_taken exp=%0b got=%0b", name, exp_taken, bru_actual_taken));
            check(bru_actual_npc == exp_npc,
                  $sformatf("%s: actual_npc exp=%h got=%h", name, exp_npc, bru_actual_npc));
            check(bru_actual_target == exp_target,
                  $sformatf("%s: actual_target exp=%h got=%h", name, exp_target, bru_actual_target));
            check(bru_recovery_valid == exp_recovery,
                  $sformatf("%s: recovery_valid exp=%0b got=%0b", name, exp_recovery, bru_recovery_valid));
            if (exp_recovery) begin
                check(bru_recovery_branch_tag.slot_index == tag.slot_index,
                      $sformatf("%s: recovery tag exp=%0d got=%0d", name, tag.slot_index,
                                bru_recovery_branch_tag.slot_index));
                check(bru_redirect_pc == exp_npc,
                      $sformatf("%s: redirect_pc exp=%h got=%h", name, exp_npc, bru_redirect_pc));
            end

            @(posedge clk); #1;
            check(!bru_completion_valid, $sformatf("%s: completion is a single-cycle pulse", name));
            check(!bru_recovery_valid, $sformatf("%s: recovery is a single-cycle pulse", name));
        end
    endtask

    //-------------------------------------------------------------------------
    // Reference model for the randomised BRU sweep (independent arithmetic)
    //-------------------------------------------------------------------------
    function automatic logic ref_taken(input op_t op, input logic [31:0] a, input logic [31:0] b);
        logic signed [31:0] sa;
        logic signed [31:0] sb;
        begin
            sa = a;
            sb = b;
            case (op)
                OP_BEQ:  ref_taken = (a == b);
                OP_BNE:  ref_taken = (a != b);
                OP_BLT:  ref_taken = (sa <  sb);
                OP_BGE:  ref_taken = (sa >= sb);
                OP_BLTU: ref_taken = (a <  b);
                OP_BGEU: ref_taken = (a >= b);
                default: ref_taken = 1'b0;
            endcase
        end
    endfunction

    function automatic logic [31:0] ref_npc(input op_t op, input logic [31:0] pc,
                                            input logic [31:0] a, b, imm);
        logic [31:0] tgt;
        begin
            tgt = (op == OP_JALR) ? ((a + imm) & 32'hFFFF_FFFE) : (pc + imm);
            case (op)
                OP_JAL:  ref_npc = tgt;
                OP_JALR: ref_npc = tgt;
                OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU:
                    ref_npc = ref_taken(op, a, b) ? tgt : (pc + 32'd4);
                default: ref_npc = pc + 32'd4;
            endcase
        end
    endfunction

    function automatic logic [31:0] ref_target(input op_t op, input logic [31:0] pc,
                                               input logic [31:0] a, imm);
        begin
            ref_target = (op == OP_JALR) ? ((a + imm) & 32'hFFFF_FFFE) : (pc + imm);
        end
    endfunction

    //-------------------------------------------------------------------------
    // csr_file stimulus helpers
    //-------------------------------------------------------------------------
    task automatic csr_write(input logic [11:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            csr_we    = 1'b1;
            csr_waddr = addr;
            csr_wdata = data;
            @(posedge clk); #1;
            csr_we    = 1'b0;
            csr_waddr = 12'h0;
            csr_wdata = 32'h0;
        end
    endtask

    task automatic csr_read_check(input logic [11:0] addr, input logic [31:0] exp_data,
                                  input logic exp_ok, input string name);
        begin
            @(negedge clk);
            csr_read_sel     = 1'b0;
            csr_raddr_direct = addr;
            #1;
            check(csr_raddr_ok == exp_ok,
                  $sformatf("%s: raddr_ok exp=%0b got=%0b", name, exp_ok, csr_raddr_ok));
            check(csr_rdata == exp_data,
                  $sformatf("%s: rdata exp=%h got=%h", name, exp_data, csr_rdata));
            @(posedge clk); #1;
            csr_raddr_direct = 12'h0;
        end
    endtask

    task automatic csr_trap(input logic [31:0] epc, input logic [31:0] cause);
        begin
            @(negedge clk);
            csr_trap_we     = 1'b1;
            csr_trap_mepc   = epc;
            csr_trap_mcause = cause;
            @(posedge clk); #1;
            csr_trap_we     = 1'b0;
            csr_trap_mepc   = 32'h0;
            csr_trap_mcause = 32'h0;
        end
    endtask

    task automatic csr_mret;
        begin
            @(negedge clk);
            csr_mret_we = 1'b1;
            @(posedge clk); #1;
            csr_mret_we = 1'b0;
        end
    endtask

    // trap_we + mret_we (+ optional normal write) in the same cycle: the
    // documented priority is trap > mret > commit write.
    task automatic csr_trap_mret_write(input logic [31:0] epc, input logic [31:0] cause,
                                       input logic do_write, input logic [11:0] addr,
                                       input logic [31:0] data);
        begin
            @(negedge clk);
            csr_trap_we     = 1'b1;
            csr_trap_mepc   = epc;
            csr_trap_mcause = cause;
            csr_mret_we     = 1'b1;
            if (do_write) begin
                csr_we    = 1'b1;
                csr_waddr = addr;
                csr_wdata = data;
            end
            @(posedge clk); #1;
            csr_trap_we     = 1'b0;
            csr_trap_mepc   = 32'h0;
            csr_trap_mcause = 32'h0;
            csr_mret_we     = 1'b0;
            csr_we          = 1'b0;
            csr_waddr       = 12'h0;
            csr_wdata       = 32'h0;
        end
    endtask

    //-------------------------------------------------------------------------
    // fu_csr stimulus helper
    //-------------------------------------------------------------------------
    logic [11:0] fu_csr_prev_addr;

    task automatic fu_csr_op(
        input op_t         op,
        input logic [11:0] addr,
        input logic [31:0] operand,
        input logic        use_imm,
        input logic        write_en,
        input logic [31:0] old_value,
        input logic [31:0] exp_result,
        input logic [31:0] exp_wdata,
        input logic        exp_exc,
        input tag_t        tag,
        input string       name
    );
        fu_req_t req;
        begin
            req = '0;
            req.tag          = tag;
            req.op           = op;
            req.csr_addr     = addr;
            req.csr_write_en = write_en;
            if (use_imm) begin
                req.src1 = 32'hDEAD_BEEF;   // must be ignored by the *I forms
                req.imm  = operand;
            end else begin
                req.src1 = operand;
                req.imm  = 32'hDEAD_BEEF;   // must be ignored by the register forms
            end

            @(negedge clk);
            csr_read_sel = 1'b0;
            check(!fu_csr_completion_valid, $sformatf("%s: FU idle before issue", name));
            check(fu_csr_raddr == fu_csr_prev_addr,
                  $sformatf("%s: csr_raddr stays registered during the issue cycle", name));
            fu_csr_rdata_tb    = old_value;
            fu_csr_issue_valid = 1'b1;
            fu_csr_issue_req   = req;
            fu_csr_kill_mask   = '0;
            #1;
            check(!fu_csr_completion_valid, $sformatf("%s: no completion in the issue cycle", name));

            @(posedge clk); #1;
            fu_csr_issue_valid = 1'b0;
            fu_csr_issue_req   = '0;
            fu_csr_prev_addr   = addr;

            check(fu_csr_completion_valid, $sformatf("%s: completion_valid", name));
            check(fu_csr_raddr == addr,
                  $sformatf("%s: csr_raddr exp=%h got=%h", name, addr, fu_csr_raddr));
            check(fu_csr_completion.tag.slot_index == tag.slot_index,
                  $sformatf("%s: completion tag exp=%0d got=%0d", name, tag.slot_index,
                            fu_csr_completion.tag.slot_index));
            check(fu_csr_completion.result == exp_result,
                  $sformatf("%s: result (old value) exp=%h got=%h", name, exp_result,
                            fu_csr_completion.result));
            check(fu_csr_write_data == exp_wdata,
                  $sformatf("%s: csr_write_data (new value) exp=%h got=%h", name, exp_wdata,
                            fu_csr_write_data));
            check(fu_csr_completion.exception == exp_exc,
                  $sformatf("%s: exception exp=%0b got=%0b", name, exp_exc,
                            fu_csr_completion.exception));
            if (exp_exc) begin
                check(fu_csr_completion.cause == EXC_ECALL_M,
                      $sformatf("%s: cause exp=EXC_ECALL_M got=%h", name, fu_csr_completion.cause));
                check(fu_csr_completion.tval == 32'h0,
                      $sformatf("%s: tval exp=0 got=%h", name, fu_csr_completion.tval));
            end

            @(posedge clk); #1;
            check(!fu_csr_completion_valid, $sformatf("%s: single-cycle completion", name));
        end
    endtask

    //-------------------------------------------------------------------------
    // Directed BRU tests
    //-------------------------------------------------------------------------
    task automatic test_bru_branches;
        tag_t t;
        begin
            t = mk_tag(4'd0);
            // BEQ taken; target == npc; prediction correct -> no recovery
            bru_case(OP_BEQ, 32'h8000_0000, 32'h0000_0005, 32'h0000_0005, 32'h0000_0020, 32'h8000_0020, 1'b1, 32'h8000_0020, 32'h8000_0020, t, "BEQ taken");

            // BEQ not taken: actual_target (0x8000_0120) != actual_npc (pc+4)
            t = mk_tag(4'd1);
            bru_case(OP_BEQ, 32'h8000_0100, 32'h0000_0005, 32'h0000_0006, 32'h0000_0020, 32'h8000_0104, 1'b0, 32'h8000_0120, 32'h8000_0104, t, "BEQ not taken");

            // BNE taken with a negative immediate
            t = mk_tag(4'd2);
            bru_case(OP_BNE, 32'h8000_0200, 32'h0000_0007, 32'h0000_0009, 32'hFFFF_FFF0, 32'h8000_01F0, 1'b1, 32'h8000_01F0, 32'h8000_01F0, t, "BNE taken");

            // BNE not taken
            t = mk_tag(4'd3);
            bru_case(OP_BNE, 32'h8000_0200, 32'h0000_0009, 32'h0000_0009, 32'h0000_0010, 32'h8000_0204, 1'b0, 32'h8000_0210, 32'h8000_0204, t, "BNE not taken");

            // BLT signed: -1 < 0 taken ...
            t = mk_tag(4'd4);
            bru_case(OP_BLT, 32'h8000_0300, 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0040, 32'h8000_0340, 1'b1, 32'h8000_0340, 32'h8000_0340, t, "BLT taken (-1<0)");
            // ... and 0 < -1 not taken (an unsigned compare would say taken)
            t = mk_tag(4'd5);
            bru_case(OP_BLT, 32'h8000_0300, 32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_0040, 32'h8000_0304, 1'b0, 32'h8000_0340, 32'h8000_0304, t, "BLT not taken (0<-1)");

            // BGE signed
            t = mk_tag(4'd6);
            bru_case(OP_BGE, 32'h8000_0400, 32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_0008, 32'h8000_0408, 1'b1, 32'h8000_0408, 32'h8000_0408, t, "BGE taken (0>=-1)");
            t = mk_tag(4'd7);
            bru_case(OP_BGE, 32'h8000_0400, 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0008, 32'h8000_0404, 1'b0, 32'h8000_0408, 32'h8000_0404, t, "BGE not taken (-1>=0)");

            // BLTU unsigned
            t = mk_tag(4'd8);
            bru_case(OP_BLTU, 32'h8000_0500, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0004, 32'h8000_0504, 1'b1, 32'h8000_0504, 32'h8000_0504, t, "BLTU taken (1<max)");
            t = mk_tag(4'd9);
            bru_case(OP_BLTU, 32'h8000_0500, 32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0010, 32'h8000_0504, 1'b0, 32'h8000_0510, 32'h8000_0504, t, "BLTU not taken (max<1)");

            // BGEU unsigned
            t = mk_tag(4'd10);
            bru_case(OP_BGEU, 32'h8000_0600, 32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0100, 32'h8000_0700, 1'b1, 32'h8000_0700, 32'h8000_0700, t, "BGEU taken (max>=1)");
            t = mk_tag(4'd11);
            bru_case(OP_BGEU, 32'h8000_0600, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0100, 32'h8000_0604, 1'b0, 32'h8000_0700, 32'h8000_0604, t, "BGEU not taken (1>=max)");
        end
    endtask

    task automatic test_bru_jumps;
        tag_t t;
        begin
            t = mk_tag(4'd0);
            bru_case(OP_JAL, 32'h8000_1000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0100, 32'h8000_1100, 1'b1, 32'h8000_1100, 32'h8000_1100, t, "JAL +imm");

            t = mk_tag(4'd3);
            bru_case(OP_JAL, 32'h8000_2000, 32'h0000_0000, 32'h0000_0000, 32'hFFFF_FFF0, 32'h8000_1FF0, 1'b1, 32'h8000_1FF0, 32'h8000_1FF0, t, "JAL -imm");

            t = mk_tag(4'd5);
            bru_case(OP_JALR, 32'h8000_3000, 32'h8000_4004, 32'h0000_0000, 32'h0000_0004, 32'h8000_4008, 1'b1, 32'h8000_4008, 32'h8000_4008, t, "JALR target");

            // JALR clears bit 0 of (src1 + imm)
            t = mk_tag(4'd7);
            bru_case(OP_JALR, 32'h8000_3000, 32'h8000_4005, 32'h0000_0000, 32'h0000_0000, 32'h8000_4004, 1'b1, 32'h8000_4004, 32'h8000_4004, t, "JALR clears bit0");

            t = mk_tag(4'd9);
            bru_case(OP_JALR, 32'h8000_3000, 32'h8000_4000, 32'h0000_0000, 32'h0000_0007, 32'h8000_4006, 1'b1, 32'h8000_4006, 32'h8000_4006, t, "JALR clears bit0 (imm)");

            // (src1 + imm) wraps through 0 and bit 0 is still cleared
            t = mk_tag(4'd15);
            bru_case(OP_JALR, 32'h8000_3000, 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0001, 32'h0000_0000, 1'b1, 32'h0000_0000, 32'h0000_0000, t, "JALR wrap");
        end
    endtask

    task automatic test_bru_recovery;
        tag_t t;
        begin
            // Branch predicted not-taken but actually taken -> recovery
            t = mk_tag(4'd2);
            bru_case(OP_BEQ, 32'h8000_0000, 32'h0000_0005, 32'h0000_0005, 32'h0000_0040, 32'h8000_0004, 1'b1, 32'h8000_0040, 32'h8000_0040, t, "BEQ mispredict taken");

            // Branch predicted taken but actually not taken -> recovery to pc+4
            t = mk_tag(4'd4);
            bru_case(OP_BNE, 32'h8000_0100, 32'h0000_0005, 32'h0000_0005, 32'h0000_0040, 32'h8000_0140, 1'b0, 32'h8000_0140, 32'h8000_0104, t, "BEQ mispredict not taken");

            // JAL target mispredicted
            t = mk_tag(4'd6);
            bru_case(OP_JAL, 32'h8000_0200, 32'h0000_0000, 32'h0000_0000, 32'h0000_0080, 32'h8000_0204, 1'b1, 32'h8000_0280, 32'h8000_0280, t, "JAL mispredict");

            // JAL target matching the prediction -> no recovery
            t = mk_tag(4'd8);
            bru_case(OP_JAL, 32'h8000_0200, 32'h0000_0000, 32'h0000_0000, 32'h0000_0080, 32'h8000_0280, 1'b1, 32'h8000_0280, 32'h8000_0280, t, "JAL correct prediction");

            // JALR actual target == prediction -> no recovery
            t = mk_tag(4'd10);
            bru_case(OP_JALR, 32'h8000_0300, 32'h8000_5000, 32'h0000_0000, 32'h0000_0004, 32'h8000_5004, 1'b1, 32'h8000_5004, 32'h8000_5004, t, "JALR predicted target, no recovery");

            // JALR actual target != prediction -> recovery
            t = mk_tag(4'd12);
            bru_case(OP_JALR, 32'h8000_0300, 32'h8000_5000, 32'h0000_0000, 32'h0000_0004, 32'h8000_6000, 1'b1, 32'h8000_5004, 32'h8000_5004, t, "JALR mispredict");

            // Correctly predicted conditional branch -> no recovery
            t = mk_tag(4'd14);
            bru_case(OP_BLTU, 32'h8000_0400, 32'h0000_0001, 32'h0000_0002, 32'h0000_0010, 32'h8000_0410, 1'b1, 32'h8000_0410, 32'h8000_0410, t, "BLTU correctly predicted");
        end
    endtask

    task automatic test_bru_kill;
        tag_t t;
        begin
            // Kill asserted in the completion cycle: kill wins over the
            // completion.  The killed operation is a correctly predicted branch
            // (recovery_valid = 0), which is the only stimulus a kill can hit:
            // the kill mask is derived from the BRU recovery itself and the
            // recovering branch is never in its own kill set (fu_bru.sv header).
            t = mk_tag(4'd7);
            @(negedge clk);
            bru_issue_valid = 1'b1;
            bru_issue_req   = mk_bru_req(t, OP_BEQ, 32'h8000_0000, 32'h0000_0005, 32'h0000_0005, 32'h0000_0040, 32'h8000_0040);
            bru_kill_mask   = '0;
            @(posedge clk); #1;
            bru_issue_valid = 1'b0;
            bru_issue_req   = '0;
            check(bru_completion_valid && !bru_recovery_valid,
                  "kill test: operation would complete without the kill");
            bru_kill_mask[t.slot_index] = 1'b1;
            #1;
            check(!bru_completion_valid, "kill in the completion cycle suppresses the completion");
            @(posedge clk); #1;
            bru_kill_mask = '0;
            check(!bru_completion_valid, "no completion after the kill");
            check(!bru_recovery_valid, "no recovery after the kill");

            // kill already asserted while the request is accepted: the operation
            // must never produce a completion or recovery
            t = mk_tag(4'd9);
            @(negedge clk);
            bru_issue_valid = 1'b1;
            bru_issue_req   = mk_bru_req(t, OP_JAL, 32'h8000_1000, 32'h0, 32'h0, 32'h0000_0100, 32'h8000_1100);
            bru_kill_mask[t.slot_index] = 1'b1;
            @(posedge clk); #1;
            bru_issue_valid = 1'b0;
            bru_issue_req   = '0;
            bru_kill_mask   = '0;
            check(!bru_completion_valid, "kill in the issue cycle: no completion");
            check(!bru_recovery_valid, "kill in the issue cycle: no recovery");
            @(posedge clk); #1;
            check(!bru_completion_valid, "kill in the issue cycle: still no completion");
            check(!bru_recovery_valid, "kill in the issue cycle: still no recovery");
        end
    endtask

    task automatic test_bru_random;
        int unsigned i;
        logic [31:0] rv;
        logic [31:0] pc, a, b, imm, pnpc;
        logic [31:0] exp_npc, exp_tgt;
        op_t         op;
        logic        taken;
        tag_t        t;
        begin
            for (i = 0; i < 800; i = i + 1) begin
                rv  = rnd32();
                pc  = rv & 32'hFFFF_FFFC;
                a   = rnd32();
                b   = rnd32();
                imm = rnd32();

                // Bias towards small/edge operands so signed and unsigned
                // boundaries are hit often, and keep imm small half of the time
                // so that pc + imm does not wrap on every vector.
                if ((rnd32() % 4) == 0) begin
                    case (rnd32() % 6)
                        0: a = 32'h0000_0000;
                        1: a = 32'h0000_0001;
                        2: a = 32'h7FFF_FFFF;
                        3: a = 32'h8000_0000;
                        4: a = 32'hFFFF_FFFF;
                        default: a = 32'h0000_7FFF;
                    endcase
                end
                if ((rnd32() % 4) == 0) begin
                    case (rnd32() % 6)
                        0: b = 32'h0000_0000;
                        1: b = 32'h0000_0001;
                        2: b = 32'h7FFF_FFFF;
                        3: b = 32'h8000_0000;
                        4: b = 32'hFFFF_FFFF;
                        default: b = 32'hFFFF_8000;
                    endcase
                end
                if ((rnd32() % 2) == 0) begin
                    imm = {26'h0, rnd32()[3:0], 2'b00} + 32'h0000_0004;  // 4..64
                end

                case (rnd32() % 8)
                    0: op = OP_BEQ;
                    1: op = OP_BNE;
                    2: op = OP_BLT;
                    3: op = OP_BGE;
                    4: op = OP_BLTU;
                    5: op = OP_BGEU;
                    6: op = OP_JAL;
                    default: op = OP_JALR;
                endcase

                taken = (op == OP_JAL) || (op == OP_JALR)
                        || ref_taken(op, a, b);
                exp_npc = ref_npc(op, pc, a, b, imm);
                exp_tgt = ref_target(op, pc, a, imm);

                // half of the vectors predict correctly, half do not
                if ((rnd32() % 2) == 0) begin
                    pnpc = exp_npc;
                end else begin
                    pnpc = rnd32() & 32'hFFFF_FFFC;
                end
                t.slot_index = rnd32()[3:0];

                bru_case(op, pc, a, b, imm, pnpc, taken, exp_tgt, exp_npc, t, $sformatf("random BRU #%0d", i));
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // csr_file tests
    //-------------------------------------------------------------------------
    task automatic test_csr_reset;
        begin
            // required CSRs
            csr_read_check(CSR_MSTATUS, mstatus_image(1'b0, 1'b0), 1'b1, "reset mstatus");
            csr_read_check(CSR_MIE,     32'h0000_0000, 1'b1, "reset mie");
            csr_read_check(CSR_MTVEC,   32'h8000_0000, 1'b1, "reset mtvec (MODE forced 00)");
            csr_read_check(CSR_MSCRATCH,32'h0000_0000, 1'b1, "reset mscratch");
            csr_read_check(CSR_MEPC,    32'h0000_0000, 1'b1, "reset mepc");
            csr_read_check(CSR_MCAUSE,  32'h0000_0000, 1'b1, "reset mcause");
            csr_read_check(CSR_MIP,     32'h0000_0000, 1'b1, "reset mip (timer_irq = 0)");
            csr_read_check(CSR_MHARTID, 32'h0000_0000, 1'b1, "reset mhartid");

            check(!csr_mstatus_mie, "reset mstatus.MIE = 0");
            check(!csr_mie_msie, "reset mie.MSIE = 0");
            check(!csr_mie_mtie, "reset mie.MTIE = 0");
            check(!csr_mie_meie, "reset mie.MEIE = 0");
            check(!csr_mip_msip, "reset mip.MSIP = 0");
            check(!csr_mip_mtip, "reset mip.MTIP = 0");
            check(!csr_mip_meip, "reset mip.MEIP = 0");
            check(csr_mtvec == 32'h8000_0000, "reset mtvec port");
            check(csr_mepc == 32'h0000_0000, "reset mepc port");

            // optional CSRs are not implemented with HAS_* = 0
            csr_read_check(CSR_MISA,    32'h0000_0000, 1'b0, "misa unimplemented (HAS_MISA=0)");
            csr_read_check(CSR_MTVAL,   32'h0000_0000, 1'b0, "mtval unimplemented (HAS_MTVAL=0)");
            csr_read_check(CSR_MCYCLE,  32'h0000_0000, 1'b0, "mcycle unimplemented (HAS_MCYCLE=0)");
            csr_read_check(CSR_MCYCLEH, 32'h0000_0000, 1'b0, "mcycleh unimplemented (HAS_MCYCLE=0)");

            // other unknown addresses are not implemented either
            csr_read_check(12'h000, 32'h0, 1'b0, "csr 0x000 unimplemented");
            csr_read_check(12'h303, 32'h0, 1'b0, "csr 0x303 unimplemented");
            csr_read_check(12'hC00, 32'h0, 1'b0, "csr 0xC00 unimplemented");
            csr_read_check(12'hFFF, 32'h0, 1'b0, "csr 0xFFF unimplemented");
        end
    endtask

    task automatic test_csr_random;
        int unsigned i;
        logic [31:0] rnd;
        logic [31:0] data;
        logic [11:0] addr;
        logic        r_mie, r_mpie, r_msie, r_mtie, r_meie;
        logic [31:0] r_mtvec, r_mscratch, r_mepc, r_mcause;
        begin
            // model starts from the reset values checked above
            r_mie = 1'b0;
            r_mpie = 1'b0;
            r_msie = 1'b0;
            r_mtie = 1'b0;
            r_meie = 1'b0;
            r_mtvec = 32'h8000_0000;
            r_mscratch = 32'h0;
            r_mepc = 32'h0;
            r_mcause = 32'h0;

            for (i = 0; i < 200; i = i + 1) begin
                rnd  = rnd32();
                data = rnd32();
                case (rnd % 8)
                    0: addr = CSR_MSTATUS;
                    1: addr = CSR_MIE;
                    2: addr = CSR_MTVEC;
                    3: addr = CSR_MSCRATCH;
                    4: addr = CSR_MEPC;
                    5: addr = CSR_MCAUSE;
                    6: addr = CSR_MIP;      // writes ignored
                    default: addr = CSR_MHARTID;  // read-only
                endcase

                // free-running interrupt levels
                if ((rnd32() % 4) == 0) begin
                    timer_irq    = rnd32()[0];
                    software_irq = rnd32()[0];
                    external_irq = rnd32()[0];
                end

                csr_write(addr, data);
                case (addr)
                    CSR_MSTATUS: begin
                        r_mie  = data[3];
                        r_mpie = data[7];
                    end
                    CSR_MIE: begin
                        r_msie = data[3];
                        r_mtie = data[7];
                        r_meie = data[11];
                    end
                    CSR_MTVEC:   r_mtvec = {data[31:2], 2'b00};
                    CSR_MSCRATCH: r_mscratch = data;
                    CSR_MEPC:    r_mepc = {data[31:2], 2'b00};
                    CSR_MCAUSE:  r_mcause = data;
                    default: begin
                    end
                endcase

                case (addr)
                    CSR_MSTATUS: csr_read_check(addr, mstatus_image(r_mie, r_mpie), 1'b1,
                                                $sformatf("random #%0d mstatus", i));
                    CSR_MIE:     csr_read_check(addr, mie_image(r_msie, r_mtie, r_meie), 1'b1,
                                                $sformatf("random #%0d mie", i));
                    CSR_MTVEC:   csr_read_check(addr, r_mtvec, 1'b1,
                                                $sformatf("random #%0d mtvec", i));
                    CSR_MSCRATCH: csr_read_check(addr, r_mscratch, 1'b1,
                                                $sformatf("random #%0d mscratch", i));
                    CSR_MEPC:    csr_read_check(addr, r_mepc, 1'b1,
                                                $sformatf("random #%0d mepc", i));
                    CSR_MCAUSE:  csr_read_check(addr, r_mcause, 1'b1,
                                                $sformatf("random #%0d mcause", i));
                    CSR_MIP:     csr_read_check(addr, mip_image(software_irq, timer_irq, external_irq), 1'b1,
                                                $sformatf("random #%0d mip", i));
                    default:     csr_read_check(addr, 32'h0, 1'b1,
                                                $sformatf("random #%0d mhartid", i));
                endcase
            end
        end
    endtask

    task automatic test_csr_fields;
        begin
            // mstatus: MIE[3] and MPIE[7] only, MPP fixed 2'b11
            csr_write(CSR_MSTATUS, 32'hFFFF_FFFF);
            csr_read_check(CSR_MSTATUS, 32'h0000_1888, 1'b1, "mstatus all-ones masking");
            check(csr_mstatus_mie == 1'b1, "mstatus.MIE set");
            csr_write(CSR_MSTATUS, 32'h0000_0008);
            csr_read_check(CSR_MSTATUS, 32'h0000_1808, 1'b1, "mstatus MIE only");
            csr_write(CSR_MSTATUS, 32'h0000_0080);
            csr_read_check(CSR_MSTATUS, 32'h0000_1880, 1'b1, "mstatus MPIE only");
            csr_write(CSR_MSTATUS, 32'h0000_0000);
            csr_read_check(CSR_MSTATUS, 32'h0000_1800, 1'b1, "mstatus cleared");
            check(!csr_mstatus_mie, "mstatus.MIE cleared");

            // mie: MSIE[3], MTIE[7], MEIE[11] only
            csr_write(CSR_MIE, 32'hFFFF_FFFF);
            csr_read_check(CSR_MIE, 32'h0000_0888, 1'b1, "mie MSIE/MTIE/MEIE only");
            check(csr_mie_msie == 1'b1, "mie.MSIE set");
            check(csr_mie_mtie == 1'b1, "mie.MTIE set");
            check(csr_mie_meie == 1'b1, "mie.MEIE set");
            csr_write(CSR_MIE, 32'h0000_0000);
            csr_read_check(CSR_MIE, 32'h0000_0000, 1'b1, "mie cleared");
            check(!csr_mie_msie, "mie.MSIE cleared");
            check(!csr_mie_mtie, "mie.MTIE cleared");
            check(!csr_mie_meie, "mie.MEIE cleared");

            // mtvec: MODE forced 00, BASE[31:2] R/W
            csr_write(CSR_MTVEC, 32'h8000_1237);
            csr_read_check(CSR_MTVEC, 32'h8000_1234, 1'b1, "mtvec MODE forced 00");
            check(csr_mtvec == 32'h8000_1234, "mtvec port");
            csr_write(CSR_MTVEC, 32'hFFFF_FFFF);
            csr_read_check(CSR_MTVEC, 32'hFFFF_FFFC, 1'b1, "mtvec all-ones BASE");
            csr_write(CSR_MTVEC, 32'h8000_0000);

            // mscratch: full 32-bit R/W
            csr_write(CSR_MSCRATCH, 32'hDEAD_BEEF);
            csr_read_check(CSR_MSCRATCH, 32'hDEAD_BEEF, 1'b1, "mscratch full 32-bit R/W");

            // mepc: full 32-bit R/W with [1:0] forced 00
            csr_write(CSR_MEPC, 32'hDEAD_BEEF);
            csr_read_check(CSR_MEPC, 32'hDEAD_BEEC, 1'b1, "mepc[1:0] forced 00");
            check(csr_mepc == 32'hDEAD_BEEC, "mepc port aligned");
            csr_write(CSR_MEPC, 32'h8000_1003);
            csr_read_check(CSR_MEPC, 32'h8000_1000, 1'b1, "mepc write alignment");

            // mcause: full 32-bit R/W
            csr_write(CSR_MCAUSE, 32'h8000_0007);
            csr_read_check(CSR_MCAUSE, 32'h8000_0007, 1'b1, "mcause full 32-bit R/W");
        end
    endtask

    task automatic test_csr_mip;
        begin
            timer_irq = 1'b0; software_irq = 1'b0; external_irq = 1'b0; #1;
            csr_write(CSR_MIP, 32'hFFFF_FFFF);
            csr_read_check(CSR_MIP, 32'h0000_0000, 1'b1, "mip write ignored (all sources low)");
            check(!csr_mip_msip, "mip_msip follows software_irq = 0");
            check(!csr_mip_mtip, "mip_mtip follows timer_irq = 0");
            check(!csr_mip_meip, "mip_meip follows external_irq = 0");

            software_irq = 1'b1; timer_irq = 1'b1; external_irq = 1'b1; #1;
            check(csr_mip_msip == 1'b1, "mip_msip follows software_irq = 1");
            check(csr_mip_mtip == 1'b1, "mip_mtip follows timer_irq = 1");
            check(csr_mip_meip == 1'b1, "mip_meip follows external_irq = 1");
            csr_read_check(CSR_MIP, 32'h0000_0888, 1'b1, "mip MSIP/MTIP/MEIP = 1, all other bits 0");
            csr_write(CSR_MIP, 32'h0000_0000);
            csr_read_check(CSR_MIP, 32'h0000_0888, 1'b1, "mip write cannot clear source bits");

            software_irq = 1'b0; timer_irq = 1'b0; external_irq = 1'b0; #1;
            csr_read_check(CSR_MIP, 32'h0000_0000, 1'b1, "mip follows all sources back to 0");
            check(!csr_mip_msip, "mip_msip low again");
            check(!csr_mip_mtip, "mip_mtip low again");
            check(!csr_mip_meip, "mip_meip low again");
        end
    endtask

    task automatic test_csr_trap_mret;
        begin
            // MIE = 1, MPIE = 0
            csr_write(CSR_MSTATUS, 32'h0000_0008);
            check(csr_mstatus_mie == 1'b1, "setup: MIE = 1");

            // trap: MPIE <- MIE (1), MIE <- 0, MPP <- M; mepc/mcause written
            csr_trap(32'h8000_2000, 32'h0000_000B);
            check(csr_mstatus_mie == 1'b0, "trap clears MIE");
            csr_read_check(CSR_MSTATUS, 32'h0000_1880, 1'b1, "trap: MPIE<-MIE=1, MIE=0, MPP=11");
            csr_read_check(CSR_MEPC, 32'h8000_2000, 1'b1, "trap writes mepc");
            check(csr_mepc == 32'h8000_2000, "trap mepc port");
            csr_read_check(CSR_MCAUSE, 32'h0000_000B, 1'b1, "trap writes mcause");

            // trap mepc is WARL-aligned as well; this second trap sees MIE = 0,
            // so MPIE <- MIE = 0
            csr_trap(32'h8000_3003, 32'h0000_000B);
            csr_read_check(CSR_MEPC, 32'h8000_3000, 1'b1, "trap mepc[1:0] forced 00");
            csr_read_check(CSR_MSTATUS, 32'h0000_1800, 1'b1, "second trap: MPIE<-MIE=0, MIE=0");

            // MRET with MPIE = 0 -> MIE = 0, MPIE = 1
            csr_mret();
            check(csr_mstatus_mie == 1'b0, "mret sets MIE from MPIE = 0");
            csr_read_check(CSR_MSTATUS, 32'h0000_1880, 1'b1, "mret: MIE=0, MPIE=1, MPP=11");

            // MRET with MPIE = 1 -> MIE = 1, MPIE = 1
            csr_write(CSR_MSTATUS, 32'h0000_0080);
            csr_mret();
            check(csr_mstatus_mie == 1'b1, "mret sets MIE from MPIE = 1");
            csr_read_check(CSR_MSTATUS, 32'h0000_1888, 1'b1, "mret: MIE=1, MPIE=1, MPP=11");

            // priority: trap wins over mret and over a normal write
            csr_write(CSR_MSTATUS, 32'h0000_0080);   // MIE = 0, MPIE = 1
            csr_trap_mret_write(32'h8000_4000, 32'h0000_000B, 1'b1, CSR_MSTATUS, 32'h0000_0008);
            check(csr_mstatus_mie == 1'b0, "trap beats mret and write: MIE = 0");
            csr_read_check(CSR_MSTATUS, 32'h0000_1800, 1'b1,
                           "trap beats mret/write: MPIE<-MIE=0, MIE=0, MPP=11");
            csr_read_check(CSR_MEPC, 32'h8000_4000, 1'b1, "trap beats mret/write: mepc updated");
            csr_read_check(CSR_MCAUSE, 32'h0000_000B, 1'b1, "trap beats mret/write: mcause updated");
        end
    endtask

    task automatic test_csr_unimpl;
        logic [31:0] before_mscratch;
        begin
            csr_write(CSR_MSCRATCH, 32'h1234_5678);
            before_mscratch = 32'h1234_5678;
            // writes to unimplemented addresses must not touch any state
            csr_write(CSR_MISA, 32'hFFFF_FFFF);
            csr_write(CSR_MTVAL, 32'hFFFF_FFFF);
            csr_write(CSR_MCYCLE, 32'hFFFF_FFFF);
            csr_write(CSR_MCYCLEH, 32'hFFFF_FFFF);
            csr_read_check(CSR_MSCRATCH, before_mscratch, 1'b1,
                           "unimplemented writes leave real CSRs alone");
            csr_read_check(CSR_MISA, 32'h0, 1'b0, "misa still unimplemented");
            csr_read_check(CSR_MTVAL, 32'h0, 1'b0, "mtval still unimplemented");
            csr_read_check(CSR_MCYCLE, 32'h0, 1'b0, "mcycle still unimplemented");
            csr_read_check(CSR_MCYCLEH, 32'h0, 1'b0, "mcycleh still unimplemented");
        end
    endtask

    //-------------------------------------------------------------------------
    // fu_csr tests
    //-------------------------------------------------------------------------
    // Decode-side write-enable rule of backend.md 16.2 / plan 5.15 (fu_csr has
    // no rd port: rd=x0 only removes the GPR write, CSRRW[I] still writes).
    function automatic logic ref_csr_write_en(input op_t op, input logic rs1_nonzero,
                                              input logic uimm_nonzero);
        begin
            case (op)
                OP_CSRRW, OP_CSRRWI:  ref_csr_write_en = 1'b1;
                OP_CSRRS, OP_CSRRC:   ref_csr_write_en = rs1_nonzero;
                OP_CSRRSI, OP_CSRRCI: ref_csr_write_en = uimm_nonzero;
                default:              ref_csr_write_en = 1'b0;
            endcase
        end
    endfunction

    task automatic test_fu_csr_forms;
        tag_t t;
        begin
            // write-enable rules (used to drive csr_write_en below)
            check(ref_csr_write_en(OP_CSRRW,  1'b0, 1'b0) == 1'b1, "CSRRW always writes");
            check(ref_csr_write_en(OP_CSRRWI, 1'b0, 1'b0) == 1'b1, "CSRRWI always writes");
            check(ref_csr_write_en(OP_CSRRS,  1'b0, 1'b0) == 1'b0, "CSRRS rs1=x0 does not write");
            check(ref_csr_write_en(OP_CSRRS,  1'b1, 1'b0) == 1'b1, "CSRRS rs1!=x0 writes");
            check(ref_csr_write_en(OP_CSRRC,  1'b0, 1'b0) == 1'b0, "CSRRC rs1=x0 does not write");
            check(ref_csr_write_en(OP_CSRRC,  1'b1, 1'b0) == 1'b1, "CSRRC rs1!=x0 writes");
            check(ref_csr_write_en(OP_CSRRSI, 1'b0, 1'b0) == 1'b0, "CSRRSI uimm=0 does not write");
            check(ref_csr_write_en(OP_CSRRSI, 1'b0, 1'b1) == 1'b1, "CSRRSI uimm!=0 writes");
            check(ref_csr_write_en(OP_CSRRCI, 1'b0, 1'b0) == 1'b0, "CSRRCI uimm=0 does not write");
            check(ref_csr_write_en(OP_CSRRCI, 1'b0, 1'b1) == 1'b1, "CSRRCI uimm!=0 writes");

            // old value used by the directed vectors
            // CSRRW: new = src (always writes, even with src = 0 / rd = x0)
            t = mk_tag(4'd0);
            fu_csr_op(OP_CSRRW, CSR_MSCRATCH, 32'h1234_5678, 1'b0, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h1234_5678, 1'b0, t, "CSRRW src!=0");
            t = mk_tag(4'd1);
            fu_csr_op(OP_CSRRW, CSR_MSCRATCH, 32'h0000_0000, 1'b0, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_0000, 1'b0, t, "CSRRW src=0 (rs1=x0) still writes");

            // CSRRS: new = old | src
            t = mk_tag(4'd2);
            fu_csr_op(OP_CSRRS, CSR_MSCRATCH, 32'h0000_000F, 1'b0, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00FF, 1'b0, t, "CSRRS src!=0");
            t = mk_tag(4'd3);
            fu_csr_op(OP_CSRRS, CSR_MSCRATCH, 32'h0000_0000, 1'b0, 1'b0, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00F0, 1'b0, t, "CSRRS src=0 (no write)");
            fu_csr_op(OP_CSRRS, CSR_MSCRATCH, 32'hA5A5_5A5A, 1'b0, 1'b1, 32'h0000_0000,
                      32'h0000_0000, 32'hA5A5_5A5A, 1'b0, t, "CSRRS old = 0");

            // CSRRC: new = old & ~src (a full 32-bit complement)
            t = mk_tag(4'd4);
            fu_csr_op(OP_CSRRC, CSR_MSCRATCH, 32'h0000_000F, 1'b0, 1'b1, 32'h0000_00FF,
                      32'h0000_00FF, 32'h0000_00F0, 1'b0, t, "CSRRC src!=0");
            t = mk_tag(4'd5);
            fu_csr_op(OP_CSRRC, CSR_MSCRATCH, 32'h0000_0000, 1'b0, 1'b0, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00F0, 1'b0, t, "CSRRC src=0 (no write)");
            fu_csr_op(OP_CSRRC, CSR_MSCRATCH, 32'h0F0F_0F0F, 1'b0, 1'b1, 32'hFFFF_FFFF,
                      32'hFFFF_FFFF, 32'hF0F0_F0F0, 1'b0, t, "CSRRC old = all ones");

            // CSRRWI: zero-extended uimm[4:0], always writes
            t = mk_tag(4'd6);
            fu_csr_op(OP_CSRRWI, CSR_MSCRATCH, 32'hFFFF_FF9B, 1'b1, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_001B, 1'b0, t, "CSRRWI uimm!=0 (zero-extended)");
            t = mk_tag(4'd7);
            fu_csr_op(OP_CSRRWI, CSR_MSCRATCH, 32'h0000_0000, 1'b1, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_0000, 1'b0, t, "CSRRWI uimm=0 still writes");

            // CSRRSI / CSRRCI: write only when uimm != 0
            t = mk_tag(4'd8);
            fu_csr_op(OP_CSRRSI, CSR_MSCRATCH, 32'h0000_000F, 1'b1, 1'b1, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00FF, 1'b0, t, "CSRRSI uimm!=0");
            t = mk_tag(4'd9);
            fu_csr_op(OP_CSRRSI, CSR_MSCRATCH, 32'h0000_0000, 1'b1, 1'b0, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00F0, 1'b0, t, "CSRRSI uimm=0 (no write)");
            t = mk_tag(4'd10);
            fu_csr_op(OP_CSRRCI, CSR_MSCRATCH, 32'h0000_000F, 1'b1, 1'b1, 32'h0000_00FF,
                      32'h0000_00FF, 32'h0000_00F0, 1'b0, t, "CSRRCI uimm!=0");
            t = mk_tag(4'd11);
            fu_csr_op(OP_CSRRCI, CSR_MSCRATCH, 32'h0000_0000, 1'b1, 1'b0, 32'h0000_00F0,
                      32'h0000_00F0, 32'h0000_00F0, 1'b0, t, "CSRRCI uimm=0 (no write)");

            // immediate operand must be zero-extended, never read src1
            t = mk_tag(4'd12);
            fu_csr_op(OP_CSRRWI, CSR_MTVEC, 32'h0000_001F, 1'b1, 1'b1, 32'h8000_0000,
                      32'h8000_0000, 32'h0000_001F, 1'b0, t, "CSRRWI uimm=31");

            // rd = x0 is invisible to this unit (no rd port): the old value is
            // still returned and CSRRW[I] still computes a write value.
            t = mk_tag(4'd13);
            fu_csr_op(OP_CSRRW, CSR_MIE, 32'h0000_0000, 1'b0, 1'b1, 32'h0000_0080,
                      32'h0000_0080, 32'h0000_0000, 1'b0, t, "CSRRW rd=x0 case (write value kept)");
        end
    endtask

    task automatic test_fu_csr_ecall_mret;
        tag_t t;
        begin
            t = mk_tag(4'd5);
            fu_csr_op(OP_ECALL, 12'h000, 32'h0, 1'b0, 1'b0, 32'h0000_0000,
                      32'h0000_0000, 32'h0000_0000, 1'b1, t, "ECALL exception");
            t = mk_tag(4'd6);
            fu_csr_op(OP_ECALL, CSR_MIP, 32'h0, 1'b0, 1'b0, 32'hFFFF_FFFF,
                      32'h0000_0000, 32'h0000_0000, 1'b1, t, "ECALL ignores csr_rdata");

            t = mk_tag(4'd7);
            fu_csr_op(OP_MRET, 12'h000, 32'h0, 1'b0, 1'b0, 32'h0000_0000,
                      32'h0000_0000, 32'h0000_0000, 1'b0, t, "MRET normal completion");
            t = mk_tag(4'd8);
            fu_csr_op(OP_MRET, CSR_MSTATUS, 32'h0, 1'b0, 1'b0, 32'h0000_1888,
                      32'h0000_0000, 32'h0000_0000, 1'b0, t, "MRET ignores csr_rdata");

            // FENCE / FENCE.I are serializing no-ops on this unit; they must
            // not leak csr_rdata into the GPR result or the write sideband.
            t = mk_tag(4'd9);
            fu_csr_op(OP_FENCE, 12'h000, 32'h0, 1'b0, 1'b0, 32'hFFFF_FFFF,
                      32'h0000_0000, 32'h0000_0000, 1'b0, t, "FENCE no-op ignores csr_rdata");
            t = mk_tag(4'd10);
            fu_csr_op(OP_FENCE, 12'h000, 32'h1, 1'b1, 1'b0, 32'hFFFF_FFFF,
                      32'h0000_0000, 32'h0000_0000, 1'b0, t, "FENCE.I no-op ignores csr_rdata");
        end
    endtask

    task automatic test_fu_csr_kill;
        tag_t t;
        fu_req_t req;
        begin
            // kill in the completion cycle
            t = mk_tag(4'd4);
            req = '0;
            req.tag = t;
            req.op = OP_CSRRW;
            req.csr_addr = CSR_MSCRATCH;
            req.csr_write_en = 1'b1;
            req.src1 = 32'hCAFE_F00D;
            @(negedge clk);
            csr_read_sel = 1'b0;
            fu_csr_rdata_tb = 32'h0;
            fu_csr_issue_valid = 1'b1;
            fu_csr_issue_req = req;
            fu_csr_kill_mask = '0;
            @(posedge clk); #1;
            fu_csr_issue_valid = 1'b0;
            fu_csr_issue_req = '0;
            check(fu_csr_completion_valid, "fu_csr kill test: would complete without the kill");
            fu_csr_kill_mask[t.slot_index] = 1'b1;
            #1;
            check(!fu_csr_completion_valid, "fu_csr kill in the completion cycle suppresses it");
            @(posedge clk); #1;
            fu_csr_kill_mask = '0;
            check(!fu_csr_completion_valid, "fu_csr: no completion after the kill");

            // kill already present in the issue cycle
            t = mk_tag(4'd13);
            @(negedge clk);
            fu_csr_issue_valid = 1'b1;
            fu_csr_issue_req = req;
            fu_csr_issue_req.tag = t;
            fu_csr_kill_mask[t.slot_index] = 1'b1;
            @(posedge clk); #1;
            fu_csr_issue_valid = 1'b0;
            fu_csr_issue_req = '0;
            fu_csr_kill_mask = '0;
            check(!fu_csr_completion_valid, "fu_csr kill in the issue cycle: no completion");
            @(posedge clk); #1;
            check(!fu_csr_completion_valid, "fu_csr kill in the issue cycle: still no completion");
        end
    endtask

    // Integration: the registered csr_raddr reaches the real csr_file and the
    // old value is captured in the completion cycle.  A CSRRW through this unit
    // must NOT change the file (commit does the write).
    task automatic fu_csr_file_op(
        input op_t         op,
        input logic [11:0] addr,
        input logic [31:0] operand,
        input logic [31:0] exp_result,
        input logic [31:0] exp_wdata,
        input logic        exp_ok,
        input tag_t        tag,
        input string       name
    );
        fu_req_t req;
        begin
            req = '0;
            req.tag          = tag;
            req.op           = op;
            req.csr_addr     = addr;
            req.csr_write_en = 1'b1;
            req.src1         = operand;

            csr_read_sel = 1'b1;   // the unit's registered address drives the file
            @(negedge clk);
            check(!fu_csr_completion_valid, $sformatf("%s: FU idle before issue", name));
            fu_csr_issue_valid = 1'b1;
            fu_csr_issue_req   = req;
            fu_csr_kill_mask   = '0;

            @(posedge clk); #1;
            fu_csr_issue_valid = 1'b0;
            fu_csr_issue_req   = '0;
            fu_csr_prev_addr   = addr;

            check(fu_csr_completion_valid, $sformatf("%s: completion_valid", name));
            check(fu_csr_raddr == addr,
                  $sformatf("%s: registered csr_raddr exp=%h got=%h", name, addr, fu_csr_raddr));
            check(csr_raddr_ok == exp_ok,
                  $sformatf("%s: csr_raddr_ok exp=%0b got=%0b", name, exp_ok, csr_raddr_ok));
            check(fu_csr_completion.result == exp_result,
                  $sformatf("%s: old value from the CSR file exp=%h got=%h", name, exp_result,
                            fu_csr_completion.result));
            check(fu_csr_write_data == exp_wdata,
                  $sformatf("%s: new value exp=%h got=%h", name, exp_wdata, fu_csr_write_data));
            check(!fu_csr_completion.exception, $sformatf("%s: no exception", name));

            @(posedge clk); #1;
            check(!fu_csr_completion_valid, $sformatf("%s: single-cycle completion", name));
            csr_read_sel = 1'b0;
        end
    endtask

    task automatic test_fu_csr_file;
        begin
            // leave known values in the file through the commit write port
            csr_write(CSR_MSCRATCH, 32'hCAFE_F00D);
            csr_write(CSR_MTVEC, 32'h8000_5000);

            // CSRRW reads the real file and computes the new value; the unit has
            // no write port, so the file must still hold the old value.
            fu_csr_file_op(OP_CSRRW, CSR_MSCRATCH, 32'h1234_5678, 32'hCAFE_F00D,
                           32'h1234_5678, 1'b1, mk_tag(4'd2), "CSRRW reads the real CSR file");
            fu_csr_file_op(OP_CSRRS, CSR_MSCRATCH, 32'h0000_0000, 32'hCAFE_F00D,
                           32'hCAFE_F00D, 1'b1, mk_tag(4'd3),
                           "CSR file unchanged after an fu_csr write op");
            fu_csr_file_op(OP_CSRRC, CSR_MTVEC, 32'h0000_000F, 32'h8000_5000,
                           32'h8000_5000, 1'b1, mk_tag(4'd4),
                           "mtvec read through the CSR unit");
            // the unit sees the same decode as the file for optional addresses
            fu_csr_file_op(OP_CSRRS, CSR_MISA, 32'h0000_0000, 32'h0000_0000,
                           32'h0000_0000, 1'b0, mk_tag(4'd5),
                           "misa unimplemented read through the unit");
        end
    endtask

    //-------------------------------------------------------------------------
    // Main sequence
    //-------------------------------------------------------------------------
    initial begin
        // idle stimulus
        bru_issue_valid    = 1'b0;
        bru_issue_req      = '0;
        bru_kill_mask      = '0;

        timer_irq          = 1'b0;
        software_irq       = 1'b0;
        external_irq       = 1'b0;
        csr_raddr_direct   = 12'h0;
        csr_read_sel       = 1'b0;
        csr_we             = 1'b0;
        csr_waddr          = 12'h0;
        csr_wdata          = 32'h0;
        csr_trap_we        = 1'b0;
        csr_trap_mepc      = 32'h0;
        csr_trap_mcause    = 32'h0;
        csr_mret_we        = 1'b0;

        fu_csr_issue_valid = 1'b0;
        fu_csr_issue_req   = '0;
        fu_csr_kill_mask   = '0;
        fu_csr_rdata_tb    = 32'h0;
        fu_csr_prev_addr   = 12'h0;

        // synchronous active-high reset
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        test_bru_branches();
        test_bru_jumps();
        test_bru_recovery();
        test_bru_kill();
        test_bru_random();

        test_csr_reset();
        test_csr_random();
        test_csr_fields();
        test_csr_mip();
        test_csr_trap_mret();
        test_csr_unimpl();

        test_fu_csr_forms();
        test_fu_csr_ecall_mret();
        test_fu_csr_kill();
        test_fu_csr_file();

        if (errors != 0) begin
            $fatal(1, "tb_bru_csr: %0d of %0d checks FAILED", errors, checks);
        end

        $display("ALL TESTS PASSED: %0d checks - fu_bru (all 6 conditional branches taken/not-taken, JAL/JALR targets incl. JALR bit-0 clearing, actual_target for not-taken branches, pred_npc match/mismatch, single-cycle recovery, kill vs completion/recovery, fixed-seed randomised sweep); csr_file (reset values, mstatus MIE/MPIE/MPP, mie MSIE/MTIE/MEIE only, mtvec MODE=00, mepc[1:0]=00, mip MSIP/MTIP/MEIP follow the three level inputs with writes ignored, mhartid read-only HART_ID, raddr_ok for required/unimplemented addresses, trap/mret transitions and priority, fixed-seed randomised write/readback); fu_csr (FENCE/FENCE.I no-op, all six Zicsr forms with src=0 and write-enable rules, old-value result and new-value csr_write_data, zero-extended uimm operands, ECALL exception registration, MRET normal completion, kill suppression, real CSR-file read integration and no early write)", checks);
        $finish;
    end

endmodule
