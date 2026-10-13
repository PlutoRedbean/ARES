`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// counter.sv replacement.
//
// CDC policy:
//   - cnt_enable_cpu: 1-bit level, CPU clock domain -> counter clock domain,
//     synchronized by xpm_cdc_single through cdc_single_xpm.
//   - cnt_ms_bin: multi-bit monotonic counter, counter clock domain -> CPU clock
//     domain, synchronized by xpm_cdc_gray. No FIFO is used.
//
//   Add xpm_cdc_verilator_stubs.sv to the Verilator file list. Vivado still uses
//   the real XPM implementations.
//////////////////////////////////////////////////////////////////////////////////

module counter(
    input  logic         cpu_clk,
    input  logic         cnt_clk,
    input  logic         rst,

    input  logic         cnt_enable_cpu,
    output logic [31:0]  perip_rdata,
    output logic         timer_irq
);
    // Keep normal tests and FPGA time at 1 ms. Functional RTOS regressions may
    // opt into a faster logical tick; performance tests must leave it disabled.
`ifdef JYD_FAST_TIMER
    localparam logic [18:0] CNT_1MS_MAX = 19'd4_999;
`elsif __VERILATOR__
    // The untimed JYD simulation advances cnt_clk with the configured CPU
    // clock. CORE_FREQ is expressed in MHz, hence CORE_FREQ * 1000 cycles/ms.
    localparam logic [18:0] CNT_1MS_MAX =
        19'($rtoi(`CORE_FREQ * 1000.0) - 1);
`else
    localparam logic [18:0] CNT_1MS_MAX = 19'd49_999;
`endif

    logic        cnt_enable_cnt;
    logic [18:0] cnt_1ms;
    logic [31:0] cnt_ms_bin;
    logic [31:0] cnt_ms_cpu_seen;

    cdc_single_xpm #(
        .DEST_SYNC_FF (2),
        .INIT_SYNC_FF (0)
    ) u_cnt_enable_cdc (
        .src_clk  (cpu_clk),
        .src_in   (cnt_enable_cpu),
        .dest_clk (cnt_clk),
        .dest_out (cnt_enable_cnt)
    );

    always_ff @(posedge cnt_clk) begin
        if (rst) begin
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

    xpm_cdc_gray #(
        .DEST_SYNC_FF          (2),
        .INIT_SYNC_FF          (0),
        .REG_OUTPUT            (1),
        .SIM_ASSERT_CHK        (0),
        .SIM_LOSSLESS_GRAY_CHK (0),
        .WIDTH                 (32)
    ) u_cnt_gray_cdc (
        .src_clk      (cnt_clk),
        .src_in_bin   (cnt_ms_bin),
        .dest_clk     (cpu_clk),
        .dest_out_bin (perip_rdata)
    );

    /* Convert each synchronized millisecond change into one CPU-clock pulse. */
    always_ff @(posedge cpu_clk) begin
        if (rst) begin
            cnt_ms_cpu_seen <= 32'd0;
            timer_irq       <= 1'b0;
        end else begin
            timer_irq <= 1'b0;
            if (!cnt_enable_cpu) begin
                cnt_ms_cpu_seen <= perip_rdata;
            end else if (perip_rdata != cnt_ms_cpu_seen) begin
                cnt_ms_cpu_seen <= perip_rdata;
                timer_irq       <= 1'b1;
            end
        end
    end
endmodule
