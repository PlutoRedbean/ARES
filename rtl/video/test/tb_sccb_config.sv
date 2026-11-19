`timescale 1ns/1ps
module tb_sccb_config;
    bit clk_cam, clk_sys, rst = 1;
    always #20 clk_cam = !clk_cam;
    always #18.519 clk_sys = !clk_sys;
    wire scl, cam_reset_n;
    tri1 sda;
    video_capture_wrap dut (
        .clk_27m(clk_sys), .clk_cam, .rst_sys(rst), .cam_reset(cam_reset_n),
        .cam_scl(scl), .cam_sda(sda), .cam_pclk(1'b0), .cam_vsync(1'b0),
        .cam_href(1'b0), .cam_data(8'd0), .pixel_clk(), .pixel_rst(),
        .pixel_vsync(), .pixel_de(), .pixel_rgb565(), .cam_init_done(),
        .dbg_vsync_cnt(), .dbg_line_cnt(), .dbg_pixel_cnt(), .dbg_pclk_cnt()
    );

    // Decode at the camera pins. The master releases SDA for every ACK.
    task automatic check_write(input logic [31:0] expected);
        logic [31:0] bits;
        @(negedge sda);
        if (scl !== 1) $fatal(1, "missing SCCB START");
        for (int n = 0; n < 36; n++) begin
            @(posedge scl);
            if (n % 9 != 8) bits = {bits[30:0], sda};
        end
        if (bits !== expected) $fatal(1, "SCCB write %h expected %h", bits, expected);
        @(posedge sda);
        if (scl !== 1) $fatal(1, "missing SCCB STOP");
    endtask

    initial begin
        repeat (8) @(negedge clk_sys);
        rst = 0;
        @(posedge cam_reset_n);
        @(negedge clk_cam);
        while (!dut.cam_release[1]) @(negedge clk_cam);
        repeat (1249) begin
            @(negedge clk_cam);
            if (dut.u_reg_config.clock_20k !== 0) $fatal(1, "early SCCB divider edge");
        end
        @(negedge clk_cam);
        if (dut.u_reg_config.clock_20k !== 1) $fatal(1, "missing SCCB divider edge");
        check_write(32'h78310311);
        check_write(32'h78300882);
        // Interrupt a transaction. The sensor and sequencer restart at word 0.
        @(negedge sda);
        repeat (4) @(posedge scl);
        @(negedge clk_sys); rst = 1;
        repeat (12) @(negedge clk_sys);
        if (cam_reset_n !== 0 || scl !== 1 || sda !== 1) $fatal(1, "SCCB reset");
        rst = 0;
        @(posedge cam_reset_n);
        check_write(32'h78310311);
        $display("SCCB clock enable, pin sequence and restart PASS");
        $finish;
    end

    initial begin
        repeat (1500000) @(posedge clk_cam);
        $fatal(1, "SCCB timeout");
    end
endmodule
