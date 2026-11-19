// guard/rtl/board/guard_fifo.sv
//
// 8 位同步 FIFO（first-word-fall-through）：dout 直接指向队首，pop 才前进。
// level 由 wptr/rptr 相减得到（指针多一位做满/空区分）。
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集（logic/always_ff/always_comb/函数），
// 不用 interface/struct/动态数组。

`timescale 1ns/1ps

module guard_fifo #(
    parameter int AW = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  din,
    input  logic        push,
    input  logic        pop,
    output logic [7:0]  dout,
    output logic        empty,
    output logic        full,
    output logic [AW:0] level
);

    localparam int DEPTH = 1 << AW;

    logic [7:0]  mem [0:DEPTH-1];
    logic [AW:0] wptr, rptr;

    wire do_push = push && !full;
    wire do_pop  = pop  && !empty;

    assign empty = (wptr == rptr);
    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    assign dout  = mem[rptr[AW-1:0]];
    assign level = wptr - rptr;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
            rptr <= '0;
        end else begin
            if (do_push) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            if (do_pop) begin
                rptr <= rptr + 1'b1;
            end
        end
    end

endmodule
