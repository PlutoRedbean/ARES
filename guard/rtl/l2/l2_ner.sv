// guard/rtl/l2/l2_ner.sv
//
// 字符级 INT8 CNN（v2 模型）的 RTL。64 字节窗口 -> 每字符 3 分类 -> span。
// 串行实现：每个 MAC 两拍（驱动 ROM 地址 + 累加），~32 ms/窗口 @25 MHz。
// 目标不是速度，而是与 host/golden/ner.py 的整数语义逐位一致。

`timescale 1ns/1ps

module l2_ner (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [3:0]  out_type,
    output logic        busy
);

    localparam int VOCAB_N = `NER_VOCAB_N;
    localparam logic [23:0] M1 = 24'd17589;
    localparam logic [23:0] M2 = 24'd24005;

    // ---------------------------------------------------------------- ROM
    logic [15:0] emb_addr;   logic [7:0]  emb_data;
    logic [11:0] c1_addr, c2_addr;
    logic [7:0]  c1_data, c2_data;
    logic [4:0]  c1b_addr, c2b_addr;
    logic signed [31:0] c1b_data, c2b_data;
    logic [7:0]  h_addr;     logic [7:0]  h_data;
    logic [1:0]  hb_addr;    logic signed [31:0] hb_data;
    logic [9:0]  voc_addr;   logic [23:0] voc_key;  logic [9:0] voc_id;

    l2_ner_rom u_rom (
        .emb_addr(emb_addr), .emb_data(emb_data),
        .conv1_addr(c1_addr), .conv1_data(c1_data),
        .conv1_b_addr(c1b_addr), .conv1_b_data(c1b_data),
        .conv2_addr(c2_addr), .conv2_data(c2_data),
        .conv2_b_addr(c2b_addr), .conv2_b_data(c2b_data),
        .head_addr(h_addr), .head_data(h_data),
        .head_b_addr(hb_addr), .head_b_data(hb_data)
    );

    l2_ner_vocab u_voc (.addr(voc_addr), .key(voc_key), .id(voc_id));

    // ---------------------------------------------------------------- 存储
    logic [7:0]  ch_buf [0:63];
    logic [9:0]  tok_id [0:63];
    logic [5:0]  tok_off[0:63];
    logic [1:0]  tok_len[0:63];
    logic signed [7:0]  x  [0:2047];
    logic signed [7:0]  h1 [0:2047];
    logic signed [7:0]  h2 [0:2047];
    logic [1:0]  lab [0:63];
    logic signed [31:0] b1_reg [0:31];
    logic signed [31:0] b2_reg [0:31];
    logic signed [31:0] hb_reg [0:2];

    logic [6:0]  nbyte, ntok;
    logic [31:0] win_base;

    typedef enum logic [3:0] {
        S_RECV, S_TOK, S_EMB, S_C1B, S_C1, S_C2B, S_C2, S_HB, S_HEAD, S_SPAN
    } state_t;
    state_t st;

    logic        step;
    logic [6:0]  ti;
    logic [9:0]  va;
    logic [23:0] key_r;
    logic [1:0]  tlen_r;
    logic [6:0]  i, o, c;
    logic [1:0]  k, cls;
    logic signed [47:0] acc;
    logic signed [31:0] best;
    logic [1:0]  best_cls;
    logic [6:0]  sp, run_start;
    logic [1:0]  run_lab;

    assign busy = (st != S_RECV);

    wire [9:0]  tid = (i < ntok) ? tok_id[i[5:0]] : 10'd0;
    wire [6:0]  a_idx = i + {5'd0, k} - 7'd1;
    wire        a_ok  = (i + {5'd0, k} >= 7'd1) && (a_idx <= 7'd63);
    wire signed [7:0] a_x  = a_ok ? x [a_idx * 7'd32 + {1'b0, c}] : 8'sd0;
    wire signed [7:0] a_h1 = a_ok ? h1[a_idx * 7'd32 + {1'b0, c}] : 8'sd0;
    wire [11:0] w_addr = {5'd0, o} * 12'd96 + {10'd0, k} * 12'd32 + {5'd0, c};

    function automatic logic signed [7:0] rq(input logic signed [47:0] v, input logic [23:0] m);
        logic signed [71:0] p, q;
        begin
            p = v * $signed({1'b0, m});
            q = (p + 72'sd8388608) >>> 24;
            if (q < 0)        rq = 8'sd0;
            else if (q > 127) rq = 8'sd127;
            else              rq = q[7:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_RECV; nbyte <= 7'd0; ntok <= 7'd0; win_base <= 32'd0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0; out_type <= 4'd0;
            step <= 1'b0; acc <= 48'sd0;
        end else begin
            out_valid <= 1'b0;
            case (st)
            S_RECV: begin
                if (in_valid) begin
                    ch_buf[nbyte[5:0]] <= in_char;
                    nbyte <= nbyte + 7'd1;
                end
                if ((nbyte == 7'd64) || (in_last && nbyte != 7'd0)) begin
                    st <= S_TOK; ti <= 7'd0; ntok <= 7'd0; va <= 10'd0;
                end
            end

            S_TOK: begin
                if (ti >= nbyte) begin
                    st <= S_EMB; i <= 7'd0; c <= 7'd0; step <= 1'b0;
                end else if (va == 10'd0) begin
                    tlen_r <= (ch_buf[ti[5:0]] >= 8'hE4 && ch_buf[ti[5:0]] <= 8'hE9) ? 2'd3 : 2'd1;
                    key_r  <= (ch_buf[ti[5:0]] >= 8'hE4 && ch_buf[ti[5:0]] <= 8'hE9)
                              ? {ch_buf[ti[5:0]], ch_buf[ti[5:0] + 6'd1], ch_buf[ti[5:0] + 6'd2]}
                              : {ch_buf[ti[5:0]], 8'h01, 8'h01};
                    tok_off[ntok[5:0]] <= ti[5:0];
                    tok_len[ntok[5:0]] <= (ch_buf[ti[5:0]] >= 8'hE4 && ch_buf[ti[5:0]] <= 8'hE9) ? 2'd3 : 2'd1;
                    tok_id [ntok[5:0]] <= 10'd1;
                    va <= 10'd1;
                end else if (va < 10'(VOCAB_N)) begin
                    if (voc_key == key_r) tok_id[ntok[5:0]] <= voc_id;
                    va <= va + 10'd1;
                end else begin
                    va <= 10'd0;
                    ntok <= ntok + 7'd1;
                    ti <= ti + ((tlen_r == 2'd3) ? 7'd3 : 7'd1);
                end
            end

            S_EMB: begin
                if (!step) begin
                    emb_addr <= {tid[8:0], 5'd0} + {11'd0, c[4:0]} + 16'd0;
                    step <= 1'b1;
                end else begin
                    x[i * 7'd32 + {1'b0, c}] <= $signed(emb_data);
                    step <= 1'b0;
                    if (c == 7'd31) begin
                        c <= 7'd0;
                        if (i == 7'd63) begin st <= S_C1B; i <= 7'd0; end
                        else i <= i + 7'd1;
                    end else c <= c + 7'd1;
                end
            end

            S_C1B: begin
                c1b_addr <= o[4:0];
                b1_reg[o[4:0]] <= c1b_data;
                b2_reg[o[4:0]] <= c2b_data;
                c2b_addr <= o[4:0];
                if (o == 7'd31) begin o <= 7'd0; i <= 7'd0; k <= 2'd0; c <= 7'd0; step <= 1'b0; st <= S_C1; end
                else o <= o + 7'd1;
            end

            S_C1: begin
                if (!step) begin
                    c1_addr <= w_addr;
                    step <= 1'b1;
                end else begin
                    acc <= acc + $signed(c1_data) * $signed({8'd0, a_x});
                    step <= 1'b0;
                    if (k == 2'd2 && c == 7'd31) begin
                        h1[i * 7'd32 + {1'b0, o[4:0]}] <=
                            rq(acc + $signed(c1_data) * $signed({8'd0, a_x}) + b1_reg[o[4:0]], M1);
                        acc <= 48'sd0;
                        if (o == 7'd31) begin
                            o <= 7'd0;
                            if (i == 7'd63) begin st <= S_C2B; i <= 7'd0; end
                            else i <= i + 7'd1;
                        end else o <= o + 7'd1;
                    end else if (c == 7'd31) begin
                        c <= 7'd0; k <= k + 2'd1;
                    end else c <= c + 7'd1;
                end
            end

            S_C2B: begin
                if (o == 7'd31) begin o <= 7'd0; i <= 7'd0; k <= 2'd0; c <= 7'd0; step <= 1'b0; st <= S_C2; end
                else o <= o + 7'd1;
            end

            S_C2: begin
                if (!step) begin
                    c2_addr <= w_addr;
                    step <= 1'b1;
                end else begin
                    acc <= acc + $signed(c2_data) * $signed({8'd0, a_h1});
                    step <= 1'b0;
                    if (k == 2'd2 && c == 7'd31) begin
                        h2[i * 7'd32 + {1'b0, o[4:0]}] <=
                            rq(acc + $signed(c2_data) * $signed({8'd0, a_h1}) + b2_reg[o[4:0]], M2);
                        acc <= 48'sd0;
                        if (o == 7'd31) begin
                            o <= 7'd0;
                            if (i == 7'd63) begin st <= S_HB; i <= 7'd0; end
                            else i <= i + 7'd1;
                        end else o <= o + 7'd1;
                    end else if (c == 7'd31) begin
                        c <= 7'd0; k <= k + 2'd1;
                    end else c <= c + 7'd1;
                end
            end

            S_HB: begin
                hb_addr <= cls[1:0];
                hb_reg[cls[1:0]] <= hb_data;
                if (cls == 2'd2) begin cls <= 2'd0; i <= 7'd0; o <= 7'd0; step <= 1'b0; acc <= 48'sd0;
                                            best <= 32'sd0; best_cls <= 2'd0; st <= S_HEAD; end
                else cls <= cls + 2'd1;
            end

            S_HEAD: begin
                if (!step) begin
                    h_addr <= {6'd0, cls} * 8'd32 + {1'b0, o[4:0]};
                    step <= 1'b1;
                end else begin
                    acc <= acc + $signed(h_data) * $signed({8'd0, h2[i * 7'd32 + {1'b0, o[4:0]}]});
                    step <= 1'b0;
                    if (o == 7'd31) begin
                        // 一个类跑完：和当前最优比（并列取小 cls）
                        if (cls == 2'd0 || (acc + $signed(h_data) * $signed({8'd0, h2[i * 7'd32 + {1'b0, o[4:0]}]}) + hb_reg[cls[1:0]]) > best) begin
                            best <= acc + $signed(h_data) * $signed({8'd0, h2[i * 7'd32 + {1'b0, o[4:0]}]}) + hb_reg[cls[1:0]];
                            best_cls <= cls;
                        end
                        acc <= 48'sd0;
                        o <= 7'd0;
                        if (cls == 2'd2) begin
                            lab[i[5:0]] <= best_cls;
                            cls <= 2'd0;
                            best <= 32'sd0; best_cls <= 2'd0;
                            if (i == 7'd63) begin st <= S_SPAN; sp <= 7'd0; run_lab <= 2'd0; run_start <= 7'd0; end
                            else i <= i + 7'd1;
                        end else cls <= cls + 2'd1;
                    end else o <= o + 7'd1;
                end
            end

            S_SPAN: begin
                // 扫描 lab[]：连续相同非零标签且 >=2 个字符 -> 输出 span
                if (sp >= ntok) begin
                    st <= S_RECV;
                    nbyte <= 7'd0;
                    win_base <= win_base + 32'(nbyte);
                    ntok <= 7'd0;
                end else if (lab[sp[5:0]] == 2'd0) begin
                    run_lab <= 2'd0;
                    sp <= sp + 7'd1;
                end else if (run_lab != lab[sp[5:0]]) begin
                    run_lab <= lab[sp[5:0]];
                    run_start <= sp;
                    sp <= sp + 7'd1;
                end else begin
                    // 同一段落：到末尾或类型变化时结算
                    sp <= sp + 7'd1;
                end
            end

            default: st <= S_RECV;
            endcase
        end
    end

endmodule