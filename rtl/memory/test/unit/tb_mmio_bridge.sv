//=============================================================================
// ARES LSU - self-checking unit bench for the L11 MMIO bridge
//-----------------------------------------------------------------------------
// DUT  : rtl/memory/mmio_bridge.sv (single outstanding device channel)
// Spec : docs/microarch/memory.md 3.1 (uncached MMIO: one outstanding
//        transaction, LQ before SQ, Write Ack = side effect complete, load
//        completion only after the device response);
//        rtl/memory/LSU_INTERFACES.md section 12 (frozen interface + the six
//        required assertions) and section 8 (verification requirements).
// FREE items: FREE-10 (verification environment internal structure).
//
// Structure (independent top, own clock/reset, no DPI, no harness):
//   * behavioural device model: single outstanding request, programmable
//     request-ready backpressure and response latency (>= 1 cycle), exactly
//     one response per accepted request, address dependent read data; it also
//     flags a request that arrives while its own transaction is outstanding,
//   * a golden checker engine that runs once per cycle and compares every DUT
//     output against an independent reference model of the owner state
//     {IDLE, LOAD, STORE} plus a scoreboard of accepted transactions (order,
//     payload, routing, exactly-once response),
//   * directed tests: reset/idle, single load (word aligned address forced to
//     the containing word, no byte enables), single store + Write Ack,
//     same-cycle LQ priority and the held SQ request served next, response
//     routing follows the REGISTERED owner (both directions), requests blocked
//     while busy, device backpressure with frozen owner-selected fields, reset
//     in the middle of an outstanding transaction,
//   * a fixed-seed randomised phase (>= 10k cycles) with random clients, random
//     device ready and random response latency, compared against the model
//     every cycle,
//   * SV state/transition coverage counters (FREE-10): the three owner states
//     and the seven legal transitions must all be observed (the two
//     owner-switch-while-busy transitions are illegal and are checked).
//
// Build / run (repository root, explicit file list):
// cmd: verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module tb_mmio_bridge --Mdir sim/build/unit/tb_mmio_bridge -o tb_mmio_bridge rtl/common/ares_pkg.sv rtl/memory/mmio_bridge.sv rtl/memory/test/unit/tb_mmio_bridge.sv
//   sim/build/unit/tb_mmio_bridge/tb_mmio_bridge   (-o must be a file NAME: the generated make runs inside --Mdir)
//=============================================================================
`timescale 1ns/1ps

module tb_mmio_bridge;
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    localparam int unsigned RAND_CYCLES     = 12000;
    localparam int unsigned RNG_SEED        = 32'h2B11_0011;   // "M2b L11"
    localparam int unsigned WATCHDOG_CYCLES = 400000;

    // Owner state encoding used by the coverage counters.
    localparam int unsigned ST_IDLE  = 0;
    localparam int unsigned ST_LOAD  = 1;
    localparam int unsigned ST_STORE = 2;
    localparam int unsigned N_STATES = 3;
    localparam int unsigned N_TRANS  = 7;   // legal transitions only

    //-------------------------------------------------------------------------
    // Clock / reset (self-contained)
    //-------------------------------------------------------------------------
    logic clk;
    logic rst = 1'b1;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // A stalled handshake is reported instead of hanging the run.
    initial begin
        repeat (WATCHDOG_CYCLES) @(posedge clk);
        $fatal(1, "TB FAILED: watchdog timeout after %0d cycles", WATCHDOG_CYCLES);
    end

    //-------------------------------------------------------------------------
    // DUT ports
    //-------------------------------------------------------------------------
    logic        lq_req_valid;
    logic        lq_req_ready;
    logic [31:0] lq_req_addr;
    logic        lq_rsp_valid;
    logic [31:0] lq_rsp_data;
    logic        sq_req_valid;
    logic        sq_req_ready;
    logic        sq_req_ack;
    logic [31:0] sq_req_addr;
    logic [31:0] sq_req_data;
    logic [3:0]  sq_req_strb;
    logic        mmio_req_valid;
    logic        mmio_req_ready;
    logic        mmio_write;
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wdata;
    logic [3:0]  mmio_wstrb;
    logic        mmio_rsp_valid;
    logic        mmio_rsp_ready;
    logic [31:0] mmio_rsp_data;
    logic        busy;

    mmio_bridge dut (.*);

    // lsu_top wires the LQ response payload straight from the device bus (the
    // bridge only routes lq_rsp_valid); the DUT asserts both stay consistent.
    assign lq_rsp_data = mmio_rsp_data;

    //=========================================================================
    // Device model (memory.md 3.1 seam): one outstanding request, exactly one
    // response per accepted request, programmable ready / response latency.
    //=========================================================================
    typedef enum logic [1:0] { DEV_IDLE, DEV_WAIT, DEV_RSP } dev_state_e;
    dev_state_e  dev_state;
    logic [7:0]  dev_cnt;        // remaining response latency
    logic [31:0] dev_rdata_r;
    int unsigned dev_lag;        // response latency in cycles (>= 1)
    int unsigned dev_prot_err;   // device-side protocol violations

    assign mmio_rsp_valid = (dev_state == DEV_RSP);
    assign mmio_rsp_data  = dev_rdata_r;

    function automatic logic [31:0] dev_read_data(input logic [31:0] word_addr);
        dev_read_data = word_addr ^ 32'hD00D_5EED;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            dev_state   <= DEV_IDLE;
            dev_cnt     <= 8'd0;
            dev_rdata_r <= 32'd0;
        end else begin
            unique case (dev_state)
                DEV_IDLE: begin
                    if (mmio_req_valid && mmio_req_ready) begin
                        dev_rdata_r <= mmio_write ? 32'd0 : dev_read_data(mmio_addr);
                        dev_cnt     <= 8'(dev_lag - 1);
                        dev_state   <= DEV_WAIT;
                    end
                end
                DEV_WAIT: begin
                    if (dev_cnt == 8'd0) dev_state <= DEV_RSP;
                    else                 dev_cnt   <= dev_cnt - 8'd1;
                end
                DEV_RSP: begin
                    if (mmio_rsp_ready) dev_state <= DEV_IDLE;
                end
                default: dev_state <= DEV_IDLE;
            endcase
        end
    end

    // Independent device-side observation: the channel must never present a
    // second request while one is outstanding.
    always_ff @(posedge clk) begin
        if (!rst && mmio_req_valid && mmio_req_ready && (dev_state != DEV_IDLE)) begin
            dev_prot_err <= dev_prot_err + 1;
            $display("[%0t] FAIL: device received a request while a transaction is outstanding",
                     $time);
        end
    end

    //=========================================================================
    // Golden checker engine (one pass per cycle, mid-cycle)
    //=========================================================================
    int unsigned checks;
    int unsigned errors;
    int unsigned cycle_cnt;
    int unsigned rand_cycles;

    logic m_busy;                 // mirror of the DUT's busy register
    logic m_owner;                // mirror of the DUT's owner_store register

    // expected device view for the current cycle
    logic        e_lq_gnt, e_sq_gnt;
    logic        e_req_valid, e_write;
    logic [31:0] e_addr, e_wdata;
    logic [3:0]  e_wstrb;
    logic        e_lq_ready, e_sq_ready;
    logic        e_lq_rsp, e_sq_ack;

    // scoreboard of accepted, not yet answered transactions (device order)
    typedef struct packed {
        logic        write;
        logic [31:0] addr;
        logic [31:0] wdata;
        logic [3:0]  wstrb;
    } txn_t;
    txn_t exp_q [$];

    // statistics / coverage counters
    int unsigned n_load_acc, n_store_acc, n_load_rsp, n_store_rsp;
    int unsigned n_abandoned, n_abandoned_load, n_abandoned_store;
    int unsigned n_same_cycle, n_backpressure, n_busy_block;
    int unsigned dev_acc_cnt, dev_rsp_cnt, mdl_prot_err;

    logic [N_STATES-1:0] cov_state;    // states observed
    logic [N_TRANS-1:0]  cov_trans;    // legal transitions observed
    int unsigned         cov_prev;
    int unsigned         cov_cur;

    function automatic int unsigned cov_state_of(input logic b, input logic own);
        cov_state_of = b ? (own ? ST_STORE : ST_LOAD) : ST_IDLE;
    endfunction

    // 3x3 transition table collapsed onto the 7 LEGAL transitions:
    //   0 IDLE->IDLE  1 IDLE->LOAD  2 IDLE->STORE
    //   3 LOAD->IDLE  4 LOAD->LOAD
    //   5 STORE->IDLE 6 STORE->STORE
    function automatic int unsigned cov_trans_idx(input int unsigned from,
                                                  input int unsigned to);
        unique case (from)
            ST_IDLE: cov_trans_idx = to;
            ST_LOAD: cov_trans_idx = (to == ST_IDLE) ? 32'd3 : 32'd4;
            default: cov_trans_idx = (to == ST_IDLE) ? 32'd5 : 32'd6;
        endcase
    endfunction

    task automatic dump_ctx();
        $display("  cycle=%0d rst=%b | DUT busy=%b owner=%b | model busy=%b owner=%b",
                 cycle_cnt, rst, busy, dut.owner_store_r, m_busy, m_owner);
        $display("  clients: lq_v=%b lq_rdy=%b lq_addr=%08h | sq_v=%b sq_rdy=%b ack=%b addr=%08h data=%08h strb=%b",
                 lq_req_valid, lq_req_ready, lq_req_addr, sq_req_valid, sq_req_ready,
                 sq_req_ack, sq_req_addr, sq_req_data, sq_req_strb);
        $display("  device : req_v=%b rdy=%b wr=%b addr=%08h wdata=%08h wstrb=%b rsp_v=%b rsp_d=%08h",
                 mmio_req_valid, mmio_req_ready, mmio_write, mmio_addr, mmio_wdata,
                 mmio_wstrb, mmio_rsp_valid, mmio_rsp_data);
        $display("  model  : exp_req=%b exp_wr=%b exp_addr=%08h exp_wstrb=%b exp_lq_rdy=%b exp_sq_rdy=%b exp_lq_rsp=%b exp_ack=%b",
                 e_req_valid, e_write, e_addr, e_wstrb, e_lq_ready, e_sq_ready,
                 e_lq_rsp, e_sq_ack);
    endtask

    task automatic chk(input logic cond, input string msg);
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            if (errors <= 10) begin
                $display("[%0t] FAIL: %s", $time, msg);
                dump_ctx();
            end
        end
    endtask

    task automatic engine_cycle();
        txn_t t;
        begin
            if (rst) begin
                // Reset abandons whatever the channel owned.
                m_busy   = 1'b0;
                m_owner  = 1'b0;
                cov_prev = ST_IDLE;
                for (int unsigned i = 0; i < exp_q.size(); i++) begin
                    n_abandoned = n_abandoned + 1;
                    if (exp_q[i].write) n_abandoned_store = n_abandoned_store + 1;
                    else                n_abandoned_load  = n_abandoned_load + 1;
                end
                exp_q.delete();
            end else begin
                cycle_cnt = cycle_cnt + 1;

                //---- independent reference of every DUT output --------------
                e_lq_gnt   = lq_req_valid && !m_busy;
                e_sq_gnt   = sq_req_valid && !lq_req_valid && !m_busy;
                e_req_valid = e_lq_gnt || e_sq_gnt;
                e_write    = e_sq_gnt;
                e_addr     = e_sq_gnt ? {sq_req_addr[31:2], 2'b00}
                                      : {lq_req_addr[31:2], 2'b00};
                e_wstrb    = e_sq_gnt ? sq_req_strb : 4'h0;
                e_wdata    = sq_req_data;
                e_lq_ready = e_lq_gnt && mmio_req_ready;
                e_sq_ready = e_sq_gnt && mmio_req_ready;
                e_lq_rsp   = mmio_rsp_valid && m_busy && !m_owner;
                e_sq_ack   = mmio_rsp_valid && m_busy &&  m_owner;

                chk(busy === m_busy, "busy differs from the owner model");
                chk(lq_req_ready === e_lq_ready, "lq_req_ready mismatch");
                chk(sq_req_ready === e_sq_ready, "sq_req_ready mismatch");
                chk(mmio_req_valid === e_req_valid, "mmio_req_valid mismatch");
                chk(mmio_write === e_write, "mmio_write mismatch");
                chk(mmio_addr === e_addr, "mmio_addr mismatch");
                chk(mmio_wstrb === e_wstrb, "mmio_wstrb mismatch");
                chk(mmio_wdata === e_wdata, "mmio_wdata mismatch");
                chk(lq_rsp_valid === e_lq_rsp, "lq_rsp_valid mismatch");
                chk(sq_req_ack === e_sq_ack, "sq_req_ack mismatch");
                chk(mmio_rsp_ready === 1'b1, "mmio_rsp_ready must be tied high");
                chk(!(lq_rsp_valid && sq_req_ack), "response routes are not exclusive");
                chk(!mmio_req_valid || !busy, "device request while a transaction is outstanding");
                chk(!mmio_req_valid || (mmio_addr[1:0] == 2'b00), "device address not word aligned");
                chk(mmio_write || (mmio_wstrb == 4'h0), "a read carries byte enables");

                //---- device request handshake (scoreboard) ------------------
                if (mmio_req_valid && mmio_req_ready) begin
                    dev_acc_cnt = dev_acc_cnt + 1;
                    t.write = e_write;
                    t.addr  = e_addr;
                    t.wdata = e_wdata;
                    t.wstrb = e_wstrb;
                    exp_q.push_back(t);
                    chk(exp_q.size() == 1, "more than one accepted request outstanding");
                    if (e_write) n_store_acc = n_store_acc + 1;
                    else         n_load_acc  = n_load_acc + 1;
                end
                if (lq_req_valid && sq_req_valid && !m_busy)  n_same_cycle   = n_same_cycle + 1;
                if (mmio_req_valid && !mmio_req_ready)        n_backpressure = n_backpressure + 1;
                if (m_busy && (lq_req_valid || sq_req_valid)) n_busy_block   = n_busy_block + 1;

                //---- device response handshake (routing) --------------------
                if (mmio_rsp_valid && mmio_rsp_ready) begin
                    dev_rsp_cnt = dev_rsp_cnt + 1;
                    if (exp_q.size() == 0) begin
                        chk(1'b0, "response without an accepted request");
                    end else begin
                        t = exp_q.pop_front();
                        if (t.write) begin
                            n_store_rsp = n_store_rsp + 1;
                            chk(sq_req_ack && !lq_rsp_valid, "store ack not routed to the SQ");
                        end else begin
                            n_load_rsp = n_load_rsp + 1;
                            chk(lq_rsp_valid && !sq_req_ack, "load response not routed to the LQ");
                            chk(mmio_rsp_data == dev_read_data(t.addr),
                                "load data does not belong to the accepted word address");
                        end
                    end
                end

                //---- owner state model (same rules as the DUT registers) ----
                if (e_req_valid && mmio_req_ready) begin
                    m_busy  = 1'b1;
                    m_owner = e_write;
                end else if (mmio_rsp_valid && m_busy) begin
                    m_busy = 1'b0;
                end

                //---- FSM coverage (DUT state observed this cycle) ----------
                cov_cur = cov_state_of(dut.busy_r, dut.owner_store_r);
                cov_state[cov_cur] = 1'b1;
                if ((cov_prev == ST_LOAD  && cov_cur == ST_STORE) ||
                    (cov_prev == ST_STORE && cov_cur == ST_LOAD)) begin
                    chk(1'b0, "illegal transition: owner changed while busy");
                end else begin
                    cov_trans[cov_trans_idx(cov_prev, cov_cur)] = 1'b1;
                end
                cov_prev = cov_cur;
            end
        end
    endtask

    always @(negedge clk) begin
        #2;
        engine_cycle();
    end

    //=========================================================================
    // Stimulus helpers (one clock per call)
    //   drv(): runs just after a rising edge, applies new stimulus
    //   smp(): runs mid-cycle, reads the values the next rising edge samples
    // All stimulus updates happen right after drv() so that the engine (which
    // samples mid-cycle) sees the same cycle the DUT sees.
    //=========================================================================
    task automatic drv(); @(posedge clk); #1; endtask
    task automatic smp(); @(negedge clk); #2; endtask

    task automatic idle_clients();
        lq_req_valid = 1'b0;
        sq_req_valid = 1'b0;
        lq_req_addr  = 32'h8000_0000;
        sq_req_addr  = 32'h8000_0000;
        sq_req_data  = 32'd0;
        sq_req_strb  = 4'h0;
    endtask

    //=========================================================================
    // Directed phases
    //=========================================================================
    task automatic phase_reset();
        $display("[tb_mmio_bridge] phase 1: reset / idle");
        rst            = 1'b1;
        mmio_req_ready = 1'b1;     // even a ready device must not be requested
        idle_clients();
        repeat (3) drv();
        smp();
        chk(!busy, "reset: busy = 0");
        chk(!mmio_req_valid && !lq_req_ready && !sq_req_ready, "reset: no client/device request");
        chk(!lq_rsp_valid && !sq_req_ack, "reset: no response");
        chk(mmio_rsp_ready, "reset: mmio_rsp_ready tied high");
        drv();
        rst = 1'b0;                // sampled at the next rising edge
        drv();
        smp();
        chk(!busy && !mmio_req_valid && !lq_req_ready && !sq_req_ready
            && !lq_rsp_valid && !sq_req_ack, "idle: silent channel after reset release");
        drv();
    endtask

    task automatic phase_load_single();
        int unsigned cyc;
        $display("[tb_mmio_bridge] phase 2: single load (device read)");
        idle_clients();
        dev_lag        = 1;
        mmio_req_ready = 1'b1;
        lq_req_addr    = 32'h8000_1007;    // low bits must be masked away
        lq_req_valid   = 1'b1;
        smp();                             // cycle 0: request presented
        chk(lq_req_ready, "load: lq_req_ready on the accept cycle");
        chk(!sq_req_ready, "load: sq_req_ready must stay low");
        chk(mmio_req_valid && !mmio_write, "load: device read request presented");
        chk(mmio_addr == 32'h8000_1004, "load: address forced to the containing word");
        chk(mmio_wstrb == 4'h0, "load: no byte enables on a read");
        drv();                             // request accepted at this edge
        lq_req_valid = 1'b0;
        smp();                             // cycle 1
        chk(busy, "load: busy set by the request handshake");
        chk(!lq_req_ready && !sq_req_ready, "load: no accept while busy");
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (lq_rsp_valid) break;
            chk(!sq_req_ack, "load: no Write Ack before the response");
        end
        chk(lq_rsp_valid, "load: device response routed to the LQ");
        chk(!sq_req_ack, "load: no Write Ack for a load");
        chk(busy, "load: busy still set during the response cycle");
        drv();                             // response consumed at this edge
        smp();
        chk(!busy && !lq_rsp_valid && !sq_req_ack, "load: single-cycle response, channel idle");
        drv();
    endtask

    task automatic phase_store_single();
        int unsigned cyc;
        $display("[tb_mmio_bridge] phase 3: single store (device write + Write Ack)");
        idle_clients();
        dev_lag        = 2;                // also exercises the BUSY->BUSY self transition
        mmio_req_ready = 1'b1;
        sq_req_addr    = 32'h8000_2003;
        sq_req_data    = 32'h1234_ABCD;
        sq_req_strb    = 4'b1010;
        sq_req_valid   = 1'b1;
        smp();                             // cycle 0
        chk(sq_req_ready, "store: sq_req_ready on the accept cycle");
        chk(!lq_req_ready, "store: lq_req_ready must stay low");
        chk(mmio_req_valid && mmio_write, "store: device write request presented");
        chk(mmio_addr == 32'h8000_2000, "store: address forced to the containing word");
        chk(mmio_wdata == 32'h1234_ABCD, "store: write data passed through");
        chk(mmio_wstrb == 4'b1010, "store: byte enables passed through");
        drv();                             // write accepted at this edge
        sq_req_valid = 1'b0;
        smp();                             // cycle 1
        chk(busy, "store: busy set by the write handshake");
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (sq_req_ack) break;
            chk(!lq_rsp_valid, "store: no load response for a store");
        end
        chk(sq_req_ack, "store: Write Ack routed to the SQ");
        chk(!lq_rsp_valid, "store: no load response for a store");
        chk(busy, "store: busy still set during the ack cycle");
        drv();                             // ack consumed at this edge
        smp();
        chk(!busy && !sq_req_ack, "store: single-cycle ack, channel idle");
        drv();
    endtask

    task automatic phase_priority();
        int unsigned cyc;
        $display("[tb_mmio_bridge] phase 4: same-cycle LQ priority, held SQ served next");
        idle_clients();
        dev_lag        = 1;
        mmio_req_ready = 1'b1;
        lq_req_addr    = 32'h8000_3000;
        lq_req_valid   = 1'b1;
        sq_req_addr    = 32'h8000_4000;
        sq_req_data    = 32'hDDDD_0001;
        sq_req_strb    = 4'hF;
        sq_req_valid   = 1'b1;
        smp();                             // cycle 0: both clients request
        chk(lq_req_ready, "priority: LQ wins the same-cycle arbitration");
        chk(!sq_req_ready, "priority: the SQ must not be accepted in the same cycle");
        chk(!mmio_write && mmio_addr == 32'h8000_3000, "priority: the device sees the load");
        drv();                             // load outstanding, both requests held
        smp();                             // cycle 1
        chk(busy, "priority: load outstanding");
        chk(!mmio_req_valid && !lq_req_ready && !sq_req_ready,
            "priority: no second device request while busy");
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (lq_rsp_valid) break;
            chk(!lq_req_ready && !sq_req_ready, "priority: busy blocks both clients");
        end
        chk(lq_rsp_valid && !sq_req_ack, "priority: the load owns the response");
        drv();                             // load response consumed
        lq_req_valid = 1'b0;
        smp();                             // cycle: the SQ owns the idle channel
        chk(sq_req_ready && !lq_req_ready, "priority: the held SQ request is served next");
        chk(mmio_write && mmio_wdata == 32'hDDDD_0001 && mmio_wstrb == 4'hF,
            "priority: store payload presented");
        drv();                             // store accepted
        sq_req_valid = 1'b0;
        smp();                             // cycle 1 of the store
        chk(busy, "priority: store outstanding");
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (sq_req_ack) break;
        end
        chk(sq_req_ack && !lq_rsp_valid, "priority: store completes with a Write Ack");
        drv();
        smp();
        chk(!busy, "priority: channel idle again");
        drv();
        idle_clients();
    endtask

    task automatic phase_owner_routing();
        int unsigned cyc;
        $display("[tb_mmio_bridge] phase 5: the response follows the REGISTERED owner");
        // (a) load outstanding, the LQ withdraws and the SQ asks: the pending
        //     response must still go to the LQ.
        idle_clients();
        dev_lag        = 3;
        mmio_req_ready = 1'b1;
        lq_req_addr    = 32'h8000_5000;
        lq_req_valid   = 1'b1;
        smp();                             // cycle 0
        chk(lq_req_ready && !mmio_write, "owner(a): load accepted");
        drv();                             // load outstanding
        lq_req_valid = 1'b0;
        sq_req_addr  = 32'h8000_6000;
        sq_req_data  = 32'h0BAD_F00D;
        sq_req_strb  = 4'h3;
        sq_req_valid = 1'b1;
        smp();                             // cycle 1
        for (cyc = 0; cyc < 8; cyc++) begin
            chk(!lq_req_ready && !sq_req_ready, "owner(a): busy blocks the new SQ request");
            if (lq_rsp_valid) break;
            drv();
            smp();
        end
        chk(lq_rsp_valid && !sq_req_ack, "owner(a): response routed to the LQ, not the SQ");
        drv();                             // response consumed
        sq_req_valid = 1'b0;
        smp();
        chk(!busy, "owner(a): channel idle after the load response");
        drv();
        // (b) mirror image: store outstanding, the SQ withdraws and the LQ
        //     asks: the Write Ack must still go to the SQ.
        idle_clients();
        dev_lag        = 3;
        sq_req_addr    = 32'h8000_7000;
        sq_req_data    = 32'hFEED_1234;
        sq_req_strb    = 4'hC;
        sq_req_valid   = 1'b1;
        smp();                             // cycle 0
        chk(sq_req_ready && mmio_write, "owner(b): store accepted");
        drv();                             // store outstanding
        sq_req_valid = 1'b0;
        lq_req_addr  = 32'h8000_8000;
        lq_req_valid = 1'b1;
        smp();                             // cycle 1
        for (cyc = 0; cyc < 8; cyc++) begin
            chk(!lq_rsp_valid, "owner(b): no load response for a store transaction");
            if (sq_req_ack) break;
            drv();
            smp();
        end
        chk(sq_req_ack && !lq_rsp_valid, "owner(b): Write Ack routed to the SQ, not the LQ");
        drv();                             // ack consumed
        lq_req_valid = 1'b0;
        smp();
        chk(!busy, "owner(b): channel idle after the ack");
        drv();
        idle_clients();
    endtask

    task automatic phase_backpressure();
        int unsigned cyc;
        logic [31:0] a0, d0;
        logic [3:0]  s0;
        logic        w0;
        $display("[tb_mmio_bridge] phase 6: device backpressure, frozen request fields");
        idle_clients();
        dev_lag        = 1;
        mmio_req_ready = 1'b0;             // the device stalls the request
        lq_req_addr    = 32'h8000_9006;    // -> word address 0x8000_9004
        lq_req_valid   = 1'b1;
        sq_req_addr    = 32'h8000_A000;
        sq_req_data    = 32'h5A5A_5A5A;
        sq_req_strb    = 4'hF;
        sq_req_valid   = 1'b1;
        a0 = 32'd0;
        d0 = 32'd0;
        s0 = 4'h0;
        w0 = 1'b0;
        // The LQ (older) owns the stalled request: it must be presented, must
        // not be accepted, and its owner-selected fields must not move.
        for (cyc = 0; cyc < 5; cyc++) begin
            smp();
            chk(mmio_req_valid && !mmio_req_ready, "backpressure: request presented, not accepted");
            chk(!lq_req_ready && !sq_req_ready, "backpressure: client not accepted");
            chk(!busy, "backpressure: no transaction started");
            chk(!mmio_write && mmio_addr == 32'h8000_9004 && mmio_wstrb == 4'h0,
                "backpressure: the LQ (older) owns the stalled request");
            if (cyc == 0) begin
                a0 = mmio_addr;
                d0 = mmio_wdata;
                s0 = mmio_wstrb;
                w0 = mmio_write;
            end else begin
                chk(mmio_addr == a0 && mmio_wdata == d0 && mmio_wstrb == s0
                    && mmio_write == w0,
                    "backpressure: owner-selected request fields frozen");
            end
            drv();
        end
        // release the device: the held LQ request is taken with its frozen fields
        mmio_req_ready = 1'b1;
        smp();                             // cycle 5
        chk(lq_req_ready && !sq_req_ready, "backpressure: held LQ request accepted first");
        chk(mmio_addr == a0 && mmio_wstrb == s0 && mmio_write == w0,
            "backpressure: accepted with the frozen fields");
        drv();                             // load outstanding
        lq_req_valid   = 1'b0;
        mmio_req_ready = 1'b0;             // stall the device again
        smp();                             // cycle 6: the SQ request is still held
        chk(busy, "backpressure: load outstanding");
        chk(!lq_req_ready && !sq_req_ready, "backpressure: no accept while busy");
        for (cyc = 0; cyc < 8; cyc++) begin
            chk(!sq_req_ready, "backpressure: held SQ request blocked while busy");
            if (lq_rsp_valid) break;
            drv();
            smp();
        end
        chk(lq_rsp_valid && !sq_req_ack, "backpressure: load response after the stall");
        drv();                             // response consumed, busy cleared
        mmio_req_ready = 1'b1;             // device ready again
        smp();                             // the held SQ request is taken now
        chk(sq_req_ready && mmio_write && mmio_addr == 32'h8000_A000
            && mmio_wdata == 32'h5A5A_5A5A && mmio_wstrb == 4'hF,
            "backpressure: the held SQ request is taken next with its own fields");
        drv();                             // store accepted
        sq_req_valid = 1'b0;
        smp();
        chk(busy, "backpressure: store outstanding");
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (sq_req_ack) break;
        end
        chk(sq_req_ack, "backpressure: store completes with a Write Ack");
        drv();
        smp();
        chk(!busy, "backpressure: channel idle");
        drv();
        idle_clients();
    endtask

    task automatic phase_reset_busy();
        int unsigned cyc;
        $display("[tb_mmio_bridge] phase 7: reset in the middle of a transaction");
        idle_clients();
        dev_lag        = 4;                // the response is still pending
        mmio_req_ready = 1'b1;
        lq_req_addr    = 32'h8000_B000;
        lq_req_valid   = 1'b1;
        smp();                             // cycle 0
        chk(lq_req_ready, "reset-busy: load accepted");
        drv();                             // load outstanding
        lq_req_valid = 1'b0;
        smp();                             // cycle 1
        chk(busy, "reset-busy: transaction outstanding");
        rst = 1'b1;                        // sampled at the next rising edge
        drv();                             // cycle 2: the DUT is in reset
        smp();
        chk(!busy, "reset-busy: busy cleared by reset");
        chk(!lq_rsp_valid && !sq_req_ack, "reset-busy: no stale response delivered");
        chk(!mmio_req_valid && !lq_req_ready && !sq_req_ready, "reset-busy: channel silent");
        drv();                             // cycle 3: still in reset
        rst = 1'b0;
        drv();                             // cycle 4: reset released
        smp();
        chk(!busy && !mmio_req_valid && !lq_rsp_valid && !sq_req_ack,
            "reset-busy: stays idle after reset release");
        // recovery: a fresh uncached store completes normally
        drv();                             // cycle 5
        sq_req_addr  = 32'h8000_C000;
        sq_req_data  = 32'hA5A5_1111;
        sq_req_strb  = 4'hF;
        sq_req_valid = 1'b1;
        dev_lag      = 1;
        smp();
        chk(sq_req_ready && mmio_write, "reset-busy: channel usable after reset");
        drv();                             // store accepted
        sq_req_valid = 1'b0;
        smp();                             // cycle 6
        for (cyc = 0; cyc < 8; cyc++) begin
            drv();
            smp();
            if (sq_req_ack) break;
        end
        chk(sq_req_ack, "reset-busy: post-reset store completes with a Write Ack");
        drv();
        smp();
        chk(!busy, "reset-busy: channel idle again");
        drv();
        idle_clients();
    endtask

    //=========================================================================
    // Randomised phase
    //=========================================================================
    // Fixed-seed xorshift (same generator as the other LSU benches).
    int unsigned rng_state;

    function automatic int unsigned rnd();
        rng_state = rng_state ^ (rng_state << 13);
        rng_state = rng_state ^ (rng_state >> 17);
        rng_state = rng_state ^ (rng_state << 5);
        return rng_state;
    endfunction

    // Random client state: a request is only re-pointed while it is not held.
    logic        c_lq_v, c_sq_v;
    logic [31:0] c_lq_addr, c_sq_addr, c_sq_data;
    logic [3:0]  c_sq_strb;
    int unsigned c_lq_gap, c_sq_gap;   // idle cycles before the next request

    task automatic random_cycle();
        begin
            // The LQ has priority, so both clients use the same short random
            // idle gap to keep the load and the store stream active.
            if (!c_lq_v) begin
                if (c_lq_gap == 0) begin
                    c_lq_v    = 1'b1;
                    c_lq_addr = rnd();     // random low bits: the DUT must mask them
                end else begin
                    c_lq_gap = c_lq_gap - 1;
                end
            end
            if (!c_sq_v) begin
                if (c_sq_gap == 0) begin
                    c_sq_v    = 1'b1;
                    c_sq_addr = rnd();
                    c_sq_data = rnd();
                    c_sq_strb = 4'(rnd());
                end else begin
                    c_sq_gap = c_sq_gap - 1;
                end
            end
            // fields change only while the request is not asserted
            lq_req_valid   = c_lq_v;
            lq_req_addr    = c_lq_addr;
            sq_req_valid   = c_sq_v;
            sq_req_addr    = c_sq_addr;
            sq_req_data    = c_sq_data;
            sq_req_strb    = c_sq_strb;
            mmio_req_ready = ((rnd() % 100) < 70);
            if ((rnd() % 100) < 25) dev_lag = 1 + int'(rnd() % 4);
            smp();
            // The LQ wins every tie, so its client re-arms a little slower
            // than the SQ client: both streams stay active (roughly half of
            // the accepted transactions are stores).
            if (lq_req_ready) begin
                c_lq_v   = 1'b0;
                c_lq_gap = 4 + int'(rnd() % 3);
            end
            if (sq_req_ready) begin
                c_sq_v   = 1'b0;
                c_sq_gap = int'(rnd() % 2);
            end
            rand_cycles = rand_cycles + 1;
            drv();
        end
    endtask

    task automatic phase_random();
        $display("[tb_mmio_bridge] phase 8: %0d randomised cycles (seed %08h)",
                 RAND_CYCLES, RNG_SEED);
        idle_clients();
        c_lq_v = 1'b0;
        c_sq_v = 1'b0;
        mmio_req_ready = 1'b1;
        rng_state = RNG_SEED;
        for (int unsigned i = 0; i < RAND_CYCLES; i++) random_cycle();
        // drain: no new requests, let every outstanding transaction finish
        idle_clients();
        c_lq_v = 1'b0;
        c_sq_v = 1'b0;
        mmio_req_ready = 1'b1;
        for (int unsigned i = 0; i < 20; i++) begin
            smp();
            drv();
        end
        chk(!busy && !mmio_req_valid && !lq_rsp_valid && !sq_req_ack,
            "random: channel idle after the drain");
    endtask

    //=========================================================================
    // Main
    //=========================================================================
    initial begin
        checks       = 0;
        errors       = 0;
        cycle_cnt    = 0;
        rand_cycles  = 0;
        rng_state    = RNG_SEED;
        dev_lag      = 1;
        dev_prot_err = 0;
        mdl_prot_err = 0;
        n_load_acc = 0; n_store_acc = 0; n_load_rsp = 0; n_store_rsp = 0;
        n_abandoned = 0; n_abandoned_load = 0; n_abandoned_store = 0;
        n_same_cycle = 0; n_backpressure = 0; n_busy_block = 0;
        dev_acc_cnt = 0; dev_rsp_cnt = 0;
        cov_state = '0;
        cov_trans = '0;
        cov_prev  = ST_IDLE;
        c_lq_v = 1'b0; c_sq_v = 1'b0;
        c_lq_gap = 0; c_sq_gap = 0;
        c_lq_addr = 32'd0; c_sq_addr = 32'd0; c_sq_data = 32'd0; c_sq_strb = 4'h0;
        exp_q.delete();
        idle_clients();
        mmio_req_ready = 1'b1;

        phase_reset();
        phase_load_single();
        phase_store_single();
        phase_priority();
        phase_owner_routing();
        phase_backpressure();
        phase_reset_busy();
        phase_random();

        //---- final invariants ------------------------------------------------
        chk(exp_q.size() == 0, "final: no accepted transaction left unanswered");
        chk(dev_prot_err == 0, "final: device saw no second outstanding request");
        chk(mdl_prot_err == 0, "final: no model protocol violation");
        chk(dev_acc_cnt == dev_rsp_cnt + n_abandoned,
            "final: exactly one response per accepted transaction");
        chk(dev_acc_cnt == n_load_acc + n_store_acc, "final: accepted request accounting");
        chk(n_load_rsp + n_store_rsp + n_abandoned == dev_acc_cnt,
            "final: response accounting");
        chk(n_load_rsp + n_abandoned_load == n_load_acc,
            "final: every load got its response (or was abandoned by reset)");
        chk(n_store_rsp + n_abandoned_store == n_store_acc,
            "final: every store got its Write Ack (or was abandoned by reset)");

        //---- coverage --------------------------------------------------------
        $display("[tb_mmio_bridge] mmio_bridge coverage: states %0d/%0d, transitions %0d/%0d",
                 $countones(cov_state), N_STATES, $countones(cov_trans), N_TRANS);
        chk($countones(cov_state) == N_STATES, "coverage: all owner states visited");
        chk($countones(cov_trans) == N_TRANS, "coverage: all legal transitions visited");
        chk(rand_cycles >= 10000, "coverage: at least 10k randomised cycles");
        chk(n_load_acc > 800, "coverage: enough loads");
        chk(n_store_acc > 800, "coverage: enough stores");
        chk(n_same_cycle > 20, "coverage: same-cycle LQ/SQ contention");
        chk(n_backpressure > 100, "coverage: device request backpressure cycles");
        chk(n_busy_block > 100, "coverage: requests blocked while busy");
        chk(n_abandoned >= 1, "coverage: reset during an outstanding transaction");

        $display("-- loads=%0d/%0d stores=%0d/%0d same_cycle=%0d backpressure=%0d busy_block=%0d abandoned=%0d dev_acc=%0d dev_rsp=%0d checks=%0d --",
                 n_load_acc, n_load_rsp, n_store_acc, n_store_rsp, n_same_cycle,
                 n_backpressure, n_busy_block, n_abandoned, dev_acc_cnt, dev_rsp_cnt, checks);
        if (errors != 0)
            $fatal(1, "TB FAILED: %0d errors in %0d checks", errors, checks);
        $display("ALL TESTS PASSED: %0d checks - reset/idle, single load (address forced to the containing word, no byte enables), single store + Write Ack, same-cycle LQ priority with the held SQ served next, response routing by registered owner (both directions), busy blocks new requests, device backpressure with frozen owner-selected fields, reset mid-transaction, %0d-cycle fixed-seed random vs owner model, mmio_bridge coverage: states 3/3, transitions 7/7",
                 checks, rand_cycles);
        $finish;
    end

endmodule





