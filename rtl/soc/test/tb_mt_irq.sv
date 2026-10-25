//=============================================================================
// ARES SoC - miniTensor MMIO control path IRQ unit test
//-----------------------------------------------------------------------------
// DUT: ares_mt_host_adapter with a behavioural CV-X-IF slave.
//
// Checks the first tensor-IRQ slice:
//   * MT_STATUS.need_work (bit 5) is set only when the last queued command
//     completes and the queue is empty
//   * mt_irq is a level from the sticky sources gated by MT_IRQ_MASK
//   * a new KICK or MT_IRQ_ACK clears need_work/done, so an idle tensor does
//     not hold the interrupt forever
//   * MT_IRQ_ACK is write-1-to-clear per source bit
//   * MT_STATUS read while not busy clears the sticky flags
//   * accept_err and kick_err reach the IRQ mask
//   * HART_ID is driven on the CV-X-IF issue/register channels
//
// The slave intentionally accepts any instruction; mini_tensor_top itself is
// covered by its own regression and by the ares_soc_top lint gate.
//=============================================================================
`timescale 1ns/1ps
module tb_mt_irq;
    logic clk;
    logic rst;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
    end
    always #5 clk = ~clk;

    int unsigned checks = 0;
    int unsigned errors = 0;

    localparam logic [2:0] IDX_INSTR    = 3'd0;
    localparam logic [2:0] IDX_RS1      = 3'd1;
    localparam logic [2:0] IDX_RS2      = 3'd2;
    localparam logic [2:0] IDX_KICK     = 3'd3;
    localparam logic [2:0] IDX_IRQ_MASK = 3'd6;
    localparam logic [2:0] IDX_IRQ_ACK  = 3'd7;

    localparam logic [4:0] IRQ_NEED_WORK = 5'h10;
    localparam logic [4:0] IRQ_KICK_ERR  = 5'h08;
    localparam logic [4:0] IRQ_ACCEPT_ERR= 5'h04;
    localparam logic [4:0] IRQ_DONE      = 5'h01;

    task automatic check(input logic cond, input string name);
        begin
            checks++;
            if (!cond) begin
                /* verilator lint_off BLKSEQ */
                errors = errors + 1;
                /* verilator lint_on BLKSEQ */
                $display("FAIL: %s", name);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    logic        reg_wr_en;
    logic [2:0]  reg_wr_idx;
    logic [31:0] reg_wr_data;
    logic        status_rd;
    logic [31:0] status;
    logic [31:0] result_data;
    logic        mt_irq;

    core_v_xif xif ();

    ares_mt_host_adapter #(
        .ISSUE_TO_REGISTER(1),
        .REGISTER_TO_COMMIT(1),
        .FIFO_DEPTH(3),
        .HART_ID(1'b1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .reg_wr_en(reg_wr_en),
        .reg_wr_idx(reg_wr_idx),
        .reg_wr_data(reg_wr_data),
        .status_rd(status_rd),
        .status(status),
        .result_data(result_data),
        .mt_irq(mt_irq),
        .xif(xif)
    );

    //-------------------------------------------------------------------------
    // Behavioural CV-X-IF slave
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_REG, S_WAIT, S_RES} slave_state_t;
    slave_state_t slave_state;
    logic         slave_stall;
    logic         reject_next;
    logic         result_valid_q;
    int unsigned  wait_cnt;
    logic [3:0]   cap_id;
    logic         cap_hartid;

    assign xif.issue_ready    = (slave_state == S_IDLE) && !slave_stall;
    assign xif.register_ready = (slave_state == S_REG);

    always_comb begin
        xif.issue_resp = '0;
        xif.issue_resp.accept = !reject_next;
        xif.issue_resp.writeback[0] = 1'b1;
        xif.issue_resp.register_read = 2'b11;
    end

    assign xif.compressed_ready = 1'b1;
    assign xif.compressed_resp  = '0;
    assign xif.mem_valid        = 1'b0;
    assign xif.mem_req          = '0;

    assign xif.result_valid = result_valid_q;

    always_comb begin
        xif.result = '0;
        xif.result.hartid = cap_hartid;
        xif.result.id     = cap_id;
        xif.result.data   = 32'h1000_0000 + 32'(cap_id);
        xif.result.rd     = 5'd3;
        xif.result.we[0]  = 1'b1;
        xif.result.err    = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            slave_state    <= S_IDLE;
            result_valid_q <= 1'b0;
            wait_cnt       <= 0;
            cap_id         <= 0;
            cap_hartid     <= 0;
        end else begin
            case (slave_state)
                S_IDLE: begin
                    if (xif.issue_valid && xif.issue_ready) begin
                        if (xif.issue_resp.accept) begin
                            cap_id     <= xif.issue_req.id;
                            cap_hartid <= xif.issue_req.hartid;
                            wait_cnt   <= 2;
                            slave_state<= S_REG;
                        end
                        // Rejected issue: stay IDLE; the adapter reports accept_err.
                    end
                end
                S_REG: begin
                    if (xif.register_valid && xif.register_ready) begin
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
                    if (result_valid_q && xif.result_ready) begin
                        result_valid_q <= 1'b0;
                        slave_state    <= S_IDLE;
                    end
                end
                default: slave_state <= S_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // MMIO helpers
    //-------------------------------------------------------------------------
    task automatic mmio_write(input logic [2:0] idx, input logic [31:0] data);
        begin
            @(negedge clk);
            reg_wr_en   = 1'b1;
            reg_wr_idx  = idx;
            reg_wr_data = data;
            @(posedge clk);
            #1;
            reg_wr_en   = 1'b0;
            reg_wr_idx  = 3'd0;
            reg_wr_data = 32'd0;
        end
    endtask

    task automatic push(input logic [31:0] instr, input logic [31:0] rs1,
                        input logic [31:0] rs2);
        begin
            mmio_write(IDX_INSTR, instr);
            mmio_write(IDX_RS1, rs1);
            mmio_write(IDX_RS2, rs2);
            mmio_write(IDX_KICK, 32'd1);
        end
    endtask

    task automatic read_status(output logic [31:0] data);
        begin
            @(negedge clk);
            status_rd = 1'b1;
            #1;
            data = status;
            @(posedge clk);
            #1;
            status_rd = 1'b0;
        end
    endtask

    task automatic wait_irq(input string name);
        int unsigned n;
        begin
            n = 0;
            while (!mt_irq && (n < 500)) begin
                @(posedge clk);
                #1;
                n++;
            end
            check(mt_irq, name);
        end
    endtask

    task automatic wait_low(input string name);
        int unsigned n;
        begin
            n = 0;
            while (mt_irq && (n < 100)) begin
                @(posedge clk);
                #1;
                n++;
            end
            check(!mt_irq, name);
        end
    endtask

    //-------------------------------------------------------------------------
    // Main sequence
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // only the defined status bits are inspected
    logic [31:0] st;
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        reg_wr_en   = 1'b0;
        reg_wr_idx  = 3'd0;
        reg_wr_data = 32'd0;
        status_rd   = 1'b0;
        slave_stall = 1'b0;
        reject_next = 1'b0;
        wait_cnt    = 0;
        cap_id      = 0;
        cap_hartid  = 0;
        result_valid_q = 0;

        repeat (4) @(posedge clk);
        #1;
        rst = 1'b0;
        repeat (2) @(posedge clk);

        check(!mt_irq, "reset: mt_irq low");
        check(status[5:0] == 6'h00, "reset: status clean");

        // Enable only NEED_WORK first.
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_NEED_WORK});

        // Two commands: one IRQ when the batch drains.
        push(32'h0000_0001, 32'h0, 32'h0);
        push(32'h0000_0002, 32'h0, 32'h0);
        wait_irq("need_work IRQ after two commands");
        check(cap_hartid == 1'b1, "CV-X-IF issue hartid = HART_ID=1");
        check(status[5] == 1'b1, "status.need_work set");
        check(status[1] == 1'b1, "status.done set on drained batch");
        check(status[0] == 1'b0, "status.busy low after drain");
        check(result_data == 32'h1000_0002, "result data from last command");
        repeat (20) @(posedge clk);
        #1;
        check(mt_irq, "need_work IRQ is a stable level, no storm");
        read_status(st);
        check(st[5] && st[1], "status read returns need_work/done");
        wait_low("status read clears mt_irq");

        // KICK clears need_work immediately (new work arrived).
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_NEED_WORK});
        push(32'h0000_0003, 32'h0, 32'h0);
        @(posedge clk); #1;
        check(!mt_irq, "KICK clears need_work before completion");
        wait_irq("next need_work IRQ");
        read_status(st);
        wait_low("status read clears second IRQ");

        // DONE-only mask.
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_DONE});
        push(32'h0000_0004, 32'h0, 32'h0);
        wait_irq("done-only IRQ");
        check(status[1] == 1'b1, "done-only: status.done set");
        read_status(st);
        wait_low("done-only IRQ cleared");

        // ACCEPT_ERR reaches the IRQ mask.
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_ACCEPT_ERR});
        reject_next = 1'b1;
        push(32'h0000_0005, 32'h0, 32'h0);
        wait_irq("accept_err IRQ");
        check(status[3] == 1'b1, "accept_err status set");
        read_status(st);
        wait_low("accept_err IRQ cleared");
        reject_next = 1'b0;

        // KICK_ERR reaches the IRQ mask.  Stop the slave so the queue fills.
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_KICK_ERR});
        slave_stall = 1'b1;
        // One command is popped into S_ISSUE before the stall bites, so the
        // depth-3 FIFO needs four more pushes plus the dropped kick.
        push(32'h0000_0006, 32'h0, 32'h0);
        push(32'h0000_0007, 32'h0, 32'h0);
        push(32'h0000_0008, 32'h0, 32'h0);
        push(32'h0000_0009, 32'h0, 32'h0);
        push(32'h0000_000A, 32'h0, 32'h0);  // this kick is dropped
        wait_irq("kick_err IRQ");
        check(status[4] == 1'b1, "kick_err status set");
        mmio_write(IDX_IRQ_ACK, {27'd0, IRQ_KICK_ERR});
        wait_low("MT_IRQ_ACK clears kick_err");
        slave_stall = 1'b0;
        repeat (100) @(posedge clk);
        #1;
        read_status(st);

        // need_work ACK bit.
        mmio_write(IDX_IRQ_MASK, {27'd0, IRQ_NEED_WORK});
        push(32'h0000_000B, 32'h0, 32'h0);
        wait_irq("need_work IRQ for ack test");
        mmio_write(IDX_IRQ_ACK, {27'd0, IRQ_NEED_WORK});
        wait_low("MT_IRQ_ACK clears need_work");
        read_status(st);
        check(status[2:0] == 3'b000, "busy/done/err clear after ack/status");

        if (errors == 0) begin
            $display("ALL TESTS PASSED: %0d checks - adapter need_work/done/accept_err/kick_err IRQ, level/ack/status-clear, HART_ID=1, no storm", checks);
        end else begin
            $display("*** FAILED: %0d errors / %0d checks ***", errors, checks);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
