`timescale 1ns/1ps
`include "video_defs.vh"

//=============================================================================
// ARES pipeline AMP + camera -> DDR3 double buffer -> HDMI 720p30
//-----------------------------------------------------------------------------
// External pixel stream (already captured by video_capture_wrap) is written
// into the vendor framebuf on the camera pixel clock.  The framebuf owns the
// camera-pixel <-> DDR3 <-> HDMI clock-domain crossings.  The HDMI read side
// runs on the independent 37.125 MHz pix_clk.
//
// The DDR3 IP instance MUST be named I_ips_ddr_top: official_ddr3.fdc uses
// that absolute path.
//=============================================================================
module pipeline_amp_video #(
    parameter [1:0] PATTERN_MODE = `VIDEO_PAT_OFF
) (
    // System / video resets come from the board-level video_clk_reset.
    input  wire        clk_27m,
    input  wire        rst_sys,           // active high, 27 MHz domain

    // Camera pixel stream (from the shared video_capture_wrap).
    input  wire        pixel_clk,
    input  wire        pixel_rst,         // active high
    input  wire        pixel_vsync,
    input  wire        pixel_de,
    input  wire [15:0] pixel_rgb565,

    // HDMI pixel / configuration domains.
    input  wire        clk_pix,
    input  wire        rst_pix,
    input  wire        clk_cfg,
    input  wire        rst_cfg,
    input  wire        phy_rstn,

    // DDR3 reference/device.
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

    // HDMI TX (MS7210).
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        rstn_out,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    // Status for LEDs.
    output wire        ddr_init_done,
    output wire        hdmi_init_done,
    output wire        fb_init_done
);

    // ---------------------------------------------------------- DDR3 ref clk
    wire ref_clk_125m;
    GTP_INBUFGDS u_refclk_buf (
        .O  (ref_clk_125m),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    wire        ddr_core_clk;
    wire        ddr_pll_lock;
    wire        ddr_phy_pll_lock;
    wire        ddr_gpll_lock;
    wire        ddr_rst_gpll_lock;
    wire        ddr_cpd_lock;
    wire        ddr_init_fail;
    wire        ddr_align_error;
    wire [33:0] ddr_debug_calib_ctrl;
    wire [67:0] ddr_dbg_slice_status;

    // ------------------------------------------------------------- framebuf AXI
    wire [27:0]  fb_awaddr;
    wire [3:0]   fb_awid;
    wire [3:0]   fb_awlen;
    wire [2:0]   fb_awsize;
    wire [1:0]   fb_awburst;
    wire         fb_awvalid;
    wire         fb_awready;
    wire [255:0] fb_wdata;
    wire [31:0]  fb_wstrb;
    wire         fb_wlast;
    wire         fb_wvalid;
    wire         fb_wready;
    wire         fb_bready;
    wire [27:0]  fb_araddr;
    wire [3:0]   fb_arid;
    wire [3:0]   fb_arlen;
    wire [2:0]   fb_arsize;
    wire [1:0]   fb_arburst;
    wire         fb_arvalid;
    wire         fb_arready;
    wire         fb_rready;
    wire [255:0] fb_rdata;
    wire         fb_rvalid;
    wire         fb_rlast;
    wire [3:0]   fb_rid;

    // ------------------------------------------------- DDR3 init retry logic
    reg [1:0]  ddr_fail_sync;
    reg [2:0]  retry_state;
    reg [19:0] retry_cnt;
    reg [1:0]  retry_tries;
    reg        dbg_phy_rst_n;
    reg [1:0]  ddr_init_sync;

    localparam [2:0] RT_IDLE = 3'd0;
    localparam [2:0] RT_LOW  = 3'd1;
    localparam [2:0] RT_WAIT = 3'd2;

    always @(posedge clk_27m) begin
        if (rst_sys) begin
            ddr_fail_sync <= 2'b00;
            ddr_init_sync <= 2'b00;
            retry_state   <= RT_IDLE;
            retry_cnt     <= 20'd0;
            retry_tries   <= 2'd0;
            dbg_phy_rst_n <= 1'b1;
        end else begin
            ddr_fail_sync <= {ddr_fail_sync[0], ddr_init_fail};
            ddr_init_sync <= {ddr_init_sync[0], ddr_init_done};
            case (retry_state)
                RT_IDLE: begin
                    dbg_phy_rst_n <= 1'b1;
                    if (ddr_fail_sync[1] && !ddr_init_sync[1] &&
                        (retry_tries < 2'd3)) begin
                        dbg_phy_rst_n <= 1'b0;
                        retry_cnt     <= 20'd0;
                        retry_state   <= RT_LOW;
                    end
                end
                RT_LOW: begin
                    if (retry_cnt == 20'd100000) begin
                        retry_cnt     <= 20'd0;
                        dbg_phy_rst_n <= 1'b1;
                        retry_state   <= RT_WAIT;
                    end else begin
                        retry_cnt <= retry_cnt + 20'd1;
                    end
                end
                RT_WAIT: begin
                    if (retry_cnt == 20'd270000) begin
                        retry_cnt   <= 20'd0;
                        retry_tries <= retry_tries + 2'd1;
                        retry_state <= RT_IDLE;
                    end else begin
                        retry_cnt <= retry_cnt + 20'd1;
                    end
                end
                default: retry_state <= RT_IDLE;
            endcase
        end
    end

    // The vendor framebuf may drive AXI during DDR3 calibration.  Hold all
    // AXI valids low until init completes.
    wire fb_awvalid_g = fb_awvalid & ddr_init_done;
    wire fb_wvalid_g  = fb_wvalid  & ddr_init_done;
    wire fb_arvalid_g = fb_arvalid & ddr_init_done;

    // ---------------------------------------------------------------- DDR3 IP
    ddr3_test I_ips_ddr_top (
        .ref_clk                (ref_clk_125m),
        .resetn                 (phy_rstn),
        .core_clk               (ddr_core_clk),
        .pll_lock               (ddr_pll_lock),
        .phy_pll_lock           (ddr_phy_pll_lock),
        .gpll_lock              (ddr_gpll_lock),
        .rst_gpll_lock          (ddr_rst_gpll_lock),
        .ddrphy_cpd_lock        (ddr_cpd_lock),
        .ddr_init_done          (ddr_init_done),

        .axi_awaddr             (fb_awaddr),
        .axi_awuser_ap          (1'b0),
        .axi_awuser_id          (4'd0),
        .axi_awlen              (fb_awlen),
        .axi_awready            (fb_awready),
        .axi_awvalid            (fb_awvalid_g),

        .axi_wdata              (fb_wdata),
        .axi_wstrb              (fb_wstrb),
        .axi_wready             (fb_wready),
        .axi_wusero_id          (),
        .axi_wusero_last        (fb_wlast),

        .axi_araddr             (fb_araddr),
        .axi_aruser_ap          (1'b0),
        .axi_aruser_id          (4'd0),
        .axi_arlen              (fb_arlen),
        .axi_arready            (fb_arready),
        .axi_arvalid            (fb_arvalid_g),

        .axi_rdata              (fb_rdata),
        .axi_rid                (),
        .axi_rlast              (fb_rlast),
        .axi_rvalid             (fb_rvalid),

        .apb_clk                (1'b0),
        .apb_rst_n              (1'b1),
        .apb_sel                (1'b0),
        .apb_enable             (1'b0),
        .apb_addr               (8'd0),
        .apb_write              (1'b0),
        .apb_ready              (),
        .apb_wdata              (16'd0),
        .apb_rdata              (),

        .mem_cs_n               (mem_cs_n),
        .mem_rst_n              (mem_rst_n),
        .mem_ck                 (mem_ck),
        .mem_ck_n               (mem_ck_n),
        .mem_cke                (mem_cke),
        .mem_ras_n              (mem_ras_n),
        .mem_cas_n              (mem_cas_n),
        .mem_we_n               (mem_we_n),
        .mem_odt                (mem_odt),
        .mem_a                  (mem_a),
        .mem_ba                 (mem_ba),
        .mem_dqs                (mem_dqs),
        .mem_dqs_n              (mem_dqs_n),
        .mem_dq                 (mem_dq),
        .mem_dm                 (mem_dm),

        .dbg_gate_start             (1'b0),
        .dbg_cpd_start              (1'b0),
        .dbg_ddrphy_rst_n           (dbg_phy_rst_n),
        .dbg_gpll_scan_rst          (1'b0),
        .samp_position_dyn_adj      (1'b0),
        .init_samp_position_even    (32'd0),
        .init_samp_position_odd     (32'd0),
        .wrcal_position_dyn_adj     (1'b0),
        .init_wrcal_position        (32'd0),
        .force_read_clk_ctrl        (1'b0),
        .init_slip_step             (16'd0),
        .init_read_clk_ctrl         (12'd0),
        .debug_calib_ctrl           (ddr_debug_calib_ctrl),
        .dbg_slice_status           (ddr_dbg_slice_status),
        .dbg_slice_state            (),
        .debug_data                 (),
        .dbg_dll_upd_state          (),
        .debug_gpll_dps_phase       (),
        .dbg_rst_dps_state          (),
        .dbg_tran_err_rst_cnt       (),
        .dbg_ddrphy_init_fail       (ddr_init_fail),
        .debug_cpd_offset_adj       (1'b0),
        .debug_cpd_offset_dir       (1'b0),
        .debug_cpd_offset           (10'd0),
        .debug_dps_cnt_dir0         (),
        .debug_dps_cnt_dir1         (),
        .ck_dly_en                  (1'b0),
        .init_ck_dly_step           (8'd0),
        .ck_dly_set_bin             (),
        .align_error                (ddr_align_error),
        .debug_rst_state            (),
        .debug_cpd_state            ()
    );

    // ---------------------------------------------------------- framebuffer
    wire        hdmi_rd_en;
    wire        hdmi_rd_vsync;
    wire [11:0] hdmi_x_act;
    wire [11:0] hdmi_y_act;
    wire [15:0] fb_rgb565;
    wire        fb_vout_de;

    fram_buf #(
        .MEM_ROW_WIDTH    (15),
        .MEM_COLUMN_WIDTH (10),
        .MEM_BANK_WIDTH   (3),
        .MEM_DQ_WIDTH     (32),
        .H_NUM            (12'd1280),
        .V_NUM            (12'd720),
        .PIX_WIDTH        (16)
    ) u_fb (
        .vin_clk     (pixel_clk),
        .wr_fsync    (pixel_vsync),
        .wr_en       (pixel_de),
        .wr_data     (pixel_rgb565),
        .init_done   (fb_init_done),

        .ddr_clk     (ddr_core_clk),
        .ddr_rstn    (ddr_init_done),

        .vout_clk    (clk_pix),
        .rd_fsync    (hdmi_rd_vsync),
        .rd_en       (hdmi_rd_en),
        .vout_de     (fb_vout_de),
        .vout_data   (fb_rgb565),

        .axi_awaddr  (fb_awaddr),
        .axi_awid    (fb_awid),
        .axi_awlen   (fb_awlen),
        .axi_awsize  (fb_awsize),
        .axi_awburst (fb_awburst),
        .axi_awready (fb_awready),
        .axi_awvalid (fb_awvalid),

        .axi_wdata   (fb_wdata),
        .axi_wstrb   (fb_wstrb),
        .axi_wlast   (fb_wlast),
        .axi_wvalid  (fb_wvalid),
        .axi_wready  (fb_wready),
        .axi_bid     (4'd0),

        .axi_araddr  (fb_araddr),
        .axi_arid    (fb_arid),
        .axi_arlen   (fb_arlen),
        .axi_arsize  (fb_arsize),
        .axi_arburst (fb_arburst),
        .axi_arvalid (fb_arvalid),
        .axi_arready (fb_arready),

        .axi_rready  (fb_rready),
        .axi_rdata   (fb_rdata),
        .axi_rvalid  (fb_rvalid),
        .axi_rlast   (fb_rlast),
        .axi_rid     (fb_rid)
    );

    // --------------------------------------------------------------- HDMI TX
    video_hdmi_wrap #(
        .USE_EXT_DE (1),
        // Fixed gesture guide window from the standalone demo:
        //   x 520..760, y 254..404, 2 px green border.
        .OSD_BOX   (1),
        .OSD_X0    (12'd520),
        .OSD_Y0    (12'd254),
        .OSD_X1    (12'd760),
        .OSD_Y1    (12'd404),
        .OSD_THICK (12'd2),
        .OSD_COLOR (16'h07E0)
    ) u_hdmi (
        .pix_clk        (clk_pix),
        .pix_rst        (rst_pix),
        .cfg_clk        (clk_cfg),
        .cfg_rst        (rst_cfg),
        .phy_rstn       (phy_rstn),
        .vout_rgb565    (fb_rgb565),
        .ext_de         (fb_vout_de),
        .pattern_mode   (PATTERN_MODE),
        .rd_en          (hdmi_rd_en),
        .rd_vsync       (hdmi_rd_vsync),
        .x_act          (hdmi_x_act),
        .y_act          (hdmi_y_act),
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

    assign rstn_out = phy_rstn;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_ok = &{1'b0,
        fb_awid, fb_awsize, fb_awburst, fb_bready,
        fb_arid, fb_arsize, fb_arburst, fb_rready, fb_rid,
        hdmi_x_act, hdmi_y_act,
        ddr_debug_calib_ctrl, ddr_dbg_slice_status,
        ddr_pll_lock, ddr_phy_pll_lock, ddr_gpll_lock, ddr_rst_gpll_lock,
        ddr_cpd_lock, ddr_align_error};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
