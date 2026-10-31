`timescale 1ns / 1ps
`include "autoconf.vh"
module student_top#(
    parameter                           P_SW_CNT            = 64,
    parameter                           P_LED_CNT           = 32,
    parameter                           P_SEG_CNT           = 40,
    parameter                           P_KEY_CNT           = 8,
    parameter [31:0]                    DATA_OFFSET         = 32'd0,
    // Hart identity for the multi-hart CoreMark port (0xA000_0FF0/FF4).
    parameter [31:0]                    HART_ID             = 32'd0,
    parameter [31:0]                    HART_COUNT          = 32'd1,
    // 0: internal 32 KiB IROM and the mainline instruction cache.
    // 1: the caller supplies the instruction-fetch path (multi-hart AMP top);
    //    USE_ICACHE/ICACHE_PIPE_HITS are then unused inside this wrapper.
    parameter integer                   EXTERNAL_IROM       = 0,
    // Single-hart profile (EXTERNAL_IROM=0): 0 disables the internal cache.
    parameter                           USE_ICACHE          = 1,
    parameter                           ICACHE_PIPE_HITS    = 1
) (
    input                                       w_cpu_clk     ,
    input                                       w_clk_50Mhz   ,
    input                                       w_clk_rst     ,
    input  [P_KEY_CNT - 1:0]                    virtual_key   ,
    input  [P_SW_CNT  - 1:0]                    virtual_sw    ,
    input  [7:0]                                uart_rx_data  ,
    input                                       uart_rx_ready ,
    input                                       uart_tx_busy  ,

    output [7:0]                                uart_tx_data  ,
    output                                      uart_tx_start ,

    output [P_LED_CNT - 1:0]                    virtual_led   ,
    output [P_SEG_CNT - 1:0]                    virtual_seg   ,

    // Pipeline-core commit observation (M1)
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_pc_next,
    output wire        retire_rd_wen,
    output wire [ 4:0] retire_rd,
    output wire [31:0] retire_wdata,
    output wire        retire_is_ebreak,

    // Instruction-fetch port for the shared/replicated IROM top.  It uses
    // the same req/rsp handshake as the internal cache and is only driven
    // when EXTERNAL_IROM=1; the single-hart profile ties it off.
    output wire        irom_req_valid,
    output wire [31:0] irom_req_addr,
    input  wire        irom_req_ready,
    input  wire        irom_rsp_valid,
    input  wire [31:0] irom_rsp_data,
    output wire        irom_rsp_ready,
    output wire        irom_flush,

    // Shared uncached MMIO pass-through for the multi-hart mailbox.  The
    // single-hart profile leaves it tied off in the board/top-level wrapper.
    input  wire [31:0] shared_rdata,
    output wire        shared_req_valid,
    output wire        shared_req_write,
    output wire [31:0] shared_req_addr,
    output wire [31:0] shared_req_wdata,
    output wire [3:0]  shared_req_wstrb
);

    // Core fetch handshake and the selected instruction-memory path.
    wire        core_irom_req_valid;
    wire [31:0] core_irom_req_addr;
    wire        core_irom_req_ready;
    wire        core_irom_rsp_valid;
    wire [31:0] core_irom_rsp_data;
    wire        core_irom_rsp_ready;
    wire        core_irom_flush;

    wire [`CONFIG_IROM_ADDR_WIDTH:0] inst_addr;
    wire [31:0]                      instruction;

    // perip
    wire [31:0] perip_addr, perip_wdata, perip_rdata;
    wire perip_valid, perip_ready, perip_rvalid, perip_wen;
    wire [1:0] perip_mask;
    wire perip_idle;

    myCPU Core_cpu (
        .cpu_rst            (w_clk_rst),
        .cpu_clk            (w_cpu_clk),

        // Interface to the instruction-fetch path
        .irom_req_valid     (core_irom_req_valid),
        .irom_req_addr      (core_irom_req_addr),
        .irom_req_ready     (core_irom_req_ready),
        .irom_rsp_valid     (core_irom_rsp_valid),
        .irom_rsp_data      (core_irom_rsp_data),
        .irom_rsp_ready     (core_irom_rsp_ready),
        .irom_flush         (core_irom_flush),

        // Interface to DRAM & periphera
        .perip_valid        (perip_valid),
        .perip_ready        (perip_ready),
        .perip_rvalid       (perip_rvalid),
        .perip_addr         (perip_addr),     
        .perip_wen          (perip_wen),     
        .perip_mask         (perip_mask),   
        .perip_wdata        (perip_wdata),    
        .perip_rdata        (perip_rdata),    
        .perip_idle         (perip_idle),
        // Single-hart profile: no remote L1 invalidations.
        .coh_inv_valid      (1'b0),
        .coh_inv_addr       (32'd0),
        .coh_epoch          (8'd0),
        .data_offset        (DATA_OFFSET),
        .retire_valid       (retire_valid),
        .retire_pc          (retire_pc),
        .retire_pc_next     (retire_pc_next),
        .retire_rd_wen      (retire_rd_wen),
        .retire_rd          (retire_rd),
        .retire_wdata       (retire_wdata),
        .retire_is_ebreak   (retire_is_ebreak)
    );

    generate
        if (EXTERNAL_IROM != 0) begin : g_external_irom
            // The AMP top owns the per-hart cache/refill path.
            assign irom_req_valid      = core_irom_req_valid;
            assign irom_req_addr       = core_irom_req_addr;
            assign core_irom_req_ready = irom_req_ready;
            assign core_irom_rsp_valid = irom_rsp_valid;
            assign core_irom_rsp_data  = irom_rsp_data;
            assign irom_rsp_ready      = core_irom_rsp_ready;
            assign irom_flush          = core_irom_flush;
            assign inst_addr           = {(`CONFIG_IROM_ADDR_WIDTH+1){1'b0}};
        end else begin : g_internal_irom
            assign irom_req_valid = 1'b0;
            assign irom_req_addr  = 32'd0;
            assign irom_rsp_ready = 1'b0;
            assign irom_flush     = 1'b0;

            if (USE_ICACHE) begin : g_icache
                wire        refill_req_valid;
                wire [31:0] refill_req_addr;
                wire        refill_req_ready;
                wire        refill_rsp_valid;
                wire [31:0] refill_rsp_data;
                wire        refill_rsp_ready;

                pipeline_icache #(
                    .ADDR_WIDTH (32),
                    .DATA_WIDTH (32),
                    .LINE_BYTES (32),
                    .NR_SETS    (32),
                    .NR_WAYS    (4),
                    .BEAT_BYTES (4),
                    .PIPE_HITS  (ICACHE_PIPE_HITS)
                ) u_icache (
                    .clk               (w_cpu_clk),
                    .rst               (w_clk_rst),

                    .req_valid         (core_irom_req_valid),
                    .req_addr          (core_irom_req_addr),
                    .req_ready         (core_irom_req_ready),
                    .rsp_valid         (core_irom_rsp_valid),
                    .rsp_data          (core_irom_rsp_data),
                    .rsp_ready         (core_irom_rsp_ready),
                    .flush             (core_irom_flush),

                    .refill_req_valid  (refill_req_valid),
                    .refill_req_addr   (refill_req_addr),
                    .refill_req_ready  (refill_req_ready),
                    .refill_rsp_valid  (refill_rsp_valid),
                    .refill_rsp_data   (refill_rsp_data),
                    .refill_rsp_ready  (refill_rsp_ready),

                    .stats_dump        (retire_valid && retire_is_ebreak),
                    .hit_count         (),
                    .miss_count        (),
                    .refill_count      (),
                    .request_count     ()
                );

                // Reuse the 1-cycle passthrough as the IROM refill adapter.
                pipeline_irom_passthrough #(
                    .ADDR_WIDTH           (32),
                    .IROM_WORD_ADDR_WIDTH (`CONFIG_IROM_ADDR_WIDTH + 1)
                ) u_irom_refill (
                    .clk              (w_cpu_clk),
                    .rst              (w_clk_rst),
                    .req_valid        (refill_req_valid),
                    .req_addr         (refill_req_addr),
                    .req_ready        (refill_req_ready),
                    .rsp_valid        (refill_rsp_valid),
                    .rsp_data         (refill_rsp_data),
                    .rsp_ready        (refill_rsp_ready),
                    .flush            (core_irom_flush),
                    .irom_addr        (inst_addr),
                    .irom_data        (instruction)
                );
            end else begin : g_direct
                // Baseline path: original direct-IROM timing, same handshake.
                pipeline_irom_passthrough #(
                    .ADDR_WIDTH           (32),
                    .IROM_WORD_ADDR_WIDTH (`CONFIG_IROM_ADDR_WIDTH + 1)
                ) u_irom_passthrough (
                    .clk              (w_cpu_clk),
                    .rst              (w_clk_rst),
                    .req_valid        (core_irom_req_valid),
                    .req_addr         (core_irom_req_addr),
                    .req_ready        (core_irom_req_ready),
                    .rsp_valid        (core_irom_rsp_valid),
                    .rsp_data         (core_irom_rsp_data),
                    .rsp_ready        (core_irom_rsp_ready),
                    .flush            (core_irom_flush),
                    .irom_addr        (inst_addr),
                    .irom_data        (instruction)
                );
            end

            IROM_BMEM32 Mem_IROM (
                .addra            (inst_addr  ),
                .clka             (w_cpu_clk  ),
                .douta            (instruction)
            );
        end
    endgenerate

    perip_bridge #(
        .HART_ID        (HART_ID),
        .HART_COUNT     (HART_COUNT)
    ) bridge_inst (
        .clk				(w_cpu_clk),
        .cnt_clk            (w_clk_50Mhz),
        .rst                (w_clk_rst),
        .perip_valid        (perip_valid),
        .perip_ready        (perip_ready),
        .perip_rvalid       (perip_rvalid),
        .perip_addr			(perip_addr),
        .perip_wdata		(perip_wdata),
        .perip_wen			(perip_wen),
        .perip_mask			(perip_mask),
        .perip_rdata		(perip_rdata),
        .perip_idle         (perip_idle),
        .timer_irq          (),
        .virtual_sw_input	(virtual_sw),
        .virtual_key_input	(virtual_key),	
        .uart_rx_data      (uart_rx_data),
        .uart_rx_ready     (uart_rx_ready),
        .uart_tx_busy      (uart_tx_busy),
        .uart_tx_data      (uart_tx_data),
        .uart_tx_start     (uart_tx_start),
        .virtual_seg_output	(virtual_seg),
        .virtual_led_output (virtual_led),
        .shared_rdata       (shared_rdata),
        .shared_req_valid   (shared_req_valid),
        .shared_req_write   (shared_req_write),
        .shared_req_addr    (shared_req_addr),
        .shared_req_wdata   (shared_req_wdata),
        .shared_req_wstrb   (shared_req_wstrb)
    );

endmodule
