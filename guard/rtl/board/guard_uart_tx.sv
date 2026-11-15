// guard/rtl/board/guard_uart_tx.sv
//
// 8N1 发送器：ready 为高时在 valid 那一拍吃进 data，10 个位时间后回到 idle。
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集（logic/always_ff/always_comb/函数），
// 不用 interface/struct/动态数组。

`timescale 1ns/1ps

module guard_uart_tx #(
    parameter int OV = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       tick,
    input  logic [7:0] data,
    input  logic       valid,
    output logic       ready,       // == !busy
    output logic       tx
);

    localparam logic [7:0] FULL = OV;

    logic [9:0] sh;                 // {stop, data[7:0], start}
    logic [3:0] bit_i;
    logic [7:0] cnt;
    logic       busy;

    assign ready = ~busy;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sh    <= 10'h3FF;
            bit_i <= 4'd0;
            cnt   <= 8'd0;
            busy  <= 1'b0;
            tx    <= 1'b1;
        end else if (!busy) begin
            tx <= 1'b1;
            if (valid) begin
                sh    <= {1'b1, data, 1'b0};
                bit_i <= 4'd0;
                cnt   <= 8'd0;
                busy  <= 1'b1;
                tx    <= 1'b0;      // 起始位
            end
        end else if (tick && (cnt + 8'd1 >= FULL)) begin
            cnt <= 8'd0;
            if (bit_i == 4'd9) begin
                busy <= 1'b0;
                tx   <= 1'b1;
            end else begin
                bit_i <= bit_i + 4'd1;
                tx    <= sh[bit_i + 4'd1];
            end
        end else if (tick) begin
            cnt <= cnt + 8'd1;
        end
    end

endmodule
