`timescale 1ns / 1ps
`include "autoconf.vh"
module student_top#(
    parameter                           P_SW_CNT            = 64,
    parameter                           P_LED_CNT           = 32,
    parameter                           P_SEG_CNT           = 40,
    parameter                           P_KEY_CNT           = 8
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
    output [P_SEG_CNT - 1:0]                    virtual_seg   
);

    // IROM
    logic [31:0] pc;
    logic [`CONFIG_IROM_ADDR_WIDTH - 1:0] inst_addr;
    logic [63:0] instruction;

    // perip
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic perip_valid, perip_ready, perip_rvalid, perip_wen;
    logic [1:0] perip_mask;
    logic timer_irq;

    // miniTensor accelerator control + 128-bit uncached DMA
    core_v_xif mt_xif ();

    logic        mt_wr_en;
    logic [2:0]  mt_wr_idx;
    logic [31:0] mt_wr_data;
    logic        mt_status_rd;
    logic [31:0] mt_status;
    logic [31:0] mt_result;

    logic         mt_mem_rd_valid, mt_mem_rd_ready;
    logic         mt_mem_rsp_valid, mt_mem_rsp_ready;
    logic [31:0]  mt_mem_rd_addr;
    logic [127:0] mt_mem_rsp_data;
    logic         mt_mem_wr_valid, mt_mem_wr_ready;
    logic [31:0]  mt_mem_wr_addr;
    logic [127:0] mt_mem_wr_data;
    logic [15:0]  mt_mem_wr_be;

    // The ROM stores two RV32 instructions in each 64-bit entry.
    assign inst_addr = pc[`CONFIG_IROM_ADDR_WIDTH + 2:3];

    myCPU Core_cpu (
        .cpu_rst            (w_clk_rst),
        .cpu_clk            (w_cpu_clk),
        .timer_irq          (timer_irq),

        // Interface to IROM
        .irom_addr          (pc),             
        .irom_data          (instruction),   

        // Interface to DRAM & periphera
        .perip_valid        (perip_valid),
        .perip_ready        (perip_ready),
        .perip_rvalid       (perip_rvalid),
        .perip_addr         (perip_addr),     
        .perip_wen          (perip_wen),     
        .perip_mask         (perip_mask),   
        .perip_wdata        (perip_wdata),    
        .perip_rdata        (perip_rdata)     
    );

`ifdef __VERILATOR__
    // The DPI-backed simulation model changes its latency internally.
    IROM_BMEM Mem_IROM (
`elsif CONFIG_IROM_CORE_OUTPUT_REGISTER
    IROM_BMEM_TAGE Mem_IROM (
`else
    IROM_BMEM Mem_IROM (
`endif
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
        .timer_irq          (timer_irq),
        .virtual_sw_input	(virtual_sw),
        .virtual_key_input	(virtual_key),	
        .uart_rx_data      (uart_rx_data),
        .uart_rx_ready     (uart_rx_ready),
        .uart_tx_busy      (uart_tx_busy),
        .uart_tx_data      (uart_tx_data),
        .uart_tx_start     (uart_tx_start),
        .virtual_seg_output	(virtual_seg),
        .virtual_led_output (virtual_led),

        .mt_wr_en           (mt_wr_en),
        .mt_wr_idx          (mt_wr_idx),
        .mt_wr_data         (mt_wr_data),
        .mt_status_rd       (mt_status_rd),
        .mt_status          (mt_status),
        .mt_result          (mt_result)
    );

    // ---------------------------------------------------------------------
    // miniTensor: MMIO -> CV-X-IF adapter, the accelerator itself, and the
    // 128-bit DMA bridge into the DPI memory model.
    // ---------------------------------------------------------------------
    mt_cvxif_shim u_mt_shim (
        .clk         (w_cpu_clk),
        .rst         (w_clk_rst),
        .reg_wr_en   (mt_wr_en),
        .reg_wr_idx  (mt_wr_idx),
        .reg_wr_data (mt_wr_data),
        .status_rd   (mt_status_rd),
        .status      (mt_status),
        .result_data (mt_result),
        .xif         (mt_xif)
    );

    mini_tensor_top #(
        .X_ID_WIDTH(4),
        .X_HARTID_WIDTH(1),
        .DATA_WIDTH(128),
        .UB_DEPTH(256)
    ) u_mini_tensor (
        .clk           (w_cpu_clk),
        .rst           (w_clk_rst),
        .xif           (mt_xif),
        .mem_rd_valid  (mt_mem_rd_valid),
        .mem_rd_ready  (mt_mem_rd_ready),
        .mem_rd_addr   (mt_mem_rd_addr),
        .mem_rsp_valid (mt_mem_rsp_valid),
        .mem_rsp_ready (mt_mem_rsp_ready),
        .mem_rsp_data  (mt_mem_rsp_data),
        .mem_wr_valid  (mt_mem_wr_valid),
        .mem_wr_ready  (mt_mem_wr_ready),
        .mem_wr_addr   (mt_mem_wr_addr),
        .mem_wr_data   (mt_mem_wr_data),
        .mem_wr_be     (mt_mem_wr_be),
        .ub_rd_en      (1'b0),
        .ub_rd_addr    (8'd0),
        .ub_rd_valid   (),
        .ub_rd_data    (),
        .dma_busy      ()
    );

    mt_dma_bridge u_mt_dma (
        .clk           (w_cpu_clk),
        .rst           (w_clk_rst),
        .mem_rd_valid  (mt_mem_rd_valid),
        .mem_rd_ready  (mt_mem_rd_ready),
        .mem_rd_addr   (mt_mem_rd_addr),
        .mem_rsp_valid (mt_mem_rsp_valid),
        .mem_rsp_ready (mt_mem_rsp_ready),
        .mem_rsp_data  (mt_mem_rsp_data),
        .mem_wr_valid  (mt_mem_wr_valid),
        .mem_wr_ready  (mt_mem_wr_ready),
        .mem_wr_addr   (mt_mem_wr_addr),
        .mem_wr_data   (mt_mem_wr_data),
        .mem_wr_be     (mt_mem_wr_be)
    );

endmodule
