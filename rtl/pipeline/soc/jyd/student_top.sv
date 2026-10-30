`timescale 1ns / 1ps
`include "autoconf.vh"
module student_top#(
    parameter                           P_SW_CNT            = 64,
    parameter                           P_LED_CNT           = 32,
    parameter                           P_SEG_CNT           = 40,
    parameter                           P_KEY_CNT           = 8,
    parameter [31:0]                    DATA_OFFSET         = 32'd0,
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
    output wire        retire_is_ebreak
);

    // IROM: one 32-bit instruction per entry (no 64-bit pair path).
    wire [31:0] pc;
    wire [`CONFIG_IROM_ADDR_WIDTH:0] inst_addr;
    wire [31:0] instruction;
    wire [31:0] irom_rsp_data;

    // Instruction-fetch handshake (cache or 1-cycle passthrough)
    wire irom_req_valid;
    wire irom_req_ready;
    wire irom_rsp_valid;
    wire irom_rsp_ready;
    wire irom_flush;

    // perip
    wire [31:0] perip_addr, perip_wdata, perip_rdata;
    wire perip_valid, perip_ready, perip_rvalid, perip_wen;
    wire [1:0] perip_mask;
    wire perip_idle;

    myCPU Core_cpu (
        .cpu_rst            (w_clk_rst),
        .cpu_clk            (w_cpu_clk),

        // Interface to the instruction-fetch path
        .irom_req_valid     (irom_req_valid),
        .irom_req_addr      (pc),
        .irom_req_ready     (irom_req_ready),
        .irom_rsp_valid     (irom_rsp_valid),
        .irom_rsp_data      (irom_rsp_data),
        .irom_rsp_ready     (irom_rsp_ready),
        .irom_flush         (irom_flush),

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

                .req_valid         (irom_req_valid),
                .req_addr          (pc),
                .req_ready         (irom_req_ready),
                .rsp_valid         (irom_rsp_valid),
                .rsp_data          (irom_rsp_data),
                .rsp_ready         (irom_rsp_ready),
                .flush             (irom_flush),

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
                .flush            (irom_flush),
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
                .req_valid        (irom_req_valid),
                .req_addr         (pc),
                .req_ready        (irom_req_ready),
                .rsp_valid        (irom_rsp_valid),
                .rsp_data         (irom_rsp_data),
                .rsp_ready        (irom_rsp_ready),
                .flush            (irom_flush),
                .irom_addr        (inst_addr),
                .irom_data        (instruction)
            );
        end
    endgenerate

    IROM_BMEM32 Mem_IROM (
        .addra            (inst_addr  ),
        .clka             (w_cpu_clk  ),
        .douta            (instruction)
    );

    // IROM_DMEM Mem_IROM (
    //     .a                (inst_addr  ),
    //     .spo              (instruction)
    // );
    
    perip_bridge bridge_inst (
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
        .virtual_led_output (virtual_led)
    );

endmodule
