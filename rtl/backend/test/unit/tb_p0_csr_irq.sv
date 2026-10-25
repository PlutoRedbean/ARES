//=============================================================================
// ARES - P0 integration unit test: per-hart CSR interrupts and trap priority
//-----------------------------------------------------------------------------
// DUTs: csr_file (HART_ID = 1) + be_trap_ctrl.
//
// Checks the P0 contract added on top of the original single-hart timer path:
//   * mhartid is parameterised (HART_ID=1 here, 0 in the existing benches)
//   * mie.MSIE/MTIE/MEIE and mip.MSIP/MTIP/MEIP are independent, read-only
//     source bits for mip and writable enables for mie
//   * interrupt priority is MEI > MSI > MTI and mcause is 0x8000_000B /
//     0x8000_0003 / 0x8000_0007 respectively
//   * the Drain-to-Boundary accepts only with ciq_empty && lsu_mmio_order_idle
//   * a disappearing source cancels the drain without taking a trap
//
// FREE items: FREE-10 (verification environment).
//=============================================================================
`timescale 1ns/1ps
module tb_p0_csr_irq;
    import ares_pkg::*;

    localparam logic [11:0] CSR_MSTATUS = 12'h300;
    localparam logic [11:0] CSR_MIE     = 12'h304;
    localparam logic [11:0] CSR_MEPC    = 12'h341;
    localparam logic [11:0] CSR_MCAUSE  = 12'h342;
    localparam logic [11:0] CSR_MIP     = 12'h344;
    localparam logic [11:0] CSR_MHARTID = 12'hF14;

    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic check(input logic cond, input string name);
        begin
            checks++;
            if (!cond) begin
                errors++;
                $display("FAIL: %s", name);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // CSR file
    //-------------------------------------------------------------------------
    logic        timer_irq, software_irq, external_irq;
    logic [11:0] csr_raddr;
    logic [31:0] csr_rdata;
    logic        csr_raddr_ok;
    logic        csr_we;
    logic [11:0] csr_waddr;
    logic [31:0] csr_wdata;
    logic        mstatus_mie;
    logic        mie_msie, mie_mtie, mie_meie;
    logic        mip_msip, mip_mtip, mip_meip;
    logic [31:0] mtvec, mepc;
    logic        trap_we, mret_we;
    logic [31:0] trap_mepc, trap_mcause;

    csr_file #(
        .RESET_MTVEC(32'h8000_0100),
        .HART_ID(32'd1)
    ) dut_csr (
        .clk         (clk),
        .rst         (rst),
        .timer_irq   (timer_irq),
        .software_irq(software_irq),
        .external_irq(external_irq),
        .raddr       (csr_raddr),
        .rdata       (csr_rdata),
        .raddr_ok    (csr_raddr_ok),
        .we          (csr_we),
        .waddr       (csr_waddr),
        .wdata       (csr_wdata),
        .trap_we     (trap_we),
        .trap_mepc   (trap_mepc),
        .trap_mcause (trap_mcause),
        .mret_we     (mret_we),
        .mstatus_mie (mstatus_mie),
        .mie_msie    (mie_msie),
        .mie_mtie    (mie_mtie),
        .mie_meie    (mie_meie),
        .mip_msip    (mip_msip),
        .mip_mtip    (mip_mtip),
        .mip_meip    (mip_meip),
        .mtvec       (mtvec),
        .mepc        (mepc)
    );

    //-------------------------------------------------------------------------
    // Trap controller
    //-------------------------------------------------------------------------
    logic        head_is_ecall, head_is_mret;
    logic [31:0] head_pc;
    tag_t        commit_ptr;
    logic [1:0]  commit_fire;
    logic [31:0] commit_pc_next [2];
    logic        lsu_mmio_order_idle, ciq_empty;

    /* verilator lint_off UNUSEDSIGNAL */  // observation-only trap outputs
    logic        ecall_valid, mret_valid, irq_valid, irq_accept_evt;
    logic [31:0] ecall_pc, mret_pc, irq_pc;
    logic        full_flush_valid, full_flush_keep_head;
    tag_t        full_flush_ptr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        irq_drain;
    logic [31:0] arch_next_pc;

    be_trap_ctrl dut_trap (
        .clk                  (clk),
        .rst                  (rst),
        .head_is_ecall        (head_is_ecall),
        .head_pc              (head_pc),
        .commit_ptr           (commit_ptr),
        .commit_fire          (commit_fire),
        .head_is_mret         (head_is_mret),
        .commit_pc_next       (commit_pc_next),
        .mstatus_mie          (mstatus_mie),
        .mie_msie             (mie_msie),
        .mie_mtie             (mie_mtie),
        .mie_meie             (mie_meie),
        .mip_msip             (mip_msip),
        .mip_mtip             (mip_mtip),
        .mip_meip             (mip_meip),
        .mtvec                (mtvec),
        .mepc                 (mepc),
        .lsu_mmio_order_idle  (lsu_mmio_order_idle),
        .ciq_empty            (ciq_empty),
        .ecall_valid          (ecall_valid),
        .ecall_pc             (ecall_pc),
        .mret_valid           (mret_valid),
        .mret_pc              (mret_pc),
        .irq_valid            (irq_valid),
        .irq_pc               (irq_pc),
        .irq_accept_evt       (irq_accept_evt),
        .full_flush_valid     (full_flush_valid),
        .full_flush_keep_head (full_flush_keep_head),
        .full_flush_ptr       (full_flush_ptr),
        .trap_we              (trap_we),
        .trap_mepc            (trap_mepc),
        .trap_mcause          (trap_mcause),
        .mret_we              (mret_we),
        .irq_drain            (irq_drain),
        .architectural_next_pc(arch_next_pc)
    );

    // The trap controller's trap_we/mepc/mcause drive the CSR file directly,
    // exactly like ares_core_top; the CSR MIE/mie outputs feed back.
    //-------------------------------------------------------------------------
    // CSR helpers
    //-------------------------------------------------------------------------
    task automatic csr_write(input logic [11:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            csr_we    = 1'b1;
            csr_waddr = addr;
            csr_wdata = data;
            @(posedge clk);
            #1;
            csr_we    = 1'b0;
            csr_waddr = 12'h0;
            csr_wdata = 32'h0;
        end
    endtask

    task automatic csr_read(input logic [11:0] addr, output logic [31:0] data,
                            output logic ok);
        begin
            @(negedge clk);
            csr_raddr = addr;
            #1;
            data = csr_rdata;
            ok   = csr_raddr_ok;
        end
    endtask

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic clear_all_irq;
        begin
            timer_irq    = 1'b0;
            software_irq = 1'b0;
            external_irq = 1'b0;
        end
    endtask

    task automatic setup_irq(input logic msie, input logic mtie, input logic meie,
                             input logic msip, input logic mtip, input logic meip);
        begin
            clear_all_irq();
            software_irq = msip;
            timer_irq    = mtip;
            external_irq = meip;
            csr_write(CSR_MIE, {20'h0, meie, 3'h0, mtie, 3'h0, msie, 3'h0});
            csr_write(CSR_MSTATUS, 32'h0000_0008);  // MIE=1
            @(negedge clk);
        end
    endtask

    logic [31:0] rd;
    logic        ok;
    logic [31:0] cause;

    //-------------------------------------------------------------------------
    // Main sequence
    //-------------------------------------------------------------------------
    initial begin
        // Idle stimulus
        timer_irq = 1'b0;
        software_irq = 1'b0;
        external_irq = 1'b0;
        csr_raddr = 12'h0;
        csr_we = 1'b0;
        csr_waddr = 12'h0;
        csr_wdata = 32'h0;
        head_is_ecall = 1'b0;
        head_is_mret = 1'b0;
        head_pc = 32'h0;
        commit_ptr = '0;
        commit_fire = 2'b00;
        commit_pc_next[0] = 32'h0;
        commit_pc_next[1] = 32'h0;
        lsu_mmio_order_idle = 1'b1;
        ciq_empty = 1'b1;

        repeat (3) tick();
        rst = 1'b0;
        repeat (2) tick();

        // mhartid is parameterised
        csr_read(CSR_MHARTID, rd, ok);
        check(ok && (rd == 32'h0000_0001), "mhartid reads HART_ID=1");

        // reset values
        csr_read(CSR_MIE, rd, ok);
        check(ok && (rd == 32'h0), "reset mie = 0");
        csr_read(CSR_MIP, rd, ok);
        check(ok && (rd == 32'h0), "reset mip = 0");
        check(!mstatus_mie, "reset mstatus.MIE = 0");

        // MIE=0 suppresses the drain
        setup_irq(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0);
        csr_write(CSR_MSTATUS, 32'h0);
        tick();
        check(!irq_drain, "MIE=0 suppresses IRQ drain");
        check(!irq_accept_evt, "MIE=0 does not accept");

        // MTI
        setup_irq(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0);
        tick();
        check(irq_drain, "MTI enters drain");
        check(irq_accept_evt, "MTI accepted with empty CIQ and idle LSU");
        check(trap_mcause == 32'(EXC_MACHINE_TIMER), "MTI cause = 0x80000007");
        check(irq_pc == mtvec, "MTI redirect PC = mtvec");
        tick();
        check(!mstatus_mie, "trap clears mstatus.MIE");
        csr_read(CSR_MCAUSE, cause, ok);
        check(ok && (cause == 32'(EXC_MACHINE_TIMER)), "MTI writes mcause");
        csr_read(CSR_MEPC, rd, ok);
        check(ok && (rd == arch_next_pc), "MTI writes mepc = architectural next PC");

        // MSI
        setup_irq(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
        tick();
        check(irq_accept_evt, "MSI accepted");
        check(trap_mcause == 32'(EXC_MACHINE_SOFT), "MSI cause = 0x80000003");
        tick();
        csr_read(CSR_MCAUSE, cause, ok);
        check(ok && (cause == 32'(EXC_MACHINE_SOFT)), "MSI writes mcause");

        // MEI
        setup_irq(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1);
        tick();
        check(irq_accept_evt, "MEI accepted");
        check(trap_mcause == 32'(EXC_MACHINE_EXT), "MEI cause = 0x8000000B");
        tick();
        csr_read(CSR_MCAUSE, cause, ok);
        check(ok && (cause == 32'(EXC_MACHINE_EXT)), "MEI writes mcause");

        // Priority MEI > MSI > MTI while blocked by ciq_empty
        setup_irq(1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
        ciq_empty = 1'b0;
        tick();
        check(irq_drain, "all sources enter drain");
        check(!irq_accept_evt, "non-empty CIQ blocks acceptance");
        ciq_empty = 1'b1;
        #1;
        check(irq_accept_evt, "CIQ empty releases acceptance");
        check(trap_mcause == 32'(EXC_MACHINE_EXT), "priority: MEI wins");
        external_irq = 1'b0;
        #1;
        check(trap_mcause == 32'(EXC_MACHINE_SOFT), "priority: MSI next");
        software_irq = 1'b0;
        #1;
        check(trap_mcause == 32'(EXC_MACHINE_TIMER), "priority: MTI last");

        // LSU not idle blocks acceptance; deasserting the last source cancels
        lsu_mmio_order_idle = 1'b0;
        timer_irq = 1'b0;
        #1;
        check(irq_valid && !irq_accept_evt, "source loss cancels without accepting");
        check(irq_pc == arch_next_pc, "cancel redirects to architectural next PC");
        tick();
        check(!irq_drain, "drain leaves after cancel");
        lsu_mmio_order_idle = 1'b1;

        // mip source bits are read-only and independent of the enables
        clear_all_irq();
        software_irq = 1'b1;
        timer_irq = 1'b1;
        external_irq = 1'b1;
        #1;
        check(mip_msip && mip_mtip && mip_meip, "mip source bits follow inputs");
        csr_write(CSR_MIP, 32'hFFFF_FFFF);
        csr_read(CSR_MIP, rd, ok);
        check(ok && (rd == 32'h0000_0888), "mip writes ignored, all source bits readable");
        clear_all_irq();
        #1;
        check(!mip_msip && !mip_mtip && !mip_meip, "mip source bits clear with inputs");

        // mie mask bits
        csr_write(CSR_MIE, 32'hFFFF_FFFF);
        csr_read(CSR_MIE, rd, ok);
        check(ok && (rd == 32'h0000_0888), "mie masks to MSIE/MTIE/MEIE");
        check(mie_msie && mie_mtie && mie_meie, "mie output bits set");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - P0 per-hart CSR interrupts + MEI>MSI>MTI priority, mcause values, drain/cancel gating, mhartid=1, mie/mip masks", checks);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    // Timeout guard
    initial begin
        #100000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
