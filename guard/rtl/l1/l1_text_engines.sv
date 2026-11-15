// guard/rtl/l1/l1_text_engines.sv
//
// L1 文本类引擎：邮箱、IPv4、统一社会信用代码（USCC）、车牌。
// 每个引擎独立工作在同一字符流上，各自输出 (start, len) 命中脉冲；
// 重叠的命中由上层（M2 策略）处理，L1 只负责"报出来"。
//
// 与 host/golden/pii_rules.py 的 _email_ok / _ipv4_ok / _uscc_ok / _plate_at
// 逐条对齐。

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
    logic        run_q, good_q;
    logic [31:0] start_q, last_good_q;
    logic [6:0]  len_q;
    logic        too_long_q;
    logic [63:0][7:0] buf_q;

    logic accept;
    assign accept = is_alnum(in_char) || in_char == 8'h2E || in_char == 8'h5F ||
                    in_char == 8'h25 || in_char == 8'h2B || in_char == 8'h2D ||
                    in_char == 8'h40;

    // ---------------- validation (combinational over the buffered run) ----
    logic [6:0] slen;
    logic [5:0] at_pos, last_dot;
    integer     nat, ndots, tld_len;
    logic       ok;
    integer     i;

    always_comb begin
        ok       = 1'b0;
        at_pos   = 6'd0;
        nat      = 0;
        ndots    = 0;
        last_dot = 6'd0;
        tld_len  = 0;
        slen     = 7'd0;

        if (run_q && !too_long_q && good_q && (last_good_q >= start_q)) begin
            slen = 7'(last_good_q - start_q + 32'd1);
            if (slen >= 7'd5 && slen <= 7'd64) begin
                for (i = 0; i < MAXLEN; i = i + 1) begin
                    if (i < slen && buf_q[i] == 8'h40) begin
                        at_pos = 6'(i);
                        nat    = nat + 1;
                    end
                end
                if (nat == 1 && at_pos >= 1 && at_pos <= 32) begin
                    ok = 1'b1;
                    if (buf_q[0] == 8'h2E) ok = 1'b0;
                    if (buf_q[at_pos - 1] == 8'h2E) ok = 1'b0;
                    for (i = 0; i < MAXLEN - 1; i = i + 1) begin
                        if (i + 1 < at_pos && buf_q[i] == 8'h2E && buf_q[i + 1] == 8'h2E)
                            ok = 1'b0;
                    end
                    if (int'(at_pos) + 1 >= int'(slen)) ok = 1'b0;
                    if (ok && buf_q[at_pos + 1] == 8'h2E) ok = 1'b0;
                    if (ok && buf_q[at_pos + 1] == 8'h2D) ok = 1'b0;
                    if (ok && buf_q[slen - 1] == 8'h2E) ok = 1'b0;
                    for (i = 0; i < MAXLEN; i = i + 1) begin
                        if (ok && i > at_pos && i < slen) begin
                            if (buf_q[i] == 8'h2E) begin
                                ndots    = ndots + 1;
                                last_dot = 6'(i);
                                if (i + 1 < slen && buf_q[i + 1] == 8'h2E) ok = 1'b0;
                                if (i + 1 < slen && buf_q[i + 1] == 8'h2D) ok = 1'b0;
                                if (i > 0 && buf_q[i - 1] == 8'h2D) ok = 1'b0;
                            end else if (!is_alnum(buf_q[i]) && buf_q[i] != 8'h2D) begin
                                ok = 1'b0;
                            end
                        end
                    end
                    if (ok && ndots < 1) ok = 1'b0;
                    if (ok) begin
                        tld_len = int'(slen) - 1 - int'(last_dot);
                        if (tld_len < 2 || tld_len > 24) ok = 1'b0;
                    end
                    for (i = 0; i < MAXLEN; i = i + 1) begin
                        if (ok && i > last_dot && i < slen && !is_alpha(buf_q[i])) ok = 1'b0;
                    end
                end
            end
        end
    end

    // ---------------- sequential -----------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; good_q <= 1'b0;
            start_q <= 32'd0; last_good_q <= 32'd0;
            len_q <= 7'd0; too_long_q <= 1'b0; buf_q <= '0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok) begin
                    out_valid <= 1'b1;
                    out_start <= start_q;
                    out_len   <= 8'(slen);
                end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (accept) begin
                    if (!run_q) begin
                        run_q      <= 1'b1;
                        start_q    <= pos_q;
                        len_q      <= 7'd1;
                        too_long_q <= 1'b0;
                        buf_q[0]   <= in_char;
                        good_q     <= (in_char != 8'h2E);
                        last_good_q <= pos_q;
                    end else if (len_q < 7'd64) begin
                        buf_q[len_q] <= in_char;
                        len_q <= len_q + 7'd1;
                        if (in_char != 8'h2E) begin
                            last_good_q <= pos_q;
                            good_q      <= 1'b1;
                        end
                    end else begin
                        too_long_q <= 1'b1;
                    end
                end else begin
                    if (ok) begin
                        out_valid <= 1'b1;
                        out_start <= start_q;
                        out_len   <= 8'(slen);
                    end
                    run_q <= 1'b0;
                end
            end
        end
    end

endmodule

// ---------------------------------------------------------------- IPv4
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

    logic [31:0] pos_q;
    logic        run_q, good_q;
    logic [31:0] start_q, last_good_q;
    logic [5:0]  len_q;
    logic        too_long_q;
    logic [15:0][7:0] buf_q;

    logic accept;
    assign accept = is_digit(in_char) || in_char == 8'h2E;

    logic [5:0] slen;
    logic       ok;
    integer     i, groups, ndig, val, lead_zero;

    always_comb begin
        ok = 1'b0; slen = 6'd0;
        groups = 0; ndig = 0; val = 0; lead_zero = 0;
        if (run_q && !too_long_q && good_q && (last_good_q >= start_q)) begin
            slen = 6'(last_good_q - start_q + 32'd1);
            if (slen >= 6'd7 && slen <= 6'd15) begin
                ok = 1'b1;
                for (i = 0; i < 16; i = i + 1) begin
                    if (ok && i < slen) begin
                        if (buf_q[i] == 8'h2E) begin
                            if (ndig == 0) ok = 1'b0;
                            if (lead_zero != 0 && ndig > 1) ok = 1'b0;
                            if (val > 255) ok = 1'b0;
                            groups = groups + 1;
                            ndig = 0; val = 0; lead_zero = 0;
                        end else begin
                            if (ndig == 0 && buf_q[i] == 8'h30) lead_zero = 1;
                            val = val * 10 + int'(buf_q[i] - 8'h30);
                            ndig = ndig + 1;
                            if (ndig > 3) ok = 1'b0;
                        end
                    end
                end
                if (ok) begin
                    if (groups != 3) ok = 1'b0;
                    if (ndig == 0) ok = 1'b0;
                    if (lead_zero != 0 && ndig > 1) ok = 1'b0;
                    if (val > 255) ok = 1'b0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; good_q <= 1'b0;
            start_q <= 32'd0; last_good_q <= 32'd0;
            len_q <= 6'd0; too_long_q <= 1'b0; buf_q <= '0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok) begin
                    out_valid <= 1'b1; out_start <= start_q; out_len <= 8'(slen);
                end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (accept) begin
                    if (!run_q) begin
                        run_q <= 1'b1; start_q <= pos_q; len_q <= 6'd1;
                        too_long_q <= 1'b0; buf_q[0] <= in_char;
                        good_q <= (in_char != 8'h2E);
                        last_good_q <= pos_q;
                    end else if (len_q < 6'd16) begin
                        buf_q[len_q] <= in_char;
                        len_q <= len_q + 6'd1;
                        if (in_char != 8'h2E) begin
                            last_good_q <= pos_q;
                            good_q      <= 1'b1;
                        end
                    end else begin
                        too_long_q <= 1'b1;
                    end
                end else begin
                    if (ok) begin
                        out_valid <= 1'b1; out_start <= start_q; out_len <= 8'(slen);
                    end
                    run_q <= 1'b0;
                end
            end
        end
    end

endmodule

// ---------------------------------------------------------------- USCC
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

    logic [31:0] pos_q;
    logic        run_q;
    logic [31:0] start_q;
    logic [5:0]  len_q;
    logic        too_long_q;
    logic [17:0][7:0] buf_q;

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

    logic [15:0] total_w;
    logic        has_alpha;
    logic [5:0]  check;
    logic        ok;
    integer      i;

    always_comb begin
        total_w   = 16'd0;
        has_alpha = 1'b0;
        check     = 6'd0;
        ok        = 1'b0;
        if (run_q && !too_long_q && (len_q == 6'd18)) begin
            for (i = 0; i < 18; i = i + 1) begin
                if (i < 17) total_w = total_w + uscc_weight(5'(i)) * uscc_idx(buf_q[i]);
                if (is_alpha(buf_q[i])) has_alpha = 1'b1;
            end
            check = 6'(31 - (total_w % 16'd31));
            if (check == 6'd31) check = 6'd0;
            if (has_alpha && uscc_idx(buf_q[17]) == check) ok = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; run_q <= 1'b0; start_q <= 32'd0; len_q <= 6'd0;
            too_long_q <= 1'b0; buf_q <= '0;
            out_valid <= 1'b0; out_start <= 32'd0; out_len <= 8'd0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) pos_q <= pos_q + 32'd1;

            if (in_last) begin
                if (ok) begin out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd18; end
                run_q <= 1'b0;
            end else if (in_valid) begin
                if (accept) begin
                    if (!run_q) begin
                        run_q <= 1'b1; start_q <= pos_q; len_q <= 6'd1;
                        too_long_q <= 1'b0; buf_q[0] <= in_char;
                    end else if (len_q < 6'd18) begin
                        buf_q[len_q] <= in_char; len_q <= len_q + 6'd1;
                    end else begin
                        too_long_q <= 1'b1;
                    end
                end else begin
                    if (ok) begin out_valid <= 1'b1; out_start <= start_q; out_len <= 8'd18; end
                    run_q <= 1'b0;
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
