// guard/rtl/board/guard_uart_rx.sv
//
// 8N1 接收器：16 倍过采样、位中部采样、起始位复检、帧错误上报。
// 引脚先过两级同步；异步输入不在时序路径上（fdc 对 uart_rx 设了 false path）。
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集（logic/always_ff/always_comb/函数），
// 不用 interface/struct/动态数组。

`timescale 1ns/1ps

module guard_uart_rx #(
    parameter int OV = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,          // 原始引脚
    input  logic       tick,        // OV * BAUD
    output logic [7:0] data,
    output logic       valid,       // 1 拍
    output logic       frame_err    // 1 拍：停止位为低
);

    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_START = 2'd1;
    localparam logic [1:0] S_DATA  = 2'd2;
    localparam logic [1:0] S_STOP  = 2'd3;
    localparam logic [7:0] HALF = OV / 2;
    localparam logic [7:0] FULL = OV;

    logic rx_s0, rx_s1;
    logic [1:0] st;
    logic [7:0] cnt;
    logic [2:0] bit_i;
    logic [7:0] sh;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1;
            rx_s1 <= 1'b1;
        end else begin
            rx_s0 <= rx;
            rx_s1 <= rx_s0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 8'd0;
            bit_i     <= 3'd0;
            sh        <= 8'd0;
            data      <= 8'd0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            valid     <= 1'b0;
            frame_err <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (!rx_s1) begin
                        st  <= S_START;
                        cnt <= 8'd0;
                    end
                end
                S_START: begin
                    if (tick) begin
                        if (cnt + 8'd1 >= HALF) begin
                            cnt <= 8'd0;
                            if (!rx_s1) begin       // 半位后仍为低：真起始位
                                st    <= S_DATA;
                                bit_i <= 3'd0;
                            end else begin
                                st <= S_IDLE;       // 毛刺
                            end
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end
                S_DATA: begin
                    if (tick) begin
                        if (cnt + 8'd1 >= FULL) begin
                            cnt       <= 8'd0;
                            sh[bit_i] <= rx_s1;     // 位中部
                            if (bit_i == 3'd7) st <= S_STOP;
                            else               bit_i <= bit_i + 3'd1;
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end
                S_STOP: begin
                    if (tick) begin
                        if (cnt + 8'd1 >= FULL) begin
                            cnt <= 8'd0;
                            st  <= S_IDLE;
                            if (rx_s1) begin
                                data  <= sh;
                                valid <= 1'b1;
                            end else begin
                                frame_err <= 1'b1;
                            end
                        end else begin
                            cnt <= cnt + 8'd1;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
