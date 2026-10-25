//=============================================================================
// ARES core verification - self-checking test for the TB memory model
//-----------------------------------------------------------------------------
// Exercises sim/rtl/tb_mem_beat_if.sv (128-bit beat -> DPI model) and
// sim/rtl/tb_mmio_if.sv (MMIO -> DPI model) against an independent byte-level
// shadow model, covering the semantics the LSU is allowed to rely on
// (memory.md 6.7 / 3.1, flow doc section 3.2/3.3):
//
//   * full-beat write/read round trip through the DPI model
//   * arbitrary byte enables, including patterns (0x5, 0x8000) that the
//     model's 2-bit size mask cannot express directly - the classic silent
//     corruption source when the lane offset is applied to an unaligned
//     address
//   * same-cycle write + read to the same 16B beat is ordered write-first
//   * a stalled response keeps its data stable (no live re-read)
//   * MMIO single outstanding, exactly-one response per request, response one
//     cycle after the request and never before the side effect
//   * the DPI memory itself matches the shadow model (writes really landed)
//
// Harness: built through sim/Makefile as TOPNAME=tb_mem_model, so the standard
// simulation main.cpp drives clock/reset and stops on the ebreak() below.
// Run: make tb-mem-model   (see rtl/memory/test/README.md)
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_mem_model (
    input clock,
    input reset
);
    import "DPI-C" function int  perip_read(input int addr);
    import "DPI-C" function void ebreak();

    wire clk = clock;
    wire rst = reset;

    //-------------------------------------------------------------------------
    // Scratch region: 64 bytes of cacheable DRAM, 16B aligned.
    //-------------------------------------------------------------------------
    localparam logic [31:0] BASE = 32'h8010_0400;
    localparam int unsigned SHADOW_BYTES = 64;

    localparam logic [127:0] D0 = 128'h0f0e_0d0c_0b0a_0908_0706_0504_0302_0100;
    localparam logic [127:0] D1 = 128'he7e6_e5e4_e3e2_e1e0_dfde_dddc_dbd_a9d8;
    localparam logic [127:0] D2 = 128'hf7f6_f5f4_f3f2_f1f0_fffe_fdfc_fbfa_f9f8;
    localparam logic [127:0] D3 = 128'h1716_1514_1312_1110_1f1e_1d1c_1b1a_1918;
    localparam logic [127:0] D4 = 128'h2726_2524_2322_2120_2f2e_2d2c_2b2a_2928;

    //-------------------------------------------------------------------------
    // Beat channel
    //-------------------------------------------------------------------------
    logic         wr_valid;
    logic         wr_ready;
    logic [31:0]  wr_addr;
    logic [127:0] wr_data;
    logic [15:0]  wr_be;

    logic         rd_valid;
    logic         rd_ready;
    logic [31:0]  rd_addr;
    logic         rsp_valid;
    logic         rsp_ready;
    logic [127:0] rsp_data;

    tb_mem_beat_if #(
        .MEM_LATENCY (1),
        .STALL_PERIOD(0)
    ) dut_beat (
        .clk         (clk),
        .rst         (rst),
        .mem_rd_valid(rd_valid),
        .mem_rd_ready(rd_ready),
        .mem_rd_addr (rd_addr),
        .mem_rsp_valid(rsp_valid),
        .mem_rsp_ready(rsp_ready),
        .mem_rsp_data(rsp_data),
        .mem_wr_valid(wr_valid),
        .mem_wr_ready(wr_ready),
        .mem_wr_addr (wr_addr),
        .mem_wr_data (wr_data),
        .mem_wr_be   (wr_be)
    );

    //-------------------------------------------------------------------------
    // MMIO channel
    //-------------------------------------------------------------------------
    logic        m_req_valid;
    logic        m_req_ready;
    logic        m_write;
    logic [31:0] m_addr;
    logic [31:0] m_wdata;
    logic [3:0]  m_wstrb;
    logic        m_rsp_valid;
    logic        m_rsp_ready;
    logic [31:0] m_rdata;

    tb_mmio_if dut_mmio (
        .clk           (clk),
        .rst           (rst),
        .mmio_req_valid(m_req_valid),
        .mmio_req_ready(m_req_ready),
        .mmio_write    (m_write),
        .mmio_addr     (m_addr),
        .mmio_wdata    (m_wdata),
        .mmio_wstrb    (m_wstrb),
        .mmio_rsp_valid(m_rsp_valid),
        .mmio_rsp_ready(m_rsp_ready),
        .mmio_rdata    (m_rdata)
    );

    //-------------------------------------------------------------------------
    // Independent byte-level shadow of the scratch region
    //-------------------------------------------------------------------------
    logic [7:0] shadow [SHADOW_BYTES];

    task automatic shadow_apply(input logic [31:0]  addr,
                                input logic [127:0] data,
                                input logic [15:0]  be);
        int i;
        begin
            for (i = 0; i < 16; i++)
                /* verilator lint_off BLKSEQ */  // task-local shadow update
                if (be[i]) shadow[int'(addr - BASE) + i] = data[8*i +: 8];
                /* verilator lint_on BLKSEQ */
        end
    endtask

    task automatic shadow_check_data(input logic [31:0]  addr,
                                     input logic [127:0] data,
                                     input string        msg);
        int i;
        begin
            for (i = 0; i < 16; i++)
                check(data[8*i +: 8] == shadow[int'(addr - BASE) + i], msg);
        end
    endtask

    // Cross-check that the adapter's byte lanes reached the DPI model exactly
    // as the shadow says (catches "wrote the right thing to the wrong lane").
    task automatic shadow_check_mem(input logic [31:0] addr);
        int i;
        logic [31:0] w;
        begin
            for (i = 0; i < 4; i++) begin
                w = 32'(perip_read(int'(addr) + 4*i));
                check(w == {shadow[int'(addr - BASE) + 4*i + 3],
                            shadow[int'(addr - BASE) + 4*i + 2],
                            shadow[int'(addr - BASE) + 4*i + 1],
                            shadow[int'(addr - BASE) + 4*i + 0]},
                      "DPI memory differs from the shadow model");
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // Error bookkeeping
    //-------------------------------------------------------------------------
    int unsigned errors;
    int unsigned cyc;

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            /* verilator lint_off BLKSEQ */  // task-local scoreboard update
            errors = errors + 1;
            /* verilator lint_on BLKSEQ */
            if (errors <= 20) $display("[cyc %0d] FAIL: %s", cyc, msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // Command list
    //-------------------------------------------------------------------------
    localparam logic [3:0] OP_WR      = 4'd0;
    localparam logic [3:0] OP_RD      = 4'd1;
    localparam logic [3:0] OP_SAME    = 4'd2;
    localparam logic [3:0] OP_STABLE  = 4'd3;
    localparam logic [3:0] OP_MMIO_WR = 4'd4;
    localparam logic [3:0] OP_MMIO_RD = 4'd5;
    localparam logic [3:0] OP_END     = 4'd15;

    typedef struct packed {
        logic [3:0]   op;
        logic [31:0]  addr;
        logic [127:0] data;
        logic [15:0]  be;
        logic [31:0]  wdata;
        logic [3:0]   wstrb;
    } cmd_t;

    function automatic cmd_t cmd_of(input int unsigned i);
        cmd_t c;
        begin
            c       = '0;
            c.be    = 16'hffff;
            c.wstrb = 4'hf;
            case (i)
                0:  begin c.op = OP_WR;      c.addr = BASE;           c.data = D0; end
                1:  begin c.op = OP_RD;      c.addr = BASE;                          end
                2:  begin c.op = OP_WR;      c.addr = BASE + 32'd16;  c.data = D1;
                                                    c.be = 16'h0005;                   end
                3:  begin c.op = OP_RD;      c.addr = BASE + 32'd16;                  end
                4:  begin c.op = OP_WR;      c.addr = BASE + 32'd32;  c.data = D2;
                                                    c.be = 16'h8000;                   end
                5:  begin c.op = OP_RD;      c.addr = BASE + 32'd32;                  end
                6:  begin c.op = OP_WR;      c.addr = BASE + 32'd48;  c.data = D3; end
                7:  begin c.op = OP_SAME;    c.addr = BASE + 32'd48;  c.data = D4; end
                8:  begin c.op = OP_STABLE;  c.addr = BASE + 32'd48;                  end
                9:  begin c.op = OP_MMIO_WR; c.addr = 32'ha000_03f8;
                                             c.wdata = 32'h41; c.wstrb = 4'h1;         end
                10: begin c.op = OP_MMIO_RD; c.addr = 32'ha000_0048;                  end
                11: begin c.op = OP_RD;      c.addr = BASE + 32'd48;                  end
                default: c.op = OP_END;
            endcase
            cmd_of = c;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Sequencer
    //-------------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_INIT, S_LOAD, S_DISPATCH, S_WR, S_WR_WAIT, S_RD, S_RD_WAIT, S_RD_RSP,
        S_SAME, S_SAME_WAIT, S_SAME_RSP, S_STABLE, S_STABLE_WAIT, S_STABLE_RSP,
        S_MWR, S_MWR_WAIT, S_MWR_RSP, S_MRD, S_MRD_WAIT, S_MRD_RSP,
        S_ADVANCE, S_DONE
    } state_e;

    state_e      state;
    cmd_t        cur;
    int unsigned idx;
    logic [1:0]  hold;
    logic        seen;
    logic [127:0] seen_data;
    logic        done;

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= S_INIT;
            cur        <= '0;
            idx        <= 0;
            errors     <= 0;
            cyc        <= 0;
            hold       <= 2'd0;
            seen       <= 1'b0;
            seen_data  <= 128'd0;
            done       <= 1'b0;
            wr_valid   <= 1'b0;
            rd_valid   <= 1'b0;
            rsp_ready  <= 1'b0;
            wr_addr    <= 32'd0;
            wr_data    <= 128'd0;
            wr_be      <= 16'd0;
            rd_addr    <= 32'd0;
            m_req_valid<= 1'b0;
            m_write    <= 1'b0;
            m_addr     <= 32'd0;
            m_wdata    <= 32'd0;
            m_wstrb    <= 4'd0;
            m_rsp_ready<= 1'b0;
            for (int i = 0; i < SHADOW_BYTES; i++) shadow[i] <= 8'd0;
        end else begin
            cyc <= cyc + 1;

            case (state)
                S_INIT: state <= S_LOAD;

                S_LOAD: begin
                    cur   <= cmd_of(idx);
                    state <= S_DISPATCH;
                end

                S_DISPATCH: begin
                    case (cur.op)
                        OP_WR:      state <= S_WR;
                        OP_RD:      state <= S_RD;
                        OP_SAME:    state <= S_SAME;
                        OP_STABLE:  state <= S_STABLE;
                        OP_MMIO_WR: state <= S_MWR;
                        OP_MMIO_RD: state <= S_MRD;
                        default:    state <= S_DONE;
                    endcase
                end

                //---- beat write ------------------------------------------
                S_WR: begin
                    wr_valid <= 1'b1;
                    wr_addr  <= cur.addr;
                    wr_data  <= cur.data;
                    wr_be    <= cur.be;
                    state    <= S_WR_WAIT;
                end
                S_WR_WAIT: begin
                    if (wr_ready) begin
                        wr_valid <= 1'b0;
                        shadow_apply(cur.addr, cur.data, cur.be);
                        shadow_check_mem(cur.addr);
                        state <= S_ADVANCE;
                    end
                end

                //---- beat read -------------------------------------------
                S_RD: begin
                    rd_valid <= 1'b1;
                    rd_addr  <= cur.addr;
                    state    <= S_RD_WAIT;
                end
                S_RD_WAIT: begin
                    if (rd_ready) begin
                        rd_valid  <= 1'b0;
                        rsp_ready <= 1'b1;
                        state     <= S_RD_RSP;
                    end
                end
                S_RD_RSP: begin
                    if (rsp_valid) begin
                        rsp_ready <= 1'b0;
                        shadow_check_data(cur.addr, rsp_data,
                                          "beat read data differs from the shadow model");
                        state <= S_ADVANCE;
                    end
                end

                //---- same-cycle write + read (write must win) ------------
                S_SAME: begin
                    wr_valid <= 1'b1;
                    wr_addr  <= cur.addr;
                    wr_data  <= cur.data;
                    wr_be    <= 16'hffff;
                    rd_valid <= 1'b1;
                    rd_addr  <= cur.addr;
                    shadow_apply(cur.addr, cur.data, 16'hffff);
                    state    <= S_SAME_WAIT;
                end
                S_SAME_WAIT: begin
                    if (wr_ready) wr_valid <= 1'b0;
                    if (rd_ready) begin
                        rd_valid  <= 1'b0;
                        rsp_ready <= 1'b1;
                        state     <= S_SAME_RSP;
                    end
                end
                S_SAME_RSP: begin
                    if (rsp_valid) begin
                        rsp_ready <= 1'b0;
                        check(rsp_data == cur.data,
                              "same-cycle read did not observe the write (write-first violated)");
                        shadow_check_mem(cur.addr);
                        state <= S_ADVANCE;
                    end
                end

                //---- stalled response must stay stable -------------------
                S_STABLE: begin
                    rd_valid <= 1'b1;
                    rd_addr  <= cur.addr;
                    hold     <= 2'd2;
                    seen     <= 1'b0;
                    state    <= S_STABLE_WAIT;
                end
                S_STABLE_WAIT: begin
                    if (rd_ready) begin
                        rd_valid <= 1'b0;
                        state    <= S_STABLE_RSP;
                    end
                end
                S_STABLE_RSP: begin
                    if (rsp_valid) begin
                        if (!seen) begin
                            seen      <= 1'b1;
                            seen_data <= rsp_data;
                        end else begin
                            check(rsp_data == seen_data,
                                  "stalled response data changed");
                        end
                        if (hold == 2'd0) begin
                            rsp_ready <= 1'b1;
                            shadow_check_data(cur.addr, rsp_data,
                                              "stalled read data differs from the shadow model");
                            state <= S_ADVANCE;
                        end else begin
                            hold <= hold - 2'd1;
                        end
                    end
                end

                //---- MMIO write ------------------------------------------
                S_MWR: begin
                    m_req_valid <= 1'b1;
                    m_write     <= 1'b1;
                    m_addr      <= cur.addr;
                    m_wdata     <= cur.wdata;
                    m_wstrb     <= cur.wstrb;
                    state       <= S_MWR_WAIT;
                end
                S_MWR_WAIT: begin
                    if (m_req_ready) begin
                        m_req_valid <= 1'b0;
                        state       <= S_MWR_RSP;
                    end
                end
                S_MWR_RSP: begin
                    check(m_rsp_valid,
                          "MMIO write response did not arrive one cycle after the request");
                    if (m_rsp_valid) begin
                        m_rsp_ready <= 1'b1;
                        state       <= S_ADVANCE;
                    end
                end

                //---- MMIO read -------------------------------------------
                S_MRD: begin
                    m_req_valid <= 1'b1;
                    m_write     <= 1'b0;
                    m_addr      <= cur.addr;
                    state       <= S_MRD_WAIT;
                end
                S_MRD_WAIT: begin
                    if (m_req_ready) begin
                        m_req_valid <= 1'b0;
                        state       <= S_MRD_RSP;
                    end
                end
                S_MRD_RSP: begin
                    check(m_rsp_valid,
                          "MMIO read response did not arrive one cycle after the request");
                    if (m_rsp_valid) begin
                        m_rsp_ready <= 1'b1;
                        $display("note: MMIO RTC read returned 0x%08x", m_rdata);
                        state <= S_ADVANCE;
                    end
                end

                //---- housekeeping ----------------------------------------
                S_ADVANCE: begin
                    m_rsp_ready <= 1'b0;
                    rsp_ready   <= 1'b0;
                    idx         <= idx + 1;
                    state       <= S_LOAD;
                end

                S_DONE: begin
                    if (!done) begin
                        done <= 1'b1;
                        if (errors == 0) begin
                            $display("ALL TESTS PASSED: tb_mem_model verified 12 memory-model operations in %0d cycles",
                                     cyc);
                            ebreak();
                        end else begin
                            $display("FAILED: tb_mem_model saw %0d errors", errors);
                            $fatal(1, "tb_mem_model verification failed");
                        end
                    end
                end

                default: state <= S_DONE;
            endcase
        end
    end

endmodule
