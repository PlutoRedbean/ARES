//=============================================================================
// ARES - shared L2 cache (bring-up)
//-----------------------------------------------------------------------------
// Functional shared L2 for two 128-bit-beat masters:
//   * 64 B lines, 16 B beats, 4 beats/line
//   * 4-way set-associative, round-robin replacement
//   * write-back + write-allocate
//   * two core ports, one 128-bit memory port
//   * one L2 transaction at a time (bring-up version; no per-port MSHR)
//
// Core-side protocol is the existing LSU memory beat protocol:
//   read : req_valid/ready + addr -> rsp_valid/ready + data
//   write: req_valid/ready + addr/data/be (no write response)
//
// Memory-side protocol is the same beat protocol.  A line refill issues four
// 16 B reads; a dirty-victim writeback issues four 16 B writes.
//
// Storage: the data array is a single synchronous 1R1W memory
// (registered read address -> data one cycle later, one write port).  This is
// the pattern Pango ADS maps to a GTP_DRM36K block RAM; the previous
// asynchronous-read version was built from ~72k distributed RAM LUTs (182% of
// the device's LUTRAM) and could not fit.  Cost: a hit takes one extra cycle
// (S_LOOKUP -> S_DATA) and a writeback beat one extra cycle (S_WB_RD -> S_WB).
// The beat protocol has no fixed latency, so this is invisible to the masters.
//
// Tag/valid/dirty/replacement state is small and stays in distributed RAM,
// where the tags are available combinationally in the S_LOOKUP cycle.
//
// This is intentionally a small, verifiable first L2.  The final target
// (128 KiB, 8 banks, 2 core ports + video, per-port MSHRs, QoS) is a later
// PPA/performance step; this module establishes the shared-memory hierarchy.
//=============================================================================
module l2_top #(
    parameter int unsigned SETS = 128,   // 128*4*64B = 32 KiB
    parameter int unsigned WAYS = 4
) (
    input  logic         clk,
    input  logic         rst,

    //---- core port 0 -------------------------------------------------------
    input  logic         c0_rd_valid,
    output logic         c0_rd_ready,
    input  logic [ 31:0] c0_rd_addr,
    output logic         c0_rsp_valid,
    input  logic         c0_rsp_ready,
    output logic [127:0] c0_rsp_data,
    input  logic         c0_wr_valid,
    output logic         c0_wr_ready,
    input  logic [ 31:0] c0_wr_addr,
    input  logic [127:0] c0_wr_data,
    input  logic [ 15:0] c0_wr_be,

    //---- core port 1 -------------------------------------------------------
    input  logic         c1_rd_valid,
    output logic         c1_rd_ready,
    input  logic [ 31:0] c1_rd_addr,
    output logic         c1_rsp_valid,
    input  logic         c1_rsp_ready,
    output logic [127:0] c1_rsp_data,
    input  logic         c1_wr_valid,
    output logic         c1_wr_ready,
    input  logic [ 31:0] c1_wr_addr,
    input  logic [127:0] c1_wr_data,
    input  logic [ 15:0] c1_wr_be,

    //---- instruction read port (128-bit beat, read-only) -------------------
    input  logic         i_rd_valid,
    output logic         i_rd_ready,
    input  logic [ 31:0] i_rd_addr,
    output logic         i_rsp_valid,
    input  logic         i_rsp_ready,
    output logic [127:0] i_rsp_data,

    //---- second instruction read port (2-core AMP) --------------------------
    input  logic         i1_rd_valid,
    output logic         i1_rd_ready,
    input  logic [ 31:0] i1_rd_addr,
    output logic         i1_rsp_valid,
    input  logic         i1_rsp_ready,
    output logic [127:0] i1_rsp_data,

    //---- memory port (128-bit beat) ----------------------------------------
    output logic         mem_rd_valid,
    input  logic         mem_rd_ready,
    output logic [ 31:0] mem_rd_addr,
    input  logic         mem_rsp_valid,
    output logic         mem_rsp_ready,
    input  logic [127:0] mem_rsp_data,
    output logic         mem_wr_valid,
    input  logic         mem_wr_ready,
    output logic [ 31:0] mem_wr_addr,
    output logic [127:0] mem_wr_data,
    output logic [ 15:0] mem_wr_be,

    //---- observation -------------------------------------------------------
    output logic         l2_idle,
    output logic [ 31:0] hit_count,
    output logic [ 31:0] miss_count
);
    import l2_pkg::*;

    localparam int unsigned IDX_W = $clog2(SETS);
    localparam int unsigned WAY_W = $clog2(WAYS);
    localparam int unsigned TAG_W = 32 - OFFSET_W - IDX_W;
    localparam int unsigned DM_AW = IDX_W + WAY_W + BEAT_W;

    typedef enum logic [3:0] {
        S_IDLE,
        S_LOOKUP,
        S_DATA,
        S_WB_RD,
        S_WB,
        S_RF_REQ,
        S_RF_RSP,
        S_RESP
    } state_t;

    state_t state_q;

    // Cache arrays.  Data is a synchronous 1R1W memory (BRAM); the small tag /
    // state arrays are not reset except for valid/dirty.
    logic [TAG_W-1:0]       tag_mem   [SETS][WAYS];
    logic                   valid_mem [SETS][WAYS];
    logic                   dirty_mem [SETS][WAYS];
    logic [127:0]           data_mem  [0:SETS*WAYS*BEATS-1];
    logic [WAY_W-1:0]       rr_mem    [SETS];

    logic [127:0]           dm_rdata;
    logic                   dm_we;
    logic [DM_AW-1:0]       dm_waddr;
    logic [127:0]           dm_wdata;
    wire  [WAY_W-1:0]       dm_read_way;
    wire  [BEAT_W-1:0]      dm_read_beat;
    wire  [DM_AW-1:0]       dm_raddr;

    // The read address is combinational (sampled by the memory's own input
    // register at the clock edge) and the write port is registered: the ADS
    // block-RAM template.  Data is valid in the cycle after S_LOOKUP/S_WB_RD.
    assign dm_read_way   = (state_q == S_WB_RD) ? victim_way : hit_way;
    assign dm_read_beat  = (state_q == S_WB_RD) ? wb_beat    : req_beat;
    assign dm_raddr      = {req_set, dm_read_way, dm_read_beat};

    always_ff @(posedge clk) begin
        if (dm_we) data_mem[dm_waddr] <= dm_wdata;
        dm_rdata <= data_mem[dm_raddr];
    end

    // Latched request.
    logic                   req_write;
    logic [2:0]             req_port;
    /* verilator lint_off UNUSEDSIGNAL */  // lower 4 bits are zero for 16 B beats
    logic [31:0]            req_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [127:0]           req_wdata;
    logic [15:0]            req_be;

    wire [IDX_W-1:0]        req_set  = req_addr[OFFSET_W +: IDX_W];
    wire [TAG_W-1:0]        req_tag  = req_addr[31 -: TAG_W];
    wire [BEAT_W-1:0]       req_beat = req_addr[4 +: BEAT_W];

    // Lookup.
    logic                   hit;
    logic [WAY_W-1:0]       hit_way;
    always_comb begin
        hit     = 1'b0;
        hit_way = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (!hit && valid_mem[req_set][w] && (tag_mem[req_set][w] == req_tag)) begin
                hit     = 1'b1;
                hit_way = WAY_W'(w);
            end
        end
    end

    // Port arbitration: I0/I1 fetch first (alternating when both request),
    // then core0/core1 D.  Both I ports are read-only 128-bit beats feeding
    // the two ICache AXI bridges.
    logic                   req_any;
    logic [2:0]             sel_port;
    logic                   sel_write;
    logic                   i_pref;
    always_comb begin
        req_any   = 1'b0;
        sel_port  = 3'd0;
        sel_write = 1'b0;
        if (i_rd_valid && i1_rd_valid) begin
            req_any  = 1'b1;
            sel_port = i_pref ? 3'd3 : 3'd2;
        end else if (i_rd_valid) begin
            req_any  = 1'b1;
            sel_port = 3'd2;
        end else if (i1_rd_valid) begin
            req_any  = 1'b1;
            sel_port = 3'd3;
        end else if (c0_rd_valid) begin
            req_any  = 1'b1;
            sel_port = 3'd0;
        end else if (c0_wr_valid) begin
            req_any   = 1'b1;
            sel_port  = 3'd0;
            sel_write = 1'b1;
        end else if (c1_rd_valid) begin
            req_any  = 1'b1;
            sel_port = 3'd1;
        end else if (c1_wr_valid) begin
            req_any   = 1'b1;
            sel_port  = 3'd1;
            sel_write = 1'b1;
        end
    end

    assign c0_rd_ready = (state_q == S_IDLE) && req_any && (sel_port == 3'd0) && !sel_write;
    assign c0_wr_ready = (state_q == S_IDLE) && req_any && (sel_port == 3'd0) &&  sel_write;
    assign c1_rd_ready = (state_q == S_IDLE) && req_any && (sel_port == 3'd1) && !sel_write;
    assign c1_wr_ready = (state_q == S_IDLE) && req_any && (sel_port == 3'd1) &&  sel_write;
    assign i_rd_ready  = (state_q == S_IDLE) && req_any && (sel_port == 3'd2);
    assign i1_rd_ready = (state_q == S_IDLE) && req_any && (sel_port == 3'd3);

    // Response / memory-port wiring.
    logic        rsp_valid_q;
    logic [127:0] rsp_data_q;
    logic [WAY_W-1:0] victim_way;
    logic [BEAT_W-1:0] wb_beat;
    logic [BEAT_W-1:0] rf_beat;

    assign c0_rsp_valid = rsp_valid_q && (req_port == 3'd0);
    assign c1_rsp_valid = rsp_valid_q && (req_port == 3'd1);
    assign i_rsp_valid  = rsp_valid_q && (req_port == 3'd2);
    assign i1_rsp_valid = rsp_valid_q && (req_port == 3'd3);
    assign c0_rsp_data  = rsp_data_q;
    assign c1_rsp_data  = rsp_data_q;
    assign i_rsp_data   = rsp_data_q;
    assign i1_rsp_data  = rsp_data_q;
    wire selected_rsp_ready =
        (req_port == 3'd3) ? i1_rsp_ready :
        (req_port == 3'd2) ? i_rsp_ready :
        (req_port == 3'd1) ? c1_rsp_ready : c0_rsp_ready;

    wire [25:0] line_base_hi = req_addr[31:OFFSET_W];
    wire [31:0] mem_rf_addr  = {line_base_hi, rf_beat, 4'b0000};
    // The victim may have a different tag from the request that caused the
    // eviction, so rebuild the writeback address from the victim's tag.
    wire [TAG_W-1:0] victim_tag = tag_mem[req_set][victim_way];
    wire [31:0] mem_wb_addr = {victim_tag, req_set, wb_beat, 4'b0000};

    assign mem_rd_valid = (state_q == S_RF_REQ);
    assign mem_rd_addr  = mem_rf_addr;
    assign mem_rsp_ready = (state_q == S_RF_RSP);
    assign mem_wr_valid = (state_q == S_WB);
    assign mem_wr_addr  = mem_wb_addr;
    // dm_rdata holds the beat addressed by the read issued in S_WB_RD.
    assign mem_wr_data  = dm_rdata;
    assign mem_wr_be    = 16'hFFFF;
    assign l2_idle      = (state_q == S_IDLE);

    function automatic logic [127:0] merge_be(input logic [127:0] old,
                                              input logic [127:0] new_data,
                                              input logic [15:0]  be);
        logic [127:0] v;
        begin
            v = old;
            for (int i = 0; i < 16; i++)
                if (be[i]) v[8*i +: 8] = new_data[8*i +: 8];
            merge_be = v;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q     <= S_IDLE;
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 128'h0;
            i_pref      <= 1'b0;
            hit_count   <= 32'h0;
            miss_count  <= 32'h0;
            victim_way  <= '0;
            wb_beat     <= '0;
            rf_beat     <= '0;
            dm_we       <= 1'b0;
            dm_waddr    <= '0;
            dm_wdata    <= 128'h0;
            for (int s = 0; s < SETS; s++) begin
                rr_mem[s] <= '0;
                for (int w = 0; w < WAYS; w++) begin
                    valid_mem[s][w] <= 1'b0;
                    dirty_mem[s][w] <= 1'b0;
                end
            end
        end else begin
            dm_we <= 1'b0;                 // one-cycle write pulse by default
            case (state_q)
                S_IDLE: begin
                    if (req_any) begin
                        req_write <= sel_write;
                        req_port  <= sel_port;
                        if (sel_port == 3'd3) begin
                            req_addr  <= i1_rd_addr;
                            req_wdata <= 128'h0;
                            req_be    <= 16'h0;
                        end else if (sel_port == 3'd2) begin
                            req_addr  <= i_rd_addr;
                            req_wdata <= 128'h0;
                            req_be    <= 16'h0;
                        end else if (sel_port == 3'd1) begin
                            req_addr  <= sel_write ? c1_wr_addr : c1_rd_addr;
                            req_wdata <= c1_wr_data;
                            req_be    <= c1_wr_be;
                        end else begin
                            req_addr  <= sel_write ? c0_wr_addr : c0_rd_addr;
                            req_wdata <= c0_wr_data;
                            req_be    <= c0_wr_be;
                        end
                        if (sel_port >= 3'd2) i_pref <= ~i_pref;
                        state_q <= S_LOOKUP;
                    end
                end

                // Tags are distributed RAM and readable in this cycle.  Issue
                // the data read for the hit way; the data arrives in S_DATA.
                S_LOOKUP: begin
                    if (hit) begin
                        state_q  <= S_DATA;
                    end else begin
                        miss_count <= miss_count + 32'd1;
                        victim_way <= rr_mem[req_set];
                        wb_beat    <= '0;
                        rf_beat    <= '0;
                        if (dirty_mem[req_set][rr_mem[req_set]])
                            state_q <= S_WB_RD;
                        else
                            state_q <= S_RF_REQ;
                    end
                end

                // dm_rdata is valid now (read issued in S_LOOKUP).
                S_DATA: begin
                    hit_count <= hit_count + 32'd1;
                    if (req_write) begin
                        dm_we    <= 1'b1;
                        dm_waddr <= {req_set, hit_way, req_beat};
                        dm_wdata <= merge_be(dm_rdata, req_wdata, req_be);
                        dirty_mem[req_set][hit_way] <= 1'b1;
                        state_q  <= S_IDLE;
                    end else begin
                        rsp_data_q  <= dm_rdata;
                        rsp_valid_q <= 1'b1;
                        state_q     <= S_RESP;
                    end
                end

                // Fetch one dirty beat from the array before driving the
                // memory write port (BRAM read latency).
                S_WB_RD: begin
                    state_q  <= S_WB;
                end

                S_WB: begin
                    if (mem_wr_valid && mem_wr_ready) begin
                        if (wb_beat == BEAT_W'(BEATS-1)) begin
                            rf_beat <= '0;
                            state_q <= S_RF_REQ;
                        end else begin
                            wb_beat <= wb_beat + 1'b1;
                            state_q <= S_WB_RD;
                        end
                    end
                end

                S_RF_REQ: begin
                    if (mem_rd_valid && mem_rd_ready) state_q <= S_RF_RSP;
                end

                S_RF_RSP: begin
                    if (mem_rsp_valid) begin
                        if (!req_write && (rf_beat == req_beat))
                            rsp_data_q <= mem_rsp_data;

                        dm_we    <= 1'b1;
                        dm_waddr <= {req_set, victim_way, rf_beat};
                        if (req_write && (rf_beat == req_beat))
                            dm_wdata <= merge_be(mem_rsp_data, req_wdata, req_be);
                        else
                            dm_wdata <= mem_rsp_data;

                        if (rf_beat == BEAT_W'(BEATS-1)) begin
                            tag_mem[req_set][victim_way]   <= req_tag;
                            valid_mem[req_set][victim_way] <= 1'b1;
                            dirty_mem[req_set][victim_way] <= req_write;
                            rr_mem[req_set] <= rr_mem[req_set] + 1'b1;
                            if (req_write) begin
                                state_q <= S_IDLE;
                            end else begin
                                rsp_valid_q <= 1'b1;
                                state_q     <= S_RESP;
                            end
                        end else begin
                            rf_beat <= rf_beat + 1'b1;
                            state_q <= S_RF_REQ;
                        end
                    end
                end

                S_RESP: begin
                    if (rsp_valid_q && selected_rsp_ready) begin
                        rsp_valid_q <= 1'b0;
                        state_q     <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
