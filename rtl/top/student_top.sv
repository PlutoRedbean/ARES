// JYD platform migration. Core FE remains an external ARES contract.
// Approved board map / aliases and limitations: docs/jyd_soc_integration.md.
module student_top (
    input logic w_cpu_clk, w_clk_50Mhz, w_clk_rst,
    input logic [7:0] virtual_key,
    input logic [63:0] virtual_sw,
    input logic [7:0] uart_rx_data,
    input logic uart_rx_ready, uart_tx_busy,
    output logic [7:0] uart_tx_data,
    output logic uart_tx_start,
    output logic [31:0] virtual_led,
    output logic [39:0] virtual_seg,
    // Synchronous 32KiB IROM; response is the 64-bit pair one cycle later.
    /* verilator lint_off UNUSEDSIGNAL */ // 32KiB ROM decodes only word-pair index
    input logic [31:0] ifetch_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [63:0] ifetch_data,
    // miniTensor control seam: DMA integration remains a later milestone.
    output logic mt_wr_en,
    output logic [2:0] mt_wr_idx,
    output logic [31:0] mt_wr_data,
    output logic mt_status_rd,
    input logic [31:0] mt_status, mt_result,
    // FE contract remains external until C5.
    input  logic [1:0]                       iq_valid,
    input  fe_pkg::iq_entry_t              iq_inst [2],
    output logic [1:0]                       iq_accept_count,

    //---- Redirect: BE -> FE (contract section 3) ---------------------------
    output logic                             backend_redirect_valid,
    output logic [31:0]                      backend_redirect_pc,
    output fe_pkg::fe_redirect_kind_t      backend_redirect_kind,
    output logic [fe_pkg::GHR_WIDTH-1:0]     backend_redirect_ghr_before,
    output logic                             backend_redirect_actual_taken,

    //---- BPU update: Commit -> FE (contract section 4) ---------------------
    input  logic [1:0]                       bpu_update_credit,
    output logic [1:0]                       bpu_update_valid,
    output fe_pkg::bpu_update_t            bpu_update [2]
);
    logic timer_irq;
    logic software_irq, external_irq;
    /* verilator lint_off UNUSEDSIGNAL */  // C5 FE integration will consume this pulse
    logic fence_i_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    logic mem_wr_valid, mem_wr_ready;
    logic [31:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0] mem_wr_be;
    logic mmio_req_valid, mmio_req_ready, mmio_write;
    logic [31:0] mmio_addr, mmio_wdata, mmio_rsp_data;
    logic [3:0] mmio_wstrb;
    logic mmio_rsp_valid, mmio_rsp_ready;
    logic perip_valid, perip_ready, perip_rvalid, perip_order_idle, perip_wen;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic [3:0] perip_wstrb;

    assign software_irq = 1'b0;
    assign external_irq = 1'b0;

    ares_core_top #(
        .MMIO_BASE(32'h8020_0000), .MMIO_MASK(32'hFFF0_0000),
        .JYD_UNCACHED_WINDOWS(1'b1)
    ) Core_cpu (
        .clk(w_cpu_clk), .rst(w_clk_rst), .timer_irq(timer_irq),
        .software_irq(software_irq), .external_irq(external_irq),
        .fence_i_valid(fence_i_valid),
        .iq_valid(iq_valid),
        .iq_inst(iq_inst),
        .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc),
        .backend_redirect_kind(backend_redirect_kind),
        .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit(bpu_update_credit),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update),
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
        .retire_valid(),
        .retire_pc(),
        .retire_pc_next(),
        .retire_rd_wen(),
        .retire_rd(),
        .retire_wdata(),
        .retire_is_ebreak(),
        .irq_redirect_valid(),
        .irq_redirect_pc(),
        .decode_err(),
        .decode_err_pc(),
        .decode_err_inst(),
        .dep_error(),
        .dbg_occupancy(),
        .dbg_arch_next_pc(),
        .dbg_lq_used(),
        .dbg_sq_used()
    );

    IROM_BMEM Mem_IROM (
        .clka(w_cpu_clk), .addra(ifetch_addr[14:3]), .douta(ifetch_data)
    );
    ares_jyd_bus_bridge bus_bridge (
        .clk(w_cpu_clk), .rst(w_clk_rst),
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
        .perip_valid(perip_valid),
        .perip_ready(perip_ready),
        .perip_rvalid(perip_rvalid),
        .perip_order_idle(perip_order_idle),
        .perip_wen(perip_wen),
        .perip_addr(perip_addr),
        .perip_wdata(perip_wdata),
        .perip_wstrb(perip_wstrb),
        .perip_rdata(perip_rdata)
    );

    perip_bridge bridge_inst (
        .clk(w_cpu_clk), .cnt_clk(w_clk_50Mhz), .rst(w_clk_rst),
        .perip_valid(perip_valid),
        .perip_ready(perip_ready),
        .perip_rvalid(perip_rvalid),
        .perip_order_idle(perip_order_idle),
        .perip_wen(perip_wen),
        .perip_addr(perip_addr),
        .perip_wdata(perip_wdata),
        .perip_wstrb(perip_wstrb),
        .perip_rdata(perip_rdata),
        .timer_irq(timer_irq),
        .virtual_sw_input(virtual_sw), .virtual_key_input(virtual_key),
        .uart_rx_data(uart_rx_data), .uart_rx_ready(uart_rx_ready),
        .uart_tx_busy(uart_tx_busy), .uart_tx_data(uart_tx_data),
        .uart_tx_start(uart_tx_start),
        .virtual_seg_output(virtual_seg), .virtual_led_output(virtual_led),
        .mt_wr_en(mt_wr_en), .mt_wr_idx(mt_wr_idx), .mt_wr_data(mt_wr_data),
        .mt_status_rd(mt_status_rd), .mt_status(mt_status), .mt_result(mt_result)
    );
endmodule
