// guard/rtl/board/guard_uart_core.sv
//
// 串口 ⇄ L1 脱敏流水线的桥：
//
//   uart_rx ─► RX FIFO ─► l1_redact_top ─► TX FIFO ─► uart_tx
//                            │
//                            └─ 每帧结束（LF 或空闲超时）后输出一行审计摘要
//
// 三个关键机制：
//
// 1) 冲刷（帧边界）：L1 引擎只有看到 in_last 才会关闭当前数字/字符串游程，
//    也才会把 64 字节回退窗口里的尾巴冲出来。本模块在收到 LF 之后（或连续
//    空闲超过 IDLE_BITS 个位时间（默认 300000 ≈ 2.6 s @115200）之后）打一拍
//    in_last，等 l1_redactor 的 done，
//    再输出摘要、复位流水线，进入下一帧。
//
// 2) 流控：脱敏器输出没有反压，1 字节/拍；串口发是 1 字节/86.8 µs（115200）。
//    这里用一条不变量保证 TX FIFO 永不溢出：
//        txq_level + inflight <= DEPTH-2  且  inflight < 128
//    其中 inflight = 已进脱敏器 - 已出脱敏器（等于它 128 字节缓冲里的字节数）。
//    只有当不变量还成立时才把 RX 的字节送进流水线；出队不改变左边之和。
//    这样既不用改已验证的 l1_redact.sv，也不需要给输出加反压。
//
// 3) 帧间复位：l1_merge / l1_redactor 的 flush_q / eos_q 在 in_last 之后一直
//    保持，没有“重新开始”的入口。每帧结束后把流水线软复位 8 拍，下一帧从
//    干净状态开始（TX/RX FIFO 不受影响，已脱敏的字节继续发）。
//
// 协议（ASCII，115200 8N1）：
//   · 上位机随便发文本；板子边收边回脱敏后的文本（mask 策略，长度不变）
//   · LF 或空闲自动结束当前帧，随后回一行
//       [guard] n=NNN id18=NNN id15=NNN mobile=NNN bank=NNN email=NNN
//               ipv4=NNN uscc=NNN plate=NNN ovf=NNN
//   · 数字固定 3 位零填充；n=本帧提交的 span 总数，ovf=本帧是否出过错
//
// 目标：盘古 200Pro+/PG2L200H，PDS 2025.2（ADS）与 Verilator 双栈验证。
// 约定：只用可综合的 SystemVerilog 子集。

`timescale 1ns/1ps

module guard_uart_core #(
    parameter int CLK_FREQ   = 10_000_000,
    parameter int BAUD       = 115200,
    parameter int OV         = 16,
    parameter int AW         = 8,          // 收发 FIFO 深度 = 2^AW 字节
    parameter int LF_TO_CRLF = 1,          // 输出把 LF 补成 CRLF（终端友好）
    parameter int REPORT_EN  = 1,          // 每帧结束回一行审计摘要
    parameter int IDLE_BITS  = 300000       // 空闲多少个位时间后强制冲刷（≈2.6 s @115200）
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       uart_rx,
    output logic       uart_tx,

    // 状态输出（板级 LED / 调试）
    output logic       st_rx,       // 收到一个字节（1 拍）
    output logic       st_tx,       // 发出一个字节（1 拍）
    output logic       st_hit,      // 提交一个 span（1 拍）
    output logic       st_busy,     // 当前帧未结束
    output logic       st_err,      // 粘滞错误（溢出/丢字节/帧错误）
    output logic [7:0] st_n         // 上一帧提交的 span 数
);

    localparam int DEPTH = 1 << AW;
    localparam logic [AW:0] LIMIT = DEPTH - 2;
    localparam logic [31:0] IDLE_TICKS = (CLK_FREQ / BAUD) * IDLE_BITS;

    localparam logic [1:0] F_RUN   = 2'd0;
    localparam logic [1:0] F_FLUSH = 2'd1;
    localparam logic [1:0] F_RPT   = 2'd2;
    localparam logic [1:0] F_RST   = 2'd3;

    // ---------------- 声明（先声明后使用，ADS 不接受隐式 net） ----------------
    logic        tick;

    logic [7:0]  rx_byte;
    logic        rx_valid, rx_frame_err;

    logic [7:0]  tx_byte;
    logic        tx_valid, tx_ready;

    logic [7:0]  rxq_dout;
    logic        rxq_empty, rxq_full, rxq_pop;
    logic [AW:0] rxq_level;

    logic [7:0]  txq_din, txq_dout;
    logic        txq_push, txq_pop, txq_empty, txq_full;
    logic [AW:0] txq_level;

    logic        hold_valid;
    logic [7:0]  hold_byte;

    logic        l1_rst_n;
    logic        in_valid;
    logic [7:0]  in_char;
    logic        in_last;
    logic        out_valid;
    logic [7:0]  out_char;
    logic        a_valid;
    logic [31:0] a_start;
    logic [7:0]  a_len;
    logic [3:0]  a_type;
    logic        done_q, ovf_q;
    logic [15:0] dropped_q;

    logic [7:0]  rpt_byte;
    logic        rpt_valid, rpt_busy, rpt_fin, rpt_start;

    logic [7:0]  c_n, c_id18, c_id15, c_mob, c_bank, c_mail, c_ip, c_uscc, c_plate;

    logic [1:0]  fst;
    logic [3:0]  rst_cnt;
    logic [31:0] idle_cnt;
    logic [7:0]  frame_bytes;
    logic        in_last_r;
    logic [7:0]  last_n;
    logic        at_line_start;
    logic        at_line_start_now;   // 本拍结束后的行首状态（摘要行首要不要补 LF）
    logic        err_q, err_sticky;
    logic [15:0] inflight;
    logic        rpt_seen;      // 报告确实开始过（busy 电平握手用）

    wire [15:0] sum_level;
    wire        flow_ok;
    wire        accept;
    wire        idle_flush;
    wire        txt_push, rpt_push;
    wire        frame_err_now;

    // =====================================================================
    // 串口物理层
    // =====================================================================
    guard_uart_baud #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .OV(OV)) u_baud (
        .clk(clk), .rst_n(rst_n), .tick(tick)
    );

    guard_uart_rx #(.OV(OV)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx), .tick(tick),
        .data(rx_byte), .valid(rx_valid), .frame_err(rx_frame_err)
    );

    guard_uart_tx #(.OV(OV)) u_tx (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    // =====================================================================
    // 收发 FIFO
    // =====================================================================
    guard_fifo #(.AW(AW)) u_rxq (
        .clk(clk), .rst_n(rst_n),
        .din(rx_byte), .push(rx_valid), .pop(rxq_pop),
        .dout(rxq_dout), .empty(rxq_empty), .full(rxq_full), .level(rxq_level)
    );

    guard_fifo #(.AW(AW)) u_txq (
        .clk(clk), .rst_n(rst_n),
        .din(txq_din), .push(txq_push), .pop(txq_pop),
        .dout(txq_dout), .empty(txq_empty), .full(txq_full), .level(txq_level)
    );

    // =====================================================================
    // 输出整形：LF → CRLF（可选）
    // =====================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_valid   <= 1'b0;
            tx_byte    <= 8'd0;
            txq_pop    <= 1'b0;
            hold_valid <= 1'b0;
            hold_byte  <= 8'd0;
        end else begin
            tx_valid <= 1'b0;
            txq_pop  <= 1'b0;
            if (tx_ready && !tx_valid) begin
                if (hold_valid) begin
                    tx_byte    <= hold_byte;
                    tx_valid   <= 1'b1;
                    hold_valid <= 1'b0;
                end else if (!txq_empty) begin
                    if ((LF_TO_CRLF != 0) && (txq_dout == 8'h0A)) begin
                        tx_byte    <= 8'h0D;      // 先补 \r
                        tx_valid   <= 1'b1;
                        hold_byte  <= 8'h0A;      // \n 下一拍发
                        hold_valid <= 1'b1;
                        txq_pop    <= 1'b1;
                    end else begin
                        tx_byte  <= txq_dout;
                        tx_valid <= 1'b1;
                        txq_pop  <= 1'b1;
                    end
                end
            end
        end
    end

    // =====================================================================
    // L1 脱敏流水线
    // =====================================================================
    l1_redact_top u_l1 (
        .clk(clk), .rst_n(l1_rst_n),
        .in_valid(in_valid), .in_char(in_char), .in_last(in_last),
        .out_valid(out_valid), .out_char(out_char),
        .a_valid(a_valid), .a_start(a_start), .a_len(a_len), .a_type(a_type),
        .done(done_q), .ovf(ovf_q), .dropped(dropped_q)
    );

    // =====================================================================
    // 审计摘要
    // =====================================================================
    guard_report u_rpt (
        .clk(clk), .rst_n(rst_n),
        .start    (rpt_start),
        .at_line_start(at_line_start_now),
        .v_n      (c_n),
        .v_id18   (c_id18),
        .v_id15   (c_id15),
        .v_mobile (c_mob),
        .v_bank   (c_bank),
        .v_email  (c_mail),
        .v_ipv4   (c_ip),
        .v_uscc   (c_uscc),
        .v_plate  (c_plate),
        .v_err    (err_q),
        .byte_out (rpt_byte),
        .byte_valid(rpt_valid),
        .fifo_full(txq_full),
        .busy     (rpt_busy),
        .finished (rpt_fin)
    );

    // =====================================================================
    // 流控 / 帧边界
    // =====================================================================
    assign sum_level = txq_level + inflight;
    assign flow_ok   = (sum_level <= {7'd0, LIMIT}) && (inflight < 16'd128);
    assign accept    = (fst == F_RUN) && !rxq_empty && flow_ok;

    assign rxq_pop  = accept;
    assign in_valid = accept;
    assign in_char  = rxq_dout;
    assign in_last  = in_last_r;

    assign idle_flush = (fst == F_RUN) && (frame_bytes != 8'd0) && rxq_empty &&
                        (idle_cnt >= IDLE_TICKS);

    assign rpt_start = (fst == F_FLUSH) && done_q;

    // 摘要行首要不要补 LF，取决于"本拍结束之后"最后一个输出字节是不是 LF：
    // done 和最后一个文本字节的 push 是同一拍（done 晚 ncount 归零一拍，正好撞上），
    // 所以这里要取 next 值，不能直接用寄存器里的旧值。
    assign at_line_start_now = txq_push ? (txq_din == 8'h0A) : at_line_start;

    // TX 入口复用：文本优先，摘要其次
    assign txt_push = out_valid;
    assign rpt_push = (REPORT_EN != 0) && rpt_valid && !txq_full;
    assign txq_din  = out_valid ? out_char : rpt_byte;
    assign txq_push = txt_push || rpt_push;

    assign frame_err_now = (rx_valid && rxq_full) || rx_frame_err || ovf_q ||
                           (out_valid && txq_full);

    assign l1_rst_n = rst_n && (fst != F_RST);

    // =====================================================================
    // 主状态机
    // =====================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fst           <= F_RUN;
            rst_cnt       <= 4'd0;
            idle_cnt      <= 32'd0;
            frame_bytes   <= 8'd0;
            in_last_r     <= 1'b0;
            last_n        <= 8'd0;
            rpt_seen      <= 1'b0;
            at_line_start <= 1'b1;
            err_q         <= 1'b0;
            err_sticky    <= 1'b0;
            inflight      <= 16'd0;
            c_n           <= 8'd0;
            c_id18        <= 8'd0;
            c_id15        <= 8'd0;
            c_mob         <= 8'd0;
            c_bank        <= 8'd0;
            c_mail        <= 8'd0;
            c_ip          <= 8'd0;
            c_uscc        <= 8'd0;
            c_plate       <= 8'd0;
        end else begin
            in_last_r <= 1'b0;

            // ---- inflight：进/出脱敏器各一 ----
            if (!l1_rst_n) begin
                inflight <= 16'd0;
            end else begin
                case ({accept, out_valid})
                    2'b10:   inflight <= inflight + 16'd1;
                    2'b01:   inflight <= inflight - 16'd1;
                    default: ;
                endcase
            end

            // ---- 空闲计时（用于没有 LF 结尾的帧） ----
            if (accept) begin
                idle_cnt <= 32'd0;
            end else if (idle_cnt != 32'hFFFF_FFFF) begin
                idle_cnt <= idle_cnt + 32'd1;
            end

            // ---- 行首状态（决定摘要要不要先补 CRLF） ----
            if (txq_push) begin
                at_line_start <= (txq_din == 8'h0A);
            end

            // ---- 本帧 span 计数 ----
            if (a_valid) begin
                c_n <= c_n + 8'd1;
                case (a_type)
                    4'd1:    c_id18  <= c_id18  + 8'd1;
                    4'd2:    c_id15  <= c_id15  + 8'd1;
                    4'd3:    c_mob   <= c_mob   + 8'd1;
                    4'd4:    c_bank  <= c_bank  + 8'd1;
                    4'd5:    c_mail  <= c_mail  + 8'd1;
                    4'd6:    c_ip    <= c_ip    + 8'd1;
                    4'd7:    c_uscc  <= c_uscc  + 8'd1;
                    4'd8:    c_plate <= c_plate + 8'd1;
                    default: ;
                endcase
            end

            // ---- 错误（帧内 + 粘滞） ----
            if (frame_err_now) begin
                err_q      <= 1'b1;
                err_sticky <= 1'b1;
            end

            // ---- 帧状态机 ----
            case (fst)
                F_RUN: begin
                    if (accept) begin
                        frame_bytes <= frame_bytes + 8'd1;
                    end
                    if (accept && (in_char == 8'h0A)) begin
                        fst       <= F_FLUSH;
                        in_last_r <= 1'b1;
                    end else if (idle_flush) begin
                        fst       <= F_FLUSH;
                        in_last_r <= 1'b1;
                    end
                end

                F_FLUSH: begin
                    if (done_q) begin
                        fst    <= F_RPT;
                        last_n <= c_n;
                    end
                end

                F_RPT: begin
                    // 用 busy 电平而不是 finished 单拍脉冲：报告开始后 busy 一直为 1，
                    // 最后一个字节送进 TX FIFO 才落下。rpt_seen 兜住“还没起来”的那拍。
                    if (rpt_busy) begin
                        rpt_seen <= 1'b1;
                    end
                    if ((REPORT_EN == 0) || (rpt_seen && !rpt_busy)) begin
                        fst      <= F_RST;
                        rpt_seen <= 1'b0;
                    end
                end

                F_RST: begin
                    if (rst_cnt + 4'd1 >= 4'd8) begin
                        rst_cnt     <= 4'd0;
                        fst         <= F_RUN;
                        frame_bytes <= 8'd0;
                        err_q       <= 1'b0;
                        c_n         <= 8'd0;
                        c_id18      <= 8'd0;
                        c_id15      <= 8'd0;
                        c_mob       <= 8'd0;
                        c_bank      <= 8'd0;
                        c_mail      <= 8'd0;
                        c_ip        <= 8'd0;
                        c_uscc      <= 8'd0;
                        c_plate     <= 8'd0;
                    end else begin
                        rst_cnt <= rst_cnt + 4'd1;
                    end
                end

                default: fst <= F_RUN;
            endcase
        end
    end

    assign st_rx   = rx_valid;
    assign st_tx   = tx_valid;
    assign st_hit  = a_valid;
    assign st_busy = (fst != F_RUN);
    assign st_err  = err_sticky;
    assign st_n    = last_n;

endmodule
