// ---------------------------------------------------------------------------
// tb_video_top - S0 bring-up testbench
//
// Drives the board clock/reset, lets the behavioral PLL run, and checks:
//   * pll_lock reaches the LED
//   * a 720p30 frame has exactly 1280*720 DE pixels
//   * MS7210 init completes (I2C runs against an undriven SDA, so ACK is
//     ignored; the vendor FSM only waits for byte_over)
//
// Run:
//   $ verilator --binary --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//       -Wno-BLKSEQ -Wno-SIDEEFFECT -Irtl/video --top-module tb_video_top \
//       -o tb_video_top \
//       rtl/video/video_top.v rtl/video/video_clk_reset.v \
//       rtl/video/video_hdmi_wrap.v rtl/video/video_pattern_gen.v \
//       rtl/video/video_status.v rtl/video/sim/video_ip_pll_sim.v \
//       rtl/video/legacy/sync_vg.v rtl/video/legacy/ms7210_ctl.v \
//       rtl/video/legacy/iic_dri.v rtl/video/test/tb_video_top.v
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_video_top;

    reg clk_27m = 1'b0;
    always #18.5185 clk_27m = ~clk_27m;          // 27.0 MHz

    reg ref_clk_p = 1'b0;
    always #4.0 ref_clk_p = ~ref_clk_p;          // 125 MHz
    wire ref_clk_n = ~ref_clk_p;

    reg rst_n = 1'b0;

    // Camera / DDR3 are idle in S0.
    reg cmos1_pclk = 1'b0, cmos2_pclk = 1'b0;
    reg cmos1_vsync = 1'b0, cmos2_vsync = 1'b0;
    reg cmos1_href = 1'b0, cmos2_href = 1'b0;
    reg [7:0] cmos1_data = 8'd0, cmos2_data = 8'd0;

    wire cmos1_reset, cmos2_reset;
    wire cmos1_scl, cmos1_sda, cmos2_scl, cmos2_sda;
    wire iic_tx_sda;
    wire [3:0] mem_dqs, mem_dqs_n;
    wire [31:0] mem_dq;

    wire mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_cs_n;
    wire mem_ras_n, mem_cas_n, mem_we_n, mem_odt;
    wire [14:0] mem_a;
    wire [2:0] mem_ba;
    wire [3:0] mem_dm;

    wire pix_clk, de_out, hs_out, vs_out;
    wire [7:0] r_out, g_out, b_out;
    wire rstn_out, iic_tx_scl;
    wire [7:0] led;
    wire uart_tx;

    video_top #(
        .CAM_SEL       (0),
        .FB_BASE0_BYTE (28'h0100_0000),
        .FB_BASE1_BYTE (28'h0110_0000),
        .FB_ADDR_SHIFT (2),
        .BIST_BYTES    (32'h0040_0000),
        .PATTERN_MODE  (2'd1)
    ) dut (
        .clk_27m       (clk_27m),
        .rst_n         (rst_n),

        .cmos1_reset   (cmos1_reset),
        .cmos1_scl     (cmos1_scl),
        .cmos1_sda     (cmos1_sda),
        .cmos1_pclk    (cmos1_pclk),
        .cmos1_vsync   (cmos1_vsync),
        .cmos1_href    (cmos1_href),
        .cmos1_data    (cmos1_data),

        .cmos2_reset   (cmos2_reset),
        .cmos2_scl     (cmos2_scl),
        .cmos2_sda     (cmos2_sda),
        .cmos2_pclk    (cmos2_pclk),
        .cmos2_vsync   (cmos2_vsync),
        .cmos2_href    (cmos2_href),
        .cmos2_data    (cmos2_data),

        .ref_clk_p     (ref_clk_p),
        .ref_clk_n     (ref_clk_n),
        .mem_rst_n     (mem_rst_n),
        .mem_ck        (mem_ck),
        .mem_ck_n      (mem_ck_n),
        .mem_cke       (mem_cke),
        .mem_cs_n      (mem_cs_n),
        .mem_ras_n     (mem_ras_n),
        .mem_cas_n     (mem_cas_n),
        .mem_we_n      (mem_we_n),
        .mem_odt       (mem_odt),
        .mem_a         (mem_a),
        .mem_ba        (mem_ba),
        .mem_dqs       (mem_dqs),
        .mem_dqs_n     (mem_dqs_n),
        .mem_dq        (mem_dq),
        .mem_dm        (mem_dm),

        .pix_clk       (pix_clk),
        .de_out        (de_out),
        .hs_out        (hs_out),
        .vs_out        (vs_out),
        .r_out         (r_out),
        .g_out         (g_out),
        .b_out         (b_out),
        .rstn_out      (rstn_out),
        .iic_tx_scl    (iic_tx_scl),
        .iic_tx_sda    (iic_tx_sda),

        .led           (led),
        .uart_tx       (uart_tx)
    );

    // ---------------------------------------------------------- frame checks
    integer errors = 0;
    integer frame_pixels = 0;
    integer frames = 0;
    reg     vs_d = 1'b0;

    always @(posedge pix_clk) begin
        vs_d <= vs_out;
        if (de_out) frame_pixels <= frame_pixels + 1;

        if (vs_out && !vs_d) begin
            frames <= frames + 1;
            if ((frames == 1) || (frames == 2)) begin
                $display("frame %0d: de pixels = %0d", frames + 1, frame_pixels);
                if (frame_pixels != 1280 * 720) begin
                    $display("FAIL: expected %0d active pixels", 1280 * 720);
                    errors = errors + 1;
                end
            end
            frame_pixels <= 0;
        end
    end

    // ------------------------------------------------------------- sequence
    initial begin
        repeat (20) @(posedge clk_27m);
        rst_n = 1'b1;

        #2_000_000;                       // 2 ms: PLL + timing should be alive
        if (led[1] !== 1'b1) begin
            $display("FAIL: pll_lock LED is not set");
            errors = errors + 1;
        end

        wait (frames >= 3);
`ifdef VIDEO_SIM
        #5_000_000;                       // init is tied done in the sim wrap
`else
        #600_000_000;                     // MS7210 init + margin (real FSM)
`endif

        if (led[3] !== 1'b1) begin
            $display("FAIL: hdmi_init_done LED is not set");
            errors = errors + 1;
        end
        if (led[4] !== 1'b1) begin
            $display("FAIL: cam_init_done LED is not set (VIDEO_SIM should force it)");
            errors = errors + 1;
        end
        if (^pix_clk === 1'bx) begin
            $display("FAIL: pix_clk is X");
            errors = errors + 1;
        end

        if (errors == 0) $display("*** TB_VIDEO_TOP S1 PASS ***");
        else             $display("*** TB_VIDEO_TOP S1 FAILED %0d ***", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;                   // 2 s watchdog
        $display("*** TB_VIDEO_TOP TIMEOUT ***");
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_out = &{1'b0, cmos1_reset, cmos2_reset, cmos1_scl, cmos1_sda,
        cmos2_scl, cmos2_sda, mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_cs_n,
        mem_ras_n, mem_cas_n, mem_we_n, mem_odt, mem_a, mem_ba, mem_dm,
        hs_out, r_out, g_out, b_out, rstn_out, iic_tx_scl, uart_tx};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
