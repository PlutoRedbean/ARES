// guard/rtl/l2/l2_semantic_top.sv
//
// L2 语义层顶层：字节流 -> 关键词窗口 + 数字游程 -> INT8 特征
//              -> miniTensor MXU 上的 INT4 GEMM -> 4 类
//
// 输出与 L1 的检测并行、互不影响：L1 用校验位/结构，L2 用上下文语义。
// 现在 L2 只"报"（class + span），不参与替换；接进摘要行是下一步。

`timescale 1ns/1ps

module l2_semantic_top (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    output logic        out_valid,
    output logic [1:0]  out_class,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [31:0] out_s0,
    output logic [31:0] out_s1,
    output logic [31:0] out_s2,
    output logic [31:0] out_s3
);

    wire        kw_valid;
    wire [31:0] kw_start;
    wire [7:0]  kw_len;
    wire [2:0]  kw_kid;

    l1_keyword_match u_kw (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(kw_valid),
        .out_start(kw_start),
        .out_len  (kw_len),
        .out_kid  (kw_kid)
    );

    wire        f_valid;
    wire [63:0] feat;
    wire [31:0] f_start;
    wire [7:0]  f_len;

    l2_features u_feat (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .kw_valid (kw_valid),
        .kw_start (kw_start),
        .kw_len   (kw_len),
        .kw_kid   (kw_kid),
        .feat_valid(f_valid),
        .feat     (feat),
        .run_start(f_start),
        .run_len  (f_len)
    );

    wire        g_valid;
    wire [1:0]  g_class;

    l2_int4_gemm u_gemm (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (f_valid),
        .in_feat  (feat),
        .out_valid(g_valid),
        .out_class(g_class),
        .out_s0   (out_s0),
        .out_s1   (out_s1),
        .out_s2   (out_s2),
        .out_s3   (out_s3)
    );

    // GEMM 要跑十几个周期，span 得跟着握手拍存住
    logic [31:0] start_q;
    logic [7:0]  len_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            start_q <= 32'd0;
            len_q   <= 8'd0;
        end else if (f_valid) begin
            start_q <= f_start;
            len_q   <= f_len;
        end
    end

    assign out_valid = g_valid;
    assign out_class = g_class;
    assign out_start = start_q;
    assign out_len   = len_q;

endmodule
