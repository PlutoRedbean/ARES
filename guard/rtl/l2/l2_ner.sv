// guard/rtl/l2/l2_ner.sv
//
// 字符级 INT8 CNN（v2 模型）的 RTL：64 字节窗口 -> 每字符 3 分类 -> span。
// 组合 ROM 寻址 + 1 MAC/拍（~456k 拍/窗口 ≈ 18 ms @25 MHz）。速度不是目标，
// 与 host/golden/ner.py 的整数语义一致才是。

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

    `include "ner_config.svh"

    localparam int VOCAB_N = `NER_VOCAB_N;
    localparam logic [23:0] M1 = 24'd281423;   // s=28: logits 与金标 60/60 完全相同
    localparam logic [23:0] M2 = 24'd384084;

    // ROM（组合读）
    logic [15:0] emb_addr;   logic [7:0]  emb_data;
    logic [11:0] c1_addr, c2_addr, w_addr;
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

    // 存储
    logic [7:0]  ch_buf [0:63];
    logic [9:0]  tok_id [0:63];
    logic [5:0]  tok_off[0:63];
    logic [2:0]  tok_len[0:63];
    logic signed [7:0]  x  [0:2047];
    logic signed [7:0]  h1 [0:2047];
    logic signed [7:0]  h2 [0:2047];
    logic [1:0]  lab [0:63];
    logic signed [31:0] b1_reg [0:31];
    logic signed [31:0] b2_reg [0:31];
    logic signed [31:0] hb_reg [0:2];

    logic [6:0]  nbyte, ntok;
    logic [7:0]  pend_byte;
    logic        pend_ok;
    logic [31:0] win_base;

    typedef enum logic [3:0] {
        S_RECV, S_TOK, S_EMB, S_C1B, S_C1, S_C2, S_HB, S_HEAD, S_SPAN, S_DONE
    } state_t;
    state_t st;

    logic [6:0]  ti, i, o, c, sp, rs;
    logic [9:0]  va;
    logic [23:0] key_r;
    logic [2:0]  tlen_r;
    logic [1:0]  k, cls, rl;
    logic signed [47:0] acc;
    logic signed [31:0] best;
    logic [1:0]  best_cls;

    assign busy = (st != S_RECV);

    wire [9:0]  tid = (i < ntok) ? tok_id[i[5:0]] : 10'd0;
    wire [6:0]  a_idx = i + {5'd0, k} - 7'd1;
    wire        a_ok  = (i + {5'd0, k} >= 7'd1) && (a_idx <= 7'd63);
    wire signed [7:0] a_x  = a_ok ? x [{5'd0, a_idx} * 12'd32 + {4'd0, c}] : 8'sd0;
    wire signed [7:0] a_h1 = a_ok ? h1[{5'd0, a_idx} * 12'd32 + {4'd0, c}] : 8'sd0;

    assign emb_addr = {tid[8:0], 5'd0} + {11'd0, c[4:0]};
    assign w_addr   = {5'd0, o} * 12'd96 + {10'd0, k} * 12'd32 + {5'd0, c};
    assign c1_addr  = w_addr;
    assign c2_addr  = w_addr;
    assign c1b_addr = o[4:0];
    assign c2b_addr = o[4:0];
    assign h_addr   = {6'd0, cls} * 8'd32 + {1'b0, o[4:0]};
    assign hb_addr  = cls[1:0];
    assign voc_addr = va;

    function automatic logic [2:0] ureq_len(input logic [7:0] b);
        ureq_len = (b >= 8'hF0) ? 3'd4 : (b >= 8'hE0) ? 3'd3 : (b >= 8'hC0) ? 3'd2 : 3'd1;
    endfunction

    function automatic logic [23:0] tkey_at(input logic [5:0] off);
        logic [2:0] ln;
        begin
            ln = ureq_len(ch_buf[off]);
            tkey_at = {ch_buf[off],
                       (ln >= 3'd2) ? ch_buf[off + 6'd1] : 8'h01,
                       (ln >= 3'd3) ? ch_buf[off + 6'd2] : 8'h01};
        end
    endfunction

    function automatic logic signed [7:0] rq(input logic signed [47:0] v, input logic [23:0] m);
        logic signed [71:0] p, q;
        begin
            p = v * $signed({1'b0, m});
            q = (p + 72'sd134217728) >>> 28;
            if (q < 0)        rq = 8'sd0;
            else if (q > 127) rq = 8'sd127;
            else              rq = q[7:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_RECV; nbyte <= 7'd0; ntok <= 7'd0; win_base <= 32'd0; pend_ok <= 1'b0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0; out_type <= 4'd0;
        end else begin
            out_valid <= 1'b0;
            case (st)
            S_RECV: begin
                // 先把上一窗留下的那个字节放进新窗
                if (pend_ok) begin
                    ch_buf[6'd0] <= pend_byte;
                    nbyte <= 7'd1;
                    pend_ok <= 1'b0;
                end else if (in_valid) begin
                    // 字符对齐：这个字节若是新字符的起点，且放进来会超 64 字节，
                    // 就结束本窗（它留给下一窗）
                    if ((nbyte != 7'd0) && (nbyte + 7'(ureq_len(in_char)) > 7'd64)) begin
                        pend_byte <= in_char;
                        pend_ok   <= 1'b1;
                        st <= S_TOK; ti <= 7'd0; ntok <= 7'd0; va <= 10'd0;
                    end else begin
                        ch_buf[nbyte[5:0]] <= in_char;
                        nbyte <= nbyte + 7'd1;
                    end
                end
                if (in_last && nbyte != 7'd0 && !pend_ok) begin
                    st <= S_TOK; ti <= 7'd0; ntok <= 7'd0; va <= 10'd0;
                end
            end

            S_TOK: begin
                if (ti >= nbyte) begin
                    st <= S_EMB; i <= 7'd0; c <= 7'd0;
                end else if (va == 10'd0) begin
                    tlen_r <= ureq_len(ch_buf[ti[5:0]]);
                    key_r  <= tkey_at(ti[5:0]);
                    if (voc_key == tkey_at(ti[5:0])) tok_id[ntok[5:0]] <= voc_id;
                    tok_off[ntok[5:0]] <= ti[5:0];
                    tok_len[ntok[5:0]] <= ureq_len(ch_buf[ti[5:0]]);
                    tok_id [ntok[5:0]] <= 10'd1;
                    va <= 10'd1;
                end else if (va < 10'(VOCAB_N)) begin
                    if (voc_key == key_r) tok_id[ntok[5:0]] <= voc_id;
                    va <= va + 10'd1;
                end else begin
                    va <= 10'd0;
                    ntok <= ntok + 7'd1;
                    ti <= ti + {4'd0, tlen_r};
                end
            end

            S_EMB: begin
                x[{5'd0, i} * 12'd32 + {4'd0, c}] <= $signed(emb_data);
                if (c == 7'd31) begin
                    c <= 7'd0;
                    if (i == 7'd63) begin st <= S_C1B; i <= 7'd0; o <= 7'd0; end
                    else i <= i + 7'd1;
                end else c <= c + 7'd1;
            end

            S_C1B: begin
                b1_reg[o[4:0]] <= c1b_data;
                b2_reg[o[4:0]] <= c2b_data;
                if (o == 7'd31) begin o <= 7'd0; i <= 7'd0; k <= 2'd0; c <= 7'd0; acc <= 48'sd0; st <= S_C1; end
                else o <= o + 7'd1;
            end

            S_C1: begin
                acc <= acc + $signed(c1_data) * $signed(a_x);
                if (k == 2'd2 && c == 7'd31) begin
                    h1[{5'd0, i} * 12'd32 + {4'd0, o[4:0]}] <=
                        rq(acc + $signed(c1_data) * $signed(a_x) + b1_reg[o[4:0]], M1);
                    acc <= 48'sd0;
                    if (o == 7'd31) begin
                        o <= 7'd0;
                        if (i == 7'd63) begin st <= S_C2; i <= 7'd0; k <= 2'd0; c <= 7'd0; end
                        else begin i <= i + 7'd1; k <= 2'd0; c <= 7'd0; end
                    end else begin o <= o + 7'd1; k <= 2'd0; c <= 7'd0; end
                end else if (c == 7'd31) begin c <= 7'd0; k <= k + 2'd1; end
                else c <= c + 7'd1;
            end

            S_C2: begin
                acc <= acc + $signed(c2_data) * $signed(a_h1);
                if (k == 2'd2 && c == 7'd31) begin
                    h2[{5'd0, i} * 12'd32 + {4'd0, o[4:0]}] <=
                        rq(acc + $signed(c2_data) * $signed(a_h1) + b2_reg[o[4:0]], M2);
                    acc <= 48'sd0;
                    if (o == 7'd31) begin
                        o <= 7'd0;
                        if (i == 7'd63) begin st <= S_HB; cls <= 2'd0; i <= 7'd0; o <= 7'd0; end
                        else begin i <= i + 7'd1; k <= 2'd0; c <= 7'd0; end
                    end else begin o <= o + 7'd1; k <= 2'd0; c <= 7'd0; end
                end else if (c == 7'd31) begin c <= 7'd0; k <= k + 2'd1; end
                else c <= c + 7'd1;
            end

            S_HB: begin
                hb_reg[cls[1:0]] <= hb_data;
                if (cls == 2'd2) begin cls <= 2'd0; i <= 7'd0; o <= 7'd0; acc <= 48'sd0;
                                          best <= 32'sh80000000; best_cls <= 2'd0; st <= S_HEAD; end
                else cls <= cls + 2'd1;
            end

            S_HEAD: begin
                acc <= acc + $signed(h_data) * $signed(h2[{5'd0, i} * 12'd32 + {4'd0, o[4:0]}]);
                if (o == 7'd31) begin
                    // 一个类跑完：和当前最优比（并列取小 cls），直接把赢家写进 lab
                    if ((acc + $signed(h_data) * $signed(h2[{5'd0, i} * 12'd32 + {4'd0, o[4:0]}]))
                        + hb_reg[cls[1:0]] > best) begin
                        lab[i[5:0]] <= cls;
                        best <= (acc + $signed(h_data) * $signed(h2[{5'd0, i} * 12'd32 + {4'd0, o[4:0]}]))
                                + hb_reg[cls[1:0]];
                    end
                    acc <= 48'sd0; o <= 7'd0;
                    if (cls == 2'd2) begin
                        cls <= 2'd0; best <= 32'sh80000000;
                        if (i == 7'd63) begin st <= S_SPAN; sp <= 7'd0; rs <= 7'd0; rl <= 2'd0; end
                        else i <= i + 7'd1;
                    end else cls <= cls + 2'd1;
                end else o <= o + 7'd1;
            end

            S_SPAN: begin
                if (sp >= ntok) begin
                    if (rl != 2'd0 && (sp - rs) >= 7'd2) begin
                        out_valid <= 1'b1;
                        out_type  <= (rl == 2'd1) ? 4'd9 : 4'd10;
                        out_start <= win_base + 32'(tok_off[rs[5:0]]);
                        out_len   <= 8'(tok_off[sp - 7'd1] + {4'd0, tok_len[sp - 7'd1]})
                                     - 8'(tok_off[rs[5:0]]);
                    end
                    st <= S_DONE;
                end else if (rl == 2'd0) begin
                    if (lab[sp[5:0]] != 2'd0) begin rl <= lab[sp[5:0]]; rs <= sp; end
                    sp <= sp + 7'd1;
                end else if (lab[sp[5:0]] == rl) begin
                    sp <= sp + 7'd1;
                end else begin
                    if ((sp - rs) >= 7'd2) begin
                        out_valid <= 1'b1;
                        out_type  <= (rl == 2'd1) ? 4'd9 : 4'd10;
                        out_start <= win_base + 32'(tok_off[rs[5:0]]);
                        out_len   <= 8'(tok_off[sp - 7'd1] + {4'd0, tok_len[sp - 7'd1]})
                                     - 8'(tok_off[rs[5:0]]);
                    end
                    rl <= 2'd0;
                end
            end

            S_DONE: begin
                win_base <= win_base + 32'(nbyte);
                nbyte <= 7'd0;
                ntok  <= 7'd0;
                st    <= S_RECV;
            end

            default: st <= S_RECV;
            endcase
        end
    end

endmodule