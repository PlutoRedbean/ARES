// guard/rtl/l1/l1_text_engines.sv
//
// L1 文本类引擎：邮箱、IPv4、统一社会信用代码（USCC）、车牌。
// 每个引擎独立工作在同一字符流上，各自输出 (start, len) 命中脉冲；
// 重叠的命中由上层（M2 策略）处理，L1 只负责"报出来"。
//
// 与 host/golden/pii_rules.py 的 _email_ok / _ipv4_ok / _uscc_ok / _plate_at
// 逐条对齐。
//
// 时序（2026-11-17 重写）：邮箱 / IPv4 / USCC 原来是"游程结束那一拍对整个缓冲
// 做组合校验"——邮箱是 64 次迭代的 ok/nat/ndots 链、IPv4 是 16 级分组状态链、
// USCC 是 17 项加权和链。PDS 实测这个文件的最差路径 ≈75 ns，27 MHz 不收敛
// （见 docs/board-uart.md §2.1）。现在改成**逐字节增量校验**：每来一个字节只
// 更新几个小寄存器，游程结束时只做几次比较，路径深度从 ~64 级降到 ~10 级。
// 语义不变，由 1000 例语料 + 43 例边界逐条兜住。

`timescale 1ns/1ps

package l1_text_pkg;

    function automatic logic is_alpha(input logic [7:0] c);
        is_alpha = (c >= 8'h41 && c <= 8'h5A) || (c >= 8'h61 && c <= 8'h7A);
    endfunction

    function automatic logic is_digit(input logic [7:0] c);
        is_digit = (c >= 8'h30 && c <= 8'h39);
    endfunction

    function automatic logic is_alnum(input logic [7:0] c);
        is_alnum = is_alpha(c) || is_digit(c);
    endfunction

    function automatic logic is_upper(input logic [7:0] c);
        is_upper = (c >= 8'h41 && c <= 8'h5A);
    endfunction

endpackage

// ---------------------------------------------------------------- email
//
// 游程 = EMAIL_CHARS 极大游程，尾部 '.' 裁掉后校验（与金标一致）。
// 增量状态（每字节更新）：nat('@' 个数) / at(第一个 '@' 位置) / bad(结构违规) /
// lab(当前 label 长度) / tld,tlda(最后一段长度、是否全字母) / ndots。
// 尾部 '.' 用快照处理：每遇到非 '.' 的接受字节就把整体状态拷进 g_*，
// 游程结束时只看 g_*。
module l1_email_engine (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len
);

    import l1_text_pkg::*;

    localparam int MAXLEN = 64;

    logic [31:0] pos_q;
    logic        run_q;
    logic [31:0] start_q;
    logic [6:0]  len_q;         // 游程已收字节数
    logic        too_long_q;

    logic [1:0]  nat_q;
    logic [6:0]  at_q;
    logic [7:0]  prev_q;
    logic        bad_q;
    logic [6:0]  lab_q;
    logic [6:0]  tld_q;
    logic        tlda_q;
    logic [6:0]  ndots_q;

    logic [1:0]  g_nat;
    logic [6:0]  g_at;
    logic        g_bad;
    logic [6:0]  g_tld;
    logic        g_tlda;
    logic [6:0]  g_ndots;
    logic [6:0]  g_len;
    logic [31:0] g_last;

    logic accept;
    assign accept = is_alnum(in_char) || in_char == 8'h2E || in_char == 8'h5F ||
                    in_char == 8'h25 || in_char == 8'h2B || in_char == 8'h2D ||
                    in_char == 8'h40;

    // ---- "本字节之前"的状态（新游程用初值） ----
    wire        b_first = ~run_q;
    wire [1:0]  b_nat   = run_q ? nat_q   : 2'd0;
    wire [7:0]  b_prev  = run_q ? prev_q  : 8'h00;
    wire [6:0]  b_lab   = run_q ? lab_q   : 7'd0;
    wire [6:0]  b_tld   = run_q ? tld_q   : 7'd0;
    wire        b_tlda  = run_q ? tlda_q  : 1'b1;
    wire [6:0]  b_ndots = run_q ? ndots_q : 7'd0;
    wire        b_bad   = run_q ? bad_q   : 1'b0;
    wire [6:0]  b_len   = run_q ? len_q   : 7'd0;    // 本字节在游程里的下标

    // ---- 本字节事件 ----
    wire c_dot   = (in_char == 8'h2E);
    wire c_at    = (in_char == 8'h40);
    wire c_alnum = is_alnum(in_char);
    wire c_alpha = is_alpha(in_char);
    wire c_hyph  = (in_char == 8'h2D);
    wire c_domch = c_alnum || c_hyph || c_dot;

    wire in_dom  = (b_nat != 2'd0);
    wire lab_new = in_dom && ((b_prev == 8'h40) || (b_prev == 8'h2E));

    wire [1:0] n_nat = (c_at && !in_dom) ? 2'd1 :
                       (c_at &&  in_dom) ? 2'd2 : b_nat;
    wire [6:0] n_at  = (c_at && !in_dom) ? b_len : (in_dom ? at_q : 7'd0);

    wire bad_ev =
        (b_first && c_dot)                                     // 本地部分以 '.' 开头
      || (!in_dom && !b_first && (b_prev == 8'h2E) && c_dot)    // 本地部分 ".."
      || (in_dom && c_at)                                       // 第二个 '@'
      || (c_at && !b_first && (b_prev == 8'h2E))                // 本地部分以 '.' 结尾
      || (in_dom && !c_at && !c_domch)                          // domain 非法字符
      || (in_dom && !c_at && lab_new && c_hyph)                 // label 以 '-' 开头
      || (in_dom && c_dot && (b_prev == 8'h2D))                 // label 以 '-' 结尾
      || (in_dom && c_dot && ((b_prev == 8'h2E) || (b_prev == 8'h40)));  // 空 label

    wire [6:0] n_lab   = c_dot ? 7'd0 : (in_dom ? (b_lab + 7'd1) : b_lab);
    wire [6:0] n_tld   = !in_dom ? b_tld : (c_dot ? 7'd0 : (b_tld + 7'd1));
    wire       n_tlda  = !in_dom ? b_tlda : (c_dot ? 1'b1 : (b_tlda && c_alpha));
    wire [6:0] n_ndots = (in_dom && c_dot) ? (b_ndots + 7'd1) : b_ndots;
    wire       n_bad   = b_bad || bad_ev;

    // ---- 游程结束判定（只看快照，几级比较） ----
    wire ok = run_q && !g_bad && (g_nat == 2'd1) &&
              (g_len >= 7'd5) && (g_len <= 7'd64) &&
              (g_at >= 7'd1) && (g_at <= 7'd32) &&
              (g_ndots >= 7'd1) &&
              (g_tld >= 7'd2) && (g_tld <= 7'd24) && g_tlda;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; start_q <= 32'd0;
            len_q <= 7'd0; too_long_q <= 1'b0;
            nat_q <= 2'd0; at_q <= 7'd0; prev_q <= 8'd0; bad_q <= 1'b0;
            lab_q <= 7'd0; tld_q <= 7'd0; tlda_q <= 1'b1; ndots_q <= 7'd0;
            g_nat <= 2'd0; g_at <= 7'd0; g_bad <= 1'b1; g_tld <= 7'd0;
            g_tlda <= 1'b0; g_ndots <= 7'd0; g_len <= 7'd0; g_last <= 32'd0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok && !too_long_q) begin
                    out_valid <= 1'b1;
                    out_start <= start_q;
                    out_len   <= 8'(g_len);
                end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (!accept) begin
                    if (ok && !too_long_q) begin
                        out_valid <= 1'b1;
                        out_start <= start_q;
                        out_len   <= 8'(g_len);
                    end
                    run_q <= 1'b0;
                end else if (!run_q) begin
                    // 新游程：本字节下标 0
                    run_q      <= 1'b1;
                    start_q    <= pos_q;
                    len_q      <= 7'd1;
                    too_long_q <= 1'b0;
                    nat_q      <= n_nat;
                    at_q       <= n_at;
                    prev_q     <= in_char;
                    bad_q      <= n_bad;
                    lab_q      <= n_lab;
                    tld_q      <= n_tld;
                    tlda_q     <= n_tlda;
                    ndots_q    <= n_ndots;
                    // 新游程先作废快照：全是 '.' 的游程不该复用上一轮的结果
                    g_bad      <= 1'b1;
                    g_len      <= 7'd0;
                    if (!c_dot) begin
                        g_nat   <= n_nat;
                        g_at    <= n_at;
                        g_bad   <= n_bad;
                        g_tld   <= n_tld;
                        g_tlda  <= n_tlda;
                        g_ndots <= n_ndots;
                        g_len   <= 7'd1;
                        g_last  <= pos_q;
                    end
                end else if (too_long_q) begin
                    // 已溢出：丢弃
                end else if (b_len == 7'(MAXLEN)) begin
                    too_long_q <= 1'b1;
                end else begin
                    len_q   <= len_q + 7'd1;
                    nat_q   <= n_nat;
                    at_q    <= n_at;
                    prev_q  <= in_char;
                    bad_q   <= n_bad;
                    lab_q   <= n_lab;
                    tld_q   <= n_tld;
                    tlda_q  <= n_tlda;
                    ndots_q <= n_ndots;
                    if (!c_dot) begin
                        g_nat   <= n_nat;
                        g_at    <= n_at;
                        g_bad   <= n_bad;
                        g_tld   <= n_tld;
                        g_tlda  <= n_tlda;
                        g_ndots <= n_ndots;
                        g_len   <= b_len + 7'd1;
                        g_last  <= pos_q;
                    end
                end
            end
        end
    end

endmodule

// ---------------------------------------------------------------- IPv4
//
// 游程 = [0-9.] 极大游程（<=15），尾部 '.' 裁掉后校验。
// 增量状态：grp(已完成的段数) / ndig(当前段位数) / val(当前段值) / lead(前导零) /
// bad。'.' 处结算上一段（空段、前导零、>255 都算违规）。
module l1_ipv4_engine (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len
);

    import l1_text_pkg::*;

    localparam int MAXLEN = 15;

    logic [31:0] pos_q;
    logic        run_q;
    logic [31:0] start_q;
    logic [4:0]  len_q;
    logic        too_long_q;

    logic [2:0]  grp_q;
    logic [2:0]  ndig_q;
    logic [8:0]  val_q;
    logic        lead_q;
    logic        bad_q;

    logic [2:0]  g_grp;
    logic [2:0]  g_ndig;
    logic [8:0]  g_val;
    logic        g_lead;
    logic        g_bad;
    logic [4:0]  g_len;
    logic [31:0] g_last;

    logic accept;
    assign accept = is_digit(in_char) || in_char == 8'h2E;

    wire       b_first = ~run_q;
    wire [2:0] b_grp   = run_q ? grp_q  : 3'd0;
    wire [2:0] b_ndig  = run_q ? ndig_q : 3'd0;
    wire [8:0] b_val   = run_q ? val_q  : 9'd0;
    wire       b_lead  = run_q ? lead_q : 1'b0;
    wire       b_bad   = run_q ? bad_q  : 1'b0;
    wire [4:0] b_len   = run_q ? len_q  : 5'd0;

    wire c_dot  = (in_char == 8'h2E);
    wire [3:0] d = in_char[3:0];

    // 本字节之后的状态
    wire [2:0] n_grp  = c_dot ? (b_grp + 3'd1) : b_grp;
    wire [2:0] n_ndig = c_dot ? 3'd0 : (b_ndig + 3'd1);
    wire [8:0] n_val  = c_dot ? 9'd0 :
                        (b_ndig == 3'd0) ? {5'd0, d} :
                        (b_val * 9'd10 + {5'd0, d});
    wire       n_lead = c_dot ? 1'b0 :
                        (b_ndig == 3'd0) ? (d == 4'd0) : b_lead;

    wire bad_ev = c_dot
                ? ((b_ndig == 3'd0) || ((b_ndig > 3'd1) && b_lead) || (b_val > 9'd255))
                : ((b_ndig + 3'd1) > 3'd3);
    wire n_bad = b_bad || bad_ev;

    // 游程结束判定（快照 = 最后一个数字字节处的状态）
    wire ok = run_q && !g_bad && (g_grp == 3'd3) && (g_ndig != 3'd0) &&
              !((g_ndig > 3'd1) && g_lead) && (g_val <= 9'd255) &&
              (g_len >= 5'd7) && (g_len <= 5'd15);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; start_q <= 32'd0;
            len_q <= 5'd0; too_long_q <= 1'b0;
            grp_q <= 3'd0; ndig_q <= 3'd0; val_q <= 9'd0; lead_q <= 1'b0; bad_q <= 1'b0;
            g_grp <= 3'd0; g_ndig <= 3'd0; g_val <= 9'd0; g_lead <= 1'b0;
            g_bad <= 1'b1; g_len <= 5'd0; g_last <= 32'd0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok && !too_long_q) begin
                    out_valid <= 1'b1;
                    out_start <= start_q;
                    out_len   <= 8'(g_len);
                end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (!accept) begin
                    if (ok && !too_long_q) begin
                        out_valid <= 1'b1;
                        out_start <= start_q;
                        out_len   <= 8'(g_len);
                    end
                    run_q <= 1'b0;
                end else if (!run_q) begin
                    run_q      <= 1'b1;
                    start_q    <= pos_q;
                    len_q      <= 5'd1;
                    too_long_q <= 1'b0;
                    grp_q      <= n_grp;
                    ndig_q     <= n_ndig;
                    val_q      <= n_val;
                    lead_q     <= n_lead;
                    bad_q      <= n_bad;
                    g_bad      <= 1'b1;
                    g_len      <= 5'd0;
                    if (!c_dot) begin
                        g_grp  <= n_grp;
                        g_ndig <= n_ndig;
                        g_val  <= n_val;
                        g_lead <= n_lead;
                        g_bad  <= n_bad;
                        g_len  <= 5'd1;
                        g_last <= pos_q;
                    end
                end else if (too_long_q) begin
                    // 已溢出：丢弃
                end else if (b_len == 5'(MAXLEN)) begin
                    too_long_q <= 1'b1;
                end else begin
                    len_q  <= len_q + 5'd1;
                    grp_q  <= n_grp;
                    ndig_q <= n_ndig;
                    val_q  <= n_val;
                    lead_q <= n_lead;
                    bad_q  <= n_bad;
                    if (!c_dot) begin
                        g_grp  <= n_grp;
                        g_ndig <= n_ndig;
                        g_val  <= n_val;
                        g_lead <= n_lead;
                        g_bad  <= n_bad;
                        g_len  <= b_len + 5'd1;
                        g_last <= pos_q;
                    end
                end
            end
        end
    end

endmodule

// ---------------------------------------------------------------- USCC
//
// 18 位 base31。增量：按位加权和（前 17 位）+ 是否含字母 + 第 18 位的 idx；
// 游程结束比对校验位。
module l1_uscc_engine (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len
);

    import l1_text_pkg::*;

    localparam int MAXLEN = 18;

    logic [31:0] pos_q;
    logic        run_q;
    logic [31:0] start_q;
    logic [5:0]  len_q;
    logic        too_long_q;

    logic [15:0] tot_q;
    logic        alpha_q;
    logic [5:0]  last_idx_q;

    function automatic logic [5:0] uscc_idx(input logic [7:0] c);
        case (c)
            8'h30: uscc_idx = 6'd0;  8'h31: uscc_idx = 6'd1;
            8'h32: uscc_idx = 6'd2;  8'h33: uscc_idx = 6'd3;
            8'h34: uscc_idx = 6'd4;  8'h35: uscc_idx = 6'd5;
            8'h36: uscc_idx = 6'd6;  8'h37: uscc_idx = 6'd7;
            8'h38: uscc_idx = 6'd8;  8'h39: uscc_idx = 6'd9;
            8'h41: uscc_idx = 6'd10; 8'h42: uscc_idx = 6'd11;
            8'h43: uscc_idx = 6'd12; 8'h44: uscc_idx = 6'd13;
            8'h45: uscc_idx = 6'd14; 8'h46: uscc_idx = 6'd15;
            8'h47: uscc_idx = 6'd16; 8'h48: uscc_idx = 6'd17;
            8'h4A: uscc_idx = 6'd18; 8'h4B: uscc_idx = 6'd19;
            8'h4C: uscc_idx = 6'd20; 8'h4D: uscc_idx = 6'd21;
            8'h4E: uscc_idx = 6'd22; 8'h50: uscc_idx = 6'd23;
            8'h51: uscc_idx = 6'd24; 8'h52: uscc_idx = 6'd25;
            8'h54: uscc_idx = 6'd26; 8'h55: uscc_idx = 6'd27;
            8'h57: uscc_idx = 6'd28; 8'h58: uscc_idx = 6'd29;
            8'h59: uscc_idx = 6'd30;
            default: uscc_idx = 6'h3F;
        endcase
    endfunction

    function automatic logic [4:0] uscc_weight(input logic [4:0] k);
        case (k)
            5'd0: uscc_weight = 5'd1;   5'd1: uscc_weight = 5'd3;
            5'd2: uscc_weight = 5'd9;   5'd3: uscc_weight = 5'd27;
            5'd4: uscc_weight = 5'd19;  5'd5: uscc_weight = 5'd26;
            5'd6: uscc_weight = 5'd16;  5'd7: uscc_weight = 5'd17;
            5'd8: uscc_weight = 5'd20;  5'd9: uscc_weight = 5'd29;
            5'd10: uscc_weight = 5'd25; 5'd11: uscc_weight = 5'd13;
            5'd12: uscc_weight = 5'd8;  5'd13: uscc_weight = 5'd24;
            5'd14: uscc_weight = 5'd10; 5'd15: uscc_weight = 5'd30;
            5'd16: uscc_weight = 5'd28;
            default: uscc_weight = 5'd0;
        endcase
    endfunction

    logic accept;
    assign accept = (uscc_idx(in_char) != 6'h3F);

    wire       b_first = ~run_q;
    wire [15:0] b_tot  = run_q ? tot_q : 16'd0;
    wire       b_alpha = run_q ? alpha_q : 1'b0;
    wire [5:0] b_last  = run_q ? last_idx_q : 6'd0;
    wire [5:0] b_len   = run_q ? len_q : 6'd0;

    wire [5:0] idx = uscc_idx(in_char);

    wire [15:0] n_tot   = (b_len < 6'd17) ? (b_tot + {11'd0, uscc_weight(b_len[4:0])} * {10'd0, idx})
                                          : b_tot;
    wire        n_alpha = b_alpha || is_alpha(in_char);
    wire [5:0]  n_last  = (b_len == 6'd17) ? idx : b_last;

    wire [15:0] chk_raw = 16'd31 - (tot_q % 16'd31);
    wire [5:0]  chk     = (chk_raw[5:0] == 6'd31) ? 6'd0 : chk_raw[5:0];

    wire ok = run_q && !too_long_q && (len_q == 6'd18) && alpha_q && (last_idx_q == chk);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; start_q <= 32'd0;
            len_q <= 6'd0; too_long_q <= 1'b0;
            tot_q <= 16'd0; alpha_q <= 1'b0; last_idx_q <= 6'd0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok) begin
                    out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd18;
                end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (!accept) begin
                    if (ok) begin
                        out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd18;
                    end
                    run_q <= 1'b0;
                end else if (!run_q) begin
                    run_q      <= 1'b1;
                    start_q    <= pos_q;
                    len_q      <= 6'd1;
                    too_long_q <= 1'b0;
                    tot_q      <= n_tot;
                    alpha_q    <= n_alpha;
                    last_idx_q <= n_last;
                end else if (too_long_q) begin
                    // 已溢出：丢弃
                end else if (b_len == 6'(MAXLEN)) begin
                    too_long_q <= 1'b1;
                end else begin
                    len_q      <= len_q + 6'd1;
                    tot_q      <= n_tot;
                    alpha_q    <= n_alpha;
                    last_idx_q <= n_last;
                end
            end
        end
    end

endmodule

// ---------------------------------------------------------------- 车牌
// 结构：3 字节汉字（UTF-8 E4..E9 / 80..BF / 80..BF）+ 字母（无 I/O）+ 5 位字母数字
module l1_plate_engine (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,
    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len
);

    import l1_text_pkg::*;

    localparam logic [3:0] S_H1 = 4'd1, S_H2 = 4'd2, S_H3 = 4'd3,
                           S_L  = 4'd4, S_T  = 4'd5, S_DONE = 4'd6;

    logic [31:0] pos_q, start_q;
    logic [3:0]  st_q;
    logic [2:0]  tail_q;

    logic cjk_lead, cjk_cont, plate_letter, plate_tail_ch;

    assign cjk_lead      = (in_char >= 8'hE4) && (in_char <= 8'hE9);
    assign cjk_cont      = (in_char >= 8'h80) && (in_char <= 8'hBF);
    assign plate_letter  = is_upper(in_char) && in_char != 8'h49 && in_char != 8'h4F;
    assign plate_tail_ch = is_digit(in_char) ||
                           (is_upper(in_char) && in_char != 8'h49 && in_char != 8'h4F);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; st_q <= 4'd0; start_q <= 32'd0; tail_q <= 3'd0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (st_q == S_DONE) begin
                    out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd9;
                end
                st_q <= 4'd0;
            end else if (in_valid) begin
                case (st_q)
                    4'd0: begin
                        if (cjk_lead) begin
                            st_q <= S_H1; start_q <= pos_q; tail_q <= 3'd0;
                        end
                    end
                    S_H1: begin
                        if (cjk_cont) st_q <= S_H2;
                        else if (cjk_lead) start_q <= pos_q;   // 重新起判
                        else st_q <= 4'd0;
                    end
                    S_H2: begin
                        if (cjk_cont) st_q <= S_H3;
                        else if (cjk_lead) begin st_q <= S_H1; start_q <= pos_q; end
                        else st_q <= 4'd0;
                    end
                    S_H3: begin
                        if (plate_letter) st_q <= S_L;
                        else if (cjk_lead) begin st_q <= S_H1; start_q <= pos_q; end
                        else st_q <= 4'd0;
                    end
                    S_L: begin
                        if (plate_tail_ch) begin st_q <= S_T; tail_q <= 3'd1; end
                        else if (cjk_lead) begin st_q <= S_H1; start_q <= pos_q; end
                        else st_q <= 4'd0;
                    end
                    S_T: begin
                        if (tail_q < 3'd5) begin
                            if (plate_tail_ch) begin
                                if (tail_q == 3'd4) st_q <= S_DONE;
                                tail_q <= tail_q + 3'd1;
                            end else if (cjk_lead) begin st_q <= S_H1; start_q <= pos_q; end
                            else st_q <= 4'd0;
                        end else begin
                            st_q <= S_DONE;
                        end
                    end
                    S_DONE: begin
                        if (is_alnum(in_char)) begin
                            st_q <= 4'd0;
                        end else begin
                            out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd9;
                            if (cjk_lead) begin st_q <= S_H1; start_q <= pos_q; end
                            else st_q <= 4'd0;
                        end
                    end
                    default: st_q <= 4'd0;
                endcase
            end
        end
    end

endmodule