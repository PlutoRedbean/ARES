// guard/rtl/board/guard_uart_baud.sv
//
// 分数分频波特率发生器：平均频率 = BAUD，输出 OV 倍过采样 tick。
// 10 MHz / 115200 = 86.8055… 不是整数；整数分频差 0.22%，长报文会累积到半个
// 位宽以上。这里用相位累加器，任意 (CLK_FREQ, BAUD) 都没有累积误差。
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集（logic/always_ff/always_comb/函数），
// 不用 interface/struct/动态数组。

`timescale 1ns/1ps

module guard_uart_baud #(
    parameter int CLK_FREQ = 10_000_000,
    parameter int BAUD     = 115200,
    parameter int OV       = 16
) (
    input  logic clk,
    input  logic rst_n,
    output logic tick          // 每时钟最多 1 拍，平均频率 BAUD*OV
);

    localparam logic [31:0] CLK  = CLK_FREQ;
    localparam logic [31:0] STEP = BAUD * OV;

    logic [31:0] acc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc  <= 32'd0;
            tick <= 1'b0;
        end else if (acc + STEP >= CLK) begin
            acc  <= acc + STEP - CLK;
            tick <= 1'b1;
        end else begin
            acc  <= acc + STEP;
            tick <= 1'b0;
        end
    end

endmodule
