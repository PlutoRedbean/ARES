//=============================================================================
// ARES SoC - CPU-level miniTensor need-work IRQ test
//-----------------------------------------------------------------------------
// DUTs: student_top + ares_mt_host_adapter (behavioural CV-X-IF slave).
//
// Program:
//   * mask need_work, kick one MT_VEC_RELU8 command
//   * enable mie.MEIE and mstatus.MIE
//   * trap on mt_irq (external_irq / mip.MEIP)
//   * handler reads mcause (expects 0x8000000B) and mip (expects MEIP=1),
//     ACKs need_work, returns
//   * main checks mcause/MEIP and retires EBREAK with a0=0
//
// This is the CPU/trap half of the first tensor-IRQ slice; the adapter-level
// source coverage (need_work/done/accept_err/kick_err, mask/ack) is in
// rtl/soc/test/tb_mt_irq.sv.
//=============================================================================
`timescale 1ns/1ps
module tb_mt_cpu_irq;
    import ares_pkg::*;
    import fe_pkg::*;

    localparam int unsigned IMEM_WORDS = 256;

    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // FE model + program image
    //-------------------------------------------------------------------------
    logic [31:0] imem [IMEM_WORDS];
    logic [1:0] iq_valid, iq_accept_count;
    iq_entry_t iq_inst [2];
    logic backend_redirect_valid;
    logic [31:0] backend_redirect_pc;
    fe_redirect_kind_t backend_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0] backend_redirect_ghr_before;
    logic backend_redirect_actual_taken;
    logic [1:0] bpu_update_credit, bpu_update_valid;
    bpu_update_t bpu_update [2];
    logic [31:0] fetch_pc, redirect_count;

    fe_model #(
        .RESET_PC(RESET_PC),
        .IMEM_WORDS(IMEM_WORDS)
    ) u_fe (
        .clk(clk),
        .rst(rst),
        .iq_valid(iq_valid),
        .iq_inst(iq_inst),
        .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc),
        .bpu_update_credit(bpu_update_credit),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update),
        .imem(imem),
        .fetch_pc(fetch_pc),
        .redirect_count(redirect_count)
    );

    //-------------------------------------------------------------------------
    // Platform + miniTensor MMIO adapter
    //-------------------------------------------------------------------------
    logic        mt_wr_en;
    logic [2:0]  mt_wr_idx;
    logic [31:0] mt_wr_data;
    logic        mt_status_rd;
    logic [31:0] mt_status, mt_result;
    logic        mt_irq;
    core_v_xif  mt_xif ();

    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;
    logic [63:0] ifetch_data;

    student_top u_platform (
        .w_cpu_clk(clk),
        .w_clk_50Mhz(clk),
        .w_clk_rst(rst),
        .virtual_key(8'h00),
        .virtual_sw(64'h0),
        .uart_rx_data(8'h00),
        .uart_rx_ready(1'b0),
        .uart_tx_busy(1'b0),
        .uart_tx_data(),
        .uart_tx_start(),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg),
        .ifetch_addr(32'h8000_0000),
        .ifetch_data(ifetch_data),
        .mt_wr_en(mt_wr_en),
        .mt_wr_idx(mt_wr_idx),
        .mt_wr_data(mt_wr_data),
        .mt_status_rd(mt_status_rd),
        .mt_status(mt_status),
        .mt_result(mt_result),
        .mt_irq(mt_irq),
        .iq_valid(iq_valid),
        .iq_inst(iq_inst),
        .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid),
        .backend_redirect_pc(backend_redirect_pc),
        .backend_redirect_kind(backend_redirect_kind),
        .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit(bpu_update_credit),
        .bpu_update_valid(bpu_update_valid),
        .bpu_update(bpu_update)
    );

    ares_mt_host_adapter #(
        .ISSUE_TO_REGISTER(1),
        .REGISTER_TO_COMMIT(1),
        .FIFO_DEPTH(8),
        .HART_ID(1'b0)
    ) u_adapter (
        .clk(clk),
        .rst(rst),
        .reg_wr_en(mt_wr_en),
        .reg_wr_idx(mt_wr_idx),
        .reg_wr_data(mt_wr_data),
        .status_rd(mt_status_rd),
        .status(mt_status),
        .result_data(mt_result),
        .mt_irq(mt_irq),
        .xif(mt_xif)
    );

    //-------------------------------------------------------------------------
    // Behavioural CV-X-IF slave: accepts every command and returns a result.
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_REG, S_WAIT, S_RES} slave_state_t;
    slave_state_t slave_state;
    logic         result_valid_q;
    int unsigned  wait_cnt;
    logic [3:0]   cap_id;

    assign mt_xif.issue_ready = (slave_state == S_IDLE);
    assign mt_xif.register_ready = (slave_state == S_REG);

    always_comb begin
        mt_xif.issue_resp = '0;
        mt_xif.issue_resp.accept = 1'b1;
        mt_xif.issue_resp.writeback[0] = 1'b1;
        mt_xif.issue_resp.register_read = 2'b11;
    end

    assign mt_xif.compressed_ready = 1'b1;
    assign mt_xif.compressed_resp  = '0;
    assign mt_xif.mem_valid        = 1'b0;
    assign mt_xif.mem_req          = '0;

    assign mt_xif.result_valid = result_valid_q;

    always_comb begin
        mt_xif.result = '0;
        mt_xif.result.hartid = 1'b0;
        mt_xif.result.id = cap_id;
        mt_xif.result.data = 32'h0;
        mt_xif.result.rd = 5'd0;
        mt_xif.result.we[0] = 1'b1;
        mt_xif.result.err = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            slave_state    <= S_IDLE;
            result_valid_q <= 1'b0;
            wait_cnt       <= 0;
            cap_id         <= 0;
        end else begin
            case (slave_state)
                S_IDLE: begin
                    if (mt_xif.issue_valid && mt_xif.issue_ready) begin
                        cap_id      <= mt_xif.issue_req.id;
                        wait_cnt    <= 2;
                        slave_state <= S_REG;
                    end
                end
                S_REG: begin
                    if (mt_xif.register_valid && mt_xif.register_ready) begin
                        wait_cnt    <= 2;
                        slave_state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (wait_cnt == 0) begin
                        result_valid_q <= 1'b1;
                        slave_state    <= S_RES;
                    end else begin
                        wait_cnt <= wait_cnt - 1;
                    end
                end
                S_RES: begin
                    if (result_valid_q && mt_xif.result_ready) begin
                        result_valid_q <= 1'b0;
                        slave_state    <= S_IDLE;
                    end
                end
                default: slave_state <= S_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Program image: 54 instructions, unused entries are NOPs.
    //-------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < IMEM_WORDS; i++) imem[i] = 32'h0000_0013;
        imem[0] = 32'h00000413;
        imem[1] = 32'h00000493;
        imem[2] = 32'h00000913;
        imem[3] = 32'h00000297;
        imem[4] = 32'h09428293;
        imem[5] = 32'h30529073;
        imem[6] = 32'h802012b7;
        imem[7] = 32'h01828293;
        imem[8] = 32'h01000313;
        imem[9] = 32'h0062a023;
        imem[10] = 32'h802012b7;
        imem[11] = 32'h04002337;
        imem[12] = 32'h00b30313;
        imem[13] = 32'h0062a023;
        imem[14] = 32'h802012b7;
        imem[15] = 32'h00428293;
        imem[16] = 32'h0002a023;
        imem[17] = 32'h802012b7;
        imem[18] = 32'h00828293;
        imem[19] = 32'h0002a023;
        imem[20] = 32'h802012b7;
        imem[21] = 32'h00c28293;
        imem[22] = 32'h00100313;
        imem[23] = 32'h0062a023;
        imem[24] = 32'h000012b7;
        imem[25] = 32'h80028293;
        imem[26] = 32'h30429073;
        imem[27] = 32'h00800293;
        imem[28] = 32'h30029073;
        imem[29] = 32'h00040063;
        imem[30] = 32'h800002b7;
        imem[31] = 32'h00b28293;
        imem[32] = 32'h00549c63;
        imem[33] = 32'h000012b7;
        imem[34] = 32'h80028293;
        imem[35] = 32'h00591663;
        imem[36] = 32'h00000513;
        imem[37] = 32'h00100073;
        imem[38] = 32'h00100513;
        imem[39] = 32'h00100073;
        imem[40] = 32'h342024f3;
        imem[41] = 32'h34402973;
        imem[42] = 32'h00001e37;
        imem[43] = 32'h800e0e13;
        imem[44] = 32'h01c97933;
        imem[45] = 32'h802012b7;
        imem[46] = 32'h01c28293;
        imem[47] = 32'h01000313;
        imem[48] = 32'h0062a023;
        imem[49] = 32'h802012b7;
        imem[50] = 32'h01028293;
        imem[51] = 32'h0002a383;
        imem[52] = 32'h00100413;
        imem[53] = 32'h30200073;
    end

    //-------------------------------------------------------------------------
    // Retire / EBREAK tracking
    //-------------------------------------------------------------------------
    logic [31:0] a0_q;
    int unsigned retired;

    always_ff @(posedge clk) begin
        if (rst) begin
            a0_q    <= 32'h0;
            retired <= 0;
        end else begin
            for (int lane = 0; lane < 2; lane++) begin
                if (u_platform.Core_cpu.retire_valid[lane]) begin
                    retired <= retired + 1;
                    if (u_platform.Core_cpu.retire_rd_wen[lane]
                        && (u_platform.Core_cpu.retire_rd[lane] == 5'd10)) begin
                        a0_q <= u_platform.Core_cpu.retire_wdata[lane];
                    end
                    if (u_platform.Core_cpu.retire_is_ebreak[lane]) begin
                        if (a0_q == 32'h0) begin
                            $display("ALL TESTS PASSED: mt_cpu_irq %0d retires - CPU took mip.MEIP, handler saw mcause=0x8000000B, ACKed need_work, main exited a0=0", retired);
                        end else begin
                            $display("*** FAILED: EBREAK with a0=%0d (mcause/mip check failed) ***", a0_q);
                        end
                        $finish;
                    end
                end
            end
        end
    end

    initial begin
        repeat (6) @(posedge clk);
        #1;
        rst = 1'b0;
    end

    initial begin
        #500000;
        $display("*** TIMEOUT: fetch_pc=0x%08x retired=%0d redirects=%0d ***",
                 fetch_pc, retired, redirect_count);
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_ok;
    assign unused_ok = backend_redirect_kind | ^backend_redirect_ghr_before
                     | backend_redirect_actual_taken | ^virtual_led | ^virtual_seg
                     | ^ifetch_data;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
