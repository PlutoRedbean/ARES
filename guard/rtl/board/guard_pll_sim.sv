// guard/rtl/board/guard_pll_sim.sv
//
// guard_pll 的行为级模型（同名同端口）：Verilator 仿真用这个文件，PDS 用
// guard_pll.v（里面是真 GTP_GPLL）。10 MHz 输出，lock 在 16 个 27 MHz 边沿后拉高。

`timescale 1ns/1ps

module guard_pll (
    output reg  clkout0,   // 10 MHz
    input  wire clkin1,    // 27 MHz
    output reg  lock
);

    initial begin
        clkout0 = 1'b0;
        lock    = 1'b0;
    end

    // 10 MHz -> 周期 100 ns
    always #50.0 clkout0 = ~clkout0;

    reg [4:0] lock_cnt;
    initial lock_cnt = 5'd0;

    always @(posedge clkin1) begin
        if (lock_cnt != 5'h1F) lock_cnt <= lock_cnt + 5'd1;
        else                   lock    <= 1'b1;
    end

endmodule
