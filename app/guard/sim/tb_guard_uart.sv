// guard/sim/tb_guard_uart.sv
//
// 板级端到端测试：把 case_NNNN.in 按真实 UART 位定时打到 uart_rx 上，
// 从 uart_tx 逐位收回来，和 case_NNNN.exp（金标生成的完整期望流）逐字节比。
//
// 覆盖范围：UART 收发（含过采样/分数分频）、RX/TX FIFO 流控、LF 触发冲刷、
// 空闲冲刷、帧间软复位、审计摘要格式、LF→CRLF。
//
// 用法：+dir=build/board
//
// 位定时：CLK_FREQ/BAUD = 27 拍/位（用 1 Mbaud 而不是 115200，只为跑得快；
// 过采样仍是 16 倍，和板上 27 MHz / 115200 完全同一条通路）。

`timescale 1ns/1ps

module tb_guard_uart;

    // 板级真实参数：27 MHz 晶振 → PLL → 25 MHz 核心；115200 8N1。
    // 仿真把波特率提到 1 Mbaud（位时间 1 µs）只是为了跑得快：27 个 27 MHz
    // 周期/位 = 25 个核心时钟/位，8× 过采样，和板上同一条通路。
    localparam int CRYSTAL_HZ   = 27_000_000;
    localparam int CLK_FREQ     = 25_000_000;   // PLL 输出（guard_pll_sim）
    // BAUD 留成参数，方便 -GBAUD=3000000 跑 3 Mbaud 通路（见 make board-sim-3m）
    parameter  int BAUD         = 1_000_000;
    localparam int CLKS_PER_BIT = CRYSTAL_HZ / BAUD;   // 27 个 27 MHz 周期
    localparam int MAXB         = 16384;
    localparam int IDLE_BITS    = 4000;         // 板上是 300000（≈2.6 s）；仿真取小值
    localparam int IDLE_CYCLES  = CLKS_PER_BIT * IDLE_BITS;

    logic clk = 1'b0;
    always #18.5185 clk = ~clk;               // 37.037 ns ≈ 27 MHz

    logic      rst_n   = 1'b0;
    logic      uart_rx = 1'b1;
    wire       uart_tx;
    wire [7:0] led;

    guard_board_top #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD),
        .OV        (8),
        .AW        (8),
        .LF_TO_CRLF(1),
        .REPORT_EN (1),
        .IDLE_BITS (IDLE_BITS),
        .USE_NER   (1'b0)          // 板级回归用规则版实体层（金标算不了神经网络）
    ) dut (
        .clk_27m(clk), .rst_n(rst_n), .uart_rx(uart_rx),
        .uart_tx(uart_tx), .led(led)
    );

    // ---------------- 接收模型：采样 DUT 的 uart_tx ----------------
    logic [7:0] obuf [0:MAXB-1];
    int         obytes = 0;
    int         rstate = 0;
    int         rxclk  = 0;
    int         rbit   = 0;
    logic [7:0] rsh    = 8'd0;
    logic       rx_en  = 1'b1;      // 复位期间关掉接收模型，避免半截字节算进来

    always @(posedge clk) begin
        if (!rx_en) begin
            rstate <= 0;
            rxclk  <= 0;
        end else case (rstate)
            0: begin
                if (!uart_tx) begin
                    rstate <= 1;
                    rxclk  <= 0;
                end
            end
            1: begin                        // 起始位中点
                if (rxclk == (CLKS_PER_BIT / 2 - 1)) begin
                    if (!uart_tx) begin
                        rstate <= 2;
                        rbit   <= 0;
                        rxclk  <= 0;
                    end else begin
                        rstate <= 0;        // 毛刺
                    end
                end else begin
                    rxclk <= rxclk + 1;
                end
            end
            2: begin                        // 8 个数据位，LSB 先
                if (rxclk == CLKS_PER_BIT - 1) begin
                    rsh   <= {uart_tx, rsh[7:1]};
                    rxclk <= 0;
                    if (rbit == 7) rstate <= 3;
                    else           rbit   <= rbit + 1;
                end else begin
                    rxclk <= rxclk + 1;
                end
            end
            3: begin                        // 停止位
                if (rxclk == CLKS_PER_BIT - 1) begin
                    if (obytes < MAXB) obuf[obytes] = rsh;
                    obytes  = obytes + 1;
                    rstate <= 0;
                    rxclk  <= 0;
                end else begin
                    rxclk <= rxclk + 1;
                end
            end
            default: rstate <= 0;
        endcase
    end

    // ---------------- 发送：按位驱动 uart_rx ----------------
    task automatic send_byte(input logic [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0;                              // 起始位
            repeat (CLKS_PER_BIT) @(negedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                repeat (CLKS_PER_BIT) @(negedge clk);
            end
            uart_rx = 1'b1;                              // 停止位
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
    endtask

    // 调试：+trace4 在第一次出错时打印现场
    logic err_prev = 1'b0;
    always @(posedge clk) begin
        if ($test$plusargs("logerr")) begin
            if (dut.u_core.err_sticky && !err_prev) begin
                $display("  ERR t=%0t obytes=%0d rxq=%0d txq=%0d inflight=%0d frame=%0d ovf=%b",
                         $time, obytes, dut.u_core.rxq_level, dut.u_core.txq_level,
                         dut.u_core.inflight, dut.u_core.frame_bytes, dut.u_core.ovf_q);
            end
            err_prev = dut.u_core.err_sticky;
        end
    end

    initial begin
        if ($test$plusargs("logfin")) begin
            forever begin
                @(posedge clk);
                if (dut.u_core.u_rpt.fin_q !== 1'b0) begin
                    $display("  t=%0t fin_q=1 fst=%0d core_fin=%b run=%b fld=%0d",
                             $time, dut.u_core.fst, dut.u_core.rpt_fin,
                             dut.u_core.u_rpt.run, dut.u_core.u_rpt.fld);
                end
            end
        end
    end

    // 调试：+trace2 时逐拍打印状态机（只在仿真里用层次引用）
    logic [1:0] fst_prev = 2'd0;
    always @(posedge clk) begin
        if ($test$plusargs("logfst")) begin
            if (dut.u_core.fst !== fst_prev) begin
                $display("  t=%0t fst %0d->%0d done=%b start=%b fin=%b run=%b fld=%0d pos=%0d",
                         $time, fst_prev, dut.u_core.fst, dut.u_core.done_q,
                         dut.u_core.rpt_start, dut.u_core.rpt_fin,
                         dut.u_core.u_rpt.run, dut.u_core.u_rpt.fld, dut.u_core.u_rpt.pos);
                fst_prev = dut.u_core.fst;
            end
        end
    end

    // 调试：+trace 时周期性打印内部状态（层次引用只在仿真里用）
    initial begin
        if ($test$plusargs("logstate")) begin
            forever begin
                repeat (4000) @(negedge clk);
                $display("t=%0t obytes=%0d fst=%0d fin=%b rptrun=%b fld=%0d pos=%0d busy=%b",
                         $time, obytes, dut.u_core.fst, dut.u_core.rpt_fin,
                         dut.u_core.u_rpt.run, dut.u_core.u_rpt.fld,
                         dut.u_core.u_rpt.pos, dut.u_core.u_rpt.busy);
            end
        end
    end

    // 调试：+dump=<path> 把每个用例收到的字节流追加写出（便于和 .exp 对照）
    string   dump_path;
    int      dump_fd = 0;

    string   vdir, in_path, exp_path;
    int      mfd, cfd, efd, c, idx;
    int      cases = 0, errors = 0;
    logic [7:0] ebuf [0:MAXB-1];
    int      elen;
    int      sent, budget, plen;
    int      pbuf [0:MAXB-1];   // 每个输入字节的发送门槛（.pace）

    initial begin
        if (!$value$plusargs("dir=%s", vdir)) vdir = "build/board";
        if ($value$plusargs("dump=%s", dump_path)) begin
            dump_fd = $fopen(dump_path, "w");
            if (dump_fd != 0) $display("dump -> %s", dump_path);
        end
        mfd = $fopen($sformatf("%s/manifest.txt", vdir), "r");
        if (mfd == 0) begin
            $display("FAIL: no manifest in %s", vdir);
            $fatal(1);
        end

        while ($fscanf(mfd, "%d\n", idx) == 1) begin
            cases++;

            exp_path = $sformatf("%s/case_%04d.exp", vdir, idx);
            efd = $fopen(exp_path, "rb");
            if (efd == 0) begin
                $display("FAIL case %0d: cannot open %s", idx, exp_path);
                $fatal(1);
            end
            elen = 0;
            while ((c = $fgetc(efd)) != -1) begin
                if (elen < MAXB) ebuf[elen] = c[7:0];
                elen++;
            end
            $fclose(efd);

            // 复位，然后按位发输入
            rx_en   = 1'b0;
            rst_n   = 1'b0;
            uart_rx = 1'b1;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            // PLL 锁定 + 复位同步释放：等够再开始发，否则头一个字节会撞在复位里
            repeat (200) @(negedge clk);
            obytes = 0;
            rx_en  = 1'b1;

            in_path = $sformatf("%s/case_%04d.in", vdir, idx);
            cfd = $fopen(in_path, "rb");
            if (cfd == 0) begin
                $display("FAIL case %0d: cannot open %s", idx, in_path);
                $fatal(1);
            end
            // 按回读节奏发（.pace 由金标生成）：第 i 个字节要等"已回显文本 >= 门槛"。
            // 摘要行让输出比输入多，板子的消费速度被回读速率卡住；不按节奏灌就会
            // 把 256 字节的 RX FIFO 灌爆（ovf=001、LED2 亮）。上位机
            // tools/serial_host.py 用的是同一条规则（host/golden/board_proto.py）。
            efd = $fopen($sformatf("%s/case_%04d.pace", vdir, idx), "r");
            if (efd == 0) begin
                $display("FAIL case %0d: no pace file", idx);
                $fatal(1);
            end
            plen = 0;
            begin
                int pv;
                while (($fscanf(efd, "%d\n", pv) == 1) && (plen < MAXB)) begin
                    pbuf[plen] = pv;
                    plen = plen + 1;
                end
            end
            $fclose(efd);

            sent   = 0;
            budget = (elen + 128) * 10 * CLKS_PER_BIT + IDLE_CYCLES + 400000;
            while ((c = $fgetc(cfd)) != -1) begin
                if (sent < plen) begin
                    while ((obytes < pbuf[sent]) && (budget > 0)) begin
                        @(negedge clk);
                        budget = budget - 1;
                    end
                end
                if (budget <= 0) begin
                    $display("FAIL case %0d: board stopped answering at byte %0d", idx, sent);
                    errors++;
                    break;
                end
                send_byte(c[7:0]);
                sent = sent + 1;
            end
            $fclose(cfd);

            // 等输出到齐（帧尾冲刷 + 空闲冲刷都算在预算里）
            begin
                budget = (elen + 64) * 10 * CLKS_PER_BIT + IDLE_CYCLES + 20000;
                while ((obytes < elen) && (budget > 0)) begin
                    @(negedge clk);
                    budget = budget - 1;
                end
                repeat (12 * CLKS_PER_BIT) @(negedge clk);   // 迟到字节也要抓到
            end

            if (dump_fd != 0) begin
                int k;
                for (k = 0; k < obytes; k++) $fwrite(dump_fd, "%c", obuf[k]);
                $fwrite(dump_fd, "\n----CASE %0d----\n", idx);
                $fflush(dump_fd);
            end

            if (obytes != elen) begin
                errors++;
                $display("FAIL case %0d: %s bytes exp %0d got %0d",
                         idx, in_path, elen, obytes);
            end

            begin
                int i, bad;
                i   = 0;
                bad = -1;
                while ((i < elen) && (i < obytes) && (bad < 0)) begin
                    if (obuf[i] !== ebuf[i]) bad = i;
                    i = i + 1;
                end
                if (bad >= 0) begin
                    errors++;
                    $display("FAIL case %0d: first diff at %0d exp %02x got %02x",
                             idx, bad, ebuf[bad], obuf[bad]);
                    // 前后各 24 字节的上下文（十六进制）
                    $write("  ctx @%0d:", (bad >= 24) ? bad - 24 : 0);
                    for (i = (bad >= 24) ? bad - 24 : 0; i < bad + 24; i++) begin
                        if (i == bad) $write(" |");
                        if (i < elen)  $write(" %02x", ebuf[i]); else $write(" --");
                    end
                    $write("\n  got:            ");
                    for (i = (bad >= 24) ? bad - 24 : 0; i < bad + 24; i++) begin
                        if (i < obytes) $write(" %02x", obuf[i]); else $write(" --");
                    end
                    $display("");
                end
            end

            if (errors > 3) $fatal(1, "too many failures");
        end

        $fclose(mfd);
        $display("board uart cases=%0d errors=%0d", cases, errors);
        if (errors != 0) $fatal(1, "board uart mismatch");
        $display("PASS: board UART end-to-end matches golden");
        $finish;
    end

endmodule