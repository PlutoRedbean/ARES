// guard/rtl/l1/l1_digit_engine.sv
//
// L1 规则层第一切片：流式数字游程 + 校验分类器。
//
// 输入：1 字符/拍（8-bit，UTF-8 字节；只对 ASCII 数字/分隔符敏感）。
// 输出：每命中一个格式化 PII，输出一个 (start, len, type) 脉冲。
//
// 判定（与 host/golden/pii_rules.py 逐条对齐，改一处必须改另一处）：
//   - 数字游程：'0'..'9' 累积；' '（0x20）与 '-'（0x2D）在游程内透明；
//     游程在遇到其它字符时结束，尾部透明字符不计入 span；
//   - 'X'/'x' 只在已有 17 位数字时作为第 18 位（身份证校验位）并入游程；
//   - 长度按十进制位数（不是 span 字节数）分类，优先级：
//       ID18 (18 & ISO 7064 MOD 11-2 & 出生日期合法)
//     > ID15 (15 & 出生日期合法)
//     > MOBILE (11 & 1[3-9] 前缀)
//     > BANK (13..19 & Luhn 通过)
//   - 位数 > 19 → 整段作废（不命中）。
//
// 协议：正常字符用 in_valid 逐拍送入；结束时先送 in_last（in_valid=0）
// 一拍清空游程。out_valid 为单拍脉冲，寄存器输出。

`timescale 1ns/1ps

module l1_digit_engine (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    // 上下文提示：刚刚匹配到一个 PII 关键词（用于"校验位不过也遮"的兜底）
    input  logic        ctx_valid,
    input  logic [2:0]  ctx_kid,
    input  logic [31:0] ctx_end,

    output logic        out_valid,
    output logic [31:0] out_start,
    output logic [7:0]  out_len,
    output logic [2:0]  out_type
);

    localparam logic [2:0] T_ID18   = 3'd1;
    localparam logic [2:0] T_ID15   = 3'd2;
    localparam logic [2:0] T_MOBILE = 3'd3;
    localparam logic [2:0] T_BANK   = 3'd4;

    // ---------------------------------------------------------------- state
    logic [31:0] pos_q;            // 当前字符下标（0 起点）
    logic        run_active_q;
    logic [31:0] run_start_q;
    logic [31:0] last_digit_pos_q;
    logic [5:0]  ndigits_q;
    logic        has_x_q;
    logic        too_long_q;
    logic [18:0][3:0] digits_q;    // digits_q[0] 是最右（最新）一位

    // 上下文兜底（关键词 -> 数字游程）
    logic [31:0] ctx_end_q;
    logic [2:0]  ctx_kid_q;
    logic        ctx_seen_q;

    // 影子游程：最后一个分隔符之后的数字（超长时顶替主游程）
    logic [18:0][3:0] sdig_q;
    logic [5:0]       snd_q;
    logic             shas_x_q;
    logic             sover_q;
    logic [31:0]      sstart_q;
    logic [31:0]      slast_q;

    // 分隔符处的快照：主游程分类结果（只存 type 与 span，不存数字）
    logic             snap_valid_q;
    logic [2:0]       snap_type_q;
    logic [31:0]      snap_start_q;
    logic [31:0]      snap_last_q;

    logic        is_digit;
    logic        is_sep;
    logic        is_x;
    logic [3:0]  new_digit;

    assign is_digit  = (in_char >= 8'h30) && (in_char <= 8'h39);
    assign is_sep    = (in_char == 8'h20) || (in_char == 8'h2D);
    assign is_x      = (in_char == 8'h58) || (in_char == 8'h78);
    assign new_digit = in_char[3:0];

    // ------------------------------------------------------- classification
    logic [9:0]  luhn_sum;
    logic [10:0] id_sum;
    logic        luhn_ok;
    logic        date18_ok;
    logic        date15_ok;
    logic        mobile_ok;
    logic        bank_ok;
    logic [2:0]  hit_type;

    integer i;
    integer j;
    integer jj;

    function automatic logic [3:0] luhn_double(input logic [3:0] d);
        logic [4:0] t;
        t = {1'b0, d} << 1;
        luhn_double = (t > 5'd9) ? (t - 5'd9) : t[3:0];
    endfunction

    function automatic logic [3:0] id_weight(input logic [4:0] k);
        case (k)
            5'd0,  5'd10: id_weight = 4'd7;
            5'd1,  5'd11: id_weight = 4'd9;
            5'd2,  5'd12: id_weight = 4'd10;
            5'd3,  5'd13: id_weight = 4'd5;
            5'd4,  5'd14: id_weight = 4'd8;
            5'd5,  5'd15: id_weight = 4'd4;
            5'd6,  5'd16: id_weight = 4'd2;
            5'd7:         id_weight = 4'd1;
            5'd8:         id_weight = 4'd6;
            5'd9:         id_weight = 4'd3;
            default:      id_weight = 4'd0;
        endcase
    endfunction

    function automatic logic [8:0] days_in_month(input logic [3:0] m, input logic leap);
        case (m)
            4'd1, 4'd3, 4'd5, 4'd7, 4'd8, 4'd10, 4'd12: days_in_month = 9'd31;
            4'd4, 4'd6, 4'd9, 4'd11:                    days_in_month = 9'd30;
            4'd2:                                       days_in_month = leap ? 9'd29 : 9'd28;
            default:                                    days_in_month = 9'd0;
        endcase
    endfunction

    // 左起第 k 位（k=0 是最高位）
    function automatic logic [3:0] dleft(input logic [4:0] k, input logic [5:0] n);
        dleft = digits_q[n - 6'd1 - k];
    endfunction

    logic [15:0] y18;
    logic [6:0]  m18, dd18;
    logic [7:0]  y15;
    logic [6:0]  m15, dd15;
    logic        leap18, leap15;

    always_comb begin
        luhn_sum = 10'd0;
        id_sum   = 11'd0;
        for (i = 0; i < 19; i = i + 1) begin
            if (i < ndigits_q) begin
                luhn_sum = luhn_sum + ((i[0]) ? {1'b0, luhn_double(digits_q[i])}
                                              : {1'b0, digits_q[i]});
                if (i >= 1) begin
                    id_sum = id_sum + id_weight(5'(ndigits_q - 6'd1 - i)) * digits_q[i];
                end
            end
        end
    end

    always_comb begin
        luhn_ok   = (ndigits_q >= 13) && (ndigits_q <= 19) &&
                    ((luhn_sum % 10'd10) == 10'd0) && !has_x_q;
        mobile_ok = (ndigits_q == 11) && (dleft(0, 11) == 4'd1) &&
                    (dleft(1, 11) >= 4'd3) && (dleft(1, 11) <= 4'd9);
        bank_ok   = luhn_ok;

        y18  = dleft(6, 18) * 16'd1000 + dleft(7, 18) * 16'd100 +
               dleft(8, 18) * 16'd10 + dleft(9, 18);
        m18  = dleft(10, 18) * 4'd10 + dleft(11, 18);
        dd18 = dleft(12, 18) * 4'd10 + dleft(13, 18);
        leap18 = (y18[1:0] == 2'b00);
        date18_ok = (m18 >= 7'd1) && (m18 <= 7'd12) &&
                    (dd18 >= 7'd1) && (dd18 <= {2'b0, days_in_month(m18[3:0], leap18)});

        y15  = dleft(6, 15) * 8'd10 + dleft(7, 15);
        m15  = dleft(8, 15) * 4'd10 + dleft(9, 15);
        dd15 = dleft(10, 15) * 4'd10 + dleft(11, 15);
        leap15 = (y15[1:0] == 2'b00);
        date15_ok = (m15 >= 7'd1) && (m15 <= 7'd12) &&
                    (dd15 >= 7'd1) && (dd15 <= {2'b0, days_in_month(m15[3:0], leap15)});
    end

    // ID18 的校验收敛：ISO 7064 MOD 11-2 要求 sum + check ≡ 1 (mod 11)，
    // 其中 X=10。这里先只用 luhn 之外的加权和，校验位在下面并入。
    always_comb begin
        hit_type = 3'd0;
        if (!too_long_q) begin
            if (ndigits_q == 18) begin
                if (((id_sum % 11'd11) + digits_q[0]) % 11'd11 == 11'd1)
                    hit_type = date18_ok ? T_ID18 : 3'd0;
            end else if (ndigits_q == 15) begin
                hit_type = date15_ok ? T_ID15 : 3'd0;
            end else if (ndigits_q == 11) begin
                hit_type = mobile_ok ? T_MOBILE : 3'd0;
            end else if ((ndigits_q >= 13) && (ndigits_q <= 19)) begin
                hit_type = bank_ok ? T_BANK : 3'd0;
            end
        end
    end

    // ---------------------------------------------------------------- 上下文兜底
    //
    // 游程前面 CTX_WINDOW 字节内出现过"身份证/银行卡/手机号"时，校验位不过也
    // 按该关键词的类型脱敏：隐私网关宁可多遮，也不能因为一个错别字漏掉身份证。
    // 与 host/golden/pii_rules.py 的 _loose_type / CTX_WINDOW 逐条对齐。
    localparam logic [31:0] CTX_WINDOW = 32'd8;

    function automatic logic [2:0] loose_type(input logic [5:0] n, input logic [2:0] kid);
        if (kid == 3'd0)      loose_type = (n == 6'd15) ? T_ID15 : T_ID18;
        else if (kid == 3'd1) loose_type = T_BANK;
        else if (kid == 3'd2) loose_type = T_MOBILE;
        else                  loose_type = 3'd0;
    endfunction

    wire ctx_ok = ctx_seen_q && (ctx_kid_q <= 3'd2) &&
                  (run_start_q >= ctx_end_q) && ((run_start_q - ctx_end_q) <= CTX_WINDOW);

    wire [2:0] close_type = (hit_type != 3'd0) ? hit_type :
                            (!too_long_q && ctx_ok &&
                             (ndigits_q >= 6'd11) && (ndigits_q <= 6'd19))
                              ? loose_type(ndigits_q, ctx_kid_q) : 3'd0;

    // ---------------------------------------------------------------- FSM
    //
    // 分隔符（空格/短横）在游程内透明，但 `13800138000 13800138001` 会被并成
    // 22 位游程而整段丢弃。这里的处理：
    //   - 影子游程 s* 永远只装"最后一个分隔符之后"的数字；
    //   - 分隔符处把主游程的分类结果存成快照（type + span）；
    //   - 主游程满 19 位又来数字时：先按快照结算一个 span，再用影子顶替主游程。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q           <= 32'd0;
            run_active_q    <= 1'b0;
            run_start_q     <= 32'd0;
            last_digit_pos_q<= 32'd0;
            ndigits_q       <= 6'd0;
            has_x_q         <= 1'b0;
            too_long_q      <= 1'b0;
            digits_q        <= '0;
            sdig_q          <= '0;
            snd_q           <= 6'd0;
            shas_x_q        <= 1'b0;
            sover_q         <= 1'b0;
            sstart_q        <= 32'd0;
            slast_q         <= 32'd0;
            snap_valid_q    <= 1'b0;
            snap_type_q     <= 3'd0;
            snap_start_q    <= 32'd0;
            snap_last_q     <= 32'd0;
            out_valid       <= 1'b0;
            out_start       <= 32'd0;
            out_len         <= 8'd0;
            out_type        <= 3'd0;
        end else begin
            out_valid <= 1'b0;

            if (in_valid) pos_q <= pos_q + 32'd1;

            if (ctx_valid) begin
                ctx_end_q  <= ctx_end;
                ctx_kid_q  <= ctx_kid;
                ctx_seen_q <= 1'b1;
            end

            if (in_last) begin
                if (run_active_q && (close_type != 3'd0)) begin
                    out_valid <= 1'b1;
                    out_start <= run_start_q;
                    out_len   <= last_digit_pos_q - run_start_q + 32'd1;
                    out_type  <= close_type;
                end
                run_active_q <= 1'b0;
                ndigits_q    <= 6'd0;
                has_x_q      <= 1'b0;
                too_long_q   <= 1'b0;
                snd_q        <= 6'd0;
                sover_q      <= 1'b0;
                snap_valid_q <= 1'b0;
                ctx_seen_q   <= 1'b0;   // 上下文不跨帧（金标也是逐帧扫）
            end else if (in_valid) begin
                if (is_digit) begin
                    // ---------------- 影子游程：每来一个数字都跟着走 ----------------
                    if (!sover_q) begin
                        if (snd_q == 6'd0) begin
                            sstart_q  <= pos_q;
                            sdig_q    <= '0;      // 清掉上一轮的残留，顶替时对齐才正确
                            sdig_q[0] <= new_digit;
                            snd_q     <= 6'd1;
                            slast_q   <= pos_q;
                            shas_x_q  <= 1'b0;
                        end else if (snd_q < 6'd19) begin
                            for (jj = 18; jj > 0; jj = jj - 1) sdig_q[jj] <= sdig_q[jj-1];
                            sdig_q[0] <= new_digit;
                            snd_q     <= snd_q + 6'd1;
                            slast_q   <= pos_q;
                        end else begin
                            sover_q <= 1'b1;
                        end
                    end

                    // ---------------- 主游程 ----------------
                    if (!run_active_q) begin
                        run_active_q     <= 1'b1;
                        run_start_q      <= pos_q;
                        digits_q[0]      <= new_digit;
                        ndigits_q        <= 6'd1;
                        has_x_q          <= 1'b0;
                        too_long_q       <= 1'b0;
                        last_digit_pos_q <= pos_q;
                        snap_valid_q     <= 1'b0;
                    end else if (too_long_q) begin
                        last_digit_pos_q <= pos_q;
                    end else if (ndigits_q < 6'd19) begin
                        for (j = 18; j > 0; j = j - 1) digits_q[j] <= digits_q[j-1];
                        digits_q[0]      <= new_digit;
                        ndigits_q        <= ndigits_q + 6'd1;
                        last_digit_pos_q <= pos_q;
                    end else begin
                        // 主游程满了：先结算快照，再用影子顶替
                        if (snap_valid_q) begin
                            out_valid <= 1'b1;
                            out_start <= snap_start_q;
                            out_len   <= snap_last_q - snap_start_q + 32'd1;
                            out_type  <= snap_type_q;
                        end
                        if (sover_q || (snd_q >= 6'd19)) begin
                            too_long_q <= 1'b1;      // 影子也溢出：整段作废
                        end else begin
                            digits_q        <= {sdig_q[17:0], new_digit};
                            ndigits_q       <= snd_q + 6'd1;
                            has_x_q         <= shas_x_q;
                            run_start_q     <= (snd_q == 6'd0) ? pos_q : sstart_q;
                            too_long_q      <= 1'b0;
                        end
                        last_digit_pos_q <= pos_q;
                        // 影子从这个数字重新开始
                        sdig_q[0]    <= new_digit;
                        snd_q        <= 6'd1;
                        sstart_q     <= pos_q;
                        slast_q      <= pos_q;
                        shas_x_q     <= 1'b0;
                        sover_q      <= 1'b0;
                        snap_valid_q <= 1'b0;
                    end
                end else if (is_x && run_active_q && !too_long_q && (ndigits_q == 6'd17)) begin
                    for (j = 18; j > 0; j = j - 1) digits_q[j] <= digits_q[j-1];
                    digits_q[0]      <= 4'd10;
                    ndigits_q        <= 6'd18;
                    has_x_q          <= 1'b1;
                    last_digit_pos_q <= pos_q;

                    if (!sover_q && (snd_q == 6'd17)) begin
                        for (jj = 18; jj > 0; jj = jj - 1) sdig_q[jj] <= sdig_q[jj-1];
                        sdig_q[0] <= 4'd10;
                        snd_q     <= 6'd18;
                        shas_x_q  <= 1'b1;
                        slast_q   <= pos_q;
                    end
                end else if (is_sep) begin
                    // 游程内的透明分隔符：不结束、不计入 span 尾部；只更新快照与影子
                    if (run_active_q) begin
                        snap_valid_q <= !too_long_q && (hit_type != 3'd0);
                        snap_type_q  <= hit_type;
                        snap_start_q <= run_start_q;
                        snap_last_q  <= last_digit_pos_q;
                        snd_q        <= 6'd0;
                        sover_q      <= 1'b0;
                        shas_x_q     <= 1'b0;
                    end
                end else begin
                    if (run_active_q && (close_type != 3'd0)) begin
                        out_valid <= 1'b1;
                        out_start <= run_start_q;
                        out_len   <= last_digit_pos_q - run_start_q + 32'd1;
                        out_type  <= close_type;
                    end
                    run_active_q <= 1'b0;
                    ndigits_q    <= 6'd0;
                    has_x_q      <= 1'b0;
                    too_long_q   <= 1'b0;
                    snd_q        <= 6'd0;
                    sover_q      <= 1'b0;
                    snap_valid_q <= 1'b0;
                end
            end
        end
    end

endmodule