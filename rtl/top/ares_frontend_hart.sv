//=============================================================================
// ARES - one real-frontend hart with a shared-L2 native port pair
//-----------------------------------------------------------------------------
// frontend (legacy) -> fe_legacy_adapter -> ares_core_top
//                   -> axi_l2_bridge -> L2 I read port
// core D side       -> L2 D read/write port (with an optional AMP data offset)
//
// The frontend AXI interface is internal; the hart exposes native 128-bit L2
// I/D ports so the 2-core top can share l2_top without AXI at the SoC boundary.
//=============================================================================
module ares_frontend_hart #(
    parameter logic [31:0] RESET_MTVEC   = ares_pkg::RESET_PC,
    parameter logic [31:0] RESET_VEC     = ares_pkg::RESET_PC,
    parameter logic [31:0] HART_ID       = 32'd0,
    parameter logic [31:0] DATA_OFFSET   = 32'h0
) (
    input  logic clk,
    input  logic rst,

    //---- L2 instruction read port ------------------------------------------
    output logic         i_rd_valid,
    input  logic         i_rd_ready,
    output logic [ 31:0] i_rd_addr,
    input  logic         i_rsp_valid,
    output logic         i_rsp_ready,
    input  logic [127:0] i_rsp_data,

    //---- L2 data port -------------------------------------------------------
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

    //---- observation --------------------------------------------------------
    output logic [31:0] fetch_pc,
    output logic [ 1:0] retire_valid,
    output logic [ 1:0] retire_rd_wen,
    output logic [ 4:0] retire_rd [2],
    output logic [31:0] retire_wdata [2],
    output logic [31:0] retire_pc [2],
    output logic [ 1:0] retire_is_ebreak
);
    axi_if ifu_axi();

    logic [1:0] fe_iq_rvalid;
    fe_pkg::iq_entry_t fe_iq_rbits [2];
    logic [1:0] fe_iq_raccept_cnt;
    logic fe_redirect_valid;
    logic [31:0] fe_redirect_pc;
    fe_pkg::fe_redirect_kind_t fe_redirect_kind;
    logic fe_bpu_update_en;
    fe_pkg::bpu_update_t fe_bpu_update_meta;

    logic [1:0] be_iq_valid;
    fe_pkg::iq_entry_t be_iq_inst [2];
    logic [1:0] be_iq_accept_count;
    logic be_redirect_valid;
    logic [31:0] be_redirect_pc;
    fe_pkg::fe_redirect_kind_t be_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] be_redirect_ghr_before;
    logic be_redirect_actual_taken;
    logic [1:0] be_bpu_update_credit;
    logic [1:0] be_bpu_update_valid;
    fe_pkg::bpu_update_t be_bpu_update [2];

    frontend #(
        .RESET_VEC(RESET_VEC)
    ) u_fe (
        .clk(clk), .rst(rst),
        .iq_rvalid(fe_iq_rvalid), .iq_rbits(fe_iq_rbits),
        .iq_raccept_cnt(fe_iq_raccept_cnt),
        .backend_redirect_valid(fe_redirect_valid),
        .backend_redirect_pc(fe_redirect_pc),
        .backend_redirect_kind(fe_redirect_kind),
        .bpu_update_en(fe_bpu_update_en),
        .bpu_update_meta(fe_bpu_update_meta),
        .ifu_axi_bus(ifu_axi),
        .fetch_pc_out(fetch_pc),
        .iq_occupancy(), .iq_enq_count(), .iq_deq_count(),
        .ftq_occupancy(), .ftq_alloc(), .ftq_pop(),
        .icache_refill(), .icache_req_fire()
    );

    fe_legacy_adapter u_adapter (
        .clk(clk), .rst(rst),
        .fe_iq_rvalid(fe_iq_rvalid), .fe_iq_rbits(fe_iq_rbits),
        .fe_iq_raccept_cnt(fe_iq_raccept_cnt),
        .fe_redirect_valid(fe_redirect_valid), .fe_redirect_pc(fe_redirect_pc),
        .fe_redirect_kind(fe_redirect_kind),
        .fe_bpu_update_en(fe_bpu_update_en), .fe_bpu_update_meta(fe_bpu_update_meta),
        .be_iq_valid(be_iq_valid), .be_iq_inst(be_iq_inst),
        .be_iq_accept_count(be_iq_accept_count),
        .be_redirect_valid(be_redirect_valid), .be_redirect_pc(be_redirect_pc),
        .be_redirect_kind(be_redirect_kind),
        .be_redirect_ghr_before(be_redirect_ghr_before),
        .be_redirect_actual_taken(be_redirect_actual_taken),
        .be_bpu_update_credit(be_bpu_update_credit),
        .be_bpu_update_valid(be_bpu_update_valid),
        .be_bpu_update(be_bpu_update)
    );

    logic         l2_i_rd_valid, l2_i_rd_ready;
    logic [31:0]  l2_i_rd_addr;
    logic         l2_i_rsp_valid, l2_i_rsp_ready;
    logic [127:0] l2_i_rsp_data;

    assign i_rd_valid = l2_i_rd_valid;
    assign i_rd_addr  = l2_i_rd_addr;
    assign l2_i_rd_ready = i_rd_ready;
    assign l2_i_rsp_valid = i_rsp_valid;
    assign i_rsp_ready = l2_i_rsp_ready;
    assign l2_i_rsp_data = i_rsp_data;

    axi_l2_bridge u_ibridge (
        .clk(clk), .rst(rst),
        .axi(ifu_axi),
        .l2_rd_valid(l2_i_rd_valid), .l2_rd_ready(l2_i_rd_ready), .l2_rd_addr(l2_i_rd_addr),
        .l2_rsp_valid(l2_i_rsp_valid), .l2_rsp_ready(l2_i_rsp_ready), .l2_rsp_data(l2_i_rsp_data)
    );

    logic core_mem_rd_valid, core_mem_rd_ready, core_mem_rsp_valid, core_mem_rsp_ready;
    logic [31:0] core_mem_rd_addr;
    logic [127:0] core_mem_rsp_data;
    logic core_mem_wr_valid, core_mem_wr_ready;
    logic [31:0] core_mem_wr_addr;
    logic [127:0] core_mem_wr_data;
    logic [15:0] core_mem_wr_be;

    assign mem_rd_valid = core_mem_rd_valid;
    assign core_mem_rd_ready = mem_rd_ready;
    assign mem_rd_addr = core_mem_rd_addr + DATA_OFFSET;
    assign core_mem_rsp_valid = mem_rsp_valid;
    assign core_mem_rsp_data = mem_rsp_data;
    assign mem_rsp_ready = core_mem_rsp_ready;
    assign mem_wr_valid = core_mem_wr_valid;
    assign core_mem_wr_ready = mem_wr_ready;
    assign mem_wr_addr = core_mem_wr_addr + DATA_OFFSET;
    assign mem_wr_data = core_mem_wr_data;
    assign mem_wr_be = core_mem_wr_be;

    /* verilator lint_off UNUSEDSIGNAL */
    logic mmio_req_valid, mmio_req_ready, mmio_write;
    logic [31:0] mmio_addr, mmio_wdata;
    logic [3:0] mmio_wstrb;
    logic mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_rsp_data;
    /* verilator lint_on UNUSEDSIGNAL */

    assign mmio_req_ready = 1'b1;
    assign mmio_rsp_ready = 1'b1;
    assign mmio_rsp_data  = 32'h0;
    always_ff @(posedge clk) begin
        if (rst) mmio_rsp_valid <= 1'b0;
        else     mmio_rsp_valid <= mmio_req_valid;
    end

    ares_core_top #(
        .RESET_MTVEC(RESET_MTVEC),
        .HART_ID(HART_ID)
    ) u_core (
        .clk(clk), .rst(rst),
        .iq_valid(be_iq_valid), .iq_inst(be_iq_inst), .iq_accept_count(be_iq_accept_count),
        .backend_redirect_valid(be_redirect_valid), .backend_redirect_pc(be_redirect_pc),
        .backend_redirect_kind(be_redirect_kind),
        .backend_redirect_ghr_before(be_redirect_ghr_before),
        .backend_redirect_actual_taken(be_redirect_actual_taken),
        .bpu_update_credit(be_bpu_update_credit),
        .bpu_update_valid(be_bpu_update_valid), .bpu_update(be_bpu_update),
        .timer_irq(1'b0), .software_irq(1'b0), .external_irq(1'b0),
        .fence_i_valid(),
        .mem_rd_valid(core_mem_rd_valid), .mem_rd_ready(core_mem_rd_ready), .mem_rd_addr(core_mem_rd_addr),
        .mem_rsp_valid(core_mem_rsp_valid), .mem_rsp_ready(core_mem_rsp_ready), .mem_rsp_data(core_mem_rsp_data),
        .mem_wr_valid(core_mem_wr_valid), .mem_wr_ready(core_mem_wr_ready), .mem_wr_addr(core_mem_wr_addr),
        .mem_wr_data(core_mem_wr_data), .mem_wr_be(core_mem_wr_be),
        .mmio_req_valid(mmio_req_valid), .mmio_req_ready(mmio_req_ready),
        .mmio_write(mmio_write), .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb),
        .mmio_rsp_valid(mmio_rsp_valid), .mmio_rsp_ready(mmio_rsp_ready),
        .mmio_rsp_data(mmio_rsp_data),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_pc_next(),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata), .retire_is_ebreak(retire_is_ebreak),
        .irq_redirect_valid(), .irq_redirect_pc(),
        .decode_err(), .decode_err_pc(), .decode_err_inst(), .dep_error(),
        .dbg_occupancy(), .dbg_arch_next_pc(), .dbg_lq_used(), .dbg_sq_used()
    );

endmodule
