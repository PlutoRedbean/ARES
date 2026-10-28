//=============================================================================
// ARES core top (S01) - single hart instance: Frontend interface + Backend + LSU
// (HART_ID parameter supplies mhartid; a 2-core SoC instantiates two copies)
//-----------------------------------------------------------------------------
// This is the C3 integration point of docs/implementation_plan.md section 6.4:
// it instantiates the backend subsystem top (be_top) and the memory subsystem
// top (lsu_top) and exposes exactly the contract interfaces that leave the
// core:
//
//   * FE instruction / Redirect / BPU-update interface
//     (frontend_backend_contract.md sections 2 / 3 / 4)
//   * 128-bit data bus and the MMIO device channel (memory.md 3.1 / 6.7)
//   * machine timer/software/external interrupt inputs and the simulation
//     observation ports (backend.md 16.1 / plan 5.18)
//
// The frontend itself is instantiated by the parent, exactly like the plan
// requires: C3 drives the ports from rtl/backend/test/fe_stub.sv; the C5
// ares_cpu_top parent connects the real rtl/frontend/frontend.sv.  No module-internal semantics are changed here - this file is wiring,
// reset distribution and the RESET_* consistency check.
//
// Spec sources: README, backend.md 2 / 9.6 / 16.1 / 17, memory.md 3 / 6.7,
// implementation_plan.md 6.4 (S01).
// FREE items: FREE-02 (subsystem-level file).
//=============================================================================
module ares_core_top #(
    parameter logic [31:0] RESET_MTVEC          = ares_pkg::RESET_PC,  // SPEC-M8: owned by the top
    parameter logic [31:0] HART_ID              = 32'd0,               // mhartid value
    parameter logic [31:0] MMIO_BASE            = 32'hA000_0000,       // SPEC-M7 placeholder
    parameter bit          JYD_UNCACHED_WINDOWS = 1'b0,
    parameter logic [31:0] MMIO_MASK            = 32'hFF00_0000
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
    output fe_pkg::bpu_update_t                               backend_redirect_info,

    //---- BPU update: Commit -> FE (contract section 4) ---------------------
    input  logic                [1:0] bpu_update_credit,
    output logic                [1:0] bpu_update_valid,
    output fe_pkg::bpu_update_t       bpu_update       [2],

    //---- interrupts --------------------------------------------------------
    input logic timer_irq,
    input logic software_irq,
    input logic external_irq,

    //---- 128-bit memory bus (memory.md section 6.7) ------------------------
    output logic         mem_rd_valid,
    input  logic         mem_rd_ready,
    output logic [ 31:0] mem_rd_addr,
    input  logic         mem_rsp_valid,
    output logic         mem_rsp_ready,
    input  logic [127:0] mem_rsp_data,
    output logic         mem_wr_valid,
    input  logic         mem_wr_ready,
    output logic [ 31:0] mem_wr_addr,
    output logic [127:0] mem_wr_data,
    output logic [ 15:0] mem_wr_be,

    //---- MMIO device channel (memory.md section 3.1) -----------------------
    output logic        mmio_req_valid,
    input  logic        mmio_req_ready,
    output logic        mmio_write,
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wdata,
    output logic [ 3:0] mmio_wstrb,
    input  logic        mmio_rsp_valid,
    output logic        mmio_rsp_ready,
    input  logic [31:0] mmio_rsp_data,

    //---- simulation observation (plan section 5.18) ------------------------
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
    output logic [ 1:0] decode_err,
    output logic [31:0] decode_err_pc     [2],
    output logic [31:0] decode_err_inst   [2],

    //---- test-bench / debug visibility (not architectural state) -----------
    output logic        dep_error,
    output logic [ 4:0] dbg_occupancy,
    output logic [31:0] dbg_arch_next_pc,
    output logic [ 2:0] dbg_lq_used,
    output logic [ 3:0] dbg_sq_used
);
    import ares_pkg::*;

    // Reset vector consistency (contract section 1 / SPEC-M8): the FE reset PC
    // is RESET_PC inside ares_pkg; the trap vector base must be 4-byte aligned
    // because mtvec only supports Direct mode (backend.md 16.1).
`ifdef CONFIG_SIMULATION
    initial begin
        if (RESET_MTVEC[1:0] != 2'b00)
            $fatal(1, "ares_core_top: RESET_MTVEC (0x%08x) is not 4-byte aligned", RESET_MTVEC);
        if (RESET_PC[1:0] != 2'b00)
            $fatal(1, "ares_core_top: RESET_PC (0x%08x) is not 4-byte aligned", RESET_PC);
    end
`endif

    //-------------------------------------------------------------------------
    // Backend <-> LSU (backend.md 9.6 / plan 5.10)
    //-------------------------------------------------------------------------
    logic                             lsu_can_accept;
    logic           [            2:0] load_credit;
    logic           [            3:0] store_credit;
    logic                             lsu_issue_valid;
    fu_req_t                          lsu_issue_req;
    logic                             lsu_completion_valid;
    fu_completion_t                   lsu_completion;
    logic           [CIQ_ENTRIES-1:0] kill_mask;
    logic                             load_head_valid;
    tag_t                             load_head_tag;
    logic           [            1:0] store_commit_valid;
    tag_t                             store_commit_tag          [2];
    logic           [            1:0] store_commit_ok;
    logic           [            1:0] commit_fire;
    logic                             lsu_mmio_order_idle;
    logic                             lsu_fence_idle;

    // Backend debug outputs that this level does not re-export.
    /* verilator lint_off UNUSEDSIGNAL */
    logic           [            7:0] unused_dbg_fu_issue_valid;
    fu_req_t                          unused_dbg_fu_req         [8];
    tag_t                             unused_dbg_issue_tag      [4];
    tag_t unused_dbg_commit_ptr, unused_dbg_issue_ptr, unused_dbg_alloc_ptr;
    /* verilator lint_on UNUSEDSIGNAL */

    //-------------------------------------------------------------------------
    // Backend
    //-------------------------------------------------------------------------
    be_top #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(HART_ID)
    ) u_backend (
        .clk                          (clk),
        .rst                          (rst),
        .iq_valid                     (iq_valid),
        .iq_inst                      (iq_inst),
        .iq_accept_count              (iq_accept_count),
        .backend_redirect_valid       (backend_redirect_valid),
        .backend_redirect_pc          (backend_redirect_pc),
        .backend_redirect_kind        (backend_redirect_kind),
        .backend_redirect_ghr_before  (backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .backend_redirect_info(backend_redirect_info),
        .bpu_update_credit            (bpu_update_credit),
        .bpu_update_valid             (bpu_update_valid),
        .bpu_update                   (bpu_update),
        .lsu_can_accept               (lsu_can_accept),
        .load_credit                  (load_credit),
        .store_credit                 (store_credit),
        .lsu_issue_valid              (lsu_issue_valid),
        .lsu_issue_req                (lsu_issue_req),
        .lsu_completion_valid         (lsu_completion_valid),
        .lsu_completion               (lsu_completion),
        .kill_mask                    (kill_mask),
        .load_head_valid              (load_head_valid),
        .load_head_tag                (load_head_tag),
        .store_commit_valid           (store_commit_valid),
        .store_commit_tag             (store_commit_tag),
        .store_commit_ok              (store_commit_ok),
        .lsu_mmio_order_idle          (lsu_mmio_order_idle),
        .lsu_fence_idle               (lsu_fence_idle),
        .timer_irq                    (timer_irq),
        .software_irq                 (software_irq),
        .external_irq                 (external_irq),
        .retire_valid                 (retire_valid),
        .retire_pc                    (retire_pc),
        .retire_pc_next               (retire_pc_next),
        .retire_rd_wen                (retire_rd_wen),
        .retire_rd                    (retire_rd),
        .retire_wdata                 (retire_wdata),
        .retire_is_ebreak             (retire_is_ebreak),
        .irq_redirect_valid           (irq_redirect_valid),
        .irq_redirect_pc              (irq_redirect_pc),
        .fence_i_valid                (fence_i_valid),
        .decode_err                   (decode_err),
        .decode_err_pc                (decode_err_pc),
        .decode_err_inst              (decode_err_inst),
        .dep_error                    (dep_error),
        .dbg_occupancy                (dbg_occupancy),
        .dbg_fu_issue_valid           (unused_dbg_fu_issue_valid),
        .dbg_fu_req                   (unused_dbg_fu_req),
        .dbg_issue_tag                (unused_dbg_issue_tag),
        .dbg_commit_fire              (commit_fire),
        .dbg_commit_ptr               (unused_dbg_commit_ptr),
        .dbg_issue_ptr                (unused_dbg_issue_ptr),
        .dbg_alloc_ptr                (unused_dbg_alloc_ptr),
        .dbg_arch_next_pc             (dbg_arch_next_pc)
    );

    //-------------------------------------------------------------------------
    // LSU / memory subsystem
    //-------------------------------------------------------------------------
    lsu_top #(
        .JYD_UNCACHED_WINDOWS(JYD_UNCACHED_WINDOWS),
        .MMIO_BASE(MMIO_BASE),
        .MMIO_MASK(MMIO_MASK)
    ) u_lsu (
        .clk                (clk),
        .rst                (rst),
        .lsu_can_accept     (lsu_can_accept),
        .load_credit        (load_credit),
        .store_credit       (store_credit),
        .issue_valid        (lsu_issue_valid),
        .issue_req          (lsu_issue_req),
        .completion_valid   (lsu_completion_valid),
        .completion         (lsu_completion),
        .kill_mask          (kill_mask),
        .load_head_valid    (load_head_valid),
        .load_head_tag      (load_head_tag),
        .store_commit_valid (store_commit_valid),
        .store_commit_tag   (store_commit_tag),
        .store_commit_ok    (store_commit_ok),
        .commit_fire        (commit_fire),
        .lsu_mmio_order_idle(lsu_mmio_order_idle),
        .lsu_fence_idle     (lsu_fence_idle),
        .mem_rd_valid       (mem_rd_valid),
        .mem_rd_ready       (mem_rd_ready),
        .mem_rd_addr        (mem_rd_addr),
        .mem_rsp_valid      (mem_rsp_valid),
        .mem_rsp_ready      (mem_rsp_ready),
        .mem_rsp_data       (mem_rsp_data),
        .mem_wr_valid       (mem_wr_valid),
        .mem_wr_ready       (mem_wr_ready),
        .mem_wr_addr        (mem_wr_addr),
        .mem_wr_data        (mem_wr_data),
        .mem_wr_be          (mem_wr_be),
        .mmio_req_valid     (mmio_req_valid),
        .mmio_req_ready     (mmio_req_ready),
        .mmio_write         (mmio_write),
        .mmio_addr          (mmio_addr),
        .mmio_wdata         (mmio_wdata),
        .mmio_wstrb         (mmio_wstrb),
        .mmio_rsp_valid     (mmio_rsp_valid),
        .mmio_rsp_ready     (mmio_rsp_ready),
        .mmio_rsp_data      (mmio_rsp_data),
        .dbg_lq_used        (dbg_lq_used),
        .dbg_sq_used        (dbg_sq_used)
    );


`ifdef CONFIG_BRANCH_DIFFTEST
    //-------------------------------------------------------------------------
    // Branch difftest: hand every resolved CFI to the reference model in
    // sim/csrc/branch_difftest.cpp.  The fields are exactly the ones the FE
    // trains from, so the model sees the RTL's predicted/actual pair.
    //-------------------------------------------------------------------------
    import "DPI-C" function void branch_difftest_queue_update(
        input int update_en,
        input int update_pc,
        input int predicted_pc,
        input int predicted_taken,
        input int actual_taken,
        input int actual_target
    );
    integer bd_lane;
    always @(posedge clk) begin
        if (!rst) begin
            for (bd_lane = 0; bd_lane < 2; bd_lane = bd_lane + 1) begin
                if (bpu_update_valid[bd_lane]) begin
                    branch_difftest_queue_update(
                        int'(bpu_update_valid[bd_lane]),
                        int'(bpu_update[bd_lane].update_pc),
                        int'(bpu_update[bd_lane].pred_meta.pred_target),
                        int'(bpu_update[bd_lane].pred_meta.pred_taken),
                        int'(bpu_update[bd_lane].actual_taken),
                        int'(bpu_update[bd_lane].actual_target));
                end
            end
        end
    end
`endif

endmodule
