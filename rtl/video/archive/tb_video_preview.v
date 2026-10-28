// ---------------------------------------------------------------------------
// tb_video_preview - camera -> 640x360 preview BRAM -> HDMI datapath (VIDEO_SIM)
//
// Sends three short camera frames.  Only the first four lines are driven, so
// the write side stores buffer rows 0 and 1 (camera rows 0 and 2).  The DVP
// bytes encode:
//   camera x -> R5 = (x/2) & 31
//   camera y -> G6 = y
//   B5 = 5
// and the sensor order is BGR565, so video_capture_wrap must swap it to
// {R,G,B}.  HDMI 720p reads 2x upscaled, i.e. output pixel (xo,yo) shows
// camera (2*(xo/2), 2*(yo/2)), which gives:
//   r = ((xo/2) & 31) << 3,  g = (yo & ~1) << 2,  b = 5 << 3
// The TB checks several pixels in the first four output lines.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_video_preview;

    reg clk_27m = 1'b0;
    always #18.5185 clk_27m = ~clk_27m;      // 27.0 MHz

    reg cam_pclk = 1'b0;
    always #5.9524 cam_pclk = ~cam_pclk;     // 84 MHz

    reg rst_n = 1'b0;

    wire        cmos1_reset, cmos1_scl, cmos1_sda;
    wire        cmos2_reset, cmos2_scl, cmos2_sda;
    wire        pix_clk, de_out, hs_out, vs_out;
    wire [7:0]  r_out, g_out, b_out;
    wire        rstn_out, iic_tx_scl, iic_tx_sda;
    wire [7:0]  led;
    wire        uart_tx;

    reg  cam_vsync = 1'b0;
    reg  cam_href  = 1'b0;
    reg  [7:0] cam_data = 8'd0;

    video_cam_preview_top u_dut (
        .clk_27m     (clk_27m),
        .rst_n       (rst_n),
        .cmos1_reset (cmos1_reset),
        .cmos1_scl   (cmos1_scl),
        .cmos1_sda   (cmos1_sda),
        .cmos1_pclk  (cam_pclk),
        .cmos1_vsync (cam_vsync),
        .cmos1_href  (cam_href),
        .cmos1_data  (cam_data),
        .cmos2_reset (cmos2_reset),
        .cmos2_scl   (cmos2_scl),
        .cmos2_sda   (cmos2_sda),
        .cmos2_pclk  (1'b0),
        .cmos2_vsync (1'b0),
        .cmos2_href  (1'b0),
        .cmos2_data  (8'd0),
        .ref_clk_p   (1'b0),
        .ref_clk_n   (1'b1),
        .mem_rst_n   (), .mem_ck (), .mem_ck_n (), .mem_cke (),
        .mem_cs_n    (), .mem_ras_n (), .mem_cas_n (), .mem_we_n (),
        .mem_odt     (), .mem_a (), .mem_ba (), .mem_dqs (), .mem_dqs_n (),
        .mem_dq      (), .mem_dm (),
        .pix_clk     (pix_clk),
        .de_out      (de_out),
        .hs_out      (hs_out),
        .vs_out      (vs_out),
        .r_out       (r_out),
        .g_out       (g_out),
        .b_out       (b_out),
        .rstn_out    (rstn_out),
        .iic_tx_scl  (iic_tx_scl),
        .iic_tx_sda  (iic_tx_sda),
        .led         (led),
        .uart_tx     (uart_tx)
    );

    // ---------------------------------------------------- HDMI-side counters
    integer xo = 0;
    integer yo = 0;
    integer frames = 0;
    reg     vs_out_d = 1'b0;
    reg     in_frame = 1'b0;

    always @(posedge pix_clk) begin
        if (vs_out && !vs_out_d) begin
            frames <= frames + 1;
            xo <= 0;
            yo <= 0;
            in_frame <= (frames >= 2);
        end
        vs_out_d <= vs_out;
        if (de_out) begin
            if (xo == 1279) begin
                xo <= 0;
                yo <= yo + 1;
            end else begin
                xo <= xo + 1;
            end
        end
    end

    integer errors = 0;
    integer checks = 0;

    task check_pixel;
        input integer px;
        input integer py;
        input [7:0]   dexp;
        input [7:0]   gexp;
        input [7:0]   bexp;
        begin
            checks = checks + 1;
            if (r_out !== dexp || g_out !== gexp || b_out !== bexp) begin
                errors = errors + 1;
                $display("FAIL (%0d,%0d): got r=%02x g=%02x b=%02x exp r=%02x g=%02x b=%02x",
                         px, py, r_out, g_out, b_out, dexp, gexp, bexp);
            end
        end
    endtask

    // Check on the negative edge, when the registered outputs are stable.
    always @(negedge pix_clk) begin
        if (in_frame && de_out && (yo < 4)) begin
            if ((xo == 0) || (xo == 2) || (xo == 100) || (xo == 1278)) begin
                // camera row = 2*(yo/2); camera x = 2*(xo/2)
                check_pixel(xo, yo, (((xo / 2) % 32) * 8),
                            (yo / 2) * 2 * 4, 8'd40);
            end
        end
    end

    // ------------------------------------------------------- camera stimulus
    integer line;
    integer i;

    task send_line;
        input integer y;
        integer x;
        reg [4:0] r5;
        reg [4:0] b5;
        reg [5:0] g6;
        begin
            @(negedge cam_pclk);
            cam_href = 1'b1;
            for (x = 0; x < 1280; x = x + 1) begin
                r5 = (x / 2) % 32;
                g6 = y % 64;
                b5 = 5;
                // sensor order: {B[4:0],G[5:3]} then {G[2:0],R[4:0]}
                cam_data = {b5, g6[5:3]};
                @(negedge cam_pclk);
                cam_data = {g6[2:0], r5};
                @(negedge cam_pclk);
            end
            cam_href = 1'b0;
            repeat (32) @(negedge cam_pclk);
        end
    endtask

    task send_frame;
        begin
            @(negedge cam_pclk);
            cam_vsync = 1'b1;
            repeat (8) @(negedge cam_pclk);
            cam_vsync = 1'b0;
            repeat (8) @(negedge cam_pclk);
            for (line = 0; line < 4; line = line + 1)
                send_line(line);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk_27m);
        rst_n = 1'b1;

        // Three vsyncs so both banks have been written before we check the
        // HDMI output (the read bank lags the write bank by one frame).
        repeat (4) @(negedge cam_pclk);
        send_frame;
        send_frame;
        send_frame;

        // Let the HDMI side display the last complete bank.
        repeat (3) begin
            @(posedge vs_out);
        end
        repeat (2) @(posedge vs_out);

        $display("preview: frames=%0d checks=%0d errors=%0d", frames, checks, errors);
        if (checks == 0) begin
            $display("FAIL: no pixel checks executed");
            errors = errors + 1;
        end
        if (errors == 0) $display("*** TB_VIDEO_PREVIEW PASS ***");
        else             $display("*** TB_VIDEO_PREVIEW FAILED %0d ***", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("*** TB_VIDEO_PREVIEW TIMEOUT (frames=%0d checks=%0d) ***", frames, checks);
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, cmos1_reset, cmos1_scl, cmos1_sda,
                     cmos2_reset, cmos2_scl, cmos2_sda,
                     hs_out, rstn_out, iic_tx_scl, iic_tx_sda, led, uart_tx,
                     xo, yo};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
