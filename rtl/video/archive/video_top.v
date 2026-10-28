// ---------------------------------------------------------------------------
// ARES video subsystem v1 - standalone board top (S1 camera capture)
//
// S1 adds:
//   OV5640 SCCB configuration + DVP 8->16 capture
//   vsync / line / pixel counters -> 8 LEDs + 115200 UART
// The HDMI output keeps the S0 test pattern (framebuffer arrives in S2).
//
// The board-level port list is the frozen one from the design doc.  Camera
// selection is the CAM_SEL parameter; only the selected sensor is configured.
//
// Verilog-2001 only.  No logic/always_ff/interface/package/typedef.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_top #(
    parameter integer CAM_SEL       = 0,                 // 0=CMOS1, 1=CMOS2
    parameter [27:0]  FB_BASE0_BYTE = `VIDEO_FB_BASE0_BYTE,
    parameter [27:0]  FB_BASE1_BYTE = `VIDEO_FB_BASE1_BYTE,
    parameter integer FB_ADDR_SHIFT = `VIDEO_FB_ADDR_SHIFT,
    parameter integer BIST_BYTES    = `VIDEO_BIST_BYTES,
    parameter [1:0]   PATTERN_MODE  = `VIDEO_PAT_BAR
) (
    input  wire        clk_27m,
    input  wire        rst_n,

    // ---------------------------------------------------------- OV5640 CMOS1
    output wire        cmos1_reset,
    inout  wire        cmos1_scl,
    inout  wire        cmos1_sda,
    input  wire        cmos1_pclk,
    input  wire        cmos1_vsync,
    input  wire        cmos1_href,
    input  wire [7:0]  cmos1_data,

    // ---------------------------------------------------------- OV5640 CMOS2
    output wire        cmos2_reset,
    inout  wire        cmos2_scl,
    inout  wire        cmos2_sda,
    input  wire        cmos2_pclk,
    input  wire        cmos2_vsync,
    input  wire        cmos2_href,
    input  wire [7:0]  cmos2_data,

    // ------------------------------------------------- DDR3 reference/device
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

    // ------------------------------------------------------ HDMI TX (MS7210)
    output wire        pix_clk,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        rstn_out,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    // ---------------------------------------------------------- board status
    output wire [7:0]  led,
    output wire        uart_tx
);

    localparam [1:0] STAGE   = `VIDEO_STAGE_SEL;
    localparam [2:0] VERSION = 3'd1;

    // ------------------------------------------------------- clock / reset
    wire clk_pix;
    wire clk_cfg;
    wire clk_cam;
    wire pll_lock;
    wire rst_sys;
    wire rst_pix;
    wire rst_cfg;
    wire rst_cam;
    wire phy_rstn;

    video_clk_reset u_clk_reset (
        .clk_27m  (clk_27m),
        .rst_n    (rst_n),
        .clk_pix  (clk_pix),
        .clk_cfg  (clk_cfg),
        .clk_cam  (clk_cam),
        .pll_lock (pll_lock),
        .rst_sys  (rst_sys),
        .rst_pix  (rst_pix),
        .rst_cfg  (rst_cfg),
        .rst_cam  (rst_cam),
        .phy_rstn (phy_rstn)
    );

    assign pix_clk  = clk_pix;
    assign rstn_out = phy_rstn;

    // ------------------------------------------------------------- S0 HDMI
    wire hdmi_init_done;
    wire       rd_en_unused;
    wire       rd_vsync_unused;
    wire [11:0] x_act_unused;
    wire [11:0] y_act_unused;

    video_hdmi_wrap u_hdmi (
        .pix_clk        (clk_pix),
        .pix_rst        (rst_pix),
        .cfg_clk        (clk_cfg),
        .cfg_rst        (rst_cfg),
        .phy_rstn       (phy_rstn),
        .vout_rgb565    (16'h0000),
        .pattern_mode   (PATTERN_MODE),
        .rd_en          (rd_en_unused),
        .rd_vsync       (rd_vsync_unused),
        .x_act          (x_act_unused),
        .y_act          (y_act_unused),
        .de_out         (de_out),
        .hs_out         (hs_out),
        .vs_out         (vs_out),
        .r_out          (r_out),
        .g_out          (g_out),
        .b_out          (b_out),
        .hdmi_init_done (hdmi_init_done),
        .iic_scl        (iic_tx_scl),
        .iic_sda        (iic_tx_sda)
    );

    // ------------------------------------------------------- camera capture
    wire        cam_reset;
    wire        cam_init_done;
    wire        pixel_clk;
    wire        pixel_rst;
    wire        pixel_vsync;
    wire        pixel_de;
    wire [15:0] pixel_rgb565;
    wire [31:0] cap_vsync_cnt;
    wire [31:0] cap_line_cnt;
    wire [31:0] cap_pixel_cnt;
    wire [31:0] cap_pclk_cnt;

    generate
        if ((STAGE == `VIDEO_STAGE_CAPTURE) || (STAGE == `VIDEO_STAGE_FRAMEBUF)) begin : g_capture
            if (CAM_SEL == 0) begin : g_cam1
                video_capture_wrap u_capture (
                    .clk_27m      (clk_27m),
                    .clk_cam      (clk_cam),
                    .rst_sys      (rst_sys),
                    .cam_reset    (cam_reset),
                    .cam_scl      (cmos1_scl),
                    .cam_sda      (cmos1_sda),
                    .cam_pclk     (cmos1_pclk),
                    .cam_vsync    (cmos1_vsync),
                    .cam_href     (cmos1_href),
                    .cam_data     (cmos1_data),
                    .pixel_clk    (pixel_clk),
                    .pixel_rst    (pixel_rst),
                    .pixel_vsync  (pixel_vsync),
                    .pixel_de     (pixel_de),
                    .pixel_rgb565 (pixel_rgb565),
                    .cam_init_done(cam_init_done),
                    .dbg_vsync_cnt(cap_vsync_cnt),
                    .dbg_line_cnt (cap_line_cnt),
                    .dbg_pixel_cnt(cap_pixel_cnt),
                    .dbg_pclk_cnt (cap_pclk_cnt)
                );
                assign cmos1_reset = cam_reset;
                assign cmos2_reset = 1'b1;
                assign cmos2_scl   = 1'bz;
                assign cmos2_sda   = 1'bz;
            end else begin : g_cam2
                video_capture_wrap u_capture (
                    .clk_27m      (clk_27m),
                    .clk_cam      (clk_cam),
                    .rst_sys      (rst_sys),
                    .cam_reset    (cam_reset),
                    .cam_scl      (cmos2_scl),
                    .cam_sda      (cmos2_sda),
                    .cam_pclk     (cmos2_pclk),
                    .cam_vsync    (cmos2_vsync),
                    .cam_href     (cmos2_href),
                    .cam_data     (cmos2_data),
                    .pixel_clk    (pixel_clk),
                    .pixel_rst    (pixel_rst),
                    .pixel_vsync  (pixel_vsync),
                    .pixel_de     (pixel_de),
                    .pixel_rgb565 (pixel_rgb565),
                    .cam_init_done(cam_init_done),
                    .dbg_vsync_cnt(cap_vsync_cnt),
                    .dbg_line_cnt (cap_line_cnt),
                    .dbg_pixel_cnt(cap_pixel_cnt),
                    .dbg_pclk_cnt (cap_pclk_cnt)
                );
                assign cmos2_reset = cam_reset;
                assign cmos1_reset = 1'b1;
                assign cmos1_scl   = 1'bz;
                assign cmos1_sda   = 1'bz;
            end
        end else begin : g_no_capture
            assign cmos1_reset = 1'b1;
            assign cmos2_reset = 1'b1;
            assign cmos1_scl   = 1'bz;
            assign cmos1_sda   = 1'bz;
            assign cmos2_scl   = 1'bz;
            assign cmos2_sda   = 1'bz;
            assign cam_reset      = 1'b1;
            assign cam_init_done  = 1'b0;
            assign pixel_clk      = 1'b0;
            assign pixel_rst      = 1'b1;
            assign pixel_vsync    = 1'b0;
            assign pixel_de       = 1'b0;
            assign pixel_rgb565   = 16'd0;
            assign cap_vsync_cnt  = 32'd0;
            assign cap_line_cnt   = 32'd0;
            assign cap_pixel_cnt  = 32'd0;
            assign cap_pclk_cnt   = 32'd0;
        end
    endgenerate

    // ------------------------------------------------------------- status
    // cam_init_done is generated in the cam clock domain; the counters are
    // snapshotted in the pixel domain and stable for ~1.56 ms, so a 2FF bus
    // synchronizer is safe.
    reg [1:0]  cam_init_sync;
    reg [31:0] cap_vsync_s1, cap_vsync_s2;
    reg [31:0] cap_line_s1,  cap_line_s2;
    reg [31:0] cap_pixel_s1, cap_pixel_s2;
    reg [31:0] cap_pclk_s1,  cap_pclk_s2;

    always @(posedge clk_27m) begin
        cam_init_sync <= {cam_init_sync[0], cam_init_done};
        cap_vsync_s1  <= cap_vsync_cnt;
        cap_vsync_s2  <= cap_vsync_s1;
        cap_line_s1   <= cap_line_cnt;
        cap_line_s2   <= cap_line_s1;
        cap_pixel_s1  <= cap_pixel_cnt;
        cap_pixel_s2  <= cap_pixel_s1;
        cap_pclk_s1   <= cap_pclk_cnt;
        cap_pclk_s2   <= cap_pclk_s1;
    end

    wire cam_init_done_sys = cam_init_sync[1];

    wire [31:0] status_word;
    wire [31:0] status_word2;

    assign status_word = {
        23'd0,
        1'b0,               // [8] bist_error
        1'b0,               // [7] bist_done
        1'b0,               // [6] fifo_overflow
        1'b0,               // [5] frame_drop
        cap_vsync_s2[5],    // [4] capture frame activity
        cam_init_done_sys,  // [3] cam_init_done
        hdmi_init_done,     // [2] hdmi_init_done
        1'b0,               // [1] ddr_init_done
        pll_lock            // [0] pll_lock
    };
    assign status_word2 = 32'd0;

    video_status u_status (
        .clk_27m      (clk_27m),
        .rst_sys      (rst_sys),
        .status_word  (status_word),
        .status_word2 (status_word2),
        .cap_vsync_cnt(cap_vsync_s2),
        .cap_line_cnt (cap_line_s2),
        .cap_pixel_cnt(cap_pixel_s2),
        .led          (led),
        .uart_tx      (uart_tx)
    );

    // ------------------------------------------------- DDR3 safe ties (S1)
    assign mem_rst_n   = 1'b1;
    assign mem_ck      = 1'b0;
    assign mem_ck_n    = 1'b0;
    assign mem_cke     = 1'b0;
    assign mem_cs_n    = 1'b1;
    assign mem_ras_n   = 1'b1;
    assign mem_cas_n   = 1'b1;
    assign mem_we_n    = 1'b1;
    assign mem_odt     = 1'b0;
    assign mem_a       = 15'd0;
    assign mem_ba      = 3'd0;
    assign mem_dqs     = 4'bz;
    assign mem_dqs_n   = 4'bz;
    assign mem_dq      = 32'bz;
    assign mem_dm      = 4'd0;

    // Consume pins reserved for S2 / unused branches.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_ok = &{1'b0,
        cmos1_pclk, cmos1_vsync, cmos1_href, cmos1_data,
        cmos2_pclk, cmos2_vsync, cmos2_href, cmos2_data,
        cmos1_scl, cmos1_sda, cmos2_scl, cmos2_sda,
        ref_clk_p, ref_clk_n,
        mem_dqs, mem_dqs_n, mem_dq,
        iic_tx_sda,
        cam_reset, pixel_clk, pixel_rst, pixel_vsync, pixel_de, pixel_rgb565,
        cap_pclk_cnt, cap_pclk_s1, cap_pclk_s2,
        STAGE, VERSION, CAM_SEL, FB_BASE0_BYTE, FB_BASE1_BYTE,
        FB_ADDR_SHIFT, BIST_BYTES};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
