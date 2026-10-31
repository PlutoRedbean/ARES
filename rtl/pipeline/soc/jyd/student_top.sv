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
    // 0: internal 32 KiB IROM (single-hart profile).
    // 1: the caller supplies the instruction memory (multi-hart AMP top).
    parameter integer                   EXTERNAL_IROM       = 0
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

    // Instruction-memory port for the shared/replicated IROM top.  It is
    // always driven; with EXTERNAL_IROM=0 the internal IROM also drives
    // irom_data and the caller may leave these ports open.
    output wire [`CONFIG_IROM_ADDR_WIDTH:0] irom_addr,
    output wire [31:0] irom_pc,
    input  wire [31:0] irom_data,
    input  wire        irom_ready,

    // Shared uncached MMIO pass-through for the multi-hart mailbox.  The
    // single-hart profile leaves it tied off in the board/top-level wrapper.
    input  wire [31:0] shared_rdata,
    output wire        shared_req_valid,
    output wire        shared_req_write,
    output wire [31:0] shared_req_addr,
    output wire [31:0] shared_req_wdata,
    output wire [3:0]  shared_req_wstrb
);

    // IROM: one 32-bit instruction per entry (no 64-bit pair path).
    wire [31:0] pc;
    wire [`CONFIG_IROM_ADDR_WIDTH:0] inst_addr;
    wire [31:0] instruction;

    // perip
    wire [31:0] perip_addr, perip_wdata, perip_rdata;
    wire perip_valid, perip_ready, perip_rvalid, perip_wen;
    wire [1:0] perip_mask;
    wire perip_idle;

    // 32-bit word index; CONFIG_IROM_ADDR_WIDTH is the old 64-bit-pair width.
    assign inst_addr = pc[`CONFIG_IROM_ADDR_WIDTH + 2:2];
    assign irom_addr = inst_addr;
    assign irom_pc   = pc;

    // Internal IROM always returns in one cycle; only the external path can
    // insert an instruction-cache miss stall.
    wire core_irom_ready = (EXTERNAL_IROM != 0) ? irom_ready : 1'b1;

    myCPU Core_cpu (
        .cpu_rst            (w_clk_rst),
        .cpu_clk            (w_cpu_clk),

        // Interface to IROM
        .irom_addr          (pc),             
        .irom_data          (instruction),   
        .irom_ready         (core_irom_ready),

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

    // Single-hart profile: local 32 KiB IROM.  Multi-hart AMP top: one
    // replicated IROM bank per hart outside this wrapper.
    generate
        if (EXTERNAL_IROM != 0) begin : g_external_irom
            assign instruction = irom_data;
        end else begin : g_internal_irom
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
