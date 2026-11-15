//=============================================================================
// ARES pipeline SoC - configurable 2/4-hart coherent system
//-----------------------------------------------------------------------------
// CORES selects the build option:
//   CORES=2  dual-core  (two pipeline_hart instances + coherent L2)
//   CORES=4  quad-core  (four pipeline_hart instances + coherent L2)
//
// The shared L2 is write-invalidate coherent with the write-through L1
// D-cache in the pipeline core.  All harts boot from the same IROM image and
// distinguish themselves through the shared MMIO hart-id register.  core_en
// allows a debug/simulation run to hold one or more harts in reset without
// changing the hardware configuration.
//
// The downstream memory port is the same 128-bit beat protocol used by the
// existing ARES L2 prototypes, so the simulation TB or the Pango BRAM
// wrapper can be attached unchanged.
//=============================================================================
module pipeline_mc_soc_top #(
    parameter integer CORES    = 2,
    parameter integer L2_SETS  = 128,
    parameter integer CLK_HZ   = 100_000_000,
    parameter integer UART_BAUD = 115_200,
    parameter integer DATA_STRIDE = 0,
    parameter         IROM_INIT_FILE = "build/pipeline/irom.hex"
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [CORES-1:0]         core_en,

    //---- downstream shared memory port ------------------------------------
    output wire                     mem_rd_valid,
    input  wire                     mem_rd_ready,
    output wire [ 31:0]             mem_rd_addr,
    input  wire                     mem_rsp_valid,
    output wire                     mem_rsp_ready,
    input  wire [127:0]             mem_rsp_data,
    output wire                     mem_wr_valid,
    input  wire                     mem_wr_ready,
    output wire [ 31:0]             mem_wr_addr,
    output wire [127:0]             mem_wr_data,
    output wire [ 15:0]             mem_wr_be,

    //---- board / console ---------------------------------------------------
    output wire                     uart_tx,
    output wire [31:0]              led,

    //---- observation -------------------------------------------------------
    output wire [CORES-1:0]         retire_valid,
    output wire [CORES-1:0][31:0]   retire_pc,
    output wire [CORES-1:0][31:0]   retire_pc_next,
    output wire [CORES-1:0]         retire_rd_wen,
    output wire [CORES-1:0][ 4:0]   retire_rd,
    output wire [CORES-1:0][31:0]   retire_wdata,
    output wire [CORES-1:0]         retire_is_ebreak,

    output wire                     l2_idle,
    output wire [31:0]              l2_hit_count,
    output wire [31:0]              l2_miss_count,
    output wire                     mmio_idle
);
    // ---- per-hart L2 ports ------------------------------------------------
    wire [CORES-1:0]        c_rd_valid, c_rd_ready;
    wire [CORES-1:0][31:0]  c_rd_addr;
    wire [CORES-1:0]        c_rsp_valid, c_rsp_ready;
    wire [CORES-1:0][127:0] c_rsp_data;
    wire [CORES-1:0]        c_wr_valid, c_wr_ready;
    wire [CORES-1:0][31:0]  c_wr_addr;
    wire [CORES-1:0][127:0] c_wr_data;
    wire [CORES-1:0][15:0]  c_wr_be;

    // ---- per-hart MMIO ports ---------------------------------------------
    wire [CORES-1:0]        m_req_valid, m_req_ready;
    wire [CORES-1:0]        m_write;
    wire [CORES-1:0][31:0]  m_addr, m_wdata;
    wire [CORES-1:0][ 3:0]  m_wstrb;
    wire [CORES-1:0]        m_rsp_valid, m_rsp_ready;
    wire [CORES-1:0][31:0]  m_rsp_data;

    // Each hart has a private MMIO block (hart id, cycle counter, UART).  This
    // keeps the perip response fixed at the two cycles the pipeline core
    // expects and avoids cross-hart MMIO arbitration latency on a dependent
    // MMIO load.  Shared resources are the L2 and DRAM, not the control
    // registers.
    wire [CORES-1:0]        mmio_idle_per;
    wire [CORES-1:0]        uart_tx_per;
    wire [CORES-1:0][31:0]  led_per;

    // ---- coherence sideband ----------------------------------------------
    wire [CORES-1:0] coh_inv_valid;
    wire [31:0]      coh_inv_addr;
    wire [7:0]       coh_epoch;

    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_hart
            localparam [31:0] HART_DATA_OFFSET = g * DATA_STRIDE;
            pipeline_hart #(
                .IROM_INIT_FILE (IROM_INIT_FILE),
                .DATA_OFFSET    (HART_DATA_OFFSET)
            ) u_hart (
                .clk            (clk),
                .rst            (rst | ~core_en[g]),

                .l2_rd_valid    (c_rd_valid[g]),
                .l2_rd_ready    (c_rd_ready[g]),
                .l2_rd_addr     (c_rd_addr[g]),
                .l2_rsp_valid   (c_rsp_valid[g]),
                .l2_rsp_ready   (c_rsp_ready[g]),
                .l2_rsp_data    (c_rsp_data[g]),
                .l2_wr_valid    (c_wr_valid[g]),
                .l2_wr_ready    (c_wr_ready[g]),
                .l2_wr_addr     (c_wr_addr[g]),
                .l2_wr_data     (c_wr_data[g]),
                .l2_wr_be       (c_wr_be[g]),

                .mmio_req_valid (m_req_valid[g]),
                .mmio_req_ready (m_req_ready[g]),
                .mmio_write     (m_write[g]),
                .mmio_addr      (m_addr[g]),
                .mmio_wdata     (m_wdata[g]),
                .mmio_wstrb     (m_wstrb[g]),
                .mmio_rsp_valid (m_rsp_valid[g]),
                .mmio_rsp_ready (m_rsp_ready[g]),
                .mmio_rsp_data  (m_rsp_data[g]),

                .coh_inv_valid  (coh_inv_valid[g]),
                .coh_inv_addr   (coh_inv_addr),
                .coh_epoch      (coh_epoch),

                .l2_idle        (l2_idle),
                .mmio_idle      (mmio_idle_per[g]),

                .retire_valid   (retire_valid[g]),
                .retire_pc      (retire_pc[g]),
                .retire_pc_next (retire_pc_next[g]),
                .retire_rd_wen  (retire_rd_wen[g]),
                .retire_rd      (retire_rd[g]),
                .retire_wdata   (retire_wdata[g]),
                .retire_is_ebreak(retire_is_ebreak[g])
            );
        end
    endgenerate

    pipeline_l2 #(
        .CORES (CORES),
        .SETS  (L2_SETS),
        .WAYS  (4)
    ) u_l2 (
        .clk            (clk),
        .rst            (rst),

        .c_rd_valid     (c_rd_valid),
        .c_rd_ready     (c_rd_ready),
        .c_rd_addr      (c_rd_addr),
        .c_rsp_valid    (c_rsp_valid),
        .c_rsp_ready    (c_rsp_ready),
        .c_rsp_data     (c_rsp_data),

        .c_wr_valid     (c_wr_valid),
        .c_wr_ready     (c_wr_ready),
        .c_wr_addr      (c_wr_addr),
        .c_wr_data      (c_wr_data),
        .c_wr_be        (c_wr_be),

        .coh_inv_valid  (coh_inv_valid),
        .coh_inv_addr   (coh_inv_addr),
        .coh_epoch      (coh_epoch),

        .mem_rd_valid   (mem_rd_valid),
        .mem_rd_ready   (mem_rd_ready),
        .mem_rd_addr    (mem_rd_addr),
        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_ready  (mem_rsp_ready),
        .mem_rsp_data   (mem_rsp_data),
        .mem_wr_valid   (mem_wr_valid),
        .mem_wr_ready   (mem_wr_ready),
        .mem_wr_addr    (mem_wr_addr),
        .mem_wr_data    (mem_wr_data),
        .mem_wr_be      (mem_wr_be),

        .l2_idle        (l2_idle),
        .hit_count      (l2_hit_count),
        .miss_count     (l2_miss_count)
    );

    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_mmio
            pipeline_mmio #(
                .CORES     (1),
                .HART_ID   (g),
                .CORE_COUNT(CORES),
                .CLK_HZ    (CLK_HZ),
                .UART_BAUD (UART_BAUD)
            ) u_mmio (
                .clk            (clk),
                .rst            (rst),

                .req_valid      (m_req_valid[g]),
                .req_ready      (m_req_ready[g]),
                .req_write      (m_write[g]),
                .req_addr       (m_addr[g]),
                .req_wdata      (m_wdata[g]),
                .req_wstrb      (m_wstrb[g]),

                .rsp_valid      (m_rsp_valid[g]),
                .rsp_ready      (m_rsp_ready[g]),
                .rsp_data       (m_rsp_data[g]),

                .mmio_idle      (mmio_idle_per[g]),
                .uart_tx        (uart_tx_per[g]),
                .led            (led_per[g])
            );
        end
    endgenerate

    assign mmio_idle = &mmio_idle_per;
    assign uart_tx   = uart_tx_per[0];
    assign led       = led_per[0];

endmodule
