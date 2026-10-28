// ---------------------------------------------------------------------------
// video_bist_top - standalone DDR3 BIST for the Pangu 200Pro+
//
// System PLL -> phy_rstn, DDR3 IP (125 MHz ref, 800 Mbps) -> BIST master.
//
// Result on LEDs (see fpga/pango/README.md):
//   led[0] heartbeat            led[4] ddr_init_done
//   led[1] system PLL lock      led[5] dbg_ddrphy_init_fail
//   led[2] DDR3 PLL lock        led[6] BIST error (latched)
//   led[3] ddrphy_cpd_lock      led[7] BIST pass (>=1 pass, no error)
//
// The UART prints a full BIST status line once per ~0.5 s:
//   BIST I=1 F=0 A=0 G=0 D=1 E=0 P=0000000A C=00000000 X=0000000
//
// The DDR3 IP instance MUST be named I_ips_ddr_top at this level: the IP
// constraint file uses that absolute path.
// ---------------------------------------------------------------------------
module video_bist_top #(
    // Set to 1 only for the BIST self-test build: flips one expected data bit
    // so the error path can be observed on the board.
    parameter integer BIST_INJECT_FAULT = 0
) (
    input  wire        clk_27m,
    input  wire        rst_n,

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

    output wire [7:0]  led,
    output wire        uart_tx
);

    // ------------------------------------------------------- clock / reset
    wire pll_lock;
    wire rst_sys;
    wire phy_rstn;

    video_clk_reset u_clk_reset (
        .clk_27m  (clk_27m),
        .rst_n    (rst_n),
        .clk_pix  (),
        .clk_cfg  (),
        .clk_cam  (),
        .pll_lock (pll_lock),
        .rst_sys  (rst_sys),
        .rst_pix  (),
        .rst_cfg  (),
        .rst_cam  (),
        .phy_rstn (phy_rstn)
    );

    // ------------------------------------------------------ DDR3 reference
    wire ref_clk_125m;

    GTP_INBUFGDS u_refclk_buf (
        .O  (ref_clk_125m),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    // ------------------------------------------------------------ DDR3 IP
    wire        core_clk;
    wire        ddr_init_done;
    wire        ddr_pll_lock;
    wire        ddr_phy_pll_lock;
    wire        ddr_gpll_lock;
    wire        ddr_rst_gpll_lock;
    wire        ddr_cpd_lock;
    wire        ddr_init_fail;
    wire        ddr_align_error;
    wire [33:0] ddr_debug_calib_ctrl;
    wire [67:0] ddr_dbg_slice_status;
    wire [27:0] bist_awaddr;
    wire [3:0]  bist_awlen;
    wire        bist_awvalid;
    wire        bist_awready;
    wire [255:0] bist_wdata;
    wire [31:0] bist_wstrb;
    wire        bist_wvalid;
    wire        bist_wready;
    wire [27:0] bist_araddr;
    wire [3:0]  bist_arlen;
    wire        bist_arvalid;
    wire        bist_arready;
    wire [255:0] bist_rdata;
    wire        bist_rvalid;
    wire        bist_rlast;

    ddr3_test I_ips_ddr_top (
        .ref_clk                (ref_clk_125m),
        .resetn                 (phy_rstn),
        .core_clk               (core_clk),
        .pll_lock               (ddr_pll_lock),
        .phy_pll_lock           (ddr_phy_pll_lock),
        .gpll_lock              (ddr_gpll_lock),
        .rst_gpll_lock          (ddr_rst_gpll_lock),
        .ddrphy_cpd_lock        (ddr_cpd_lock),
        .ddr_init_done          (ddr_init_done),

        .axi_awaddr             (bist_awaddr),
        .axi_awuser_ap          (1'b0),
        .axi_awuser_id          (4'd0),
        .axi_awlen              (bist_awlen),
        .axi_awready            (bist_awready),
        .axi_awvalid            (bist_awvalid),

        .axi_wdata              (bist_wdata),
        .axi_wstrb              (bist_wstrb),
        .axi_wready             (bist_wready),
        .axi_wusero_id          (),
        .axi_wusero_last        (),

        .axi_araddr             (bist_araddr),
        .axi_aruser_ap          (1'b0),
        .axi_aruser_id          (4'd0),
        .axi_arlen              (bist_arlen),
        .axi_arready            (bist_arready),
        .axi_arvalid            (bist_arvalid),

        .axi_rdata              (bist_rdata),
        .axi_rid                (),
        .axi_rlast              (bist_rlast),
        .axi_rvalid             (bist_rvalid),

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

        // Debug / calibration: safe static values.
        .dbg_gate_start             (1'b0),
        .dbg_cpd_start              (1'b0),
        .dbg_ddrphy_rst_n           (1'b1),
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

    // --------------------------------------------------------------- BIST
    wire        bist_done;
    wire        bist_error;
    wire [31:0] bist_pass_cnt;
    wire [31:0] bist_error_cnt;
    wire [27:0] bist_error_addr;
    wire [3:0]  bist_error_beat;
    wire [31:0] bist_error_expected;
    wire [31:0] bist_error_actual;
    wire [1:0]  bist_pat_sel;

    video_ddr3_bist #(
        .INJECT_FAULT (BIST_INJECT_FAULT)
    ) u_bist (
        .clk           (core_clk),
        .rst           (~ddr_init_done),
        .start         (ddr_init_done),
        .done          (bist_done),
        .error         (bist_error),
        .pass_cnt      (bist_pass_cnt),
        .error_cnt     (bist_error_cnt),
        .error_addr    (bist_error_addr),
        .error_beat    (bist_error_beat),
        .error_expected(bist_error_expected),
        .error_actual  (bist_error_actual),
        .pat_sel       (bist_pat_sel),
        .axi_awaddr    (bist_awaddr),
        .axi_awlen     (bist_awlen),
        .axi_awvalid   (bist_awvalid),
        .axi_awready   (bist_awready),
        .axi_wdata     (bist_wdata),
        .axi_wstrb     (bist_wstrb),
        .axi_wvalid    (bist_wvalid),
        .axi_wready    (bist_wready),
        .axi_araddr    (bist_araddr),
        .axi_arlen     (bist_arlen),
        .axi_arvalid   (bist_arvalid),
        .axi_arready   (bist_arready),
        .axi_rdata     (bist_rdata),
        .axi_rvalid    (bist_rvalid),
        .axi_rlast     (bist_rlast)
    );

    // ------------------------------------------------------------- status
    // BIST counters change at most once per ~0.14 s pass, i.e. much slower
    // than the 27 MHz status domain; two flops per bit is sufficient here.
    reg [1:0] ddr_init_sync;
    reg [1:0] ddr_pll_sync;
    reg [1:0] ddr_cpd_sync;
    reg [1:0] ddr_init_fail_sync;
    reg [1:0] ddr_align_sync;
    reg [1:0] bist_error_sync;
    reg [1:0] bist_done_sync;
    reg [3:0] dbg_err_sync;

    reg [31:0] pass_cnt_sync;
    reg [31:0] error_cnt_sync;
    reg [27:0] error_addr_sync;
    reg [3:0]  error_beat_sync;
    reg [31:0] error_expected_sync;
    reg [31:0] error_actual_sync;

    always @(posedge clk_27m) begin
        ddr_init_sync      <= {ddr_init_sync[0], ddr_init_done};
        ddr_pll_sync       <= {ddr_pll_sync[0], ddr_pll_lock};
        ddr_cpd_sync       <= {ddr_cpd_sync[0], ddr_cpd_lock};
        ddr_init_fail_sync <= {ddr_init_fail_sync[0], ddr_init_fail};
        ddr_align_sync     <= {ddr_align_sync[0], ddr_align_error};
        bist_error_sync    <= {bist_error_sync[0], bist_error};
        bist_done_sync     <= {bist_done_sync[0], bist_done};
        // debug_calib_ctrl is static after training; sample it in sys domain.
        dbg_err_sync       <= ddr_debug_calib_ctrl[33:30];

        pass_cnt_sync       <= bist_pass_cnt;
        error_cnt_sync      <= bist_error_cnt;
        error_addr_sync     <= bist_error_addr;
        error_beat_sync     <= bist_error_beat;
        error_expected_sync <= bist_error_expected;
        error_actual_sync   <= bist_error_actual;
    end

    video_bist_status u_status (
        .clk_27m         (clk_27m),
        .rst_sys         (rst_sys),
        .sys_pll_lock    (pll_lock),
        .ddr_pll_lock    (ddr_pll_sync[1]),
        .ddr_cpd_lock    (ddr_cpd_sync[1]),
        .init_done       (ddr_init_sync[1]),
        .init_fail       (ddr_init_fail_sync[1]),
        .align_error     (ddr_align_sync[1]),
        .calib_status    (dbg_err_sync),
        .bist_done       (bist_done_sync[1]),
        .bist_error      (bist_error_sync[1]),
        .bist_pass_cnt   (pass_cnt_sync),
        .bist_error_cnt  (error_cnt_sync),
        .bist_error_addr (error_addr_sync),
        .bist_error_beat (error_beat_sync),
        .bist_error_expected (error_expected_sync),
        .bist_error_actual   (error_actual_sync),
        .led             (led),
        .uart_tx         (uart_tx)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_ok = &{1'b0, bist_pat_sel, ddr_dbg_slice_status,
        ddr_phy_pll_lock, ddr_gpll_lock, ddr_rst_gpll_lock};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
