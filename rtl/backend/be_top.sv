//=============================================================================
// ARES backend - subsystem top (C1 integration, becomes half of ares_core_top)
//-----------------------------------------------------------------------------
// Instantiates and wires the complete backend: 2-wide Decode/Dispatch, the
// 16-entry CIQ, Producer Map + branch checkpoints, operand read, the in-order
// 4-wide issue scheduler, the eight physical FU ports (ALU0/ALU1/BRU/SMUL/MUL/
// DIV/CSR + the LSU port), the completion network, 2-wide commit, flush/kill
// generation, unified redirect arbitration, BPU training events and the
// ECALL/MRET/IRQ trap controller.
//
// Boundary: the FE instruction/redirect/BPU interfaces of
// frontend_backend_contract.md v1.0 and the LSU interface of backend.md 9.6 /
// memory.md 3.  The LSU itself belongs to the memory subsystem (C2) and is
// instantiated by the parent (tb_backend / ares_core_top).
//
// Simulation observability (retire stream, EBREAK shadow, interrupt redirect,
// decode errors) is exported as plain ports so the DPI calls stay in the TB
// and never enter the synthesizable path (backend.md 16.1, plan 5.18).
//
// FREE items: FREE-02 (subsystem-level file), FREE-04 (FU/port fan-out).
//=============================================================================
module be_top #(
    parameter logic [31:0] RESET_MTVEC = ares_pkg::RESET_PC,
    parameter logic [31:0] HART_ID      = 32'd0
) (
    input logic clk,
    input logic rst,

    //---- FE instruction interface (contract section 2) ---------------------
    input  logic              [1:0] iq_valid,
    input  fe_pkg::iq_entry_t       iq_inst        [2],
    output logic              [1:0] iq_accept_count,

    //---- Redirect: BE -> FE (contract section 3) ---------------------------
    output logic                                              backend_redirect_valid,
    output logic                      [                 31:0] backend_redirect_pc,
    output fe_pkg::fe_redirect_kind_t                         backend_redirect_kind,
    output logic                      [fe_pkg::GHR_WIDTH-1:0] backend_redirect_ghr_before,
    output logic                                              backend_redirect_actual_taken,

    //---- BPU update: Commit -> FE (contract section 4) ---------------------
    input  logic                [1:0] bpu_update_credit,
    output logic                [1:0] bpu_update_valid,
    output fe_pkg::bpu_update_t       bpu_update       [2],

    //---- LSU interface (backend.md 9.6 / plan section 5.10) ----------------
    input logic lsu_can_accept,
    input logic [2:0] load_credit,  // ares_pkg::LQ_ENTRIES = 4 (3 bits = 0..4)
    input logic [3:0] store_credit,  // ares_pkg::SQ_ENTRIES = 8 (4 bits = 0..8)
    output logic lsu_issue_valid,
    output ares_pkg::fu_req_t lsu_issue_req,
    input logic lsu_completion_valid,
    input ares_pkg::fu_completion_t lsu_completion,
    output logic [ares_pkg::CIQ_ENTRIES-1:0] kill_mask,
    output logic load_head_valid,
    output ares_pkg::tag_t load_head_tag,
    output logic [1:0] store_commit_valid,
    output ares_pkg::tag_t store_commit_tag[2],
    input logic [1:0] store_commit_ok,
    input logic lsu_mmio_order_idle,
    input logic lsu_fence_idle,

    //---- machine interrupt inputs ------------------------------------------
    input logic timer_irq,
    input logic software_irq,
    input logic external_irq,

    //---- retire / trap observation (simulation hooks) ----------------------
    output logic [ 1:0] retire_valid,
    output logic [31:0] retire_pc         [2],
    output logic [31:0] retire_pc_next    [2],
    output logic [ 1:0] retire_rd_wen,
    output logic [ 4:0] retire_rd         [2],
    output logic [31:0] retire_wdata      [2],
    output logic [ 1:0] retire_is_ebreak,
    output logic        irq_redirect_valid,
    output logic [31:0] irq_redirect_pc,
    output logic        fence_i_valid,

    //---- decode error observability (SPEC-A1 / D-C0-01) --------------------
    output logic [ 1:0] decode_err,
    output logic [31:0] decode_err_pc  [2],
    output logic [31:0] decode_err_inst[2],

    //---- assertion / test-bench visibility (not architecturally visible) ---
    output logic                     dep_error,
    output logic              [ 4:0] dbg_occupancy,
    output logic              [ 7:0] dbg_fu_issue_valid,
    output ares_pkg::fu_req_t        dbg_fu_req        [8],
    output ares_pkg::tag_t           dbg_issue_tag     [4],
    output logic              [ 1:0] dbg_commit_fire,
    output ares_pkg::tag_t           dbg_commit_ptr,
    output ares_pkg::tag_t           dbg_issue_ptr,
    output ares_pkg::tag_t           dbg_alloc_ptr,
    output logic              [31:0] dbg_arch_next_pc
);
    import ares_pkg::*;

    localparam logic [2:0] P_ALU0 = 3'd0;
    localparam logic [2:0] P_ALU1 = 3'd1;
    localparam logic [2:0] P_BRU  = 3'd2;
    localparam logic [2:0] P_SMUL = 3'd3;
    localparam logic [2:0] P_MUL  = 3'd4;
    localparam logic [2:0] P_DIV  = 3'd5;
    localparam logic [2:0] P_CSR  = 3'd6;
    localparam logic [2:0] P_LSU  = 3'd7;

    //-------------------------------------------------------------------------
    // Dispatch <-> CIQ <-> Producer Map / Checkpoint
    //-------------------------------------------------------------------------
    logic         [1:0] alloc_valid_w;
    queue_entry_t       alloc_entry_w [2];
    tag_t alloc_ptr_w, commit_ptr_w, issue_ptr_w;
    logic [4:0] free_count_w, occupancy_w;
    logic                                     serializing_present_w;
    queue_entry_t                             entry_w                 [    CIQ_ENTRIES];
    logic               [               31:0] base_valid_w;
    tag_t                                     base_tag_w              [             32];
    logic               [                1:0] pm_we_w;
    logic               [                4:0] pm_rd_w                 [              2];
    tag_t                                     pm_tag_w                [              2];
    logic               [                1:0] cp_we_w;
    tag_t                                     cp_wslot_w              [              2];
    logic               [               31:0] cp_wvalid_w             [              2];
    tag_t                                     cp_wtag_w               [              2] [32];
    logic               [               31:0] cp_rvalid_w;
    tag_t                                     cp_rtag_w               [             32];
    logic               [    CIQ_ENTRIES-1:0] cp_valid_w;

    //-------------------------------------------------------------------------
    // Issue path
    //-------------------------------------------------------------------------
    queue_entry_t                             cand_w                  [ISSUE_WIDTH_MAX];
    logic               [                4:0] gpr_raddr_w             [ GPR_READ_PORTS];
    logic               [               31:0] gpr_rdata_w             [ GPR_READ_PORTS];
    logic               [               31:0] src1_w                  [ISSUE_WIDTH_MAX];
    logic               [               31:0] src2_w                  [ISSUE_WIDTH_MAX];
    logic                                     src_ready_w             [ISSUE_WIDTH_MAX];
    logic               [ISSUE_WIDTH_MAX-1:0] issue_grant_w;
    tag_t                                     issue_tag_w             [ISSUE_WIDTH_MAX];
    logic               [                7:0] fu_issue_valid_w;
    fu_req_t                                  fu_req_w                [              8];
    logic               [                7:0] fu_can_accept_w;

    //-------------------------------------------------------------------------
    // Completion path
    //-------------------------------------------------------------------------
    logic               [                7:0] fu_completion_valid_w;
    fu_completion_t                           fu_completion_w         [              8];
    logic               [               31:0] fu_csr_write_data_w     [              8];
    logic               [               31:0] fu_actual_npc_w         [              8];
    logic                                     fu_actual_taken_w       [              8];
    logic               [               31:0] fu_actual_target_w      [              8];

    logic               [                7:0] cmpl_we_w;
    tag_t                                     cmpl_tag_w              [              8];
    logic               [               31:0] cmpl_result_w           [              8];
    logic                                     cmpl_exception_w        [              8];
    exception_cause_t                         cmpl_cause_w            [              8];
    logic               [               31:0] cmpl_tval_w             [              8];
    logic               [               31:0] cmpl_csr_w              [              8];
    logic               [               31:0] cmpl_npc_w              [              8];
    logic                                     cmpl_taken_w            [              8];
    logic               [               31:0] cmpl_target_w           [              8];

    //-------------------------------------------------------------------------
    // Commit / flush / trap / redirect
    //-------------------------------------------------------------------------
    logic               [                1:0] commit_fire_w;
    tag_t                                     commit_tag_w            [              2];
    logic               [                1:0] commit_rd_wen_w;
    logic               [                4:0] commit_rd_w             [              2];
    logic               [               31:0] commit_wdata_w          [              2];
    logic               [               31:0] commit_pc_next_w        [              2];
    logic               [                1:0] commit_is_cfi_w;
    logic               [                1:0] commit_is_mret_w;
    logic               [               31:0] commit_pc_w             [              2];
    logic                                     commit_actual_taken_w   [              2];
    logic               [               31:0] commit_actual_target_w  [              2];
    fe_pkg::cfi_type_t                        commit_actual_cfi_type_w[              2];
    fe_pkg::pred_meta_t                       commit_pred_meta_w      [              2];

    logic               [    CIQ_ENTRIES-1:0] kill_mask_w;
    logic                                     restore_valid_w;
    tag_t                                     restore_ptr_w;
    logic               [               31:0] restore_map_valid_w;
    tag_t                                     restore_map_tag_w       [             32];
    logic               [    CIQ_ENTRIES-1:0] cp_release_w;

    logic                                     recovery_valid_w;
    tag_t                                     recovery_tag_w;
    logic               [               31:0] redirect_pc_w;

    logic sel_ecall_w, sel_mret_w, sel_branch_w, sel_irq_w;
    logic ecall_valid_w, mret_valid_w, irq_valid_w;
    logic [31:0] ecall_pc_w, mret_pc_w, irq_pc_w;
    logic irq_accept_w;
    logic full_flush_valid_w, full_flush_keep_head_w;
    tag_t full_flush_ptr_w;
    logic trap_we_w, mret_we_w;
    logic [31:0] trap_mepc_w, trap_mcause_w;
    logic        irq_drain_w;
    logic [31:0] arch_next_pc_w;

    logic [ 1:0] bpu_block_w;
    logic        redirect_any_w;
    logic head_valid_w, head_done_w, head_ready_w;
    logic head_is_mret_w, head_is_ecall_w;
    logic cmpl_err_bad_state_w, cmpl_err_dup_tag_w;

    //---- CSR unit / CSR file ------------------------------------------------
    logic [11:0] csr_raddr_w;
    logic [31:0] csr_rdata_w;
    /* verilator lint_off UNUSEDSIGNAL */  // decode already filters unsupported CSR
    logic        csr_raddr_ok_w;  // addresses (D-C0-13); boundary re-check is in the unit TB
    /* verilator lint_on UNUSEDSIGNAL */
    logic        csr_commit_we_w;
    logic [11:0] csr_commit_addr_w;
    logic [31:0] csr_commit_wdata_w;
    logic mstatus_mie_w, mie_msie_w, mie_mtie_w, mie_meie_w;
    logic mip_msip_w, mip_mtip_w, mip_meip_w;
    logic [31:0] mtvec_w, mepc_w;

    //---- FU instances -------------------------------------------------------
    logic           alu0_completion_valid_w;
    fu_completion_t alu0_completion_w;
    logic           alu1_completion_valid_w;
    fu_completion_t alu1_completion_w;
    logic           bru_completion_valid_w;
    fu_completion_t bru_completion_w;
    logic [31:0] bru_actual_npc_w, bru_actual_target_w;
    logic           bru_actual_taken_w;
    logic           smul_completion_valid_w;
    fu_completion_t smul_completion_w;
    logic           mul_completion_valid_w;
    fu_completion_t mul_completion_w;
    logic div_completion_valid_w, div_can_accept_w;
    fu_completion_t        div_completion_w;
    logic                  csr_completion_valid_w;
    fu_completion_t        csr_completion_w;
    logic           [31:0] csr_unit_wdata_w;

    //=========================================================================
    // Commit-head qualification from *registered* entry state.  Keeping it out
    // of the commit/kill combinational cone is what makes the flush, commit and
    // redirect networks acyclic (see be_flush / be_trap_ctrl).
    //=========================================================================
    always_comb begin
        head_valid_w = entry_w[commit_ptr_w.slot_index].valid;
        head_done_w = (entry_w[commit_ptr_w.slot_index].state == ENTRY_DONE);
        head_ready_w = head_valid_w && head_done_w && !entry_w[commit_ptr_w.slot_index].exception;
        head_is_mret_w = head_ready_w && (entry_w[commit_ptr_w.slot_index].op == OP_MRET);
        head_is_ecall_w = head_valid_w && head_done_w
                       && entry_w[commit_ptr_w.slot_index].exception
                       && (entry_w[commit_ptr_w.slot_index].exception_cause == EXC_ECALL_M);
    end

    //=========================================================================
    // Dispatch
    //=========================================================================
    assign redirect_any_w = ecall_valid_w || mret_valid_w || irq_valid_w || recovery_valid_w;

    be_dispatch u_dispatch (
        .clk                (clk),
        .rst                (rst),
        .iq_valid           (iq_valid),
        .iq_inst            (iq_inst),
        .iq_accept_count    (iq_accept_count),
        .free_count         (free_count_w),
        .serializing_present(serializing_present_w),
        .irq_drain          (irq_drain_w),
        .redirect_active    (redirect_any_w),
        .base_valid         (base_valid_w),
        .base_tag           (base_tag_w),
        .alloc_ptr          (alloc_ptr_w),
        .alloc_valid        (alloc_valid_w),
        .alloc_entry        (alloc_entry_w),
        .pm_we              (pm_we_w),
        .pm_rd              (pm_rd_w),
        .pm_tag             (pm_tag_w),
        .cp_we              (cp_we_w),
        .cp_wslot           (cp_wslot_w),
        .cp_wvalid          (cp_wvalid_w),
        .cp_wtag            (cp_wtag_w),
        .decode_err         (decode_err)
    );

    always_comb begin
        for (int unsigned l = 0; l < 2; l++) begin
            decode_err_pc[l]   = iq_inst[l].pc;
            decode_err_inst[l] = iq_inst[l].inst;
        end
    end

    //=========================================================================
    // Centralized Issue Queue
    //=========================================================================
    ciq u_ciq (
        .clk                (clk),
        .rst                (rst),
        .alloc_valid        (alloc_valid_w),
        .alloc_entry        (alloc_entry_w),
        .alloc_ptr          (alloc_ptr_w),
        .commit_ptr         (commit_ptr_w),
        .issue_ptr          (issue_ptr_w),
        .free_count         (free_count_w),
        .occupancy_count    (occupancy_w),
        .serializing_present(serializing_present_w),
        .entry              (entry_w),
        .issue_fire         (issue_grant_w),
        .issue_tag          (issue_tag_w),
        .cmpl_we            (cmpl_we_w),
        .cmpl_tag           (cmpl_tag_w),
        .cmpl_result        (cmpl_result_w),
        .cmpl_exception     (cmpl_exception_w),
        .cmpl_cause         (cmpl_cause_w),
        .cmpl_tval          (cmpl_tval_w),
        .cmpl_csr_write_data(cmpl_csr_w),
        .cmpl_actual_npc    (cmpl_npc_w),
        .cmpl_actual_taken  (cmpl_taken_w),
        .cmpl_actual_target (cmpl_target_w),
        .commit_fire        (commit_fire_w),
        .commit_tag         (commit_tag_w),
        .restore_valid      (restore_valid_w),
        .restore_all        (full_flush_valid_w),
        .restore_ptr        (restore_ptr_w),
        .kill_mask          (kill_mask_w)
    );

    //=========================================================================
    // Producer Map and branch checkpoints
    //=========================================================================
    be_producer_map u_pmap (
        .clk              (clk),
        .rst              (rst),
        .commit_fire      (commit_fire_w),
        .commit_tag       (commit_tag_w),
        .commit_rd_wen    (commit_rd_wen_w),
        .commit_rd        (commit_rd_w),
        .disp_valid       (pm_we_w),              // pm_we already folds rd_wen && rd != x0
        .disp_rd_wen      (2'b11),
        .disp_rd          (pm_rd_w),
        .disp_tag         (pm_tag_w),
        .restore_valid    (restore_valid_w),
        .restore_valid_map(restore_map_valid_w),
        .restore_tag      (restore_map_tag_w),
        .base_valid       (base_valid_w),
        .base_tag         (base_tag_w)
    );

    //=========================================================================
    // Issue: candidates, operand read, arbitration
    //=========================================================================
    always_comb begin
        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++)
        cand_w[i] = entry_w[issue_ptr_w.slot_index+4'(i)];
    end

    be_operand_read u_oread (
        .cand     (cand_w),
        .entry    (entry_w),
        .gpr_raddr(gpr_raddr_w),
        .gpr_rdata(gpr_rdata_w),
        .src1     (src1_w),
        .src2     (src2_w),
        .src_ready(src_ready_w),
        .dep_error(dep_error)
    );

    be_gpr u_gpr (
        .clk  (clk),
        .rst  (rst),
        .raddr(gpr_raddr_w),
        .rdata(gpr_rdata_w),
        .we   (commit_rd_wen_w),
        .waddr(commit_rd_w),
        .wdata(commit_wdata_w)
    );

    always_comb begin
        fu_can_accept_w         = 8'd0;
        fu_can_accept_w[P_ALU0] = 1'b1;
        fu_can_accept_w[P_ALU1] = 1'b1;
        fu_can_accept_w[P_BRU]  = 1'b1;
        fu_can_accept_w[P_SMUL] = 1'b1;
        fu_can_accept_w[P_MUL]  = 1'b1;
        fu_can_accept_w[P_DIV]  = div_can_accept_w;
        fu_can_accept_w[P_CSR]  = 1'b1;
        fu_can_accept_w[P_LSU]  = lsu_can_accept;
    end

    be_issue_sched u_issue (
        .cand               (cand_w),
        .src1               (src1_w),
        .src2               (src2_w),
        .src_ready          (src_ready_w),
        .issue_ptr          (issue_ptr_w),
        .commit_ptr         (commit_ptr_w),
        .lsu_mmio_order_idle(lsu_mmio_order_idle),
        .lsu_fence_idle     (lsu_fence_idle),
        .recovery_valid     (recovery_valid_w),
        .flush_active       (ecall_valid_w || mret_valid_w || irq_valid_w),
        .fu_can_accept      (fu_can_accept_w),
        .load_credit        (load_credit),
        .store_credit       (store_credit),
        .issue_grant        (issue_grant_w),
        .issue_tag          (issue_tag_w),
        .fu_issue_valid     (fu_issue_valid_w),
        .fu_req             (fu_req_w)
    );

    assign lsu_issue_valid = fu_issue_valid_w[P_LSU];
    assign lsu_issue_req   = fu_req_w[P_LSU];

    //=========================================================================
    // Functional units
    //=========================================================================
    fu_alu u_alu0 (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_ALU0]),
        .issue_req       (fu_req_w[P_ALU0]),
        .kill_mask       (kill_mask_w),
        .completion_valid(alu0_completion_valid_w),
        .completion      (alu0_completion_w)
    );

    fu_alu u_alu1 (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_ALU1]),
        .issue_req       (fu_req_w[P_ALU1]),
        .kill_mask       (kill_mask_w),
        .completion_valid(alu1_completion_valid_w),
        .completion      (alu1_completion_w)
    );

    fu_bru u_bru (
        .clk                (clk),
        .rst                (rst),
        .issue_valid        (fu_issue_valid_w[P_BRU]),
        .issue_req          (fu_req_w[P_BRU]),
        .kill_mask          (kill_mask_w),
        .completion_valid   (bru_completion_valid_w),
        .completion         (bru_completion_w),
        .actual_npc         (bru_actual_npc_w),
        .actual_taken       (bru_actual_taken_w),
        .actual_target      (bru_actual_target_w),
        .recovery_valid     (recovery_valid_w),
        .recovery_branch_tag(recovery_tag_w),
        .redirect_pc        (redirect_pc_w)
    );

    fu_smul u_smul (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_SMUL]),
        .issue_req       (fu_req_w[P_SMUL]),
        .kill_mask       (kill_mask_w),
        .completion_valid(smul_completion_valid_w),
        .completion      (smul_completion_w)
    );

    fu_mul u_mul (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_MUL]),
        .issue_req       (fu_req_w[P_MUL]),
        .kill_mask       (kill_mask_w),
        .completion_valid(mul_completion_valid_w),
        .completion      (mul_completion_w)
    );

    fu_div u_div (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_DIV]),
        .issue_req       (fu_req_w[P_DIV]),
        .kill_mask       (kill_mask_w),
        .can_accept      (div_can_accept_w),
        .completion_valid(div_completion_valid_w),
        .completion      (div_completion_w)
    );

    fu_csr u_csr (
        .clk             (clk),
        .rst             (rst),
        .issue_valid     (fu_issue_valid_w[P_CSR]),
        .issue_req       (fu_req_w[P_CSR]),
        .kill_mask       (kill_mask_w),
        .csr_raddr       (csr_raddr_w),
        .csr_rdata       (csr_rdata_w),
        .completion_valid(csr_completion_valid_w),
        .completion      (csr_completion_w),
        .csr_write_data  (csr_unit_wdata_w)
    );

    //=========================================================================
    // Completion network
    //=========================================================================
    always_comb begin
        fu_completion_valid_w = 8'd0;
        for (int unsigned p = 0; p < 8; p++) begin
            fu_completion_w[p]     = '0;
            fu_csr_write_data_w[p] = 32'd0;
            fu_actual_npc_w[p]     = 32'd0;
            fu_actual_taken_w[p]   = 1'b0;
            fu_actual_target_w[p]  = 32'd0;
        end

        fu_completion_valid_w[P_ALU0] = alu0_completion_valid_w;
        fu_completion_w[P_ALU0]       = alu0_completion_w;
        fu_completion_valid_w[P_ALU1] = alu1_completion_valid_w;
        fu_completion_w[P_ALU1]       = alu1_completion_w;
        fu_completion_valid_w[P_BRU]  = bru_completion_valid_w;
        fu_completion_w[P_BRU]        = bru_completion_w;
        fu_completion_valid_w[P_SMUL] = smul_completion_valid_w;
        fu_completion_w[P_SMUL]       = smul_completion_w;
        fu_completion_valid_w[P_MUL]  = mul_completion_valid_w;
        fu_completion_w[P_MUL]        = mul_completion_w;
        fu_completion_valid_w[P_DIV]  = div_completion_valid_w;
        fu_completion_w[P_DIV]        = div_completion_w;
        fu_completion_valid_w[P_CSR]  = csr_completion_valid_w;
        fu_completion_w[P_CSR]        = csr_completion_w;
        fu_completion_valid_w[P_LSU]  = lsu_completion_valid;
        fu_completion_w[P_LSU]        = lsu_completion;

        // FU sidebands (only meaningful with that port's valid completion)
        fu_csr_write_data_w[P_CSR]    = csr_unit_wdata_w;
        fu_actual_npc_w[P_BRU]        = bru_actual_npc_w;
        fu_actual_taken_w[P_BRU]      = bru_actual_taken_w;
        fu_actual_target_w[P_BRU]     = bru_actual_target_w;
    end

    be_completion u_completion (
        .entry              (entry_w),
        .kill_mask          (kill_mask_w),
        .fu_completion_valid(fu_completion_valid_w),
        .fu_completion      (fu_completion_w),
        .csr_write_data     (fu_csr_write_data_w),
        .actual_npc         (fu_actual_npc_w),
        .actual_taken       (fu_actual_taken_w),
        .actual_target      (fu_actual_target_w),
        .cmpl_we            (cmpl_we_w),
        .cmpl_tag           (cmpl_tag_w),
        .cmpl_result        (cmpl_result_w),
        .cmpl_exception     (cmpl_exception_w),
        .cmpl_cause         (cmpl_cause_w),
        .cmpl_tval          (cmpl_tval_w),
        .cmpl_csr_write_data(cmpl_csr_w),
        .cmpl_actual_npc    (cmpl_npc_w),
        .cmpl_actual_taken  (cmpl_taken_w),
        .cmpl_actual_target (cmpl_target_w),
        .err_bad_state      (cmpl_err_bad_state_w),
        .err_dup_tag        (cmpl_err_dup_tag_w)
    );

    //=========================================================================
    // Commit, BPU events, flush, trap, redirect
    //=========================================================================
    be_commit u_commit (
        .clk                   (clk),
        .rst                   (rst),
        .entry                 (entry_w),
        .commit_ptr            (commit_ptr_w),
        .kill_mask             (kill_mask_w),
        .store_commit_ok       (store_commit_ok),
        .bpu_block             (bpu_block_w),
        .mepc                  (mepc_w),
        .commit_fire           (commit_fire_w),
        .commit_tag            (commit_tag_w),
        .commit_rd_wen         (commit_rd_wen_w),
        .commit_rd             (commit_rd_w),
        .commit_wdata          (commit_wdata_w),
        .commit_pc_next        (commit_pc_next_w),
        .commit_is_cfi         (commit_is_cfi_w),
        .commit_is_mret        (commit_is_mret_w),
        .commit_pc             (commit_pc_w),
        .commit_actual_taken   (commit_actual_taken_w),
        .commit_actual_target  (commit_actual_target_w),
        .commit_actual_cfi_type(commit_actual_cfi_type_w),
        .commit_pred_meta      (commit_pred_meta_w),
        .csr_commit_we         (csr_commit_we_w),
        .csr_commit_addr       (csr_commit_addr_w),
        .csr_commit_wdata      (csr_commit_wdata_w),
        .store_commit_valid    (store_commit_valid),
        .store_commit_tag      (store_commit_tag),
        .retire_valid          (retire_valid),
        .retire_pc             (retire_pc),
        .retire_pc_next        (retire_pc_next),
        .retire_rd_wen         (retire_rd_wen),
        .retire_rd             (retire_rd),
        .retire_wdata          (retire_wdata),
        .retire_is_ebreak      (retire_is_ebreak)
    );

    be_bpu_update u_bpu (
        .bpu_update_credit(bpu_update_credit),
        .commit_fire(commit_fire_w),
        .cand_is_cfi(commit_is_cfi_w),
        .cand_pc(commit_pc_w),
        .cand_actual_taken(commit_actual_taken_w),
        .cand_actual_target(commit_actual_target_w),
        .cand_actual_cfi_type(commit_actual_cfi_type_w),
        .cand_pred_meta(commit_pred_meta_w),
        .bpu_block(bpu_block_w),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update)
    );

    be_trap_ctrl u_trap (
        .clk                  (clk),
        .rst                  (rst),
        .head_is_ecall        (head_is_ecall_w),
        .head_pc              (entry_w[commit_ptr_w.slot_index].pc),
        .commit_ptr           (commit_ptr_w),
        .commit_fire          (commit_fire_w),
        .head_is_mret         (head_is_mret_w),
        .commit_pc_next       (commit_pc_next_w),
        .mstatus_mie          (mstatus_mie_w),
        .mie_msie             (mie_msie_w),
        .mie_mtie             (mie_mtie_w),
        .mie_meie             (mie_meie_w),
        .mip_msip             (mip_msip_w),
        .mip_mtip             (mip_mtip_w),
        .mip_meip             (mip_meip_w),
        .mtvec                (mtvec_w),
        .mepc                 (mepc_w),
        .lsu_mmio_order_idle  (lsu_mmio_order_idle),
        .ciq_empty            (occupancy_w == 5'd0),
        .ecall_valid          (ecall_valid_w),
        .ecall_pc             (ecall_pc_w),
        .mret_valid           (mret_valid_w),
        .mret_pc              (mret_pc_w),
        .irq_valid            (irq_valid_w),
        .irq_pc               (irq_pc_w),
        .irq_accept_evt       (irq_accept_w),
        .full_flush_valid     (full_flush_valid_w),
        .full_flush_keep_head (full_flush_keep_head_w),
        .full_flush_ptr       (full_flush_ptr_w),
        .trap_we              (trap_we_w),
        .trap_mepc            (trap_mepc_w),
        .trap_mcause          (trap_mcause_w),
        .mret_we              (mret_we_w),
        .irq_drain            (irq_drain_w),
        .architectural_next_pc(arch_next_pc_w)
    );

    be_flush u_flush (
        .entry               (entry_w),
        .commit_ptr          (commit_ptr_w),
        .commit_fire         (commit_fire_w),
        .commit_tag          (commit_tag_w),
        .recovery_valid      (recovery_valid_w),
        .recovery_branch_tag (recovery_tag_w),
        .full_flush_valid    (full_flush_valid_w),
        .full_flush_keep_head(full_flush_keep_head_w),
        .full_flush_ptr      (full_flush_ptr_w),
        .cp_rvalid           (cp_rvalid_w),
        .cp_rtag             (cp_rtag_w),
        .kill_mask           (kill_mask_w),
        .restore_valid       (restore_valid_w),
        .restore_ptr         (restore_ptr_w),
        .restore_map_valid   (restore_map_valid_w),
        .restore_map_tag     (restore_map_tag_w),
        .cp_release          (cp_release_w)
    );

    assign kill_mask = kill_mask_w;

    // Test-bench / assertion visibility of the CIQ pointers and occupancy.
    assign dbg_occupancy    = occupancy_w;
    assign dbg_fu_issue_valid = fu_issue_valid_w;
    for (genvar g = 0; g < 8; g++) begin : gen_dbg_req
        assign dbg_fu_req[g] = fu_req_w[g];
    end
    for (genvar g = 0; g < ISSUE_WIDTH_MAX; g++) begin : gen_dbg_tag
        assign dbg_issue_tag[g] = issue_tag_w[g];
    end
    assign dbg_commit_fire  = commit_fire_w;
    assign dbg_commit_ptr   = commit_ptr_w;
    assign dbg_issue_ptr    = issue_ptr_w;
    assign dbg_alloc_ptr    = alloc_ptr_w;
    assign dbg_arch_next_pc = arch_next_pc_w;

    be_checkpoint u_ckpt (
        .clk(clk),
        .rst(rst),
        .cp_we(cp_we_w),
        .cp_wslot(cp_wslot_w),
        .cp_wvalid(cp_wvalid_w),
        .cp_wtag(cp_wtag_w),
        .cp_release(cp_release_w),
        .rd_slot(recovery_tag_w),
        .cp_rvalid(cp_rvalid_w),
        .cp_rtag(cp_rtag_w),
        .cp_valid_out(cp_valid_w)
    );

    be_redirect u_redirect (
        .rst                  (rst),
        .ecall_valid          (ecall_valid_w),
        .ecall_pc             (ecall_pc_w),
        .mret_valid           (mret_valid_w),
        .mret_pc              (mret_pc_w),
        .branch_valid         (recovery_valid_w),
        .branch_pc            (redirect_pc_w),
`ifdef TOURNAMENT_ON
        .branch_ghr_before    (entry_w[recovery_tag_w.slot_index].pred_meta.chooser_meta.pred_ghr),
`else
        .branch_ghr_before    ('0),
`endif
        // The BRU's live sideband is used here: the recovery fires in the same
        // cycle as the completion, before the CIQ entry is updated.
        .branch_taken         (bru_actual_taken_w),
        .irq_valid            (irq_valid_w),
        .irq_pc               (irq_pc_w),
        .redirect_valid       (backend_redirect_valid),
        .redirect_pc          (backend_redirect_pc),
        .redirect_kind        (backend_redirect_kind),
        .redirect_ghr_before  (backend_redirect_ghr_before),
        .redirect_actual_taken(backend_redirect_actual_taken),
        .sel_ecall            (sel_ecall_w),
        .sel_mret             (sel_mret_w),
        .sel_branch           (sel_branch_w),
        .sel_irq              (sel_irq_w)
    );

    assign irq_redirect_valid = irq_accept_w;
    assign irq_redirect_pc    = irq_pc_w;

    // FENCE.I retires like a serializing no-op.  The frontend consumes this
    // one-cycle pulse to invalidate its instruction cache after all older
    // stores have drained (the pulse is the C5 contract hook; the real FE and
    // the SoC-level cache maintenance are wired when the FE is integrated).
    assign fence_i_valid = commit_fire_w[0]
                        && entry_w[commit_ptr_w.slot_index].is_fence
                        && entry_w[commit_ptr_w.slot_index].imm[0];

    //=========================================================================
    // CSR file (architectural writes happen only here, at commit)
    //=========================================================================
    csr_file #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(HART_ID)
    ) u_csr_file (
        .clk         (clk),
        .rst         (rst),
        .timer_irq   (timer_irq),
        .software_irq(software_irq),
        .external_irq(external_irq),
        .raddr      (csr_raddr_w),
        .rdata      (csr_rdata_w),
        .raddr_ok   (csr_raddr_ok_w),
        .we         (csr_commit_we_w),
        .waddr      (csr_commit_addr_w),
        .wdata      (csr_commit_wdata_w),
        .trap_we    (trap_we_w),
        .trap_mepc  (trap_mepc_w),
        .trap_mcause(trap_mcause_w),
        .mret_we    (mret_we_w),
        .mstatus_mie(mstatus_mie_w),
        .mie_msie   (mie_msie_w),
        .mie_mtie   (mie_mtie_w),
        .mie_meie   (mie_meie_w),
        .mip_msip   (mip_msip_w),
        .mip_mtip   (mip_mtip_w),
        .mip_meip   (mip_meip_w),
        .mtvec      (mtvec_w),
        .mepc       (mepc_w)
    );

    //=========================================================================
    // LSU-visible commit sideband
    //=========================================================================
    assign load_head_valid = entry_w[commit_ptr_w.slot_index].valid
                          && (entry_w[commit_ptr_w.slot_index].state == ENTRY_EXEC)
                          && entry_w[commit_ptr_w.slot_index].is_load;
    assign load_head_tag = commit_ptr_w;

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // An RF read is only legal when no uncommitted producer of that register
    // exists (backend.md 8.4).  Entries committing this cycle are excluded.
    //-------------------------------------------------------------------------
    logic dep_lost_w;
    logic used_w, dep_w;
    logic [3:0] dbg_dep_i, dbg_dep_e;
    logic [4:0] dbg_dep_rs;
    logic [4:0] rs_w;
    always_comb begin
        dep_lost_w = 1'b0;
        used_w = 1'b0;
        dep_w = 1'b0;
        rs_w = 5'd0;
        dbg_dep_i = 4'd0;
        dbg_dep_e = 4'd0;
        dbg_dep_rs = 5'd0;
        for (int unsigned i = 0; i < ISSUE_WIDTH_MAX; i++) begin
            if (cand_w[i].valid && (cand_w[i].state == ENTRY_WAIT)) begin
                for (int unsigned s = 0; s < 2; s++) begin
                    used_w = (s == 0) ? cand_w[i].src1_used : cand_w[i].src2_used;
                    rs_w   = (s == 0) ? cand_w[i].rs1 : cand_w[i].rs2;
                    dep_w  = (s == 0) ? cand_w[i].src1_dep_valid : cand_w[i].src2_dep_valid;
                    if (used_w && (rs_w != 5'd0) && !dep_w) begin
                        for (int unsigned e = 0; e < CIQ_ENTRIES; e++) begin
                            // Only an OLDER uncommitted writer matters (a younger one cannot have been visible at dispatch).
                            if (entry_w[e].valid && entry_w[e].rd_wen
                                && ((4'(e) - commit_ptr_w.slot_index) < (issue_ptr_w.slot_index + 4'(i) - commit_ptr_w.slot_index))
                                && (entry_w[e].rd == rs_w)
                                && !(commit_fire_w[0] && (commit_tag_w[0].slot_index == 4'(e)))
                                && !(commit_fire_w[1] && (commit_tag_w[1].slot_index == 4'(e)))
                                && !kill_mask_w[e])
                                begin
                                dep_lost_w = 1'b1;
                                dbg_dep_i  = 4'(i);
                                dbg_dep_e  = 4'(e);
                                dbg_dep_rs = rs_w;
                            end
                        end
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst)
            a_dep_lost :
            assert (!dep_lost_w)
            else
                $display(
                    "dep_lost: cand=%0d rs=x%0d entry slot=%0d valid=%b state=%0d rd_wen=%b rd=%0d commit=%0d issue=%0d alloc=%0d kill=%h",
                    dbg_dep_i,
                    dbg_dep_rs,
                    dbg_dep_e,
                    entry_w[dbg_dep_e].valid,
                    entry_w[dbg_dep_e].state,
                    entry_w[dbg_dep_e].rd_wen,
                    entry_w[dbg_dep_e].rd,
                    commit_ptr_w.slot_index,
                    issue_ptr_w.slot_index,
                    alloc_ptr_w.slot_index,
                    kill_mask_w
                );
    end

    //-------------------------------------------------------------------------
    // Producer Map invariant (backend.md 6.1): the registered map must point at
    // the youngest valid uncommitted writer of every register.  A lost binding
    // here is exactly a lost source dependency for a later consumer.
    //-------------------------------------------------------------------------
    logic [31:0] map_ok_w;
    logic [ 4:0] dbg_fail_r;
    logic [ 3:0] dbg_youngest;
    logic        exp_valid_w;
    logic [ 3:0] exp_tag_w;
    always_comb begin
        map_ok_w = '1;
        dbg_fail_r = 5'd0;
        dbg_youngest = 4'd0;
        exp_valid_w = 1'b0;
        exp_tag_w = 4'd0;
        for (int unsigned r = 1; r < 32; r++) begin
            logic       found_w;
            logic [3:0] youngest_w;
            logic [3:0] age_w;
            found_w    = 1'b0;
            youngest_w = 4'd0;
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
                age_w = 4'(i) - commit_ptr_w.slot_index;
                // Entries freed at this edge (killed or committing) are not
                // writers for the comparison: the map already reflects them
                // (commit clears + the validated checkpoint restore).
                if (entry_w[i].valid && entry_w[i].rd_wen && (entry_w[i].rd == 5'(r))
                    && !kill_mask_w[i]
                    && !(commit_fire_w[0] && (commit_tag_w[0].slot_index == 4'(i)))
                    && !(commit_fire_w[1] && (commit_tag_w[1].slot_index == 4'(i)))
                    && (!found_w || (age_w > youngest_w))) begin
                    found_w    = 1'b1;
                    youngest_w = age_w;
                end
            end
            if (found_w) begin
                // Expected map next-state: the validated checkpoint on a
                // recovery/flush cycle, otherwise dispatch_base_map plus this
                // cycle's writer updates.
                exp_valid_w = restore_valid_w ? restore_map_valid_w[r] : base_valid_w[r];
                exp_tag_w   = restore_valid_w ? restore_map_tag_w[r].slot_index : base_tag_w[r].slot_index;
                if (!((exp_valid_w && (exp_tag_w == (commit_ptr_w.slot_index + youngest_w)))
                      || (pm_we_w[0] && (pm_rd_w[0] == 5'(r)))
                      || (pm_we_w[1] && (pm_rd_w[1] == 5'(r))))) begin
                    map_ok_w[r] = 1'b0;
                    if (dbg_fail_r == 5'd0) begin
                        dbg_fail_r   = 5'(r);
                        dbg_youngest = youngest_w;
                    end
                end
            end else begin
                // No surviving writer: the map must be invalid as well.
                if (restore_valid_w ? restore_map_valid_w[r] : base_valid_w[r]) begin
                    map_ok_w[r] = 1'b0;
                    if (dbg_fail_r == 5'd0) begin
                        dbg_fail_r   = 5'(r);
                        dbg_youngest = 4'd15;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst)
            a_map_youngest :
            assert (&map_ok_w)
            else begin
                $display(
                    "map invariant: r=%0d youngest_age=%0d base_valid=%b base_tag=%0d commit=%0d",
                    dbg_fail_r, dbg_youngest, base_valid_w[dbg_fail_r],
                    base_tag_w[dbg_fail_r].slot_index, commit_ptr_w.slot_index);
                for (int unsigned i = 0; i < CIQ_ENTRIES; i++)
                $display(
                    "  slot=%0d valid=%b state=%0d rd_wen=%b rd=%0d age=%0d kill=%b",
                    i,
                    entry_w[i].valid,
                    entry_w[i].state,
                    entry_w[i].rd_wen,
                    entry_w[i].rd,
                    4'(i) - commit_ptr_w.slot_index,
                    kill_mask_w[i]
                );
            end
    end

    // Checkpoints only exist for control transfers (backend.md 15.2).
    logic [CIQ_ENTRIES-1:0] cp_branch_ok_w;
    always_comb begin
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++)
        cp_branch_ok_w[i] = !cp_valid_w[i] || entry_w[i].is_branch;
    end

    // Completion protocol: never a bogus completion (wrong state / already
    // killed entry) and never two completions on one tag (backend.md 11/13).
    always_ff @(posedge clk) begin
        if (!rst) begin
            a_cmpl_state : assert (!cmpl_err_bad_state_w);
            a_cmpl_dup : assert (!cmpl_err_dup_tag_w);
            a_dep_slot : assert (!dep_error);
            a_cp_branch : assert (&cp_branch_ok_w);
            // A branch checkpoint exists only for a control transfer
            // (backend.md 15.2).
            a_redirect_one :
            assert (!backend_redirect_valid
                                     || (({3'b0, sel_ecall_w} + {3'b0, sel_mret_w}
                                        + {3'b0, sel_branch_w} + {3'b0, sel_irq_w}) == 4'd1));
            a_arch_align : assert (arch_next_pc_w[1:0] == 2'b00);
            a_mret_lane0 : assert (!(commit_is_mret_w[1] && commit_fire_w[1]));
            // A commit-head MRET is exactly the "MRET commits this cycle" case
            // (serializing: lane 0 only, never killable - see be_flush).
            // An MRET may only retire when it is the commit head in DONE state.
            a_mret_head : assert (!commit_fire_w[0] || !commit_is_mret_w[0] || head_is_mret_w);
            a_mret_fire : assert (!head_is_mret_w || commit_fire_w[0]);
        end
    end
`endif

endmodule
