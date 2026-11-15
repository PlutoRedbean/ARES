// guard/rtl/l1/l1_keyword_match.sv
//
// 关键词提示匹配器：在 12 字节窗口上比对固定关键词表（生成自
// host/golden/keywords.py，见 build/gen/l1_keywords_pkg.sv）。
// 同一结束位置最多一个命中（关键词两两不同长度/不同后缀）。

`timescale 1ns/1ps

module l1_keyword_match (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [2:0]  out_kid
);

    import l1_keywords_pkg::*;

    localparam int WIN = 12;

    logic [31:0]       pos_q;
    logic [WIN-1:0][7:0] win_q;   // win_q[0] 是上一拍的最新字节

    // 当前字符还没进移位寄存器，比较时必须用"下一拍窗口"：
    // wnext[0] = 当前字符，wnext[i] = win_q[i-1]
    logic [WIN-1:0][7:0] wnext;
    always_comb begin
        wnext[0] = in_char;
        for (int i = 1; i < WIN; i++) wnext[i] = win_q[i - 1];
    end

    function automatic logic kw_hit(input int k);
        logic ok;
        int   len;
        ok  = 1'b1;
        len = kw_len(k);
        for (int i = 0; i < KWMAX; i++) begin
            if (i < len && wnext[len - 1 - i] != kw_byte(k, i)) ok = 1'b0;
        end
        kw_hit = ok;
    endfunction

    logic [2:0] hit_kid;
    logic       hit_any;

    always_comb begin
        hit_kid = 3'd0;
        hit_any = 1'b0;
        for (int k = 0; k < NKW; k++) begin
            if (!hit_any && kw_hit(k)) begin
                hit_any = 1'b1;
                hit_kid = 3'(k);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0;
            win_q <= '0;
            out_valid <= 1'b0;
            out_start <= 32'd0;
            out_len   <= 8'd0;
            out_kid   <= 3'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) begin
                for (int i = WIN - 1; i > 0; i--) win_q[i] <= win_q[i - 1];
                win_q[0] <= in_char;
                pos_q <= pos_q + 32'd1;
                if (hit_any && pos_q >= 32'(kw_len(hit_kid)) - 32'd1) begin
                    out_valid <= 1'b1;
                    out_start <= pos_q + 32'd1 - 32'(kw_len(hit_kid));
                    out_len   <= 8'(kw_len(hit_kid));
                    out_kid   <= hit_kid;
                end
            end
        end
    end

endmodule
