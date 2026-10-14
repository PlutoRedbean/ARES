//=============================================================================
// ARES core verification - top level test bench (C3)
//-----------------------------------------------------------------------------
// The C3 integration bench described in docs/core_verification_flow.md
// section 2:
//
//      tb_ares_core
//        |- fe_stub.sv          (contract-compliant fetch, DPI irom_read)
//        |- ares_core_top       (Backend + LSU)
//        |- tb_mem_beat_if      (128-bit D bus -> perip_read/write)
//        |- tb_mmio_if          (MMIO channel  -> perip_read/write)
//        '- observation hooks   (retire_event_enqueue / ebreak / ...)
//
// The frontend is the contract-compliant stub (F0); C5 replaces this instance
// with the real rtl/frontend/frontend.sv and keeps everything else unchanged.
// ISA acceptance (tests/cpu-tests, 35 self-checking images) runs on this top:
//
//   make run PROGRAM=tests/cpu-tests/build/add-riscv32-ares.bin
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
    import fe_pkg::*;

    wire clk = clock;
    wire rst = reset;

    // SPEC-M8: the trap vector base is owned by the top level.  The ISA
    // regression images are linked for the reset PC, so the C3 bench uses the
    // same address (a future SoC top overrides this parameter).
    localparam logic [31:0] RESET_MTVEC = RESET_PC;

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Observation hooks (backend.md section 16.1 / plan section 5.18).
    //-------------------------------------------------------------------------
    import "DPI-C" function void retire_event_enqueue(
        input int valid,
        input int pc,
        input int pc_next,
        input int rd_wen,
        input int rd_addr,
        input int rd_data,
        input int environment
    );
    import "DPI-C" function void ebreak();
    import "DPI-C" function void interrupt_redirect(input int target);
`endif

    //-------------------------------------------------------------------------
    // Frontend stub (F0) <-> core
    //-------------------------------------------------------------------------
    logic              [          1:0] iq_valid;
    iq_entry_t                         iq_inst                       [2];
    logic              [          1:0] iq_accept_count;
    logic                              backend_redirect_valid;
    logic              [         31:0] backend_redirect_pc;
    fe_redirect_kind_t                 backend_redirect_kind;
    logic              [GHR_WIDTH-1:0] backend_redirect_ghr_before;
    logic                              backend_redirect_actual_taken;
    logic              [          1:0] bpu_update_credit;
    logic              [          1:0] bpu_update_valid;
    bpu_update_t                       bpu_update                    [2];

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
        .bpu_update                   (bpu_update)
    );

    //-------------------------------------------------------------------------
    // Data-side models: 128-bit beat bus and MMIO bridge
    //-------------------------------------------------------------------------
    logic mem_rd_valid, mem_wr_valid;
    logic mem_rd_ready, mem_wr_ready, mem_rsp_valid, mem_rsp_ready;
    logic [31:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [15:0] mem_wr_be;

    logic mmio_req_valid, mmio_write;
    logic mmio_req_ready, mmio_rsp_valid, mmio_rsp_ready;
    logic [31:0] mmio_addr, mmio_wdata, mmio_rdata;
    logic [ 3:0] mmio_wstrb;

    //-------------------------------------------------------------------------
    // Observation ports of the core
    //-------------------------------------------------------------------------
    logic [ 1:0] retire_valid;
    logic [31:0] retire_pc          [2];
    logic [31:0] retire_pc_next     [2];
    logic [ 1:0] retire_rd_wen;
    logic [ 4:0] retire_rd          [2];
    logic [31:0] retire_wdata       [2];
    logic [ 1:0] retire_is_ebreak;
    logic        irq_redirect_valid;
    logic [31:0] irq_redirect_pc;
    logic [ 1:0] decode_err;
    logic [31:0] decode_err_pc      [2];
    logic [31:0] decode_err_inst    [2];
    logic        dep_error;
    logic [ 4:0] dbg_occupancy;
    logic [31:0] dbg_arch_next_pc;
    logic [ 2:0] dbg_lq_used;
    logic [ 3:0] dbg_sq_used;

    ares_core_top #(
        .RESET_MTVEC(RESET_MTVEC)
    ) u_core (
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
        .bpu_update                   (bpu_update),
        .timer_irq                    (1'b0),                           // SoC timer lands in C6
        .mem_rd_valid                 (mem_rd_valid),
        .mem_rd_ready                 (mem_rd_ready),
        .mem_rd_addr                  (mem_rd_addr),
        .mem_rsp_valid                (mem_rsp_valid),
        .mem_rsp_ready                (mem_rsp_ready),
        .mem_rsp_data                 (mem_rsp_data),
        .mem_wr_valid                 (mem_wr_valid),
        .mem_wr_ready                 (mem_wr_ready),
        .mem_wr_addr                  (mem_wr_addr),
        .mem_wr_data                  (mem_wr_data),
        .mem_wr_be                    (mem_wr_be),
        .mmio_req_valid               (mmio_req_valid),
        .mmio_req_ready               (mmio_req_ready),
        .mmio_write                   (mmio_write),
        .mmio_addr                    (mmio_addr),
        .mmio_wdata                   (mmio_wdata),
        .mmio_wstrb                   (mmio_wstrb),
        .mmio_rsp_valid               (mmio_rsp_valid),
        .mmio_rsp_ready               (mmio_rsp_ready),
        .mmio_rsp_data                (mmio_rdata),
        .retire_valid                 (retire_valid),
        .retire_pc                    (retire_pc),
        .retire_pc_next               (retire_pc_next),
        .retire_rd_wen                (retire_rd_wen),
        .retire_rd                    (retire_rd),
        .retire_wdata                 (retire_wdata),
        .retire_is_ebreak             (retire_is_ebreak),
        .irq_redirect_valid           (irq_redirect_valid),
        .irq_redirect_pc              (irq_redirect_pc),
        .decode_err                   (decode_err),
        .decode_err_pc                (decode_err_pc),
        .decode_err_inst              (decode_err_inst),
        .dep_error                    (dep_error),
        .dbg_occupancy                (dbg_occupancy),
        .dbg_arch_next_pc             (dbg_arch_next_pc),
        .dbg_lq_used                  (dbg_lq_used),
        .dbg_sq_used                  (dbg_sq_used)
    );

    tb_mem_beat_if #(
        .MEM_LATENCY (1),
        .STALL_PERIOD(0)
    ) u_mem_beat_if (
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

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Retire stream / EBREAK / interrupt observation (plan 5.18).
    // The core exports plain ports; the DPI calls live here so they can never
    // enter the synthesizable path.
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            for (int unsigned lane = 0; lane < 2; lane++) begin
                if (retire_valid[lane]) begin
                    retire_event_enqueue(1, int'(retire_pc[lane]), int'(retire_pc_next[lane]),
                                         int'(retire_rd_wen[lane]), int'({27'd0, retire_rd[lane]}),
                                         int'(retire_wdata[lane]), 0);
                    if (retire_is_ebreak[lane]) ebreak();
                end
            end
            if (irq_redirect_valid) interrupt_redirect(int'(irq_redirect_pc));
        end
    end

    // Structural sanity of the exported debug/observation ports.
    always @(posedge clk) begin
        if (!rst) begin
            if (dbg_lq_used > 3'd4) $fatal(1, "tb_ares_core: LQ occupancy overflow");
            if (dbg_sq_used > 4'd8) $fatal(1, "tb_ares_core: SQ occupancy overflow");
            if (dbg_occupancy > 5'd16) $fatal(1, "tb_ares_core: CIQ occupancy overflow");
            if (dbg_arch_next_pc[1:0] != 2'b00)
                $fatal(1, "tb_ares_core: unaligned architectural next PC");
            if ((^dbg_arch_next_pc) === 1'bx)
                $fatal(1, "tb_ares_core: unknown bits on the architectural next PC");
        end
    end

    // A decode error is a simulation failure (SPEC-A1 / D-C0-01: no illegal
    // instruction trap in v1, the violation has to be reported) - but ONLY for
    // an instruction that actually retires.  The frontend stub is
    // always-not-taken, so the instruction behind an un-predicted jump is
    // fetched and decoded speculatively and then squashed by the recovery
    // redirect; reporting that would flag the predictor, not the ISA.
    //
    // Decode-error PCs are recorded on a tiny CAM and checked when an
    // instruction commits (dispatch -> commit is always at least a few cycles,
    // so the entry is recorded before the retire check can see it).
    localparam int DE_LOG = 8;
    logic [31:0] de_pc  [0:DE_LOG-1];
    logic [31:0] de_inst[0:DE_LOG-1];
    logic        de_v   [0:DE_LOG-1];
    logic [ 2:0] de_wr;

    always @(posedge clk) begin
        if (rst) begin
            de_wr <= 3'd0;
            for (int unsigned i = 0; i < DE_LOG; i++) begin
                de_pc[i]   <= 32'd0;
                de_inst[i] <= 32'd0;
                de_v[i]    <= 1'b0;
            end
        end else begin
            if (decode_err[0]) begin
                de_pc[de_wr]   <= decode_err_pc[0];
                de_inst[de_wr] <= decode_err_inst[0];
                de_v[de_wr]    <= 1'b1;
            end
            if (decode_err[1]) begin
                de_pc[de_wr + 3'd1]   <= decode_err_pc[1];
                de_inst[de_wr + 3'd1] <= decode_err_inst[1];
                de_v[de_wr + 3'd1]    <= 1'b1;
            end
            if (decode_err != 2'b00)
                de_wr <= de_wr + 3'({1'b0, decode_err[0]} + {1'b0, decode_err[1]});

            // The check sees the pre-edge CAM contents: a dispatched
            // instruction retires several cycles later.
            for (int unsigned lane = 0; lane < 2; lane++)
            if (retire_valid[lane])
                for (int unsigned i = 0; i < DE_LOG; i++)
                if (de_v[i] && (de_pc[i] == retire_pc[lane]))
                    $fatal(
                        1,
                        "tb_ares_core: retired decode error at pc=0x%08x inst=0x%08x",
                        retire_pc[lane],
                        de_inst[i]
                    );
        end
    end

    always @(posedge clk) begin
        if (!rst && dep_error) $fatal(1, "tb_ares_core: dependency tracking error");
    end
`endif

endmodule
