// ---------------------------------------------------------------------------
// tb_video_dvp_pair - byte-pair phase must reset on every HREF low.
//
// Reproduces the on-board failure mode: the OV5640 emits extra HREF pulses
// between lines, so a capture front end that keeps its byte phase across
// blanking starts the next line on the wrong byte and shows byte-swapped
// (green/blue/magenta) colours.  video_dvp_rgb565 resets the phase on HREF
// low, so both lines must start with pixel 0x1234.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_video_dvp_pair;

    reg pclk = 1'b0;
    always #5.9524 pclk = ~pclk;             // 84 MHz

    reg rst_n = 1'b0;
    reg href = 1'b0;
    reg [7:0] data = 8'd0;
    reg vsync = 1'b0;

    wire pixel_clk;
    wire de_o;
    wire [15:0] pdata_o;

    video_dvp_rgb565 u_dut (
        .pclk      (pclk),
        .rst_n     (rst_n),
        .de_i      (href),
        .pdata_i   (data),
        .vs_i      (vsync),
        .pixel_clk (pixel_clk),
        .de_o      (de_o),
        .pdata_o   (pdata_o)
    );

    // Collect one sample per pixel clock while DE is high, split into lines
    // by the DE-low gap.
    reg [15:0] samples [0:15];
    integer n = 0;
    integer lines = 0;
    integer gap = 0;
    integer i;

    always @(posedge pixel_clk) begin
        if (de_o) begin
            samples[n] = pdata_o;
            n = n + 1;
            gap = 0;
        end else begin
            gap = gap + 1;
            if (gap == 3) lines = lines + 1;   // one gap per line
        end
    end

    task send_line;
        input [7:0] b0;
        input [7:0] b1;
        input [7:0] b2;
        input [7:0] b3;
        begin
            @(negedge pclk); href = 1'b1; data = b0;
            @(negedge pclk); data = b1;
            @(negedge pclk); data = b2;
            @(negedge pclk); data = b3;
            @(negedge pclk); href = 1'b0;
            repeat (16) @(negedge pclk);
        end
    endtask

    integer errors = 0;

    initial begin
        repeat (4) @(posedge pclk);
        rst_n = 1'b1;

        // Start the /2 divider (vendor enables it on the vsync rising edge).
        repeat (4) @(negedge pclk);
        vsync = 1'b1;
        repeat (4) @(negedge pclk);
        vsync = 1'b0;
        repeat (8) @(negedge pclk);

        // Line A: 0x12 0x34 0x56 0x78 -> 0x1234, 0x5678
        send_line(8'h12, 8'h34, 8'h56, 8'h78);

        // Extra HREF pulse in blanking: odd number of captured bytes.  The
        // old cmos_8_16bit kept this +1 in cnt and swapped the next line.
        @(negedge pclk); href = 1'b1; data = 8'hAA;
        @(negedge pclk); href = 1'b0;
        repeat (8) @(negedge pclk);

        // Line B: same bytes; must pair as 0x1234 again.
        send_line(8'h12, 8'h34, 8'h56, 8'h78);
        repeat (16) @(negedge pclk);

        $display("pair: lines_seen=%0d samples=%0d", lines, n);
        for (i = 0; i < n; i = i + 1)
            $display("  sample[%0d]=%04x", i, samples[i]);

        // Both lines must contain 0x1234 then 0x5678.
        if (n < 4) begin
            $display("FAIL: expected at least 4 pixel samples, got %0d", n);
            errors = errors + 1;
        end else if (samples[0] !== 16'h1234 || samples[1] !== 16'h5678 ||
                     samples[2] !== 16'h1234 || samples[3] !== 16'h5678) begin
            $display("FAIL: line pairing not reset (samples %04x %04x %04x %04x)",
                     samples[0], samples[1], samples[2], samples[3]);
            errors = errors + 1;
        end

        if (errors == 0) $display("*** TB_VIDEO_DVP_PAIR PASS ***");
        else             $display("*** TB_VIDEO_DVP_PAIR FAILED %0d ***", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("*** TB_VIDEO_DVP_PAIR TIMEOUT ***");
        $finish;
    end

endmodule
