`timescale 1ns/1ps
`include "video_defs.vh"

//=============================================================================
// ARES RTOS AMP + camera preview over HDMI
//-----------------------------------------------------------------------------
// Same 4-hart AMP SoC as pipeline_rtos_amp_board_top, plus an independent
// camera -> DDR3 framebuf -> HDMI 720p30 channel.
//
//   * CPU/periph: pipeline_clk_reset (70 MHz / 50 MHz in the 70 MHz project)
//   * video:      video_clk_reset (pix 37.125 MHz, cfg 10 MHz, cam 24.75 MHz)
//   * camera:     one video_capture_wrap shared by the AI and the framebuf
//   * framebuf:   vendor fram_buf + DDR3 I_ips_ddr_top
//
// The existing pipeline_rtos_amp_board_top is intentionally left untouched.
//=============================================================================
module pipeline_rtos_amp_hdmi_board_top (
    input  wire       clk_27m,
    input  wire       rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led,

    // OV5640 CMOS1
    input  wire       cmos1_pclk,
    input  wire       cmos1_vsync,
    input  wire       cmos1_href,
    input  wire [7:0] cmos1_data,
    output wire       cmos1_reset,
    inout  wire       cmos1_scl,
    inout  wire       cmos1_sda,

    // DDR3 reference/device
    input  wire        ref_clk_p,
    input  wire        ref_clk_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_cs_n,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm,

    // HDMI TX (MS7210)
    output wire        pix_clk,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        rstn_out,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda
);

    // --------------------------------------------------------- CPU/periph PLL
    wire cpu_clk, periph_clk, pll_lock, cpu_rst, periph_rst;
    wire rx_full, rx_overflow;
    wire [31:0] soc_led;
    wire [3:0] retire_valid, retire_is_ebreak;

    pipeline_clk_reset u_clk_reset (
        .clk_27m(clk_27m), .rst_n(rst_n),
        .cpu_clk(cpu_clk), .periph_clk(periph_clk), .pll_lock(pll_lock),
        .cpu_rst(cpu_rst), .periph_rst(periph_rst)
    );

    // ------------------------------------------------------------- video PLL
    wire clk_pix, clk_cfg, clk_cam;
    wire video_pll_lock;
    wire rst_sys, rst_pix, rst_cfg, phy_rstn;

    video_clk_reset u_video_clk_reset (
        .clk_27m  (clk_27m),
        .rst_n    (rst_n),
        .clk_pix  (clk_pix),
        .clk_cfg  (clk_cfg),
        .clk_cam  (clk_cam),
        .pll_lock (video_pll_lock),
        .rst_sys  (rst_sys),
        .rst_pix  (rst_pix),
        .rst_cfg  (rst_cfg),
        .rst_cam  (),
        .phy_rstn (phy_rstn)
    );

    // MS7210 pixel clock output.
    assign pix_clk = clk_pix;

    // ------------------------------------------------------- camera capture
    wire        pixel_clk_io;
    wire        pixel_clk;
    wire        pixel_rst;
    wire        pixel_vsync;
    wire        pixel_de;
    wire [15:0] pixel_rgb565;
    wire        cam_init_done;

    video_capture_wrap u_capture (
        .clk_27m      (clk_27m),
        .clk_cam      (clk_cam),
        .rst_sys      (rst_sys),
        .cam_reset    (cmos1_reset),
        .cam_scl      (cmos1_scl),
        .cam_sda      (cmos1_sda),
        .cam_pclk     (cmos1_pclk),
        .cam_vsync    (cmos1_vsync),
        .cam_href     (cmos1_href),
        .cam_data     (cmos1_data),
        .pixel_clk    (pixel_clk_io),
        .pixel_rst    (pixel_rst),
        .pixel_vsync  (pixel_vsync),
        .pixel_de     (pixel_de),
        .pixel_rgb565 (pixel_rgb565),
        .cam_init_done(cam_init_done),
        .dbg_vsync_cnt(),
        .dbg_line_cnt (),
        .dbg_pixel_cnt(),
        .dbg_pclk_cnt ()
    );

    // The framebuf write side spans many clock regions; use a global clock.
    GTP_CLKBUFG u_pixel_clk_bufg (
        .CLKIN  (pixel_clk_io),
        .CLKOUT (pixel_clk)
    );

    // --------------------------------------------------------------- AMP SoC
    pipeline_amp_top #(
        .CORES(4), .ICACHE_LINES(512), .RTOS_AI(1'b1),
        .IROM_INIT_FILE("build/rtos_amp/worker_irom.hex"),
        .DRAM_INIT_FILE("build/rtos_amp/worker_dram.hex")
    ) u_soc (
        .clk(cpu_clk), .rst(cpu_rst), .core_en(4'b1111),
        .periph_clk(periph_clk), .periph_rst(periph_rst),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .rx_full(rx_full), .rx_overflow(rx_overflow),
        .retire_valid(retire_valid), .retire_is_ebreak(retire_is_ebreak),
        .retire_pc(), .retire_pc_next(), .retire_rd_wen(), .retire_rd(), .retire_wdata(),
        .led(soc_led),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst), .pixel_vsync(pixel_vsync),
        .pixel_de(pixel_de), .pixel_rgb565(pixel_rgb565)
    );

    // ------------------------------------------------------ video -> HDMI path
    wire ddr_init_done, hdmi_init_done, fb_init_done;

    pipeline_amp_video #(
        .PATTERN_MODE(`VIDEO_PAT_OFF)
    ) u_video (
        .clk_27m(clk_27m), .rst_sys(rst_sys),
        .pixel_clk(pixel_clk), .pixel_rst(pixel_rst),
        .pixel_vsync(pixel_vsync), .pixel_de(pixel_de),
        .pixel_rgb565(pixel_rgb565),
        .clk_pix(clk_pix), .rst_pix(rst_pix),
        .clk_cfg(clk_cfg), .rst_cfg(rst_cfg), .phy_rstn(phy_rstn),
        .ref_clk_p(ref_clk_p), .ref_clk_n(ref_clk_n),
        .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_cs_n(mem_cs_n),
        .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n),
        .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba),
        .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq), .mem_dm(mem_dm),
        .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out),
        .r_out(r_out), .g_out(g_out), .b_out(b_out),
        .rstn_out(rstn_out),
        .iic_tx_scl(iic_tx_scl), .iic_tx_sda(iic_tx_sda),
        .ddr_init_done(ddr_init_done),
        .hdmi_init_done(hdmi_init_done),
        .fb_init_done(fb_init_done)
    );

    // [7] UART RX overflow, [6] framebuf init, [5] HDMI init, [4] DDR3 init,
    // [3] video PLL lock, [2] camera init, [1] SoC LED, [0] CPU PLL lock.
    assign led = {rx_overflow, fb_init_done, hdmi_init_done, ddr_init_done,
                  video_pll_lock, cam_init_done, soc_led[0], pll_lock};

endmodule
