//=============================================================================
// ARES pipeline SoC v2 - parameterized private-memory AMP top
//-----------------------------------------------------------------------------
// CORES=2/4 harts with one shared read-only instruction image, private
// per-hart data/accelerators and one shared uncached mailbox.
//
//   * IROM: USE_ICACHE=1 instantiates one shared 32 KiB bank plus a
//     round-robin refill arbiter; every hart has a private 16 KiB direct-
//     mapped I$ (Phase 3) whose refills come from the shared bank.
//     USE_ICACHE=0 is the Phase 2 profile: one replicated 32 KiB bank per
//     hart, reached through the 1-cycle instruction-fetch passthrough.
//   * Every hart uses the shared req/rsp front-end handshake
//     (req_valid/req_ready, rsp_valid/rsp_data/rsp_ready, flush); the AMP I$
//     is the pipeline_amp_icache variant, kept separate from the mainline
//     single-hart pipeline_icache module.
//   * DRAM: each hart owns a private 32 KiB window inside its local BRAM
//     address space, selected by DATA_OFFSET = hart * DATA_STRIDE.
//   * MMIO: UART/timer/cycle counter and the matrix/state accelerators stay
//     private per hart inside student_top.
//   * Mailbox: one shared uncached window at 0xA000_F000 (slot h per hart)
//     plus the hart id at 0xA000_0FF0.
//
// No L2, no coherence, no atomics.  Code memory is read-only, so the I$s
// need no coherence or FENCE.I invalidation.
//=============================================================================
`include "autoconf.vh"

module pipeline_amp_top #(
    parameter integer CORES             = 2,
    parameter integer DATA_STRIDE       = 32'h0000_8000,
    parameter integer USE_ICACHE        = 1,
    parameter integer ICACHE_LINES      = 256,
    parameter integer ICACHE_LINE_BYTES = 64
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [CORES-1:0]         core_en,

    output wire [CORES-1:0]         retire_valid,
    output wire [CORES-1:0][31:0]   retire_pc,
    output wire [CORES-1:0][31:0]   retire_pc_next,
    output wire [CORES-1:0]         retire_rd_wen,
    output wire [CORES-1:0][ 4:0]   retire_rd,
    output wire [CORES-1:0][31:0]   retire_wdata,
    output wire [CORES-1:0]         retire_is_ebreak
);
    localparam integer MEM_AW = `CONFIG_IROM_ADDR_WIDTH + 1;

    // Core-facing fetch handshake, one set per hart.
    wire [CORES-1:0][31:0]                      hart_req_addr;
    wire [CORES-1:0]                            hart_req_valid;
    wire [CORES-1:0]                            hart_req_ready;
    wire [CORES-1:0]                            hart_rsp_valid;
    wire [CORES-1:0][31:0]                      hart_rsp_data;
    wire [CORES-1:0]                            hart_rsp_ready;
    wire [CORES-1:0]                            hart_flush;

    // Cached (Phase 3) profile: one shared bank behind the refill arbiter.
    wire [CORES-1:0]                            ic_req;
    wire [CORES-1:0][`CONFIG_IROM_ADDR_WIDTH:0] ic_req_addr;
    wire [CORES-1:0]                            ic_gnt;
    wire [31:0]                                 shared_data;
    wire [`CONFIG_IROM_ADDR_WIDTH:0]            shared_addr;

    // No-cache (Phase 2) profile: private bank per hart.
    wire [CORES-1:0][`CONFIG_IROM_ADDR_WIDTH:0] bank_addr_direct;
    wire [CORES-1:0][31:0]                      bank_data_direct;

    // Shared uncached mailbox port, one request port per hart.
    wire [CORES-1:0]        mbox_req_valid;
    wire [CORES-1:0]        mbox_req_write;
    wire [CORES-1:0][31:0]  mbox_req_addr;
    wire [CORES-1:0][31:0]  mbox_req_wdata;
    wire [CORES-1:0][ 3:0]  mbox_req_wstrb;
    wire [CORES-1:0][31:0]  mbox_rsp_data;

    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_hart
            wire [7:0]  uart_tx_data_unused;
            wire        uart_tx_start_unused;
            wire [31:0] led_unused;
            wire [39:0] seg_unused;

            if (USE_ICACHE != 0) begin : g_ic
                pipeline_amp_icache #(
                    .LINE_BYTES (ICACHE_LINE_BYTES),
                    .LINES      (ICACHE_LINES)
                ) u_icache (
                    .clk          (clk),
                    .rst          (rst),

                    .req_valid    (hart_req_valid[g]),
                    .req_addr     (hart_req_addr[g]),
                    .req_ready    (hart_req_ready[g]),
                    .rsp_valid    (hart_rsp_valid[g]),
                    .rsp_data     (hart_rsp_data[g]),
                    .rsp_ready    (hart_rsp_ready[g]),
                    .flush        (hart_flush[g]),

                    .mem_req      (ic_req[g]),
                    .mem_req_addr (ic_req_addr[g]),
                    .mem_gnt      (ic_gnt[g]),
                    .mem_data     (shared_data),
                    .stat_refills (),
                    .stat_words   ()
                );
                assign bank_addr_direct[g] = {MEM_AW{1'b0}};
                assign bank_data_direct[g] = 32'd0;
            end else begin : g_direct
                pipeline_irom_passthrough #(
                    .ADDR_WIDTH           (32),
                    .IROM_WORD_ADDR_WIDTH (`CONFIG_IROM_ADDR_WIDTH + 1)
                ) u_passthrough (
                    .clk       (clk),
                    .rst       (rst),
                    .req_valid (hart_req_valid[g]),
                    .req_addr  (hart_req_addr[g]),
                    .req_ready (hart_req_ready[g]),
                    .rsp_valid (hart_rsp_valid[g]),
                    .rsp_data  (hart_rsp_data[g]),
                    .rsp_ready (hart_rsp_ready[g]),
                    .flush     (hart_flush[g]),
                    .irom_addr (bank_addr_direct[g]),
                    .irom_data (bank_data_direct[g])
                );
                assign ic_req[g]      = 1'b0;
                assign ic_req_addr[g] = {MEM_AW{1'b0}};
            end

            student_top #(
                .DATA_OFFSET     (g * DATA_STRIDE),
                .HART_ID         (g),
                .HART_COUNT      (CORES),
                .EXTERNAL_IROM   (1),
                .USE_ICACHE      (0)
            ) u_core (
                .w_cpu_clk     (clk),
                .w_clk_50Mhz   (clk),
                .w_clk_rst     (rst | ~core_en[g]),
                .virtual_key   ({8{1'b0}}),
                .virtual_sw    ({64{1'b0}}),
                .uart_rx_data  (8'd0),
                .uart_rx_ready (1'b0),
                .uart_tx_busy  (1'b0),

                .uart_tx_data  (uart_tx_data_unused),
                .uart_tx_start (uart_tx_start_unused),

                .virtual_led   (led_unused),
                .virtual_seg   (seg_unused),

                .retire_valid    (retire_valid[g]),
                .retire_pc       (retire_pc[g]),
                .retire_pc_next  (retire_pc_next[g]),
                .retire_rd_wen   (retire_rd_wen[g]),
                .retire_rd       (retire_rd[g]),
                .retire_wdata    (retire_wdata[g]),
                .retire_is_ebreak(retire_is_ebreak[g]),

                .irom_req_valid  (hart_req_valid[g]),
                .irom_req_addr   (hart_req_addr[g]),
                .irom_req_ready  (hart_req_ready[g]),
                .irom_rsp_valid  (hart_rsp_valid[g]),
                .irom_rsp_data   (hart_rsp_data[g]),
                .irom_rsp_ready  (hart_rsp_ready[g]),
                .irom_flush      (hart_flush[g]),

                .shared_rdata     (mbox_rsp_data[g]),
                .shared_req_valid (mbox_req_valid[g]),
                .shared_req_write (mbox_req_write[g]),
                .shared_req_addr  (mbox_req_addr[g]),
                .shared_req_wdata (mbox_req_wdata[g]),
                .shared_req_wstrb (mbox_req_wstrb[g])
            );
        end
    endgenerate

    generate
        if (USE_ICACHE != 0) begin : g_shared_irom
            pipeline_irom_arbiter #(
                .MASTERS    (CORES),
                .LINE_WORDS (ICACHE_LINE_BYTES / 4),
                .ADDR_W     (MEM_AW)
            ) u_arb (
                .clk       (clk),
                .rst       (rst),
                .req       (ic_req),
                .req_addr  (ic_req_addr),
                .gnt       (ic_gnt),
                .bank_addr (shared_addr)
            );

            IROM_BMEM32 u_irom (
                .addra (shared_addr),
                .clka  (clk),
                .douta (shared_data)
            );
        end else begin : g_private_irom
            for (g = 0; g < CORES; g = g + 1) begin : g_bank
                IROM_BMEM32 u_irom (
                    .addra (bank_addr_direct[g]),
                    .clka  (clk),
                    .douta (bank_data_direct[g])
                );
            end
        end
    endgenerate

    pipeline_coremark_mbox #(
        .CORES     (CORES)
    ) u_mbox (
        .clk       (clk),
        .rst       (rst),
        .req_valid (mbox_req_valid),
        .req_write (mbox_req_write),
        .req_addr  (mbox_req_addr),
        .req_wdata (mbox_req_wdata),
        .req_wstrb (mbox_req_wstrb),
        .rsp_data  (mbox_rsp_data)
    );
endmodule
