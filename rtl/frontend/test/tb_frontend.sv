// Self-checking testbench for the front-end wrapper (frontend.sv).
//
// It instantiates the whole front-end (BPU -> FTQ -> IFU -> IQ + icache) and
// attaches:
//   * a minimal AXI4-Lite read-only memory that returns a non-CFI instruction
//     (addi x0,x0,0) for every word, and
//   * a simple back-end model that drains the IQ through the `iq_*` read port.
//
// Because every fetched instruction is non-control-flow, the front-end walks
// the address space sequentially: the PCs read out of the IQ must increase by
// 4 (INST_BYTES).  The test also checks the structural invariant that the IQ
// read port is a low-contiguous prefix and that a back-end redirect flushes the
// pipeline and restarts fetch at the redirect PC.
`timescale 1ns / 1ps

`include "fe_pkg.sv"
`include "interface/axi_if.sv"
`include "bpu/gen_pc.sv"
`include "bpu/direction/bimodal.sv"
`include "bpu/direction/gshare.sv"
`include "bpu/direction/tournament.sv"
`include "bpu/direction/loop_predictor.sv"
`include "bpu/target/ubtb.sv"
`include "bpu/target/ras.sv"
`include "bpu/bpu.sv"
`include "ftq.sv"
`include "ifu/ifu.sv"
`include "ifu/icache.sv"
`include "iq.sv"
`include "frontend.sv"

module tb_frontend;
    import fe_pkg::*;

    localparam int unsigned ADDR_WIDTH = 32;
    localparam int unsigned DATA_WIDTH = 32;
    localparam logic [ADDR_WIDTH-1:0] RESET_VEC = 32'h8000_0000;
    localparam logic [ADDR_WIDTH-1:0] REDIRECT_PC = 32'h8000_1000;

    logic clk;
    logic rst;

    // IQ read port
    logic [DECODE_WIDTH-1:0] iq_rvalid;
    iq_entry_t iq_rbits[DECODE_WIDTH];
    logic iq_rready;
    logic [$clog2(DECODE_WIDTH+1)-1:0] iq_raccept_cnt;

    // back-end -> front-end
    logic backend_redirect_valid;
    logic [ADDR_WIDTH-1:0] backend_redirect_pc;
    logic bpu_update_en;
    update_meta_t bpu_update_meta;

    logic [ADDR_WIDTH-1:0] fetch_pc_out;

    axi_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) mem_bus ();

    frontend #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .RESET_VEC (RESET_VEC)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .iq_rvalid            (iq_rvalid),
        .iq_rbits             (iq_rbits),
        .iq_rready            (iq_rready),
        .iq_raccept_cnt       (iq_raccept_cnt),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc  (backend_redirect_pc),
        .bpu_update_en        (bpu_update_en),
        .bpu_update_meta      (bpu_update_meta),
        .ifu_axi_bus          (mem_bus),
        .fetch_pc_out         (fetch_pc_out)
    );

    // ------------------------------------------------------------------ clock
    always #5 clk = ~clk;

    // --------------------------------------------------- AXI4-Lite memory
    // read-only NOP memory: every word returns a non-CFI instruction
    logic [DATA_WIDTH-1:0] mem_rdata_r;
    logic                  mem_rvalid_r;
    logic                  mem_arready_r;

    assign mem_bus.arready = mem_arready_r;
    assign mem_bus.rvalid  = mem_rvalid_r;
    assign mem_bus.rdata   = mem_rdata_r;
    assign mem_bus.rresp   = 1'b0;

    // the cache never writes
    assign mem_bus.awready = 1'b0;
    assign mem_bus.wready  = 1'b0;
    assign mem_bus.bresp   = 1'b0;
    assign mem_bus.bvalid  = 1'b0;

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_arready_r <= 1'b1;
            mem_rvalid_r  <= 1'b0;
            mem_rdata_r   <= '0;
        end else begin
            mem_arready_r <= 1'b1;
            if (mem_bus.arvalid && mem_bus.arready) begin
                mem_rvalid_r <= 1'b1;
                // addi x0, x0, 0  -> 0x00000013 (not a control-flow instruction)
                mem_rdata_r  <= 32'h0000_0013;
            end else if (mem_bus.rvalid && mem_bus.rready) begin
                mem_rvalid_r <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------- back-end model
    logic auto_consume;
    logic [ADDR_WIDTH-1:0] exp_pc;
    int errors = 0;
    int consumed = 0;

    assign iq_rready      = auto_consume && iq_rvalid[0];
    assign iq_raccept_cnt = iq_rready ? 2'd1 : 2'd0;

    task automatic check(input string name, input logic cond);
        if (!cond) begin
            $display("FAIL: %s", name);
            errors++;
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            check("iq_rvalid != 2'b10", (DECODE_WIDTH != 2) || (iq_rvalid != 2'b10));
            if (iq_rvalid[0] && iq_rready) begin
                if (iq_rbits[0].pc !== exp_pc) begin
                    $display("FAIL: consumed pc=%h expected=%h", iq_rbits[0].pc, exp_pc);
                    errors++;
                end
                exp_pc   <= exp_pc + INST_BYTES;
                consumed <= consumed + 1;
            end
        end
    end

    task automatic do_redirect(input logic [ADDR_WIDTH-1:0] pc);
        auto_consume = 1'b0;
        @(posedge clk);
        backend_redirect_valid = 1'b1;
        backend_redirect_pc    = pc;
        @(posedge clk);
        backend_redirect_valid = 1'b0;
        exp_pc = pc;
        // let the flush ripple through the fetch pipeline
        repeat (4) @(posedge clk);
        auto_consume = 1'b1;
    endtask

    initial begin
        clk = 0;
        rst = 1;
        auto_consume = 0;
        backend_redirect_valid = 0;
        backend_redirect_pc = '0;
        bpu_update_en = 0;
        bpu_update_meta = '0;
        exp_pc = RESET_VEC;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        // sequential fetch: consume a good number of instructions and verify
        // every PC is the expected in-order successor
        auto_consume = 1'b1;
        begin
            int target;
            target = 64;
            while ((consumed < target) && (errors == 0) && ($time < 1_000_000)) @(posedge clk);
            check("sequential fetch reached 64 instrs", consumed >= target);
        end

        // redirect: the IQ must be flushed and fetch must restart at REDIRECT_PC
        do_redirect(REDIRECT_PC);
        begin
            int prev_consumed;
            prev_consumed = consumed;
            while ((consumed < prev_consumed + 32) && (errors == 0) && ($time < 2_000_000)) @(posedge clk);
            check("post-redirect fetch reached +32 instrs", consumed >= prev_consumed + 32);
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED (%0d instructions consumed)", consumed);
            $finish;
        end else begin
            $fatal(1, "%0d TESTS FAILED", errors);
        end
    end

    // global watchdog
    initial begin
        #5_000_000;
        $fatal(1, "TIMEOUT (consumed=%0d errors=%0d)", consumed, errors);
    end
endmodule
