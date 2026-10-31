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
//     hart and no cache.
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

    // Core-facing fetch wires, one set per hart.
    wire [CORES-1:0][31:0]                      hart_pc;
    wire [CORES-1:0][31:0]                      hart_inst;
    wire [CORES-1:0]                            hart_ready;
    wire [CORES-1:0][`CONFIG_IROM_ADDR_WIDTH:0] hart_word;

    // No-cache (Phase 2) profile: private bank per hart.
    wire [CORES-1:0][`CONFIG_IROM_ADDR_WIDTH:0] bank_addr_direct;
    wire [CORES-1:0][31:0]                      bank_data_direct;

    // Cached (Phase 3) profile: one shared bank behind the refill arbiter.
    wire [CORES-1:0]                            ic_req;
    wire [CORES-1:0][`CONFIG_IROM_ADDR_WIDTH:0] ic_req_addr;
    wire [CORES-1:0]                            ic_gnt;
    wire [31:0]                                 shared_data;
    wire [`CONFIG_IROM_ADDR_WIDTH:0]            shared_addr;

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
                pipeline_icache #(
                    .LINE_BYTES (ICACHE_LINE_BYTES),
                    .LINES      (ICACHE_LINES)
                ) u_icache (
                    .clk          (clk),
                    .rst          (rst),
                    .cpu_addr     (hart_pc[g]),
                    .cpu_data     (hart_inst[g]),
                    .cpu_ready    (hart_ready[g]),
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
                assign hart_inst[g]        = bank_data_direct[g];
                assign hart_ready[g]       = 1'b1;
                assign bank_addr_direct[g] = hart_word[g];
            end

            student_top #(
                .DATA_OFFSET     (g * DATA_STRIDE),
                .HART_ID         (g),
                .HART_COUNT      (CORES),
                .EXTERNAL_IROM   (1)
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

                .irom_addr       (hart_word[g]),
                .irom_pc         (hart_pc[g]),
                .irom_data       (hart_inst[g]),
                .irom_ready      (hart_ready[g]),

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
