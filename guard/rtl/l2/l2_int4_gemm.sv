// guard/rtl/l2/l2_int4_gemm.sv
//
// L2 推理：8 个 INT8 特征 → INT4 权重 → 4 类分数，用的就是 miniTensor 的
// 4x4 INT8 脉动阵列（vendor/minitensor/rtl/tensor/MXU/INT8_GEMM/tensor_gemm_core.sv）。
//
// 权重是 W4（INT4，-8..7），在打包进 A 矩阵时符号扩展到 INT8 —— 即 W4A8。
// K=8 超过阵列的 K=4，所以做两次 GEMM 并把第一次的 C 当作第二次的 acc_init。
//
//   C = W * x            两次 K=4 的 GEMM，acc 串联
//   y_c = C[c][0]        四列结果相同，取第 0 列
//   class = argmax_c y_c （并列/全非正 → 0 = none）

`timescale 1ns/1ps

module l2_int4_gemm (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [63:0] in_feat,     // 8 × int8
    output logic        out_valid,
    output logic [1:0]  out_class,
    output logic [31:0] out_s0,
    output logic [31:0] out_s1,
    output logic [31:0] out_s2,
    output logic [31:0] out_s3
);

    import tensor_pkg::*;

    // ---------------- INT4 权重表（与 host/golden/l2_int4.py 的 W_INT4 同源） ----
    //  行 = 类别（0 none / 1 id18 / 2 bank / 3 mobile）
    //  列 = 特征（k_id k_bank k_mob k_other dist len colon bias）
    function automatic logic signed [7:0] w4(input logic [1:0] c, input logic [2:0] f);
        case ({c, f})
            5'd0:  w4 = 8'sd0;  5'd1:  w4 = 8'sd0;  5'd2:  w4 = 8'sd0;  5'd3:  w4 = 8'sd0;
            5'd4:  w4 = 8'sd0;  5'd5:  w4 = 8'sd0;  5'd6:  w4 = 8'sd0;  5'd7:  w4 = 8'sd2;
            5'd8:  w4 = 8'sd6;  5'd9:  w4 = -8'sd6; 5'd10: w4 = -8'sd6; 5'd11: w4 = -8'sd6;
            5'd12: w4 = -8'sd2; 5'd13: w4 = 8'sd1;  5'd14: w4 = 8'sd0;  5'd15: w4 = 8'sd0;
            5'd16: w4 = -8'sd6; 5'd17: w4 = 8'sd6;  5'd18: w4 = -8'sd6; 5'd19: w4 = -8'sd6;
            5'd20: w4 = -8'sd2; 5'd21: w4 = 8'sd1;  5'd22: w4 = 8'sd0;  5'd23: w4 = 8'sd0;
            5'd24: w4 = -8'sd6; 5'd25: w4 = -8'sd6; 5'd26: w4 = 8'sd6;  5'd27: w4 = -8'sd6;
            5'd28: w4 = -8'sd2; 5'd29: w4 = 8'sd1;  5'd30: w4 = 8'sd0;  5'd31: w4 = 8'sd0;
            default: w4 = 8'sd0;
        endcase
    endfunction

    // ---------------- 打包 A / B 分块 ----------------
    logic [63:0] feat_q;
    logic [TENSOR_TILE_WIDTH-1:0] a_tile1, a_tile2, b_tile1, b_tile2;

    always_comb begin
        a_tile1 = '0;
        a_tile2 = '0;
        b_tile1 = '0;
        b_tile2 = '0;
        for (int c = 0; c < 4; c++) begin
            for (int k = 0; k < 4; k++) begin
                a_tile1[8 * (c * 4 + k) +: 8] = w4(2'(c), 3'(k));
                a_tile2[8 * (c * 4 + k) +: 8] = w4(2'(c), 3'(k + 4));
            end
        end
        for (int k = 0; k < 4; k++) begin
            for (int j = 0; j < 4; j++) begin
                b_tile1[8 * (k * 4 + j) +: 8] = feat_q[8 * k +: 8];
                b_tile2[8 * (k * 4 + j) +: 8] = feat_q[8 * (k + 4) +: 8];
            end
        end
    end

    // ---------------- 两次 GEMM + argmax ----------------
    typedef enum logic [2:0] {S_IDLE, S_G1, S_ISSUE2, S_G2, S_DONE} state_t;
    state_t state_q;
    logic   second_q;      // 0 = 第一次 GEMM（K=0..3），1 = 第二次（K=4..7）

    logic cmd_valid, cmd_ready, res_valid, res_ready;
    logic [TENSOR_TILE_WIDTH-1:0]  cmd_a, cmd_b;
    logic [TENSOR_RESULT_WIDTH-1:0] cmd_acc, res_data;
    logic [TENSOR_RESULT_WIDTH-1:0] c1_q, c2_q;

    assign cmd_a   = second_q ? a_tile2 : a_tile1;
    assign cmd_b   = second_q ? b_tile2 : b_tile1;
    assign cmd_acc = second_q ? c1_q : '0;
    assign res_ready = 1'b1;

    tensor_gemm_core u_mxu (
        .clk      (clk),
        .rst      (~rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_a_tile(cmd_a),
        .cmd_b_tile(cmd_b),
        .cmd_acc_init(cmd_acc),
        .result_valid(res_valid),
        .result_ready(res_ready),
        .result_data(res_data)
    );

    function automatic logic [1:0] argmax4(input logic signed [31:0] a,
                                          input logic signed [31:0] b,
                                          input logic signed [31:0] c,
                                          input logic signed [31:0] d);
        logic [1:0] best;
        logic signed [31:0] v;
        begin
            best = 2'd0;
            v    = a;
            if (b > v) begin best = 2'd1; v = b; end
            if (c > v) begin best = 2'd2; v = c; end
            if (d > v) begin best = 2'd3; v = d; end
            argmax4 = (v > 0) ? best : 2'd0;
        end
    endfunction

    wire signed [31:0] s0 = c2_q[0 * 32 +: 32];
    wire signed [31:0] s1 = c2_q[4 * 32 +: 32];
    wire signed [31:0] s2 = c2_q[8 * 32 +: 32];
    wire signed [31:0] s3 = c2_q[12 * 32 +: 32];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q   <= S_IDLE;
            second_q  <= 1'b0;
            feat_q    <= 64'd0;
            c1_q      <= '0;
            c2_q      <= '0;
            cmd_valid <= 1'b0;
            out_valid <= 1'b0;
            out_class <= 2'd0;
        end else begin
            out_valid <= 1'b0;
            case (state_q)
                S_IDLE: begin
                    cmd_valid <= 1'b0;
                    if (in_valid) begin
                        feat_q    <= in_feat;
                        second_q  <= 1'b0;
                        cmd_valid <= 1'b1;
                        state_q   <= S_G1;
                    end
                end
                S_G1: begin
                    if (cmd_ready && cmd_valid) cmd_valid <= 1'b0;
                    if (res_valid) begin
                        c1_q      <= res_data;
                        second_q  <= 1'b1;      // 第二次 GEMM，acc_init = C1
                        cmd_valid <= 1'b1;
                        state_q   <= S_ISSUE2;
                    end
                end
                S_ISSUE2: begin
                    if (cmd_ready && cmd_valid) begin
                        cmd_valid <= 1'b0;
                        state_q   <= S_G2;
                    end
                end
                S_G2: begin
                    if (res_valid) begin
                        c2_q    <= res_data;
                        state_q <= S_DONE;
                    end
                end
                S_DONE: begin
                    out_valid <= 1'b1;
                    out_class <= argmax4(s0, s1, s2, s3);
                    state_q <= S_IDLE;
                end
                default: state_q <= S_IDLE;
            endcase
        end
    end

    assign out_s0 = c2_q[0 * 32 +: 32];
    assign out_s1 = c2_q[4 * 32 +: 32];
    assign out_s2 = c2_q[8 * 32 +: 32];
    assign out_s3 = c2_q[12 * 32 +: 32];

endmodule
