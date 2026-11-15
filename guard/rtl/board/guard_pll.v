// guard/rtl/board/guard_pll.v
//
// PDS 综合用的 PLL 包装：27 MHz 晶振 → 10 MHz 核心时钟。
//
// 为什么不是 27 MHz：L1 规则层的校验链（19 位 Luhn / 17 位加权和 / 64 字节
// 邮箱扫描）是单周期组合逻辑，PDS 2025.2 实测最差路径 ~75 ns，27 MHz（37 ns）
// 不收敛。UART 只要 ~1.8 MHz 就能 16× 过采样 115200，所以把核心压到 10 MHz，
// 带宽仍是 10 MB/s（≈ 87 倍 UART 线速）。把校验链流水化后可以回到 27/50 MHz，
// 见 docs/board-uart.md §2。
//
// 参数沿用 ARES 板上已验证的 GTP_GPLL 配置（VCO = 27 MHz × 2 × 18.5185 = 1000 MHz）：
//   CLKOUT0 = 1000 / 100.0 = 10 MHz
//
// 仿真用 guard_pll_sim.sv（同名同端口），PDS 用本文件。

`timescale 1ns / 10fs

module guard_pll (
    output wire clkout0,   // 10 MHz 核心时钟
    input  wire clkin1,    // 27 MHz 板载时钟
    output wire lock
);

    localparam real    CLKIN_FREQ       = 27.0;
    localparam         LOCK_MODE        = 0;
    localparam integer STATIC_RATIOI    = 1;
    localparam integer STATIC_RATIOM    = 2;
    localparam real    STATIC_RATIO0    = 100.0;
    localparam real    STATIC_RATIO1    = 20.0;
    localparam integer STATIC_RATIO2    = 21;
    localparam integer STATIC_RATIO3    = 21;
    localparam integer STATIC_RATIO4    = 21;
    localparam integer STATIC_RATIO5    = 21;
    localparam integer STATIC_RATIO6    = 21;
    localparam real    STATIC_RATIOF    = 18.5185;
    localparam integer STATIC_DUTY0     = 100;
    localparam integer STATIC_DUTY1     = 20;
    localparam integer STATIC_DUTY2     = 21;
    localparam integer STATIC_DUTY3     = 21;
    localparam integer STATIC_DUTY4     = 21;
    localparam integer STATIC_DUTY5     = 21;
    localparam integer STATIC_DUTY6     = 21;
    localparam integer STATIC_DUTYF     = 19;
    localparam integer STATIC_PHASE     = 0;
    localparam integer STATIC_PHASE0    = 0;
    localparam integer STATIC_PHASE1    = 0;
    localparam integer STATIC_PHASE2    = 0;
    localparam integer STATIC_PHASE3    = 0;
    localparam integer STATIC_PHASE4    = 0;
    localparam integer STATIC_PHASE5    = 0;
    localparam integer STATIC_PHASE6    = 0;
    localparam integer STATIC_PHASEF    = 0;
    localparam integer STATIC_CPHASE0   = 0;
    localparam integer STATIC_CPHASE1   = 0;
    localparam integer STATIC_CPHASE2   = 0;
    localparam integer STATIC_CPHASE3   = 0;
    localparam integer STATIC_CPHASE4   = 0;
    localparam integer STATIC_CPHASE5   = 0;
    localparam integer STATIC_CPHASE6   = 0;
    localparam integer STATIC_CPHASEF   = 0;

    wire clkin2    = 1'b0;
    wire clkfb     = 1'b0;
    wire clkin_sel = 1'b0;
    wire dps_clk   = 1'b0;
    wire dps_en    = 1'b0;
    wire dps_dir   = 1'b0;
    wire pll_pwd   = 1'b0;
    wire rst       = 1'b0;
    wire apb_clk   = 1'b0;
    wire apb_rst_n = 1'b0;
    wire [4:0]  apb_addr  = 5'd0;
    wire        apb_sel   = 1'b0;
    wire        apb_en    = 1'b0;
    wire        apb_write = 1'b0;
    wire [15:0] apb_wdata = 16'd0;

    wire clkout0_syn = 1'b0;
    wire clkout1_syn = 1'b0;
    wire clkout2_syn = 1'b0;
    wire clkout3_syn = 1'b0;
    wire clkout4_syn = 1'b0;
    wire clkout5_syn = 1'b0;
    wire clkout6_syn = 1'b0;
    wire clkoutf_syn = 1'b0;

    GTP_GPLL #(
        .CLKIN_FREQ      (CLKIN_FREQ    ),
        .LOCK_MODE       (LOCK_MODE     ),
        .STATIC_RATIOI   (STATIC_RATIOI ),
        .STATIC_RATIOM   (STATIC_RATIOM ),
        .STATIC_RATIO0   (STATIC_RATIO0 ),
        .STATIC_RATIO1   (STATIC_RATIO1 ),
        .STATIC_RATIO2   (STATIC_RATIO2 ),
        .STATIC_RATIO3   (STATIC_RATIO3 ),
        .STATIC_RATIO4   (STATIC_RATIO4 ),
        .STATIC_RATIO5   (STATIC_RATIO5 ),
        .STATIC_RATIO6   (STATIC_RATIO6 ),
        .STATIC_RATIOF   (STATIC_RATIOF ),
        .STATIC_DUTY0    (STATIC_DUTY0  ),
        .STATIC_DUTY1    (STATIC_DUTY1  ),
        .STATIC_DUTY2    (STATIC_DUTY2  ),
        .STATIC_DUTY3    (STATIC_DUTY3  ),
        .STATIC_DUTY4    (STATIC_DUTY4  ),
        .STATIC_DUTY5    (STATIC_DUTY5  ),
        .STATIC_DUTY6    (STATIC_DUTY6  ),
        .STATIC_DUTYF    (STATIC_DUTYF  ),
        .STATIC_PHASE    (STATIC_PHASE  ),
        .STATIC_PHASE0   (STATIC_PHASE0 ),
        .STATIC_PHASE1   (STATIC_PHASE1 ),
        .STATIC_PHASE2   (STATIC_PHASE2 ),
        .STATIC_PHASE3   (STATIC_PHASE3 ),
        .STATIC_PHASE4   (STATIC_PHASE4 ),
        .STATIC_PHASE5   (STATIC_PHASE5 ),
        .STATIC_PHASE6   (STATIC_PHASE6 ),
        .STATIC_PHASEF   (STATIC_PHASEF ),
        .STATIC_CPHASE0  (STATIC_CPHASE0),
        .STATIC_CPHASE1  (STATIC_CPHASE1),
        .STATIC_CPHASE2  (STATIC_CPHASE2),
        .STATIC_CPHASE3  (STATIC_CPHASE3),
        .STATIC_CPHASE4  (STATIC_CPHASE4),
        .STATIC_CPHASE5  (STATIC_CPHASE5),
        .STATIC_CPHASE6  (STATIC_CPHASE6),
        .STATIC_CPHASEF  (STATIC_CPHASEF),
        .CLK_DPS0_EN     ("FALSE"),
        .CLK_DPS1_EN     ("FALSE"),
        .CLK_DPS2_EN     ("FALSE"),
        .CLK_DPS3_EN     ("FALSE"),
        .CLK_DPS4_EN     ("FALSE"),
        .CLK_DPS5_EN     ("FALSE"),
        .CLK_DPS6_EN     ("FALSE"),
        .CLK_DPSF_EN     ("FALSE"),
        .CLK_CAS5_EN     ("FALSE"),
        .CLKOUT0_SYN_EN  ("FALSE"),
        .CLKOUT1_SYN_EN  ("FALSE"),
        .CLKOUT2_SYN_EN  ("FALSE"),
        .CLKOUT3_SYN_EN  ("FALSE"),
        .CLKOUT4_SYN_EN  ("FALSE"),
        .CLKOUT5_SYN_EN  ("FALSE"),
        .CLKOUT6_SYN_EN  ("FALSE"),
        .CLKOUTF_SYN_EN  ("FALSE"),
        .SSC_MODE        ("DISABLE"),
        .SSC_FREQ        (25),
        .INTERNAL_FB     ("CLKOUTF"),
        .EXTERNAL_FB     ("DISABLE"),
        .BANDWIDTH       ("OPTIMIZED")
    ) u_gpll (
        .CLKOUT0        (clkout0),
        .CLKOUT1        (),
        .LOCK           (lock),
        .CLKIN1         (clkin1),
        .CLKIN2         (clkin2),
        .CLKFB          (clkfb),
        .CLKIN_SEL      (clkin_sel),
        .CLKOUT0_SYN    (clkout0_syn),
        .CLKOUT1_SYN    (clkout1_syn),
        .CLKOUT2_SYN    (clkout2_syn),
        .CLKOUT3_SYN    (clkout3_syn),
        .CLKOUT4_SYN    (clkout4_syn),
        .CLKOUT5_SYN    (clkout5_syn),
        .CLKOUT6_SYN    (clkout6_syn),
        .CLKOUTF_SYN    (clkoutf_syn),
        .DPS_CLK        (dps_clk),
        .DPS_EN         (dps_en),
        .DPS_DIR        (dps_dir),
        .PLL_PWD        (pll_pwd),
        .RST            (rst),
        .APB_CLK        (apb_clk),
        .APB_RST_N      (apb_rst_n),
        .APB_ADDR       (apb_addr),
        .APB_SEL        (apb_sel),
        .APB_EN         (apb_en),
        .APB_WRITE      (apb_write),
        .APB_WDATA      (apb_wdata)
    );

endmodule
