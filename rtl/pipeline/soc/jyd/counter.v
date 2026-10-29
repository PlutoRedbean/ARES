`timescale 1ns / 1ps
//=============================================================================
// ARES pipeline SoC - millisecond counter (Pango-portable CDC version)
//-----------------------------------------------------------------------------
// CDC policy:
//   - cnt_enable_cpu: 1-bit level, CPU clock domain -> counter clock domain,
//     synchronized by pipeline_cdc_single.
//   - cnt_ms_bin: monotonic counter, counter clock domain -> CPU clock domain,
//     synchronized by pipeline_cdc_gray.
//   - The counter clock domain has its own synchronized reset so that reset
//     release is not asynchronous to cnt_clk on the board (100 MHz CPU /
//     50 MHz peripheral).
//
// The CoreMark timing source is the free-running cycle counter in
// perip_bridge.sv, not this millisecond counter.
//=============================================================================
`include "autoconf.vh"

module counter(
    input  wire         cpu_clk,
    input  wire         cnt_clk,
    input  wire         rst,

    input  wire         cnt_enable_cpu,
    output wire [31:0]  perip_rdata,
    output wire         timer_irq
);
    // 1 ms at the board peripheral clock (50 MHz).  The Verilator TB drives
    // cnt_clk at the core frequency, so the simulation branch uses CORE_FREQ.
`ifdef JYD_FAST_TIMER
    localparam [18:0] CNT_1MS_MAX = 19'd4_999;
`elsif __VERILATOR__
    localparam [18:0] CNT_1MS_MAX =
        19'($rtoi(`CORE_FREQ * 1000.0) - 1);
`else
    localparam [18:0] CNT_1MS_MAX = 19'd49_999;
`endif

    wire         cnt_rst;
    wire         cnt_enable_cnt;
    wire [31:0]  cnt_ms_cpu;

    reg  [18:0]  cnt_1ms;
    reg  [31:0]  cnt_ms_bin;
    reg  [31:0]  cnt_ms_cpu_seen;
    reg          timer_irq_r;

    pipeline_cdc_reset_sync u_cnt_rst (
        .clk    (cnt_clk),
        .rst_in (rst),
        .rst_out(cnt_rst)
    );

    pipeline_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (0),
        .SRC_INPUT_REG (1)
    ) u_cnt_enable_cdc (
        .src_clk  (cpu_clk),
        .src_in   (cnt_enable_cpu),
        .dest_clk (cnt_clk),
        .dest_out (cnt_enable_cnt)
    );

    always @(posedge cnt_clk) begin
        if (cnt_rst) begin
            cnt_1ms    <= 19'd0;
            cnt_ms_bin <= 32'd0;
        end else if (cnt_enable_cnt) begin
            if (cnt_1ms == CNT_1MS_MAX) begin
                cnt_1ms    <= 19'd0;
                cnt_ms_bin <= cnt_ms_bin + 32'd1;
            end else begin
                cnt_1ms <= cnt_1ms + 19'd1;
            end
        end else begin
            cnt_1ms <= 19'd0;
        end
    end

    pipeline_cdc_gray #(
        .DEST_SYNC_FF (2),
        .INIT_SYNC_FF (0),
        .REG_OUTPUT   (1),
        .WIDTH        (32)
    ) u_cnt_gray_cdc (
        .src_clk      (cnt_clk),
        .src_in_bin   (cnt_ms_bin),
        .dest_clk     (cpu_clk),
        .dest_out_bin (cnt_ms_cpu)
    );

    assign perip_rdata = cnt_ms_cpu;

    // Convert each synchronized millisecond change into one CPU-clock pulse.
    always @(posedge cpu_clk) begin
        if (rst) begin
            cnt_ms_cpu_seen <= 32'd0;
            timer_irq_r     <= 1'b0;
        end else begin
            timer_irq_r <= 1'b0;
            if (!cnt_enable_cpu) begin
                cnt_ms_cpu_seen <= cnt_ms_cpu;
            end else if (cnt_ms_cpu != cnt_ms_cpu_seen) begin
                cnt_ms_cpu_seen <= cnt_ms_cpu;
                timer_irq_r     <= 1'b1;
            end
        end
    end

    assign timer_irq = timer_irq_r;
endmodule
