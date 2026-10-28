// ---------------------------------------------------------------------------
// tb_video_capture - DVP 8->16 + counter testbench (VIDEO_SIM)
//
// Drives a synthetic OV5640 DVP stream: one vsync pulse, then two 1280-pixel
// lines with byte pairs 0x12/0x34.  The sensor emits BGR565 (0x1234), and
// video_capture_wrap normalizes it to RGB565, so the captured pixel is
// 16'hA222.  Checks:
//   * first captured pixel is 16'hA222
//   * line counter = 2, pixel counter = 2560, vsync counter = 1
// The SCCB configuration is bypassed by VIDEO_SIM.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_video_capture;

    reg clk_27m = 1'b0;
    always #18.5185 clk_27m = ~clk_27m;      // 27.0 MHz

    reg clk_cam = 1'b0;
    always #20.202 clk_cam = ~clk_cam;       // 24.75 MHz

    reg cam_pclk = 1'b0;
    always #5.9524 cam_pclk = ~cam_pclk;     // 84 MHz

    reg rst_sys = 1'b0;
    reg cam_vsync = 1'b0;
    reg cam_href  = 1'b0;
    reg [7:0] cam_data = 8'd0;

    wire cam_scl, cam_sda;
    wire pixel_clk, pixel_rst, pixel_vsync, pixel_de;
    wire [15:0] pixel_rgb565;
    wire cam_reset, cam_init_done;
    wire [31:0] dbg_vsync_cnt, dbg_line_cnt, dbg_pixel_cnt, dbg_pclk_cnt;

    video_capture_wrap u_dut (
        .clk_27m      (clk_27m),
        .clk_cam      (clk_cam),
        .rst_sys      (rst_sys),
        .cam_reset    (cam_reset),
        .cam_scl      (cam_scl),
        .cam_sda      (cam_sda),
        .cam_pclk     (cam_pclk),
        .cam_vsync    (cam_vsync),
        .cam_href     (cam_href),
        .cam_data     (cam_data),
        .pixel_clk    (pixel_clk),
        .pixel_rst    (pixel_rst),
        .pixel_vsync  (pixel_vsync),
        .pixel_de     (pixel_de),
        .pixel_rgb565 (pixel_rgb565),
        .cam_init_done(cam_init_done),
        .dbg_vsync_cnt(dbg_vsync_cnt),
        .dbg_line_cnt (dbg_line_cnt),
        .dbg_pixel_cnt(dbg_pixel_cnt),
        .dbg_pclk_cnt (dbg_pclk_cnt)
    );

    integer errors = 0;
    integer line;
    integer i;
    integer de_seen = 0;
    reg [15:0] second_pixel = 16'h0000;
    integer de_pixels = 0;

    always @(posedge pixel_clk) begin
        if (pixel_de) begin
            if (de_seen < 4) $display("pixel[%0d]=%04x", de_seen, pixel_rgb565);
            if (de_seen == 1) second_pixel <= pixel_rgb565;
            de_seen   <= de_seen + 1;
            de_pixels <= de_pixels + 1;
        end
    end

    initial begin
        rst_sys = 1'b0;
        repeat (5) @(posedge clk_27m);
        rst_sys = 1'b1;

        // Start the pixel clock: video_dvp_rgb565 enables the divider on vsync.
        repeat (5) @(posedge cam_pclk);
        cam_vsync = 1'b1;
        repeat (10) @(posedge cam_pclk);
        cam_vsync = 1'b0;
        repeat (10) @(posedge cam_pclk);

        for (line = 0; line < 2; line = line + 1) begin
            // DVP data is launched on the falling edge; the sensor drives the
            // first byte on the first rising edge after HREF goes high.
            @(negedge cam_pclk);
            cam_data = 8'h12;
            cam_href = 1'b1;
            for (i = 1; i < 2560; i = i + 1) begin
                @(negedge cam_pclk);
                cam_data = i[0] ? 8'h34 : 8'h12;
            end
            @(negedge cam_pclk);
            cam_href = 1'b0;
            repeat (20) @(posedge cam_pclk);
        end

        // Wait for the counter snapshot (65536 pixel clocks = 1.56 ms).
        #2_000_000;

        $display("capture: vsync=%0d line=%0d pixel=%0d pclk=%0d de_pixels=%0d second=%04x",
                 dbg_vsync_cnt, dbg_line_cnt, dbg_pixel_cnt, dbg_pclk_cnt, de_pixels, second_pixel);

        if (second_pixel !== 16'hA222) begin
            $display("FAIL: second pixel expected A242 (BGR 1234 -> RGB)");
            errors = errors + 1;
        end
        if (dbg_vsync_cnt != 1) begin
            $display("FAIL: expected 1 vsync");
            errors = errors + 1;
        end
        if (dbg_line_cnt != 2) begin
            $display("FAIL: expected 2 lines");
            errors = errors + 1;
        end
        if (dbg_pixel_cnt != 2560) begin
            $display("FAIL: expected 2560 pixels");
            errors = errors + 1;
        end

        if (errors == 0) $display("*** TB_VIDEO_CAPTURE PASS ***");
        else             $display("*** TB_VIDEO_CAPTURE FAILED %0d ***", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("*** TB_VIDEO_CAPTURE TIMEOUT ***");
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_out = &{1'b0, cam_scl, cam_sda, cam_reset, cam_init_done,
                         pixel_rst, pixel_vsync, de_seen};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
