//=============================================================================
// ARES backend - unified Redirect arbitration (B21)
//-----------------------------------------------------------------------------
// Sole owner of the BE -> FE redirect event (frontend_backend_contract.md 3,
// backend.md 17.3): Reset > ECALL Trap > MRET > BRU Recovery > IRQ Boundary.
//
// Exactly one winner is reported per cycle; the PC is the already-arbitrated
// correct target.  REDIRECT_BRANCH carries the per-CFI ghr_before snapshot and
// the actual taken bit, REDIRECT_ARCH covers ECALL/MRET/IRQ.  There is no
// ready and no retry: the event lasts one cycle and the FE latches the PC.
//
// FREE items: FREE-04 (one-hot priority mux).
//=============================================================================
module be_redirect (
    input logic rst,

    //---- event requests (already qualified by their owners) ----------------
    input logic                         ecall_valid,
    input logic [                 31:0] ecall_pc,
    input logic                         mret_valid,
    input logic [                 31:0] mret_pc,
    input logic                         branch_valid,
    input logic [                 31:0] branch_pc,
    input logic [fe_pkg::GHR_WIDTH-1:0] branch_ghr_before,
    input logic                         branch_taken,
    input logic                         irq_valid,
    input logic [                 31:0] irq_pc,

    //---- BE -> FE redirect --------------------------------------------------
    output logic                                              redirect_valid,
    output logic                      [                 31:0] redirect_pc,
    output fe_pkg::fe_redirect_kind_t                         redirect_kind,
    output logic                      [fe_pkg::GHR_WIDTH-1:0] redirect_ghr_before,
    output logic                                              redirect_actual_taken,

    //---- winner identification for the flush path --------------------------
    output logic sel_ecall,
    output logic sel_mret,
    output logic sel_branch,
    output logic sel_irq
);
    import ares_pkg::*;
    import fe_pkg::*;

    always_comb begin
        // Reset resets the machine; the FE stub/real FE clears itself, so no
        // redirect event is emitted while rst is asserted (priority table:
        // Reset wins over every other request).
        redirect_valid        = 1'b0;
        redirect_pc           = RESET_PC;
        redirect_kind         = REDIRECT_ARCH;
        redirect_ghr_before   = '0;
        redirect_actual_taken = 1'b0;
        sel_ecall             = 1'b0;
        sel_mret              = 1'b0;
        sel_branch            = 1'b0;
        sel_irq               = 1'b0;

        if (!rst) begin
            if (ecall_valid) begin
                redirect_valid = 1'b1;
                redirect_pc    = ecall_pc;
                redirect_kind  = REDIRECT_ARCH;
                sel_ecall      = 1'b1;
            end else if (mret_valid) begin
                redirect_valid = 1'b1;
                redirect_pc    = mret_pc;
                redirect_kind  = REDIRECT_ARCH;
                sel_mret       = 1'b1;
            end else if (branch_valid) begin
                redirect_valid        = 1'b1;
                redirect_pc           = branch_pc;
                redirect_kind         = REDIRECT_BRANCH;
                redirect_ghr_before   = branch_ghr_before;
                redirect_actual_taken = branch_taken;
                sel_branch            = 1'b1;
            end else if (irq_valid) begin
                redirect_valid = 1'b1;
                redirect_pc    = irq_pc;
                redirect_kind  = REDIRECT_ARCH;
                sel_irq        = 1'b1;
            end
        end
    end
endmodule
