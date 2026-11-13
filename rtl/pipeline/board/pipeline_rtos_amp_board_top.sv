`timescale 1ns/1ps

module pipeline_rtos_amp_board_top (
    input  wire       clk_27m,
    input  wire       rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led,
    input  wire       cmos1_pclk, cmos1_vsync, cmos1_href,
    input  wire [7:0] cmos1_data,
    output wire       cmos1_reset,
    inout  wire       cmos1_scl, cmos1_sda
);
    wire cpu_clk, periph_clk, pll_lock, cpu_rst, periph_rst;
    wire rx_full, rx_overflow;
    wire [31:0] soc_led;
    wire [3:0] retire_valid, retire_is_ebreak;

    pipeline_clk_reset u_clk_reset (
        .clk_27m(clk_27m), .rst_n(rst_n),
        .cpu_clk(cpu_clk), .periph_clk(periph_clk), .pll_lock(pll_lock),
        .cpu_rst(cpu_rst), .periph_rst(periph_rst)
    );

    wire pixel_clk, sensor_pixel_rst, pixel_rst, pixel_vsync, pixel_de;
    wire [15:0] pixel_rgb565;
    reg clk_cam = 1'b0;
    always @(posedge periph_clk)
        clk_cam <= ~clk_cam;

    video_capture_wrap u_capture (
        .clk_27m(clk_27m), .clk_cam(clk_cam), .rst_sys(periph_rst),
        .cam_reset(cmos1_reset), .cam_scl(cmos1_scl), .cam_sda(cmos1_sda),
        .cam_pclk(cmos1_pclk), .cam_vsync(cmos1_vsync), .cam_href(cmos1_href),
        .cam_data(cmos1_data), .pixel_clk(pixel_clk), .pixel_rst(sensor_pixel_rst),
        .pixel_vsync(pixel_vsync), .pixel_de(pixel_de), .pixel_rgb565(pixel_rgb565),
        .cam_init_done(), .dbg_vsync_cnt(), .dbg_line_cnt(), .dbg_pixel_cnt(), .dbg_pclk_cnt()
    );

    pipeline_cdc_reset_sync u_pixel_reset (
        .clk(pixel_clk), .rst_in(cpu_rst | sensor_pixel_rst), .rst_out(pixel_rst)
    );

    pipeline_amp_top #(
        .CORES(4), .ICACHE_LINES(512), .RTOS_AI(1'b1),
        .IROM_INIT_FILE("build/rtos_amp/worker_irom.hex"),
        .DRAM_INIT_FILE("build/rtos_amp/worker_dram.hex")
    ) u_soc (
        .clk(cpu_clk), .rst(cpu_rst), .core_en(4'b1111),
        .periph_clk(periph_clk), .periph_rst(periph_rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .rx_full(rx_full), .rx_overflow(rx_overflow),
        .retire_valid(retire_valid), .retire_is_ebreak(retire_is_ebreak),
        .retire_pc(), .retire_pc_next(), .retire_rd_wen(), .retire_rd(), .retire_wdata(),
        .led(soc_led),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst), .pixel_vsync(pixel_vsync),
        .pixel_de(pixel_de), .pixel_rgb565(pixel_rgb565)
    );

    assign led = {rx_overflow, soc_led[5:0], pll_lock};
endmodule
