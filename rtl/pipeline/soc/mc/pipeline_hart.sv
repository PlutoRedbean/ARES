//=============================================================================
// ARES pipeline SoC - one hart: Mundus core + private IROM + memory adapter
//-----------------------------------------------------------------------------
// Every hart has its own 32 KiB IROM instance (the image is read-only, so
// replication is both simple and coherent by construction).  The L1 D-cache
// stays inside the core; this wrapper only exposes the write-invalidate
// sideband and the shared L2/MMIO ports.
//=============================================================================
`include "autoconf.vh"

module pipeline_hart #(
    parameter IROM_INIT_FILE = "build/pipeline/irom.hex",
    parameter [31:0] DATA_OFFSET = 32'd0
) (
    input  wire        clk,
    input  wire        rst,

    //---- shared L2 port ----------------------------------------------------
    output wire         l2_rd_valid,
    input  wire         l2_rd_ready,
    output wire [ 31:0] l2_rd_addr,
    input  wire         l2_rsp_valid,
    output wire         l2_rsp_ready,
    input  wire [127:0] l2_rsp_data,
    output wire         l2_wr_valid,
    input  wire         l2_wr_ready,
    output wire [ 31:0] l2_wr_addr,
    output wire [127:0] l2_wr_data,
    output wire [ 15:0] l2_wr_be,

    //---- shared MMIO port --------------------------------------------------
    output wire        mmio_req_valid,
    input  wire        mmio_req_ready,
    output wire        mmio_write,
    output wire [31:0] mmio_addr,
    output wire [31:0] mmio_wdata,
    output wire [ 3:0] mmio_wstrb,
    input  wire        mmio_rsp_valid,
    output wire        mmio_rsp_ready,
    input  wire [31:0] mmio_rsp_data,

    //---- coherence sideband ------------------------------------------------
    input  wire        coh_inv_valid,
    input  wire [31:0] coh_inv_addr,
    input  wire [ 7:0] coh_epoch,

    //---- activity ----------------------------------------------------------
    input  wire        l2_idle,
    input  wire        mmio_idle,

    //---- retire observation ------------------------------------------------
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_pc_next,
    output wire        retire_rd_wen,
    output wire [ 4:0] retire_rd,
    output wire [31:0] retire_wdata,
    output wire        retire_is_ebreak
);
    wire [31:0] pc;
    wire [`CONFIG_IROM_ADDR_WIDTH:0] inst_addr;
    wire [31:0] instruction;
    wire [31:0] irom_rsp_data;

    wire irom_req_valid;
    wire irom_req_ready;
    wire irom_rsp_valid;
    wire irom_rsp_ready;
    wire irom_flush;

    wire [31:0] perip_addr, perip_wdata, perip_rdata;
    wire        perip_valid, perip_ready, perip_rvalid, perip_wen;
    wire [ 1:0] perip_mask;
    wire        perip_idle;

    myCPU u_core (
        .cpu_rst            (rst),
        .cpu_clk            (clk),

        .irom_req_valid     (irom_req_valid),
        .irom_req_addr      (pc),
        .irom_req_ready     (irom_req_ready),
        .irom_rsp_valid     (irom_rsp_valid),
        .irom_rsp_data      (irom_rsp_data),
        .irom_rsp_ready     (irom_rsp_ready),
        .irom_flush         (irom_flush),

        .perip_valid        (perip_valid),
        .perip_ready        (perip_ready),
        .perip_rvalid       (perip_rvalid),
        .perip_addr         (perip_addr),
        .perip_wen          (perip_wen),
        .perip_mask         (perip_mask),
        .perip_wdata        (perip_wdata),
        .perip_rdata        (perip_rdata),
        .perip_idle         (perip_idle),

        .coh_inv_valid      (coh_inv_valid),
        .coh_inv_addr       (coh_inv_addr),
        .coh_epoch          (coh_epoch),
        .data_offset        (DATA_OFFSET),

        .retire_valid       (retire_valid),
        .retire_pc          (retire_pc),
        .retire_pc_next     (retire_pc_next),
        .retire_rd_wen      (retire_rd_wen),
        .retire_rd          (retire_rd),
        .retire_wdata       (retire_wdata),
        .retire_is_ebreak   (retire_is_ebreak)
    );

    // First-cut MC integration keeps the 1-cycle passthrough path; enabling
    // the per-hart instruction cache is a later step.
    pipeline_irom_passthrough #(
        .ADDR_WIDTH           (32),
        .IROM_WORD_ADDR_WIDTH (`CONFIG_IROM_ADDR_WIDTH + 1)
    ) u_irom_passthrough (
        .clk         (clk),
        .rst         (rst),
        .req_valid   (irom_req_valid),
        .req_addr    (pc),
        .req_ready   (irom_req_ready),
        .rsp_valid   (irom_rsp_valid),
        .rsp_data    (irom_rsp_data),
        .rsp_ready   (irom_rsp_ready),
        .flush       (irom_flush),
        .irom_addr   (inst_addr),
        .irom_data   (instruction)
    );

    IROM_BMEM32 #(
        .IROM_INIT_FILE (IROM_INIT_FILE)
    ) u_irom (
        .addra (inst_addr),
        .clka  (clk),
        .douta (instruction)
    );

    pipeline_core_port u_port (
        .clk            (clk),
        .rst            (rst),

        .perip_valid    (perip_valid),
        .perip_ready    (perip_ready),
        .perip_rvalid   (perip_rvalid),
        .perip_addr     (perip_addr),
        .perip_wen      (perip_wen),
        .perip_mask     (perip_mask),
        .perip_wdata    (perip_wdata),
        .perip_rdata    (perip_rdata),
        .perip_idle     (perip_idle),

        .l2_rd_valid    (l2_rd_valid),
        .l2_rd_ready    (l2_rd_ready),
        .l2_rd_addr     (l2_rd_addr),
        .l2_rsp_valid   (l2_rsp_valid),
        .l2_rsp_ready   (l2_rsp_ready),
        .l2_rsp_data    (l2_rsp_data),
        .l2_wr_valid    (l2_wr_valid),
        .l2_wr_ready    (l2_wr_ready),
        .l2_wr_addr     (l2_wr_addr),
        .l2_wr_data     (l2_wr_data),
        .l2_wr_be       (l2_wr_be),

        .mmio_req_valid (mmio_req_valid),
        .mmio_req_ready (mmio_req_ready),
        .mmio_write     (mmio_write),
        .mmio_addr      (mmio_addr),
        .mmio_wdata     (mmio_wdata),
        .mmio_wstrb     (mmio_wstrb),
        .mmio_rsp_valid (mmio_rsp_valid),
        .mmio_rsp_ready (mmio_rsp_ready),
        .mmio_rsp_data  (mmio_rsp_data),

        .l2_idle        (l2_idle),
        .mmio_idle      (mmio_idle)
    );

endmodule
