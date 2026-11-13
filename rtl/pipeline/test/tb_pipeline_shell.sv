`timescale 1ns/1ps
module tb_pipeline_shell (
    input wire rx,
    output wire tx,
    output wire rx_available,
    output reg [31:0] tx_count = 0,
    output reg [7:0] tx_char = 0,
    output wire [7:0] led
);
    reg clk_27m = 0, rst_n = 0;
    always begin #18 clk_27m=1; #19 clk_27m=0; end
    initial begin #200000; rst_n=1; end
`ifdef ARES_RTOS_AMP
    reg pclk = 0, vsync = 0, href = 0;
    reg [7:0] dvp = 0;
    pipeline_rtos_amp_board_top dut (.clk_27m(clk_27m), .rst_n(rst_n),
                                     .uart_rx(rx), .uart_tx(tx), .led(led),
                                     .cmos1_pclk(pclk), .cmos1_vsync(vsync),
                                     .cmos1_href(href), .cmos1_data(dvp),
                                     .cmos1_reset(), .cmos1_scl(), .cmos1_sda());
    // Place the known model patch into the sensor coordinates sampled by
    // trk_patch. The first and last crop pixels serve as geometry sentinels.
    reg [15:0] gesture_patch [0:1023];
    initial if ($test$plusargs("camera")) begin
        $readmemh("build/rtos_amp/camera_patch.hex", gesture_patch);
        forever #6 pclk = ~pclk;
    end
    initial if ($test$plusargs("camera")) begin
        wait (rst_n);
        forever begin
            @(negedge pclk);
            vsync = 1;
            repeat (12) @(negedge pclk);
            vsync = 0;
            repeat (12) @(negedge pclk);
            for (integer y = 0; y < 720; y++) begin
                for (integer x = 0; x < 1280; x++) begin
                    reg [15:0] bgr;
                    bgr = 16'hffff;
                    if (x >= 494 && x < 754 && y >= 190 && y < 450)
                        bgr = gesture_patch[((((y - 190) / 2 + 1) * 32 - 1) / 130) * 32 + (((x - 494) / 2 + 1) * 32 - 1) / 130];
                    if (x == 320 && y == 120) bgr = 16'h001f;
                    if (x == 958 && y == 598) bgr = 16'hf800;
                    @(negedge pclk);
                    href = 1;
                    dvp = bgr[15:8];
                    @(negedge pclk);
                    dvp = bgr[7:0];
                end
                @(negedge pclk);
                href = 0;
                repeat (12) @(negedge pclk);
            end
            #5_000_000;
        end
    end
    // Check the cropped corners at publication, before software can release
    // the bank. BGR565 001f is red (luma 76), f800 is blue (luma 28).
    initial if ($test$plusargs("camera")) begin
        wait (dut.u_soc.g_hart[0].g_mt.u_camera.published);
        if (dut.u_soc.g_hart[0].g_mt.u_camera.bank1[0] !== 8'd76 ||
            dut.u_soc.g_hart[0].g_mt.u_camera.bank1[76799] !== 8'd28)
            $fatal(1, "camera crop corners do not match the DVP sentinels");
        $display("Camera crop corners PASS");
    end
    wire halted = |(dut.retire_valid & dut.retire_is_ebreak);
`else
    pipeline_rtos_shell_board_top dut (.clk_27m(clk_27m), .rst_n(rst_n),
                                      .uart_rx(rx), .uart_tx(tx), .led(led));
    wire halted = dut.u_soc.retire_valid && dut.u_soc.retire_is_ebreak;
`endif
    assign rx_available = rst_n && !dut.rx_full;
    reg [7:0] ch;
    initial forever begin
        @(negedge tx);
        #4340;
        if(tx !== 0) $fatal(1,"UART start bit");
        #8680;
        for(integer i=0; i<8; i=i+1) begin ch[i]=tx; #8680; end
        if(tx !== 1) $fatal(1,"UART stop bit");
        tx_char=ch;
        tx_count=tx_count+1;
    end
    always @(posedge dut.periph_clk)
        if(dut.rx_overflow) $fatal(1,"UART RX FIFO overflow");
    always @(posedge dut.cpu_clk)
        if(!dut.cpu_rst && halted)
            $fatal(1,"Shell firmware halted");
endmodule
