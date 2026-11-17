// guard/rtl/board/guard_board_top.sv
//
// 盘古 200Pro+（PG2L200H-6IFBB676）板级顶层：串口进、脱敏、串口出。
//
//   引脚（与 gesture 线已验证的 profile 一致，另补了 UART RX）：
//     clk_27m  D18   27 MHz 板载晶振
//     rst_n    C22   低有效复位
//     uart_rx  B24   USB-UART 接收（ARES 的 MSH/RTOS 顶层用过这个脚）
//     uart_tx  C24   USB-UART 发送
//     led[7:0] A20 C18 C19 E18 A17 A18 C17 B17
//
//   LED：0=收到字节 1=发出字节 2=出错（粘滞） 3=帧未结束 4=命中 span
//        5/6=0  7=PLL 锁定（常亮；不亮说明 PLL 没锁，整块设计还在复位里）
//
// 时钟：27 MHz → PLL → 25 MHz 核心时钟（guard_pll）。
//   2026-11-17 把邮箱/IPv4/USCC 三个引擎改成逐字节增量校验，文本块从
//   −37.9 ns 变成 +22.4 ns（27 MHz）。整板在 **25 MHz** 收敛（WNS 见
//   docs/board-uart.md §2）；25 MHz + OV=8 也够跑 3 Mbaud。
//
// 复位：按键或者 PLL 未锁定都保持复位；进核心时钟域后同步释放。

`timescale 1ns/1ps

module guard_board_top #(
    parameter int CLK_FREQ   = 25_000_000,  // PLL 出来的核心时钟
    parameter int BAUD       = 115200,
    parameter int OV         = 8,           // 过采样倍数：需要 CLK_FREQ > BAUD*OV（8× 够 3 Mbaud）
    parameter int AW         = 8,
    parameter int LF_TO_CRLF = 1,
    parameter int REPORT_EN  = 1,
    parameter int IDLE_BITS  = 300000       // ≈2.6 s @115200：慢慢打字也不会被误判成帧尾
) (
    input  wire       clk_27m,
    input  wire       rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [7:0] led
);

    // ---------------- PLL：27 MHz → 25 MHz ----------------
    wire clk_core;
    wire pll_lock;

    guard_pll u_pll (
        .clkin1 (clk_27m),
        .clkout0(clk_core),
        .lock   (pll_lock)
    );

    // ---------------- 复位：异步置位（按键 / PLL 未锁），同步释放 ----------------
    wire rst_src = ~(rst_n & pll_lock);     // active high

    logic [1:0] rst_sync;
    logic       rst_n_core;

    always @(posedge clk_core or posedge rst_src) begin
        if (rst_src) begin
            rst_sync <= 2'b00;
        end else begin
            rst_sync <= {rst_sync[0], 1'b1};
        end
    end

    assign rst_n_core = rst_sync[1];

    // ---------------- 主体 ----------------
    logic st_rx, st_tx, st_hit, st_busy, st_err;

    guard_uart_core #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD),
        .OV        (OV),
        .AW        (AW),
        .LF_TO_CRLF(LF_TO_CRLF),
        .REPORT_EN (REPORT_EN),
        .IDLE_BITS (IDLE_BITS)
    ) u_core (
        .clk(clk_core), .rst_n(rst_n_core),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .st_rx(st_rx), .st_tx(st_tx), .st_hit(st_hit),
        .st_busy(st_busy), .st_err(st_err), .st_n()
    );

    // ---------------- LED：活动脉冲拉长到 ~100 ms ----------------
    localparam int STRETCH = 21;   // 2^21 / 25 MHz ≈ 84 ms

    logic [STRETCH-1:0] led_rx, led_tx, led_hit;

    always @(posedge clk_core) begin
        if (!rst_n_core) begin
            led_rx  <= '0;
            led_tx  <= '0;
            led_hit <= '0;
        end else begin
            if (st_rx)  led_rx  <= {STRETCH{1'b1}};
            else if (led_rx != 0)  led_rx  <= led_rx  - 1'b1;

            if (st_tx)  led_tx  <= {STRETCH{1'b1}};
            else if (led_tx != 0)  led_tx  <= led_tx  - 1'b1;

            if (st_hit) led_hit <= {STRETCH{1'b1}};
            else if (led_hit != 0) led_hit <= led_hit - 1'b1;
        end
    end

    assign led[0] = |led_rx;
    assign led[1] = |led_tx;
    assign led[2] = st_err;
    assign led[3] = st_busy;
    assign led[4] = |led_hit;
    assign led[5] = 1'b0;
    assign led[6] = 1'b0;
    assign led[7] = pll_lock;      // 上板第一步就看它：常亮 = 时钟/复位正常

endmodule