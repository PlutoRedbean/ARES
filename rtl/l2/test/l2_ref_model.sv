//=============================================================================
// ARES - shared L2 reference model and checker
//-----------------------------------------------------------------------------
// Owns the backing memory, keeps an independent golden image of the shared
// address window and verifies every externally visible L2 behaviour that does
// not depend on the replacement policy (decision D-A3 in
// docs/m1_closure_decisions.md):
//
//   * an accepted read gets exactly one response on the owning port, and the
//     data equals the golden beat sampled at acceptance;
//   * an accepted store updates the golden image with its byte enables;
//   * a dirty writeback reproduces the golden line, and only a matching
//     writeback updates the backing memory (a wrong one never does);
//   * a victim writeback belongs to the same set as the refill that follows;
//   * every upper and lower address stays inside one window: an address
//     outside it is fatal instead of a silent wrap through addr[23:4].
//
// Which way is replaced is deliberately NOT modelled.  Any victim is accepted
// as long as its data is correct and its set matches, so the checker does not
// become a copy of the current 4-way round-robin implementation.
//=============================================================================
module l2_ref_model #(
    parameter int unsigned SETS   = 16,
    parameter logic [31:0] BASE   = 32'h8000_0000,
    parameter int unsigned BYTES  = 1 << 20,
    parameter int unsigned MEM_LAT  = 2,  // extra cycles before a refill response
    parameter int unsigned RD_STALL = 2,  // mem_rd_ready low RD_STALL of RD_STALL+1
    parameter int unsigned WR_STALL = 1   // mem_wr_ready low WR_STALL of WR_STALL+1
) (
    input  logic         clk,
    input  logic         rst,

    // Upper ports, observe only: 0=c0, 1=c1, 2=i0, 3=i1.
    input  logic [3:0]   rd_valid,
    input  logic [3:0]   rd_ready,
    input  logic [31:0]  rd_addr    [4],
    input  logic [3:0]   rsp_valid,
    input  logic [3:0]   rsp_ready,
    input  logic [127:0] rsp_data   [4],

    // Writes, observe only: 0=c0, 1=c1.
    input  logic [1:0]   wr_valid,
    input  logic [1:0]   wr_ready,
    input  logic [31:0]  wr_addr    [2],
    input  logic [127:0] wr_data    [2],
    input  logic [15:0]  wr_be      [2],

    // Backing memory slave (driven by this model).
    input  logic         mem_rd_valid,
    output logic         mem_rd_ready,
    input  logic [31:0]  mem_rd_addr,
    output logic         mem_rsp_valid,
    input  logic         mem_rsp_ready,
    output logic [127:0] mem_rsp_data,
    input  logic         mem_wr_valid,
    output logic         mem_wr_ready,
    input  logic [31:0]  mem_wr_addr,
    input  logic [127:0] mem_wr_data,
    input  logic [15:0]  mem_wr_be,

    output int unsigned  err_data,
    output int unsigned  err_owner,
    output int unsigned  err_wb,
    output int unsigned  rsp_count,
    output int unsigned  wb_count,
    output int unsigned  accepted,
    output int unsigned  outstanding
);
    localparam int unsigned OFF_W  = 6;   // 64 B line
    localparam int unsigned IDX_W  = $clog2(SETS);

    logic [7:0] gold    [0:BYTES-1];   // architectural content of the window
    logic [7:0] backing [0:BYTES-1];   // physical memory behind the L2

    // Deterministic per-byte pattern so every test address has its own content.
    /* verilator lint_off UNUSEDSIGNAL */  // only bits [11:0] shape the pattern
    function automatic logic [7:0] pat_byte(input logic [31:0] addr);
        pat_byte = (addr[7:0] + 8'h5A) ^ {addr[11:8], 4'h0};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic bit in_window(input logic [31:0] addr);
        in_window = (addr >= BASE) && ((addr - BASE) < 32'(BYTES));
    endfunction

    function automatic logic [127:0] gold_beat(input logic [31:0] addr);
        int unsigned o;
        o = int'(addr - BASE) & ~32'hF;
        for (int b = 0; b < 16; b++)
            gold_beat[8*b +: 8] = gold[o + b];
    endfunction

    function automatic logic [127:0] backing_beat(input logic [31:0] addr);
        int unsigned o;
        o = int'(addr - BASE) & ~32'hF;
        for (int b = 0; b < 16; b++)
            backing_beat[8*b +: 8] = backing[o + b];
    endfunction

    task automatic apply_store(input logic [31:0] addr, input logic [127:0] data,
                               input logic [15:0] be);
        int unsigned o;
        o = int'(addr - BASE) & ~32'hF;
        for (int b = 0; b < 16; b++)
            if (be[b]) gold[o + b] = data[8*b +: 8];
    endtask

    task automatic guard(input string what, input logic [31:0] addr);
        if (!in_window(addr)) begin
            $display("*** L2 REF: %s address 0x%08x outside [0x%08x, +0x%0d) ***",
                     what, addr, BASE, BYTES);
            $fatal(1, "L2 reference model: out-of-window access");
        end
    endtask

    //---------------------------------------------------------------------
    // Register initialisation.  Both images start identical, so any later
    // difference is caused by an L2 writeback.
    //---------------------------------------------------------------------
    initial begin
        err_data = 0; err_owner = 0; err_wb = 0;
        rsp_count = 0; wb_count = 0; accepted = 0;
        for (int i = 0; i < BYTES; i++) begin
            gold[i]    = pat_byte(BASE + 32'(i));
            backing[i] = pat_byte(BASE + 32'(i));
        end
    end

    //---------------------------------------------------------------------
    // Backing-memory slave: deterministic stalls and read latency.
    //---------------------------------------------------------------------
    int unsigned stall_tick;
    int unsigned lat_cnt;
    logic        rd_pend_v;
    logic [31:0] rd_pend_addr;
    logic        rsp_v;
    logic [31:0] rsp_addr;

    assign mem_rd_ready  = (RD_STALL == 0) || ((stall_tick % (RD_STALL + 1)) != 0);
    assign mem_wr_ready  = (WR_STALL == 0) || ((stall_tick % (WR_STALL + 1)) != 1);
    assign mem_rsp_valid = rsp_v;
    assign mem_rsp_data  = backing_beat(rsp_addr);

    //---------------------------------------------------------------------
    // Upper-port and lower-port checking.
    //---------------------------------------------------------------------
    logic [3:0]       pend_v;
    logic [127:0]     pend_data [4];
    logic             wb_set_v;
    logic [IDX_W-1:0] wb_set;

    wire [3:0] rd_acc  = rd_valid  & rd_ready;
    wire [3:0] rsp_acc = rsp_valid & rsp_ready;
    wire [1:0] wr_acc  = wr_valid  & wr_ready;

    always @(posedge clk) begin
        if (rst) begin
            pend_v     <= 4'h0;
            wb_set_v   <= 1'b0;
            wb_set     <= '0;
            stall_tick <= 0;
            lat_cnt    <= 0;
            rd_pend_v  <= 1'b0;
            rsp_v      <= 1'b0;
            rsp_addr   <= 32'h0;
        end else begin
            stall_tick <= stall_tick + 1;

            //--- upper ports -------------------------------------------------
            for (int p = 0; p < 4; p++) begin
                if (rd_acc[p]) begin
                    guard("read", rd_addr[p]);
                    accepted <= accepted + 1;
                    if (pend_v[p]) begin
                        err_owner <= err_owner + 1;
                        $display("*** L2 REF: port %0d accepted a read while one is outstanding ***", p);
                    end
                    pend_data[p] <= gold_beat(rd_addr[p]);
                    pend_v[p]    <= 1'b1;
                end
                if (rsp_acc[p]) begin
                    rsp_count <= rsp_count + 1;
                    if (!pend_v[p]) begin
                        err_owner <= err_owner + 1;
                        $display("*** L2 REF: port %0d response without a request ***", p);
                    end else if (rsp_data[p] !== pend_data[p]) begin
                        err_data <= err_data + 1;
                        if (err_data < 4)
                            $display("*** L2 REF: port %0d data 0x%032x != golden 0x%032x ***",
                                     p, rsp_data[p], pend_data[p]);
                    end
                    pend_v[p] <= 1'b0;
                end
            end

            //--- writes ------------------------------------------------------
            for (int p = 0; p < 2; p++) begin
                if (wr_acc[p]) begin
                    guard("write", wr_addr[p]);
                    accepted <= accepted + 1;
                    apply_store(wr_addr[p], wr_data[p], wr_be[p]);
                end
            end

            //--- backing read path ------------------------------------------
            if (mem_rd_valid && mem_rd_ready) begin
                guard("refill", mem_rd_addr);
                if (mem_rd_addr[3:0] != 4'h0) begin
                    err_wb <= err_wb + 1;
                    $display("*** L2 REF: misaligned refill 0x%08x ***", mem_rd_addr);
                end
                // A refill that follows a victim writeback must be in the same set.
                if (wb_set_v && (mem_rd_addr[OFF_W +: IDX_W] != wb_set)) begin
                    err_wb <= err_wb + 1;
                    $display("*** L2 REF: refill 0x%08x set %0d != victim set %0d ***",
                             mem_rd_addr, mem_rd_addr[OFF_W +: IDX_W], wb_set);
                end
                wb_set_v  <= 1'b0;
                rd_pend_v <= 1'b1;
                rd_pend_addr <= mem_rd_addr;
                lat_cnt   <= MEM_LAT;
            end

            if (rd_pend_v) begin
                if (lat_cnt == 0) begin
                    rsp_v     <= 1'b1;
                    rsp_addr  <= rd_pend_addr;
                    rd_pend_v <= 1'b0;
                end else begin
                    lat_cnt <= lat_cnt - 1;
                end
            end
            if (rsp_v && mem_rsp_ready) rsp_v <= 1'b0;

            //--- writeback path ---------------------------------------------
            if (mem_wr_valid && mem_wr_ready) begin
                guard("writeback", mem_wr_addr);
                wb_count <= wb_count + 1;
                if (mem_wr_addr[3:0] != 4'h0 || mem_wr_be !== 16'hFFFF) begin
                    err_wb <= err_wb + 1;
                    $display("*** L2 REF: malformed writeback addr=0x%08x be=0x%04x ***",
                             mem_wr_addr, mem_wr_be);
                end
                if (gold_beat(mem_wr_addr) !== mem_wr_data) begin
                    // The reference is never updated by a wrong writeback, so
                    // the corruption cannot be hidden by later traffic.
                    err_wb <= err_wb + 1;
                    if (err_wb < 6)
                        $display("*** L2 REF: writeback 0x%08x data 0x%032x != golden 0x%032x ***",
                                 mem_wr_addr, mem_wr_data, gold_beat(mem_wr_addr));
                end else begin
                    for (int b = 0; b < 16; b++)
                        backing[int'(mem_wr_addr - BASE) + b] = mem_wr_data[8*b +: 8];
                end
                wb_set_v <= 1'b1;
                wb_set   <= mem_wr_addr[OFF_W +: IDX_W];
            end
        end
    end

    always_comb begin
        outstanding = 32'(pend_v[0]) + 32'(pend_v[1]) +
                      32'(pend_v[2]) + 32'(pend_v[3]);
    end
endmodule
