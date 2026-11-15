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

    input  logic [4:0]        src_valid,
    input  logic [4:0][31:0] src_start,
    input  logic [4:0][7:0]  src_len,
    input  logic [4:0][3:0]  src_type,

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
    int               free_list [0:NSLOT-1];
    int               nfree;

    always_comb begin
        nv = sv;
        for (int i = 0; i < NSLOT; i++) begin
            nss[i] = ss[i];
            nsl[i] = sl[i];
            nst[i] = st[i];
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
            for (int i = 0; i < NSLOT; i++) begin
                if (sv[i] && (ss[i] < nlast_end) && (ss[i] + {24'd0, sl[i]} > ss[sel]))
                    nv[i] = 1'b0;   // 与刚提交的 span 重叠
            end
        end

        // 收集空闲槽
        nfree = 0;
        for (int i = 0; i < NSLOT; i++) begin
            if (!nv[i]) begin
                free_list[nfree] = i;
                nfree = nfree + 1;
            end
        end

        // 依次插入 5 路新命中
        for (int j = 0; j < 5; j++) begin
            if (src_valid[j]) begin
                if (src_start[j] < nlast_end) begin
                    ndrop = ndrop + 16'd1;
                end else if (nfree > 0) begin
                    automatic int tgt = free_list[0];
                    nv[tgt]  = 1'b1;
                    nss[tgt] = src_start[j];
                    nsl[tgt] = src_len[j];
                    nst[tgt] = src_type[j];
                    for (int k = 1; k < NSLOT; k++) free_list[k - 1] = free_list[k];
                    nfree = nfree - 1;
                end else begin
                    ndrop = ndrop + 16'd1;
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

    output logic        out_valid,
    output logic [7:0]  out_char,

    output logic        a_valid,
    output logic [31:0] a_start,
    output logic [7:0]  a_len,
    output logic [3:0]  a_type,

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
            if (ncount > 0 && (eos_q || ((pos_q - nout_pos) >= 32'(WINDOW + 2)))) begin
                out_valid <= 1'b1;
                if (active_q) begin
                    if (sp_len_q > 8'd4 && idx_q < sp_len_q - 8'd4)
                        out_char <= 8'h2A;
                    else
                        out_char <= mem[rptr];
                    idx_q <= idx_q + 8'd1;
                    if (idx_q + 8'd1 >= sp_len_q) active_q <= 1'b0;
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
    output logic [15:0] dropped
);

    wire        digit_valid, email_valid, ipv4_valid, uscc_valid, plate_valid;
    wire [31:0] digit_start, email_start, ipv4_start, uscc_start, plate_start;
    wire [7:0]  digit_len, email_len, ipv4_len, uscc_len, plate_len;
    wire [2:0]  digit_type;

    wire        kw_valid;   // 关键词只做提示，不参与替换
    wire [31:0] kw_start;
    wire [7:0]  kw_len;
    wire [2:0]  kw_kid;

    l1_engine u_eng (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .digit_valid(digit_valid), .digit_start(digit_start), .digit_len(digit_len), .digit_type(digit_type),
        .email_valid(email_valid), .email_start(email_start), .email_len(email_len),
        .ipv4_valid(ipv4_valid),   .ipv4_start(ipv4_start),   .ipv4_len(ipv4_len),
        .uscc_valid(uscc_valid),   .uscc_start(uscc_start),   .uscc_len(uscc_len),
        .plate_valid(plate_valid), .plate_start(plate_start), .plate_len(plate_len),
        .kw_valid(kw_valid), .kw_start(kw_start), .kw_len(kw_len), .kw_kid(kw_kid)
    );

    wire        c_valid;
    wire [31:0] c_start;
    wire [7:0]  c_len;
    wire [3:0]  c_type;
    wire        pending, quiet;

    l1_merge u_merge (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_last(in_last),
        .src_valid({plate_valid, uscc_valid, ipv4_valid, email_valid, digit_valid}),
        .src_start({plate_start, uscc_start, ipv4_start, email_start, digit_start}),
        .src_len  ({plate_len,   uscc_len,   ipv4_len,   email_len,   digit_len}),
        .src_type ({4'd8, 4'd7, 4'd6, 4'd5, {1'b0, digit_type}}),
        .c_valid(c_valid), .c_start(c_start), .c_len(c_len), .c_type(c_type),
        .pending(pending), .quiet(quiet), .dropped(dropped)
    );

    l1_redactor u_red (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .s_valid(c_valid), .s_start(c_start), .s_len(c_len), .s_type(c_type),
        .out_valid(out_valid), .out_char(out_char),
        .a_valid(a_valid), .a_start(a_start), .a_len(a_len), .a_type(a_type),
        .done(done), .ovf(ovf)
    );

endmodule
