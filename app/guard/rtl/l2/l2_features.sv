// guard/rtl/l2/l2_features.sv
//
// L2 特征提取：字节流 + 关键词命中 → 8 个 INT8 特征（数字游程结束时打一拍）。
//
// 与 host/golden/l2_int4.py 的 features_from_hits / dist_bucket 逐条对齐：
//   f0 身份证关键词在窗口内   f1 银行卡   f2 手机号   f3 其它 PII 关键词
//   f4 距离档（0..3）         f5 位数 11..19   f6 前一个字节是 ':' / '='
//   f7 偏置 1
// 窗口 = 关键词结束到游程开始 <= KW_WINDOW 字节。

`timescale 1ns/1ps

module l2_features (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    // 关键词命中（来自 l1_keyword_match，同一拍有效）
    input  logic        kw_valid,
    input  logic [31:0] kw_start,
    input  logic [7:0]  kw_len,
    input  logic [2:0]  kw_kid,

    output logic        feat_valid,
    output logic [63:0] feat,       // 8 × int8（f0 在最低字节）
    output logic [31:0] run_start,
    output logic [7:0]  run_len
);

    // 组合特征 + 寄存器化输出（feat_valid 与 payload 同拍对齐）
    logic [63:0] feat_comb;
    logic [63:0] feat_q;
    logic [31:0] rs_out_q;
    logic [7:0]  rl_out_q;

    assign feat      = feat_q;
    assign run_start = rs_out_q;
    assign run_len   = rl_out_q;

    localparam logic [31:0] KW_WINDOW = 32'd12;

    logic [31:0] pos_q;
    logic [7:0]  prev_q;

    // 每个"桶"最近一次关键词命中：0=身份证 1=银行卡 2=手机号 3=其它
    logic [31:0] ke0_q, ke1_q, ke2_q, ke3_q;
    logic        k0_q,  k1_q,  k2_q,  k3_q;

    logic        run_q;
    logic [31:0] rs_q;
    logic [7:0]  rn_q;

    wire is_digit = (in_char >= 8'h30) && (in_char <= 8'h39);

    // ---- 关键词登记 ----
    wire [31:0] kw_end = kw_start + {24'd0, kw_len};

    // ---- 游程结束时的特征（组合，只在 feat_valid 那一拍被采样） ----
    logic        near0, near1, near2, near3;
    logic [31:0] d0, d1, d2, d3, dmin;
    logic [1:0]  dist_b;

    always_comb begin
        d0 = rs_q - ke0_q;
        d1 = rs_q - ke1_q;
        d2 = rs_q - ke2_q;
        d3 = rs_q - ke3_q;

        near0 = k0_q && (rs_q >= ke0_q) && (d0 <= KW_WINDOW);
        near1 = k1_q && (rs_q >= ke1_q) && (d1 <= KW_WINDOW);
        near2 = k2_q && (rs_q >= ke2_q) && (d2 <= KW_WINDOW);
        near3 = k3_q && (rs_q >= ke3_q) && (d3 <= KW_WINDOW);

        dmin = 32'd99;
        if (near0 && d0 < dmin) dmin = d0;
        if (near1 && d1 < dmin) dmin = d1;
        if (near2 && d2 < dmin) dmin = d2;
        if (near3 && d3 < dmin) dmin = d3;

        if      (dmin <= 32'd2)  dist_b = 2'd0;
        else if (dmin <= 32'd5)  dist_b = 2'd1;
        else if (dmin <= KW_WINDOW) dist_b = 2'd2;
        else                     dist_b = 2'd3;

        feat_comb[7:0]   = {7'd0, near0};
        feat_comb[15:8]  = {7'd0, near1};
        feat_comb[23:16] = {7'd0, near2};
        feat_comb[31:24] = {7'd0, near3};
        feat_comb[39:32] = {6'd0, dist_b};
        feat_comb[47:40] = {7'd0, (rn_q >= 8'd11) && (rn_q <= 8'd19)};
        feat_comb[55:48] = {7'd0, (prev_q == 8'h3A) || (prev_q == 8'h3D)};
        feat_comb[63:56] = 8'd1;
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0;
            prev_q <= 8'd0;
            ke0_q <= 32'd0; ke1_q <= 32'd0; ke2_q <= 32'd0; ke3_q <= 32'd0;
            k0_q <= 1'b0; k1_q <= 1'b0; k2_q <= 1'b0; k3_q <= 1'b0;
            run_q <= 1'b0;
            rs_q <= 32'd0;
            rn_q <= 8'd0;
            feat_valid <= 1'b0;
            feat_q <= 64'd0;
            rs_out_q <= 32'd0;
            rl_out_q <= 8'd0;
        end else begin
            feat_valid <= 1'b0;

            if (in_valid) pos_q <= pos_q + 32'd1;

            // 关键词登记（先于游程处理，同一拍的关键词对后面的游程可见）
            if (kw_valid) begin
                case (kw_kid)
                    3'd0: begin ke0_q <= kw_end; k0_q <= 1'b1; end
                    3'd1: begin ke1_q <= kw_end; k1_q <= 1'b1; end
                    3'd2: begin ke2_q <= kw_end; k2_q <= 1'b1; end
                    default: begin ke3_q <= kw_end; k3_q <= 1'b1; end
                endcase
            end

            if (in_last) begin
                if (run_q) begin
                    feat_q      <= feat_comb;
                    rs_out_q    <= rs_q;
                    rl_out_q    <= rn_q;
                    feat_valid  <= 1'b1;
                    run_q       <= 1'b0;
                end
                prev_q <= in_char;
                // 新一帧：关键词窗口清空（与金标"逐帧扫"一致）
                k0_q <= 1'b0; k1_q <= 1'b0; k2_q <= 1'b0; k3_q <= 1'b0;
                rn_q <= 8'd0;
            end else if (in_valid) begin
                if (is_digit) begin
                    if (!run_q) begin
                        run_q <= 1'b1;
                        rs_q  <= pos_q;
                        rn_q  <= 8'd1;
                    end else begin
                        rn_q <= rn_q + 8'd1;
                    end
                end else begin
                    if (run_q) begin
                        feat_q     <= feat_comb;
                        rs_out_q   <= rs_q;
                        rl_out_q   <= rn_q;
                        feat_valid <= 1'b1;
                        run_q      <= 1'b0;
                        rn_q       <= 8'd0;
                    end
                end
                prev_q <= in_char;
            end
        end
    end

endmodule
