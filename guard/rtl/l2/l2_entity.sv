// guard/rtl/l2/l2_entity.sv
//
// L2b 实体层：人名 / 地址（UTF-8 三字节流式，词典 + 线索）。
// 判定与 host/golden/entities.py 一致；表（姓氏/锚点/职务/线索）由
// tools/gen_entity_tables_sv.py 从同一个 Python 文件生成。
//
//   type 9  = name ：姓（64 个）+ 1~2 个汉字；要有名字线索（12 字节内）
//                    或"姓+职务"（王经理/李老师）
//   type 10 = addr ：地址线索（12 字节内）或锚点字起头，累积汉字/数字，
//                    6..48 字节且含锚点字

`timescale 1ns/1ps

module l2_entity (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [3:0]  out_type
);

    import l2_entity_tables::*;

    localparam logic [3:0] T_NAME = 4'd9;
    localparam logic [3:0] T_ADDR = 4'd10;
    localparam int CTX_WINDOW = 12;
    localparam int ADDR_MIN   = 6;
    localparam int ADDR_MAX   = 48;

    // ---------------------------------------------------------------- UTF-8
    logic [1:0]  ph_q;
    logic [7:0]  b0_q, b1_q;
    logic [31:0] pos_q;

    // 必须门控 in_valid：板级 in_char 在 accept=0 时保持不动，若不加这个门，
    // 一个字节会在"间隙"里被当成无数个字符重复处理（板级丢 span 的根因）。
    wire        cjk_done = in_valid && (ph_q == 2'd2) && (in_char >= 8'h80) && (in_char <= 8'hBF);
    wire [23:0] ch       = {b0_q, b1_q, in_char};
    wire [31:0] ch_start = pos_q - 32'd2;

    // 4 个字符的历史（c0 最新）
    logic [23:0] h0_q, h1_q, h2_q, h3_q;
    wire  [1:0]  cue = cue_kind(ch, h0_q, h1_q, h2_q);

    // ---------------------------------------------------------------- 状态
    logic [31:0] nm_cue_end_q, ad_cue_end_q;
    logic        nm_cue_seen_q, ad_cue_seen_q;

    logic        nm_act_q;
    logic [31:0] nm_start_q;
    logic [1:0]  nm_cnt_q;
    logic [23:0] nm_c1_q;
    logic        nm_cued_q;

    logic        ad_act_q;
    logic [31:0] ad_start_q;
    logic [7:0]  ad_len_q;
    logic        ad_anchor_q;

    // 只有"不可能是 CJK 的一部分"的字节才会结束游程（CJK 的前两字节不能收尾）
    wire is_digit_b  = (in_char >= 8'h30) && (in_char <= 8'h39);
    wire is_cjk_lead = (in_char >= 8'hE4) && (in_char <= 8'hE9);
    wire ascii_other = (ph_q == 2'd0) && !is_cjk_lead && !is_digit_b;

    wire nm_cued_now = nm_cue_seen_q && (ch_start >= nm_cue_end_q) &&
                       ((ch_start - nm_cue_end_q) <= 32'(CTX_WINDOW));
    wire ad_cued_now = ad_cue_seen_q && (ch_start >= ad_cue_end_q) &&
                       ((ch_start - ad_cue_end_q) <= 32'(CTX_WINDOW));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ph_q <= 2'd0; b0_q <= 8'd0; b1_q <= 8'd0; pos_q <= 32'd0;
            h0_q <= 24'd0; h1_q <= 24'd0; h2_q <= 24'd0; h3_q <= 24'd0;
            nm_cue_end_q <= 32'd0; ad_cue_end_q <= 32'd0;
            nm_cue_seen_q <= 1'b0; ad_cue_seen_q <= 1'b0;
            nm_act_q <= 1'b0; nm_start_q <= 32'd0; nm_cnt_q <= 2'd0;
            nm_c1_q <= 24'd0; nm_cued_q <= 1'b0;
            ad_act_q <= 1'b0; ad_start_q <= 32'd0; ad_len_q <= 8'd0; ad_anchor_q <= 1'b0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0; out_type <= 4'd0;
        end else begin
            out_valid <= 1'b0;

            if (in_valid) begin
                pos_q <= pos_q + 32'd1;
                case (ph_q)
                    2'd0: if (in_char >= 8'hE4 && in_char <= 8'hE9) begin
                              ph_q <= 2'd1; b0_q <= in_char;
                          end
                    2'd1: if (in_char >= 8'h80 && in_char <= 8'hBF) begin
                              ph_q <= 2'd2; b1_q <= in_char;
                          end else ph_q <= 2'd0;
                    default: ph_q <= 2'd0;
                endcase
            end

            if (cjk_done) begin
                h3_q <= h2_q; h2_q <= h1_q; h1_q <= h0_q; h0_q <= ch;
            end

            // ---- 线索登记（当前字符参与匹配） ----
            if (cjk_done && (cue == 2'd1)) begin
                nm_cue_end_q  <= pos_q + 32'd1;
                nm_cue_seen_q <= 1'b1;
            end
            if (cjk_done && (cue == 2'd2)) begin
                ad_cue_end_q  <= pos_q + 32'd1;
                ad_cue_seen_q <= 1'b1;
            end

            // ---- 地址游程 ----
            if (cjk_done) begin
                if (!ad_act_q) begin
                    if (is_anchor(ch) || ad_cued_now) begin
                        ad_act_q    <= 1'b1;
                        ad_start_q  <= ch_start;
                        ad_len_q    <= 8'd3;
                        ad_anchor_q <= is_anchor(ch);
                    end
                end else begin
                    ad_len_q    <= ad_len_q + 8'd3;
                    ad_anchor_q <= ad_anchor_q || is_anchor(ch);
                end
            end else if (in_valid && is_digit_b) begin
                if (ad_act_q) ad_len_q <= ad_len_q + 8'd1;
            end else if (in_valid && ascii_other) begin
                if (ad_act_q) begin
                    if (ad_anchor_q && (ad_len_q >= 8'(ADDR_MIN)) && (ad_len_q <= 8'(ADDR_MAX))) begin
                        out_valid <= 1'b1;
                        out_start <= ad_start_q;
                        out_len   <= ad_len_q;
                        out_type  <= T_ADDR;
                    end
                    ad_act_q <= 1'b0;
                end
            end

            // ---- 名字游程 ----
            if (cjk_done) begin
                if (!nm_act_q) begin
                    if (is_surname(ch)) begin
                        nm_act_q   <= 1'b1;
                        nm_start_q <= ch_start;
                        nm_cnt_q   <= 2'd1;
                        nm_cued_q  <= nm_cued_now;
                    end
                end else if (nm_cnt_q == 2'd1) begin
                    nm_cnt_q <= 2'd2;
                    nm_c1_q  <= ch;
                end else begin
                    nm_act_q <= 1'b0;
                    nm_cnt_q <= 2'd0;
                    if (nm_cued_q || is_title2(nm_c1_q, ch)) begin
                        out_valid <= 1'b1;
                        out_start <= nm_start_q;
                        out_len   <= 8'd9;
                        out_type  <= T_NAME;
                    end
                end
            end else if (in_valid && ascii_other) begin
                if (nm_act_q) begin
                    if ((nm_cnt_q == 2'd2) && nm_cued_q) begin
                        out_valid <= 1'b1;
                        out_start <= nm_start_q;
                        out_len   <= 8'd6;
                        out_type  <= T_NAME;
                    end
                    nm_act_q <= 1'b0;
                    nm_cnt_q <= 2'd0;
                end
            end

            // ---- 帧尾收尾 ----
            if (in_last) begin
                if (ad_act_q && ad_anchor_q && (ad_len_q >= 8'(ADDR_MIN)) && (ad_len_q <= 8'(ADDR_MAX))) begin
                    out_valid <= 1'b1;
                    out_start <= ad_start_q;
                    out_len   <= ad_len_q;
                    out_type  <= T_ADDR;
                end
                ad_act_q <= 1'b0;
                // 帧尾收名字：姓+1 字且前面有线索
                if (nm_act_q && (nm_cnt_q == 2'd2) && nm_cued_q) begin
                    out_valid <= 1'b1;
                    out_start <= nm_start_q;
                    out_len   <= 8'd6;
                    out_type  <= T_NAME;
                end
                nm_act_q <= 1'b0;
                nm_cnt_q <= 2'd0;
            end
        end
    end

endmodule