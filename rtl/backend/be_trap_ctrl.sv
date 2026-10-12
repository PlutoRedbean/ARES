//=============================================================================
// ARES backend - ECALL / MRET / Machine Timer interrupt control (B20)
//-----------------------------------------------------------------------------
// backend.md sections 17.1-17.3, plan section 5.15, decisions D-C0-07/08/09.
//
//   * ECALL: when the commit head is a DONE entry with exception cause 11 it
//     fires the trap once: mepc = ecall.pc, mcause = 11, MPIE<-MIE, MIE<-0,
//     MPP<-M and the whole queue (including ECALL itself) is flushed and
//     redirected to mtvec.BASE.  ECALL never commit_fire;
//   * MRET: commits normally in lane 0 (be_commit) and redirects to the
//     committed mepc; MIE<-MPIE, MPIE<-1 in the same cycle;
//   * IRQ: irq_eligible = mstatus.MIE && mie.MTIE && mip.MTIP.  On detection
//     the FSM enters IRQ_DRAIN: no new dispatch, but existing WAIT issue,
//     out-of-order completion and normal commit continue, and branch recovery
//     still wins.  The interrupt is taken only when the CIQ is empty,
//     lsu_mmio_order_idle is set and irq_eligible is still true; if the
//     condition disappeared the machine redirects to architectural_next_pc and
//     resumes without trapping;
//   * architectural_next_pc is updated only by normal commits (pc+4 / BRU
//     actual_npc / mepc) - an ECALL does not update it (D-C0-08);
//   * full_flush_ptr is the post-flush queue pointer: ECALL/MRET leave the
//     queue empty at commit_ptr+1, the IRQ boundary does not move it.
//
// FREE items: FREE-04 (parallel condition evaluation), FREE-09 (FSM encoding).
//=============================================================================
module be_trap_ctrl (
    input  logic            clk,
    input  logic            rst,

    //---- commit head and commit lanes --------------------------------------
    input  logic            head_is_ecall,        // head is DONE with cause 11 (registered state)
    input  logic [31:0]     head_pc,              // ecall.pc -> mepc
    input  tag_t            commit_ptr,
    input  logic [1:0]      commit_fire,
    input  logic            head_is_mret,         // commit head is a DONE MRET (registered state)
    input  logic [31:0]     commit_pc_next [2],

    //---- CSR state (csr_file) ----------------------------------------------
    input  logic            mstatus_mie,
    input  logic            mie_mtie,
    input  logic            mip_mtip,
    input  logic [31:0]     mtvec,
    input  logic [31:0]     mepc,

    //---- external status ----------------------------------------------------
    input  logic            lsu_mmio_order_idle,
    input  logic            ciq_empty,

    //---- redirect requests (be_redirect arbitrates) ------------------------
    output logic            ecall_valid,
    output logic [31:0]     ecall_pc,
    output logic            mret_valid,
    output logic [31:0]     mret_pc,
    output logic            irq_valid,
    output logic [31:0]     irq_pc,
    output logic            irq_accept_evt,   // accepted interrupt (accept, not cancel)

    //---- full-queue flush control (be_flush) -------------------------------
    output logic            full_flush_valid,
    output logic            full_flush_keep_head,
    output tag_t            full_flush_ptr,

    //---- CSR architectural updates (csr_file) ------------------------------
    output logic            trap_we,
    output logic [31:0]     trap_mepc,
    output logic [31:0]     trap_mcause,
    output logic            mret_we,

    //---- dispatch gate ------------------------------------------------------
    output logic            irq_drain,

    //---- architectural next PC (IRQ restore point) -------------------------
    output logic [31:0]     architectural_next_pc
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Architectural next PC: only normal commits update it.
    //-------------------------------------------------------------------------
    logic [31:0] arch_next_q;
    assign architectural_next_pc = arch_next_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            arch_next_q <= RESET_PC;
        end else begin
            if (commit_fire[0]) arch_next_q <= commit_pc_next[0];
            if (commit_fire[1]) arch_next_q <= commit_pc_next[1];   // younger wins
        end
    end

    //-------------------------------------------------------------------------
    // ECALL (synchronous, commit head)
    //-------------------------------------------------------------------------
    assign ecall_valid = head_is_ecall;
    assign ecall_pc    = mtvec;

    //-------------------------------------------------------------------------
    // MRET (normal serializing commit in lane 0).  head_is_mret is derived from
    // registered entry state, which keeps commit_fire (and therefore the kill
    // mask) out of the redirect path - no BE combinational loop.
    //-------------------------------------------------------------------------
    assign mret_valid = head_is_mret;
    assign mret_pc    = mepc;

    //-------------------------------------------------------------------------
    // Machine timer interrupt: Drain-to-Boundary FSM
    //-------------------------------------------------------------------------
    logic        irq_state;      // 0 = IRQ_IDLE, 1 = IRQ_DRAIN
    logic        irq_eligible;
    logic        irq_accept, irq_cancel;

    assign irq_eligible = mstatus_mie && mie_mtie && mip_mtip;
    assign irq_accept   = irq_state && ciq_empty && lsu_mmio_order_idle && irq_eligible;
    assign irq_cancel   = irq_state && !irq_eligible;

    assign irq_drain      = irq_state;
    assign irq_valid      = irq_accept || irq_cancel;
    assign irq_accept_evt = irq_accept;
    assign irq_pc         = irq_accept ? mtvec : arch_next_q;

    always_ff @(posedge clk) begin
        if (rst) irq_state <= 1'b0;
        else begin
            if (!irq_state) irq_state <= irq_eligible;          // enter drain
            else if (irq_accept || irq_cancel) irq_state <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Trap / MRET CSR updates
    //-------------------------------------------------------------------------
    assign trap_we     = ecall_valid || irq_accept;
    assign trap_mepc   = ecall_valid ? head_pc : arch_next_q;
    assign trap_mcause = ecall_valid ? 32'(EXC_ECALL_M) : 32'(EXC_MACHINE_TIMER);
    assign mret_we     = mret_valid;

    //-------------------------------------------------------------------------
    // Full-queue flush target
    //-------------------------------------------------------------------------
    assign full_flush_valid     = ecall_valid || mret_valid || irq_valid;
    assign full_flush_keep_head = head_is_mret;   // MRET commits, everything else dies
    always_comb begin
        if (irq_accept || irq_cancel)
            full_flush_ptr.slot_index = commit_ptr.slot_index;
        else
            full_flush_ptr.slot_index = commit_ptr.slot_index + 4'd1;
    end

`ifdef CONFIG_SIMULATION
    always_ff @(posedge clk) begin
        if (!rst) begin
            a_ecall_no_commit : assert (!ecall_valid || !commit_fire[0]);
            a_irq_empty       : assert (!irq_accept || ciq_empty);
            a_irq_mmio_idle   : assert (!irq_accept || lsu_mmio_order_idle);
        end
    end
`endif
endmodule
