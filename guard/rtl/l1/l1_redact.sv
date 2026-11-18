// guard/rtl/l1/l1_redact.sv
//
// M2：RTL 内的合并 + 替换（mask 策略，1:1 保持长度，不需要反压）。
//
//   l1_merge    ：5 路命中 → 按 (start, 优先级, 长度) 裁决重叠，延迟 64 字节提交
//   l1_redactor ：字节 FIFO 滞后 64 字节输出；命中区间除最后 4 字节外全部替换为 '*'
//   l1_redact_top：l1_engine + 上面两个
//
// 与 host/golden/redact.py 的 merge() 和 mask 策略逐条对齐。

`timescale 1ns/1ps

package l1_redact_pkg;

    function automatic logic [3:0] type_prio(input logic [3:0] t);
        case (t)
            4'd5: type_prio = 4'd1;   // email
            4'd8: type_prio = 4'd2;   // plate
            4'd7: type_prio = 4'd3;   // uscc
            4'd6: type_prio = 4'd4;   // ipv4
            4'd1: type_prio = 4'd5;   // id18
            4'd2: type_prio = 4'd6;   // id15
            4'd3: type_prio = 4'd7;   // mobile
            4'd4: type_prio = 4'd8;   // bank
            4'd10: type_prio = 4'd9;  // addr（实体层让位给结构化 PII）
            4'd9:  type_prio = 4'd10; // name
            default: type_prio = 4'd15;
        endcase
    endfunction

    localparam int WINDOW = 64;

endpackage

// ---------------------------------------------------------------- merge
module l1_merge (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,   // 与字符流同步，用于推进位置
    input  logic        in_last,

    input  logic [5:0]        src_valid,
    input  logic [5:0][31:0] src_start,
    input  logic [5:0][7:0]  src_len,
    input  logic [5:0][3:0]  src_type,

    output logic        c_valid,
    output logic [31:0] c_start,
    output logic [7:0]  c_len,
    output logic [3:0]  c_type,

    output logic        pending,    // 还有待提交的 span
    output logic        quiet,      // 已 flush 且没有待提交
    output logic [15:0] dropped
);

    import l1_redact_pkg::*;

    localparam int NSLOT = 8;

    logic [31:0] pos_q, last_end_q;
    logic        flush_q;
    logic [15:0] dropped_q;

    logic [NSLOT-1:0] sv;
    logic [31:0]      ss [0:NSLOT-1];
    logic [7:0]       sl [0:NSLOT-1];
    logic [3:0]       st [0:NSLOT-1];

    // ---------------- 选择要提交的 slot（最小 start，其次优先级/更长） ----
    integer sel;
    logic   sel_ok;
    logic [31:0] best_start;
    logic [3:0]  best_prio;
    logic [7:0]  best_len;

    always_comb begin
        sel = -1;
        sel_ok = 1'b0;
        best_start = 32'hFFFF_FFFF;
        best_prio  = 4'd15;
        best_len   = 8'd0;
        for (int i = 0; i < NSLOT; i++) begin
            if (sv[i]) begin
                if (!sel_ok ||
                    (ss[i] < best_start) ||
                    (ss[i] == best_start && type_prio(st[i]) < best_prio) ||
                    (ss[i] == best_start && type_prio(st[i]) == best_prio && sl[i] > best_len)) begin
                    sel = i;
                    sel_ok = 1'b1;
                    best_start = ss[i];
                    best_prio  = type_prio(st[i]);
                    best_len   = sl[i];
                end
            end
        end
    end

    logic do_commit;
    assign do_commit = sel_ok && (flush_q || (pos_q - ss[sel] >= 32'(WINDOW)));

    // ---------------- 下一状态（插入新命中 / 清除重叠） ----------------
    logic [NSLOT-1:0] nv;
    logic [31:0]      nss [0:NSLOT-1];
    logic [7:0]       nsl [0:NSLOT-1];
    logic [3:0]       nst [0:NSLOT-1];
    logic [31:0]      nlast_end;
    logic [15:0]      ndrop;

    // 循环变量用模块级 integer：ADS 对 always_comb 里的 int 临时数组
    // （原来的 free_list）会推出锁存器，锁存器在 PDS 里"没有时钟"，
    // 既不参与时序分析也不是我们想要的行为。改成"每次扫描空闲位、取编号
    // 最小的空槽"，与原 free_list[0] 语义完全相同，但不需要临时数组。
    integer           mi, mj, mtgt;

    always_comb begin
        nv = sv;
        for (mi = 0; mi < NSLOT; mi = mi + 1) begin
            nss[mi] = ss[mi];
            nsl[mi] = sl[mi];
            nst[mi] = st[mi];
        end
        nlast_end = last_end_q;
        ndrop = 16'd0;

        c_valid = 1'b0;
        c_start = 32'd0;
        c_len   = 8'd0;
        c_type  = 4'd0;

        if (do_commit) begin
            c_valid = 1'b1;
            c_start = ss[sel];
            c_len   = sl[sel];
            c_type  = st[sel];
            nlast_end = ss[sel] + {24'd0, sl[sel]};
            for (mi = 0; mi < NSLOT; mi = mi + 1) begin
                if (sv[mi] && (ss[mi] < nlast_end) && (ss[mi] + {24'd0, sl[mi]} > ss[sel]))
                    nv[mi] = 1'b0;   // 与刚提交的 span 重叠
            end
        end

        // 依次插入 6 路新命中：每个都占"编号最小的空槽"（原 free_list[0]）
        for (mj = 0; mj < 6; mj = mj + 1) begin
            if (src_valid[mj]) begin
                if (src_start[mj] < nlast_end) begin
                    ndrop = ndrop + 16'd1;
                end else begin
                    mtgt = -1;
                    for (mi = 0; mi < NSLOT; mi = mi + 1) begin
                        if (!nv[mi] && (mtgt < 0)) mtgt = mi;
                    end
                    if (mtgt >= 0) begin
                        nv[mtgt]  = 1'b1;
                        nss[mtgt] = src_start[mj];
                        nsl[mtgt] = src_len[mj];
                        nst[mtgt] = src_type[mj];
                    end else begin
                        ndrop = ndrop + 16'd1;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0;
            last_end_q <= 32'd0;
            flush_q <= 1'b0;
            dropped_q <= 16'd0;
            sv <= '0;
            for (int i = 0; i < NSLOT; i++) begin
                ss[i] <= '0; sl[i] <= '0; st[i] <= '0;
            end
        end else begin
            if (in_valid) pos_q <= pos_q + 32'd1;
            if (in_last)  flush_q <= 1'b1;
            sv <= nv;
            for (int i = 0; i < NSLOT; i++) begin
                ss[i] <= nss[i]; sl[i] <= nsl[i]; st[i] <= nst[i];
            end
            last_end_q <= nlast_end;
            dropped_q  <= dropped_q + ndrop;
        end
    end

    assign pending = |sv;
    assign quiet   = flush_q && !(|sv);
    assign dropped = dropped_q;

endmodule

// ---------------------------------------------------------------- redactor
module l1_redactor (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    input  logic        s_valid,
    input  logic [31:0] s_start,
    input  logic [7:0]  s_len,
    input  logic [3:0]  s_type,
    input  logic        s_hold,     // 帧尾保持输出：等合并器把最后几个 span 交出来

    output logic        out_valid,
    output logic [7:0]  out_char,

    output logic        a_valid,
    output logic [31:0] a_start,
    output logic [7:0]  a_len,
    output logic [3:0]  a_type,

    output logic        busy_l2b,     // L2b 正在推理：上层停止送数
    output logic        done,
    output logic        ovf
);

    import l1_redact_pkg::*;

    localparam int DEPTH = 128;
    localparam int SQ    = 8;

    logic [31:0] pos_q, out_pos_q;
    logic [6:0]  wptr, rptr;
    logic [7:0]  count;
    logic [DEPTH-1:0][7:0] mem;

    logic        eos_q, active_q;
    logic [31:0] sp_start_q;
    logic [7:0]  sp_len_q;
    logic [3:0]  sp_type_q;
    logic [7:0]  idx_q;
    logic        ovf_q;

    logic [SQ-1:0]       qv;
    logic [31:0]         qs [0:SQ-1];
    logic [7:0]          ql [0:SQ-1];
    logic [3:0]          qt [0:SQ-1];
    logic [3:0]          qhead, qtail, qcount;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pos_q <= 32'd0; out_pos_q <= 32'd0;
            wptr <= 7'd0; rptr <= 7'd0; count <= 8'd0;
            eos_q <= 1'b0; active_q <= 1'b0; sp_start_q <= 32'd0;
            sp_len_q <= 8'd0; sp_type_q <= 4'd0; idx_q <= 8'd0; ovf_q <= 1'b0;
            qv <= '0;
            for (int i = 0; i < SQ; i++) begin qs[i] <= '0; ql[i] <= '0; qt[i] <= '0; end
            qhead <= 4'd0; qtail <= 4'd0; qcount <= 4'd0;
            out_valid <= 1'b0; out_char <= 8'd0;
            a_valid <= 1'b0; a_start <= 32'd0; a_len <= 8'd0; a_type <= 4'd0;
            done <= 1'b0;
        end else begin
            logic [7:0]  ncount;
            logic [6:0]  nwptr, nrptr;
            logic [31:0] nout_pos;
            logic [3:0]  nh, nt, nc;
            logic        pop_q;
            logic [7:0]  mask_lim;

            ncount = count;
            nwptr  = wptr;
            nrptr  = rptr;
            nout_pos = out_pos_q;
            nh = qhead; nt = qtail; nc = qcount;
            pop_q = 1'b0;

            out_valid <= 1'b0;
            a_valid   <= 1'b0;
            done      <= 1'b0;

            if (in_last) eos_q <= 1'b1;
            if (in_valid) pos_q <= pos_q + 32'd1;

            // ---- 字节入队 ----
            if (in_valid) begin
                if (count < 8'd128) begin
                    mem[wptr] = in_char;
                    nwptr = wptr + 7'd1;
                    ncount = count + 8'd1;
                end else begin
                    ovf_q <= 1'b1;
                end
            end

            // ---- span 入队（审计同步发出） ----
            if (s_valid) begin
                a_valid <= 1'b1;
                a_start <= s_start;
                a_len   <= s_len;
                a_type  <= s_type;
                if (nc < 4'(SQ)) begin
                    qv[nt] <= 1'b1;
                    qs[nt] <= s_start;
                    ql[nt] <= s_len;
                    qt[nt] <= s_type;
                    nt = nt + 4'd1;
                    nc = nc + 4'd1;
                end else begin
                    ovf_q <= 1'b1;
                end
            end

            // ---- 出队 ----
            // 帧尾（eos）不能立刻 1:1 泄流：最后一个 span 要晚 1–2 拍才由合并器
            // 提交（见 l1_redact_top 的 quiet 计数器）。否则从这个位置直接外发，
            // span 起点已经过去了，它会永远留在队列里（漏脱敏 + done 卡死）。
            // 正常通路有 66 字节余量，不受影响。
            if (ncount > 0 && (((pos_q - nout_pos) >= 32'(WINDOW + 2)) ||
                               (eos_q && !s_hold))) begin
                out_valid <= 1'b1;
                if (active_q) begin
                    if ((sp_type_q >= 4'd9) || (sp_len_q > 8'd4 && idx_q < sp_len_q - 8'd4))
                        out_char <= 8'h2A;
                    else
                        out_char <= mem[rptr];
                    idx_q <= idx_q + 8'd1;
                    if (idx_q + 8'd1 >= sp_len_q) active_q <= 1'b0;
                end else if (nc > 4'd0 && qv[qhead] && (qs[qhead] < nout_pos)) begin
                    // 过期 span（帧尾才提交、起点已在身后）：直接丢，否则队列头永远等不到
                    pop_q = 1'b1;
                    out_char <= mem[rptr];
                end else if (nc > 4'd0 && qv[qhead] && (qs[qhead] == nout_pos)) begin
                    active_q  <= 1'b1;
                    sp_start_q <= qs[qhead];
                    sp_len_q   <= ql[qhead];
                    sp_type_q  <= qt[qhead];
                    idx_q      <= 8'd1;
                    out_char   <= (ql[qhead] > 8'd4) ? 8'h2A : mem[rptr];
                    if (ql[qhead] == 8'd1) active_q <= 1'b0;
                    pop_q = 1'b1;
                end else begin
                    out_char <= mem[rptr];
                end
                nrptr = rptr + 7'd1;
                ncount = ncount - 8'd1;
                nout_pos = nout_pos + 32'd1;
            end

            if (pop_q) begin
                nh = nh + 4'd1;
                nc = nc - 4'd1;
                qv[qhead] <= 1'b0;
            end

            rptr <= nrptr;
            wptr <= nwptr;
            count <= ncount;
            out_pos_q <= nout_pos;
            qhead <= nh;
            qtail <= nt;
            qcount <= nc;

            if (eos_q && ncount == 0 && !active_q && nc == 4'd0 && !in_valid) done <= 1'b1;
        end
    end

    assign ovf = ovf_q;

endmodule

// ---------------------------------------------------------------- top
module l1_redact_top (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [7:0]  in_char,
    input  logic        in_last,

    output logic        out_valid,
    output logic [7:0]  out_char,

    output logic        a_valid,
    output logic [31:0] a_start,
    output logic [7:0]  a_len,
    output logic [3:0]  a_type,

    output logic        done,
    output logic        ovf,
    output logic [15:0] dropped,

    // 关键词提示（只给板级摘要用，不参与替换）
    output logic        kw_valid,
    output logic [2:0]  kw_kid
);

    wire        digit_valid, email_valid, ipv4_valid, uscc_valid, plate_valid;
    wire [31:0] digit_start, email_start, ipv4_start, uscc_start, plate_start;
    wire [7:0]  digit_len, email_len, ipv4_len, uscc_len, plate_len;
    wire [2:0]  digit_type;

    wire [31:0] kw_start;
    wire [7:0]  kw_len;

    wire        ent_valid;
    wire        ent_busy;
    wire [31:0] ent_start;
    wire [7:0]  ent_len;
    wire [3:0]  ent_type;

    l1_engine u_eng (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .digit_valid(digit_valid), .digit_start(digit_start), .digit_len(digit_len), .digit_type(digit_type),
        .email_valid(email_valid), .email_start(email_start), .email_len(email_len),
        .ipv4_valid(ipv4_valid),   .ipv4_start(ipv4_start),   .ipv4_len(ipv4_len),
        .uscc_valid(uscc_valid),   .uscc_start(uscc_start),   .uscc_len(uscc_len),
        .plate_valid(plate_valid), .plate_start(plate_start), .plate_len(plate_len),
        .kw_valid(kw_valid), .kw_start(kw_start), .kw_len(kw_len), .kw_kid(kw_kid),
        .ent_valid(ent_valid), .ent_start(ent_start), .ent_len(ent_len), .ent_type(ent_type),
        .ent_busy(ent_busy)
    );

    wire        c_valid;
    wire [31:0] c_start;
    wire [7:0]  c_len;
    wire [3:0]  c_type;
    wire        pending, quiet;

    // 帧尾沉降：最后一个 span 在 in_last 之后 1–2 拍才提交，提交那一刻 pending
    // 还会短暂为 0。等 quiet 连续保持 RIPEN 拍，才认为合并器真的交完了，
    // 替换器这时才开始泄流。
    localparam logic [3:0] RIPEN = 4'd4;

    logic [3:0] quiet_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            quiet_cnt <= 4'd0;
        end else if (quiet && (quiet_cnt != 4'd15)) begin
            quiet_cnt <= quiet_cnt + 4'd1;
        end else if (!quiet) begin
            quiet_cnt <= 4'd0;
        end
    end

    wire flush_hold = (quiet_cnt < RIPEN);

    // 帧尾延迟 2 拍再通知合并器：实体引擎在 in_last 那拍才吐"帧尾收尾"的 span，
    // 同拍 flush 会让它落到替换器出队指针之后（漏遮 + done 卡死）。
    logic [1:0] last_dly_q;
    always_ff @(posedge clk) begin
        if (!rst_n) last_dly_q <= 2'd0;
        else        last_dly_q <= {last_dly_q[0], in_last};
    end

    assign busy_l2b = ent_busy;

    l1_merge u_merge (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_last(last_dly_q[1]),
        .src_valid({ent_valid, plate_valid, uscc_valid, ipv4_valid, email_valid, digit_valid}),
        .src_start({ent_start, plate_start, uscc_start, ipv4_start, email_start, digit_start}),
        .src_len  ({ent_len,   plate_len,   uscc_len,   ipv4_len,   email_len,   digit_len}),
        .src_type ({ent_type,  4'd8,        4'd7,        4'd6,        4'd5,        {1'b0, digit_type}}),
        .c_valid(c_valid), .c_start(c_start), .c_len(c_len), .c_type(c_type),
        .pending(pending), .quiet(quiet), .dropped(dropped)
    );

    l1_redactor u_red (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .s_valid(c_valid), .s_start(c_start), .s_len(c_len), .s_type(c_type),
        .s_hold(flush_hold),
        .out_valid(out_valid), .out_char(out_char),
        .a_valid(a_valid), .a_start(a_start), .a_len(a_len), .a_type(a_type),
        .done(done), .ovf(ovf)
    );

endmodule