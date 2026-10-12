//=============================================================================
// ARES core verification - top level test bench (C0 shell)
//-----------------------------------------------------------------------------
// This is the C3 integration shell described in docs/core_verification_flow.md
// section 2:
//
//      tb_ares_core
//        |- fe_stub.sv          (contract-compliant fetch, DPI irom_read)
//        |- ares_core_top       (backend + LSU)          <- TODO(C1/C2)
//        |- tb_mem_beat_if      (128-bit D bus -> perip_read/write)
//        |- tb_mmio_if          (MMIO channel  -> perip_read/write)
//        '- observation hooks   (retire_event_enqueue / ebreak / ...)
//
// C0 status: the frontend stub, both bus adapters and the DPI observation
// declarations are in place and elaborate together; the backend/LSU instance
// and the observation wiring land in C3.  Until then iq_accept_count is tied
// to 0 and the bus adapters are idle, so running this top is expected to run
// out of cycles - that is the placeholder, not a failure of the shell.
//
// Harness contract (sim/csrc/main.cpp): top level ports are exactly
// clock/reset, and the DPI calls below are the ones sim/csrc provides.
//
// FREE items: FREE-10 (verification environment structure).
//=============================================================================
module tb_ares_core (
    input clock,
    input reset
);
    import ares_pkg::*;

    wire clk = clock;
    wire rst = reset;

    // C0 shell: the stub instruction outputs and the bus slave responses have
    // no consumer until ares_core_top is instantiated in C3.  The waiver keeps
    // the shell lint-clean without silencing real warnings later.
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off UNDRIVEN */

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Observation hooks (backend.md section 16.1 / plan section 5.18).  They
    // are only called once ares_core_top exists; the declarations are kept
    // here so the DPI surface stays in one place.
    //-------------------------------------------------------------------------
    import "DPI-C" function void retire_event_enqueue(input int valid,
                                                       input int pc,
                                                       input int pc_next,
                                                       input int rd_wen,
                                                       input int rd_addr,
                                                       input int rd_data,
                                                       input int environment);
    import "DPI-C" function void ebreak();
    import "DPI-C" function void interrupt_redirect(input int target);
`endif

    //-------------------------------------------------------------------------
    // Frontend stub (F0).  The real frontend replaces this instance in C5.
    //-------------------------------------------------------------------------
    logic [1:0]            iq_valid;
    iq_entry_t             iq_inst [2];
    logic [1:0]            iq_accept_count;
    logic                  backend_redirect_valid;
    logic [31:0]           backend_redirect_pc;
    fe_redirect_kind_t     backend_redirect_kind;
    logic [GHR_WIDTH-1:0]  backend_redirect_ghr_before;
    logic                  backend_redirect_actual_taken;
    logic [1:0]            bpu_update_credit;
    logic [1:0]            bpu_update_valid;
    bpu_update_t           bpu_update [2];

    fe_stub u_fe_stub (
        .clk                          (clk),
        .rst                          (rst),
        .iq_valid                     (iq_valid),
        .iq_inst                      (iq_inst),
        .iq_accept_count              (iq_accept_count),
        .backend_redirect_valid       (backend_redirect_valid),
        .backend_redirect_pc          (backend_redirect_pc),
        .backend_redirect_kind        (backend_redirect_kind),
        .backend_redirect_ghr_before  (backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit            (bpu_update_credit),
        .bpu_update_valid             (bpu_update_valid),
        .bpu_update                    (bpu_update)
    );

    // TODO(C3): replace the tie-offs with ares_core_top (backend + LSU).
    assign iq_accept_count               = 2'd0;
    assign backend_redirect_valid        = 1'b0;
    assign backend_redirect_pc           = RESET_PC;
    assign backend_redirect_kind         = REDIRECT_ARCH;
    assign backend_redirect_ghr_before   = '0;
    assign backend_redirect_actual_taken = 1'b0;
    assign bpu_update_valid              = 2'd0;
    assign bpu_update[0]                 = '0;
    assign bpu_update[1]                 = '0;

    //-------------------------------------------------------------------------
    // Data-side models: 128-bit beat bus and MMIO bridge.  The master side is
    // tied off until the LSU exists (C2/C3).
    //-------------------------------------------------------------------------
    logic         mem_rd_valid, mem_wr_valid;
    logic         mem_rd_ready, mem_wr_ready, mem_rsp_valid, mem_rsp_ready;
    logic [31:0]  mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0]  mem_wr_be;

    assign mem_rd_valid = 1'b0;
    assign mem_wr_valid = 1'b0;
    assign mem_rsp_ready= 1'b1;
    assign mem_rd_addr  = 32'd0;
    assign mem_wr_addr  = 32'd0;
    assign mem_wr_data  = 128'd0;
    assign mem_wr_be    = 16'd0;

    tb_mem_beat_if #(.MEM_LATENCY(1), .STALL_PERIOD(0)) u_mem_beat_if (
        .clk          (clk),
        .rst          (rst),
        .mem_rd_valid (mem_rd_valid),
        .mem_rd_ready (mem_rd_ready),
        .mem_rd_addr  (mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_data (mem_rsp_data),
        .mem_wr_valid (mem_wr_valid),
        .mem_wr_ready (mem_wr_ready),
        .mem_wr_addr  (mem_wr_addr),
        .mem_wr_data  (mem_wr_data),
        .mem_wr_be    (mem_wr_be)
    );

    logic        mmio_req_valid, mmio_write;
    logic        mmio_req_ready, mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_addr, mmio_wdata, mmio_rdata;
    logic [3:0]  mmio_wstrb;

    assign mmio_req_valid = 1'b0;
    assign mmio_write     = 1'b0;
    assign mmio_rsp_ready = 1'b1;
    assign mmio_addr      = 32'd0;
    assign mmio_wdata     = 32'd0;
    assign mmio_wstrb     = 4'd0;

    tb_mmio_if u_mmio_if (
        .clk           (clk),
        .rst           (rst),
        .mmio_req_valid(mmio_req_valid),
        .mmio_req_ready(mmio_req_ready),
        .mmio_write    (mmio_write),
        .mmio_addr     (mmio_addr),
        .mmio_wdata    (mmio_wdata),
        .mmio_wstrb    (mmio_wstrb),
        .mmio_rsp_valid(mmio_rsp_valid),
        .mmio_rsp_ready(mmio_rsp_ready),
        .mmio_rdata    (mmio_rdata)
    );
    /* verilator lint_on UNDRIVEN */
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
