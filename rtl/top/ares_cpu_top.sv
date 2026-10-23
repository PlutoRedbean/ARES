/* verilator lint_off PINCONNECTEMPTY */ // optional FE performance observations
// Complete CPU: real FE, Backend/LSU, and a synchronous IROM seam.
module ares_cpu_top #(
    parameter logic [31:0] RESET_MTVEC          = ares_pkg::RESET_PC,  // SPEC-M8: owned by the top
    parameter logic [31:0] MMIO_BASE            = 32'hA000_0000,       // SPEC-M7 placeholder
    parameter bit          JYD_UNCACHED_WINDOWS = 1'b0,
    parameter logic [31:0] MMIO_MASK            = 32'hFF00_0000
) (
    input logic clk,
    input logic rst,

    output logic [31:0] irom_addr,
    input logic [63:0] irom_data,

    //---- interrupts --------------------------------------------------------
    input logic timer_irq,

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
    logic [1:0] iq_valid, iq_accept_count, bpu_update_credit, bpu_update_valid;
    fe_pkg::iq_entry_t iq_inst [2];
    fe_pkg::bpu_update_t bpu_update [2];
    fe_pkg::bpu_update_t backend_redirect_info;
    logic backend_redirect_valid, backend_redirect_actual_taken;
    logic [31:0] backend_redirect_pc;
    fe_pkg::fe_redirect_kind_t backend_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] backend_redirect_ghr_before;
    axi_if ifetch_bus ();
    frontend u_frontend (
        .clk(clk), .rst(rst), .iq_rvalid(iq_valid), .iq_rbits(iq_inst),
        .iq_raccept_cnt(iq_accept_count), .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc), .backend_redirect_kind(backend_redirect_kind),
        .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .backend_redirect_info(backend_redirect_info),
        .bpu_update_credit(bpu_update_credit), .bpu_update_valid(bpu_update_valid), .bpu_update(bpu_update),
        .ifu_axi_bus(ifetch_bus), .fetch_pc_out(), .iq_occupancy(), .iq_enq_count(), .iq_deq_count(),
        .ftq_occupancy(), .ftq_alloc(), .ftq_pop(), .icache_refill(), .icache_req_fire()
    );
    ares_irom_bridge u_irom_bridge (
        .clk(clk), .rst(rst), .bus(ifetch_bus), .irom_addr(irom_addr), .irom_data(irom_data)
    );
    ares_core_top #(.RESET_MTVEC(RESET_MTVEC), .MMIO_BASE(MMIO_BASE),
        .MMIO_MASK(MMIO_MASK), .JYD_UNCACHED_WINDOWS(JYD_UNCACHED_WINDOWS)) u_core (
        .clk(clk),
        .rst(rst),
        .iq_valid(iq_valid),
        .iq_inst(iq_inst),
        .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc),
        .backend_redirect_kind(backend_redirect_kind),
        .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .backend_redirect_info(backend_redirect_info),
        .bpu_update_credit(bpu_update_credit),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update),
        .timer_irq(timer_irq),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_data(mem_rsp_data),
        .mem_wr_valid(mem_wr_valid),
        .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data),
        .mem_wr_be(mem_wr_be),
        .mmio_req_valid(mmio_req_valid),
        .mmio_req_ready(mmio_req_ready),
        .mmio_write(mmio_write),
        .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb),
        .mmio_rsp_valid(mmio_rsp_valid),
        .mmio_rsp_ready(mmio_rsp_ready),
        .mmio_rsp_data(mmio_rsp_data),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc),
        .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen),
        .retire_rd(retire_rd),
        .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .irq_redirect_valid(irq_redirect_valid),
        .irq_redirect_pc(irq_redirect_pc),
        .decode_err(decode_err),
        .decode_err_pc(decode_err_pc),
        .decode_err_inst(decode_err_inst),
        .dep_error(dep_error),
        .dbg_occupancy(dbg_occupancy),
        .dbg_arch_next_pc(dbg_arch_next_pc),
        .dbg_lq_used(dbg_lq_used),
        .dbg_sq_used(dbg_sq_used)
    );
`ifdef CONFIG_SIMULATION
    initial begin
        if (fe_pkg::FETCH_WIDTH != 4 || fe_pkg::DECODE_WIDTH != 2)
            $fatal(1,"ARES CPU requires 4-wide fetch and 2-wide decode");
    end
`endif
endmodule

/* verilator lint_on PINCONNECTEMPTY */
