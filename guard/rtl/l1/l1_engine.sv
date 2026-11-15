// guard/rtl/l1/l1_engine.sv
//
// L1 顶层：把 5 个引擎挂到同一字符流上。每个引擎各自输出命中脉冲
// （start/len，digit 引擎额外带 type）。重叠命中不在这一层合并——
// 那是 M2 的策略（替换器/审计）要做的事。
//
// 端口按类型分组，便于测试台逐类型比对；M2 的合并器会在这里接一个
// "命中聚合 + 优先级"模块。

`timescale 1ns/1ps

module l1_engine (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    // 数字类（身份证/手机/银行卡），type: 1..4
    output logic        digit_valid,
    output logic [31:0] digit_start,
    output logic [7:0]  digit_len,
    output logic [2:0]  digit_type,

    // 邮箱
    output logic        email_valid,
    output logic [31:0] email_start,
    output logic [7:0]  email_len,

    // IPv4
    output logic        ipv4_valid,
    output logic [31:0] ipv4_start,
    output logic [7:0]  ipv4_len,

    // 统一社会信用代码
    output logic        uscc_valid,
    output logic [31:0] uscc_start,
    output logic [7:0]  uscc_len,

    // 车牌
    output logic        plate_valid,
    output logic [31:0] plate_start,
    output logic [7:0]  plate_len,

    // 关键词提示（kid 见 host/golden/keywords.py）
    output logic        kw_valid,
    output logic [31:0] kw_start,
    output logic [7:0]  kw_len,
    output logic [2:0]  kw_kid
);

    l1_digit_engine u_digit (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(digit_valid),
        .out_start(digit_start),
        .out_len  (digit_len),
        .out_type (digit_type)
    );

    l1_email_engine u_email (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(email_valid),
        .out_start(email_start),
        .out_len  (email_len)
    );

    l1_ipv4_engine u_ipv4 (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(ipv4_valid),
        .out_start(ipv4_start),
        .out_len  (ipv4_len)
    );

    l1_uscc_engine u_uscc (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(uscc_valid),
        .out_start(uscc_start),
        .out_len  (uscc_len)
    );

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

    l1_plate_engine u_plate (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_char  (in_char),
        .in_last  (in_last),
        .out_valid(plate_valid),
        .out_start(plate_start),
        .out_len  (plate_len)
    );

endmodule
