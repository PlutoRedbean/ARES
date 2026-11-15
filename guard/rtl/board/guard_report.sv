// guard/rtl/board/guard_report.sv
//
// 每帧脱敏结束后的一行审计摘要（ASCII，固定宽度数字）：
//
//   \r\n[guard] n=NNN id18=NNN id15=NNN mobile=NNN bank=NNN email=NNN
//           ipv4=NNN uscc=NNN plate=NNN ovf=NNN\r\n
//
// 数字统一 3 位零填充（0..255），所以整行长度固定 = 10 个字段 × (label+3)。
// 行首是否补 \r\n 取决于上一个输出字节是不是 LF（at_line_start），
// 这样纯文本行后面不会多出空行，而没换行结尾的文本也不会把摘要粘在行尾。
//
// 只做“格式化”，不带任何判断：值由 core 在报告开始那一拍锁存。
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集（logic/always_ff/always_comb/函数），
// 不用 interface/struct/动态数组。

`timescale 1ns/1ps

module guard_report (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       start,          // 1 拍：锁存数值并开始输出
    input  logic       at_line_start,  // 上一个输出字节是 LF
    input  logic [7:0] v_n,
    input  logic [7:0] v_id18,
    input  logic [7:0] v_id15,
    input  logic [7:0] v_mobile,
    input  logic [7:0] v_bank,
    input  logic [7:0] v_email,
    input  logic [7:0] v_ipv4,
    input  logic [7:0] v_uscc,
    input  logic [7:0] v_plate,
    input  logic       v_err,

    output logic [7:0] byte_out,
    output logic       byte_valid,     // 有字节待送（还要看 fifo_full）
    input  logic       fifo_full,
    output logic       busy,
    output logic       finished        // 1 拍：最后一个字节已送走
);

    localparam logic [3:0] F_TAIL = 4'd10;

    logic [3:0]  fld;
    logic [4:0]  pos;
    logic        run;
    logic        pref;
    logic        fin_q;

    logic [7:0]  n_q, id18_q, id15_q, mob_q, bank_q, mail_q, ip_q, uscc_q, plate_q;
    logic        err_q;

    // ---------------- 十进制 3 位（BIN → BCD），v <= 255 ----------------
    // 不能用"减 10 循环 25 次"：那是 25 级串行依赖，ADS 综合出来是几十级
    // 逻辑，直接成为时序关键路径。这里用比较树 + 一次减法，
    // 约 4–5 级。
    function automatic logic [11:0] bcd3(input logic [7:0] v);
        logic [7:0] r, t10, u;
        logic [3:0] t, h;
        begin
            if (v >= 8'd200)      begin h = 4'd2; r = v - 8'd200; end
            else if (v >= 8'd100) begin h = 4'd1; r = v - 8'd100; end
            else                  begin h = 4'd0; r = v;         end

            if      (r >= 8'd90) t = 4'd9;
            else if (r >= 8'd80) t = 4'd8;
            else if (r >= 8'd70) t = 4'd7;
            else if (r >= 8'd60) t = 4'd6;
            else if (r >= 8'd50) t = 4'd5;
            else if (r >= 8'd40) t = 4'd4;
            else if (r >= 8'd30) t = 4'd3;
            else if (r >= 8'd20) t = 4'd2;
            else if (r >= 8'd10) t = 4'd1;
            else                 t = 4'd0;

            // t*10 = t*8 + t*2（最大 90，8 位够），不用乘法器
            t10 = {t, 3'b000};
            t10 = t10 + {t, 1'b0};
            u   = r - t10;
            bcd3 = {h, t, u[3:0]};      // 注意只要低 4 位，否则 8 位 u 会把 h 挤掉
        end
    endfunction

    // ---------------- 字段表 ----------------
    logic [95:0] lab;       // 最多 12 字节：[guard] n= 前补 CRLF 正好 12 字节
    logic [3:0]  lab_len;
    logic [7:0]  fval;
    logic [11:0] bcd;

    always_comb begin
        lab     = 96'd0;
        lab_len = 4'd0;
        fval    = 8'd0;
        case (fld)
            4'd0: begin
                // 只发 LF：core 的 TX 整形会把每个 LF 补成 CRLF（包括摘要行），
                // 这里自己再写 CR 会出现 \r\r\n。
                if (pref) begin lab = "\n[guard] n="; lab_len = 4'd11; end
                else      begin lab = "[guard] n=";    lab_len = 4'd10; end
                fval = n_q;
            end
            4'd1: begin lab = " id18=";   lab_len = 4'd6; fval = id18_q; end
            4'd2: begin lab = " id15=";   lab_len = 4'd6; fval = id15_q; end
            4'd3: begin lab = " mobile="; lab_len = 4'd8; fval = mob_q;  end
            4'd4: begin lab = " bank=";   lab_len = 4'd6; fval = bank_q; end
            4'd5: begin lab = " email=";  lab_len = 4'd7; fval = mail_q; end
            4'd6: begin lab = " ipv4=";   lab_len = 4'd6; fval = ip_q;   end
            4'd7: begin lab = " uscc=";   lab_len = 4'd6; fval = uscc_q; end
            4'd8: begin lab = " plate=";  lab_len = 4'd7; fval = plate_q; end
            4'd9: begin lab = " ovf=";    lab_len = 4'd5; fval = {7'd0, err_q}; end
            default: begin lab = 96'd0; lab_len = 4'd0; fval = 8'd0; end
        endcase
        bcd = bcd3(fval);
    end

    wire [3:0] fld_len = (fld == F_TAIL) ? 4'd1 : (lab_len + 4'd3);

    // ---------------- 当前字节 ----------------
    // 字符串字面量赋给 96 位向量时是右对齐的：第 0 个字符在 bit 8*(len-1)。
    // 所以第 pos 个字符 = (lab >> 8*(len-1-pos)) 的低字节。用移位而不是变址
    // 片选，避免 pos>=len 时算出越界下标（PDS 会报 SELRANGE）。
    logic [95:0] lab_sh;
    logic [6:0]  shamt;

    always_comb begin
        lab_sh = 96'd0;
        byte_out = 8'd0;
        if (fld == F_TAIL) begin
            byte_out = 8'h0A;                  // 行尾只要 LF，CR 由 TX 整形补
        end else if (pos < {1'b0, lab_len}) begin
            shamt   = ({3'd0, lab_len} - {2'd0, pos} - 7'd1) << 3;
            lab_sh  = lab >> shamt;
            byte_out = lab_sh[7:0];
        end else begin
            case (pos - {1'b0, lab_len})
                5'd0:    byte_out = 8'h30 + {4'd0, bcd[11:8]};
                5'd1:    byte_out = 8'h30 + {4'd0, bcd[7:4]};
                default: byte_out = 8'h30 + {4'd0, bcd[3:0]};
            endcase
        end
    end

    assign byte_valid = run;
    assign busy       = run || fin_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fld   <= 4'd0;
            pos   <= 5'd0;
            run   <= 1'b0;
            pref  <= 1'b0;
            fin_q <= 1'b0;
            n_q <= 8'd0; id18_q <= 8'd0; id15_q <= 8'd0; mob_q <= 8'd0;
            bank_q <= 8'd0; mail_q <= 8'd0; ip_q <= 8'd0; uscc_q <= 8'd0;
            plate_q <= 8'd0; err_q <= 1'b0;
        end else begin
            fin_q <= 1'b0;
            if (start) begin
                run   <= 1'b1;
                fld   <= 4'd0;
                pos   <= 5'd0;
                pref  <= ~at_line_start;
                n_q     <= v_n;
                id18_q  <= v_id18;
                id15_q  <= v_id15;
                mob_q   <= v_mobile;
                bank_q  <= v_bank;
                mail_q  <= v_email;
                ip_q    <= v_ipv4;
                uscc_q  <= v_uscc;
                plate_q <= v_plate;
                err_q   <= v_err;
            end else if (run && !fifo_full) begin
                if (pos + 5'd1 >= {1'b0, fld_len}) begin
                    pos <= 5'd0;
                    if (fld == F_TAIL) begin
                        run   <= 1'b0;
                        fin_q <= 1'b1;
                    end else begin
                        fld <= fld + 4'd1;
                    end
                end else begin
                    pos <= pos + 5'd1;
                end
            end
        end
    end

endmodule
