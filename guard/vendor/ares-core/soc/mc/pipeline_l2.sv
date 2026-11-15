//=============================================================================
// ARES pipeline SoC - coherent shared L2 for 2/4 harts
//-----------------------------------------------------------------------------
// Geometry: 64 B lines, 16 B beats, 4-way set-associative, write-back +
// write-allocate, one 128-bit downstream memory port.
//
// Coherence model
// ---------------
// The pipeline core has a write-through, direct-mapped L1 D-cache.  This L2
// therefore only needs write-invalidate: every accepted store atomically
// updates the shared line and pulses a one-cycle invalidate to every other
// hart.  The invalidate carries the stored word address; the L1 clears the
// matching tag index.  A monotonically increasing epoch is exported with the L2.
// The L1 captures the epoch when a miss leaves the core and refuses to install
// a refill if the epoch changed while that refill was in flight.  This closes
// the "read old line, remote write, then install old line" race without a
// per-line directory or a second tag-RAM port.
//
// Timing
// ------
// The request is latched in S_IDLE; tag compare happens in S_LOOKUP and is
// registered before the response/refill state machines use it.  Arbitration
// is a small round-robin over the hart valid bits, not a combinational path
// through the data arrays.  The invalidate pulse is registered, so the
// coherence sideband is a flop-to-flop path.
//
// This module is intentionally a bring-up cache: one L2 transaction at a
// time.  The important M4 property is correctness of the shared/coherent
// path; per-port MSHRs and banking are a later PPA step.
//=============================================================================
module pipeline_l2 #(
    parameter integer CORES = 2,
    parameter integer SETS  = 128,
    parameter integer WAYS  = 4
) (
    input  wire                     clk,
    input  wire                     rst,

    //---- per-hart load/store ports (32-bit address, 16 B beat) -------------
    input  wire [CORES-1:0]         c_rd_valid,
    output wire [CORES-1:0]         c_rd_ready,
    input  wire [CORES-1:0][31:0]   c_rd_addr,
    output wire [CORES-1:0]         c_rsp_valid,
    input  wire [CORES-1:0]         c_rsp_ready,
    output wire [CORES-1:0][127:0]  c_rsp_data,

    input  wire [CORES-1:0]         c_wr_valid,
    output wire [CORES-1:0]         c_wr_ready,
    input  wire [CORES-1:0][31:0]   c_wr_addr,
    input  wire [CORES-1:0][127:0]  c_wr_data,
    input  wire [CORES-1:0][15:0]   c_wr_be,

    //---- coherence sideband ------------------------------------------------
    output wire [CORES-1:0]         coh_inv_valid,
    output wire [31:0]              coh_inv_addr,
    output wire [7:0]               coh_epoch,

    //---- downstream 128-bit memory port ------------------------------------
    output wire                     mem_rd_valid,
    input  wire                     mem_rd_ready,
    output wire [31:0]              mem_rd_addr,
    input  wire                     mem_rsp_valid,
    output wire                     mem_rsp_ready,
    input  wire [127:0]             mem_rsp_data,
    output wire                     mem_wr_valid,
    input  wire                     mem_wr_ready,
    output wire [31:0]              mem_wr_addr,
    output wire [127:0]             mem_wr_data,
    output wire [15:0]              mem_wr_be,

    //---- observation -------------------------------------------------------
    output wire                     l2_idle,
    output reg  [31:0]              hit_count,
    output reg  [31:0]              miss_count
);
    localparam integer OFFSET_W = 6;                 // 64 B line
    localparam integer BEAT_W   = 2;                 // four 16 B beats
    localparam integer BEATS    = 4;
    localparam integer IDX_W    = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer WAY_W    = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer TAG_W    = 32 - OFFSET_W - IDX_W;
    localparam integer CORE_W   = (CORES > 1) ? $clog2(CORES) : 1;
    localparam integer CORE_MSK = CORES - 1;

    // CORES is restricted to the two supported build options (2 or 4).
    // Keeping the round-robin index a power-of-two wrap avoids a modulo in
    // the arbiter.  The build targets and pipeline_mc_soc_top enforce it.

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOOKUP,
        S_WB,
        S_RF_REQ,
        S_RF_RSP,
        S_RESP
    } state_t;

    state_t state_q;

    // Cache arrays.  Data/tag are not reset (BRAM-friendly); valid/dirty are.
    logic [TAG_W-1:0] tag_mem   [SETS][WAYS];
    logic             valid_mem [SETS][WAYS];
    logic             dirty_mem [SETS][WAYS];
    logic [127:0]     data_mem  [SETS][WAYS][BEATS];
    logic [WAY_W-1:0] rr_mem    [SETS];

    // Latched request.
    logic             req_write;
    logic [CORE_W-1:0] req_core;
    logic [31:0]      req_addr;
    logic [127:0]     req_wdata;
    logic [15:0]      req_be;

    wire [IDX_W-1:0]  req_set  = req_addr[OFFSET_W +: IDX_W];
    wire [TAG_W-1:0]  req_tag  = req_addr[31 -: TAG_W];
    wire [BEAT_W-1:0] req_beat = req_addr[4 +: BEAT_W];

    // ---- arbitration ------------------------------------------------------
    logic [CORE_W-1:0] rr_ptr;
    logic [CORE_W-1:0] sel_core;
    logic              sel_write;
    logic              req_any;
    integer            a;

    always @(*) begin
        req_any   = 1'b0;
        sel_core  = {CORE_W{1'b0}};
        sel_write = 1'b0;
        for (a = 0; a < CORES; a = a + 1) begin
            if (!req_any) begin
                if (c_rd_valid[CORE_W'((rr_ptr + a) & CORE_MSK)]) begin
                    req_any   = 1'b1;
                    sel_core  = CORE_W'((rr_ptr + a) & CORE_MSK);
                    sel_write = 1'b0;
                end else if (c_wr_valid[CORE_W'((rr_ptr + a) & CORE_MSK)]) begin
                    req_any   = 1'b1;
                    sel_core  = CORE_W'((rr_ptr + a) & CORE_MSK);
                    sel_write = 1'b1;
                end
            end
        end
    end

    function automatic [CORES-1:0] onehot(input [CORE_W-1:0] idx);
        integer j;
        begin
            onehot = {CORES{1'b0}};
            for (j = 0; j < CORES; j = j + 1) begin
                if (idx == j[CORE_W-1:0]) onehot[j] = 1'b1;
            end
        end
    endfunction

    assign c_rd_ready = ((state_q == S_IDLE) && req_any && !sel_write)
                        ? onehot(sel_core) : {CORES{1'b0}};
    assign c_wr_ready = ((state_q == S_IDLE) && req_any &&  sel_write)
                        ? onehot(sel_core) : {CORES{1'b0}};

    // ---- tag lookup -------------------------------------------------------
    logic             hit;
    logic [WAY_W-1:0] hit_way;
    integer           w;

    always @(*) begin
        hit     = 1'b0;
        hit_way = {WAY_W{1'b0}};
        for (w = 0; w < WAYS; w = w + 1) begin
            if (!hit && valid_mem[req_set][w] && (tag_mem[req_set][w] == req_tag)) begin
                hit     = 1'b1;
                hit_way = w[WAY_W-1:0];
            end
        end
    end

    // ---- response / memory port wiring -----------------------------------
    logic             rsp_valid_q;
    logic [127:0]     rsp_data_q;
    logic [WAY_W-1:0] victim_way;
    logic [BEAT_W-1:0] wb_beat;
    logic [BEAT_W-1:0] rf_beat;

    assign c_rsp_valid = rsp_valid_q ? onehot(req_core) : {CORES{1'b0}};
    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_rsp_data
            assign c_rsp_data[g] = rsp_data_q;
        end
    endgenerate

    wire selected_rsp_ready = c_rsp_ready[req_core];

    wire [31:0] mem_rf_addr  = {req_addr[31:OFFSET_W], rf_beat, 4'b0000};
    wire [TAG_W-1:0] victim_tag = tag_mem[req_set][victim_way];
    wire [31:0] mem_wb_addr  = {victim_tag, req_set, wb_beat, 4'b0000};

    assign mem_rd_valid  = (state_q == S_RF_REQ);
    assign mem_rd_addr   = mem_rf_addr;
    assign mem_rsp_ready = (state_q == S_RF_RSP);
    assign mem_wr_valid  = (state_q == S_WB);
    assign mem_wr_addr   = mem_wb_addr;
    assign mem_wr_data   = data_mem[req_set][victim_way][wb_beat];
    assign mem_wr_be     = 16'hFFFF;
    assign l2_idle       = (state_q == S_IDLE) && !rsp_valid_q;

    // Registered invalidate pulse.  It is emitted one cycle after a store is
    // accepted, so the L1 tag write is a flop-to-flop sideband and not part of
    // the arbitration/data path.
    logic        inv_pulse_q;
    logic [CORES-1:0] inv_mask_q;
    logic [31:0] inv_addr_q;
    logic [7:0]  epoch_q;

    assign coh_inv_valid = inv_mask_q & {CORES{inv_pulse_q}};
    assign coh_inv_addr  = inv_addr_q;
    assign coh_epoch     = epoch_q;

    function automatic logic [127:0] merge_be(input logic [127:0] old,
                                              input logic [127:0] new_data,
                                              input logic [15:0]  be);
        logic [127:0] v;
        integer i;
        begin
            v = old;
            for (i = 0; i < 16; i = i + 1) begin
                if (be[i]) v[8*i +: 8] = new_data[8*i +: 8];
            end
            merge_be = v;
        end
    endfunction

    integer s;
    always @(posedge clk) begin
        if (rst) begin
            state_q     <= S_IDLE;
            req_write   <= 1'b0;
            req_core    <= {CORE_W{1'b0}};
            req_addr    <= 32'd0;
            req_wdata   <= 128'd0;
            req_be      <= 16'd0;
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 128'd0;
            rr_ptr      <= {CORE_W{1'b0}};
            inv_pulse_q <= 1'b0;
            inv_mask_q  <= {CORES{1'b0}};
            inv_addr_q  <= 32'd0;
            epoch_q     <= 8'd0;
            victim_way  <= {WAY_W{1'b0}};
            wb_beat     <= {BEAT_W{1'b0}};
            rf_beat     <= {BEAT_W{1'b0}};
            hit_count   <= 32'd0;
            miss_count  <= 32'd0;
            for (s = 0; s < SETS; s = s + 1) begin
                rr_mem[s] <= {WAY_W{1'b0}};
                for (w = 0; w < WAYS; w = w + 1) begin
                    valid_mem[s][w] <= 1'b0;
                    dirty_mem[s][w] <= 1'b0;
                end
            end
        end else begin
            inv_pulse_q <= 1'b0;

            case (state_q)
                S_IDLE: begin
                    if (req_any) begin
                        req_write <= sel_write;
                        req_core  <= sel_core;
                        req_addr  <= sel_write ? c_wr_addr[sel_core] : c_rd_addr[sel_core];
                        req_wdata <= c_wr_data[sel_core];
                        req_be    <= c_wr_be[sel_core];
                        rr_ptr    <= CORE_W'((sel_core + 1'b1) & CORE_MSK);

                        if (sel_write) begin
                            // Invalidate every other hart at the same line.
                            inv_pulse_q <= 1'b1;
                            inv_mask_q  <= ~onehot(sel_core);
                            // The L1 caches 4 B words, so invalidate the exact
                            // stored word rather than the 64 B L2 line base.
                            inv_addr_q  <= c_wr_addr[sel_core];
                            epoch_q     <= epoch_q + 8'd1;
                        end

                        state_q <= S_LOOKUP;
                    end
                end

                S_LOOKUP: begin
                    if (hit) begin
                        hit_count <= hit_count + 32'd1;
                        if (req_write) begin
                            data_mem[req_set][hit_way][req_beat] <=
                                merge_be(data_mem[req_set][hit_way][req_beat],
                                         req_wdata, req_be);
                            dirty_mem[req_set][hit_way] <= 1'b1;
                            state_q <= S_IDLE;
                        end else begin
                            rsp_data_q  <= data_mem[req_set][hit_way][req_beat];
                            rsp_valid_q <= 1'b1;
                            state_q     <= S_RESP;
                        end
                    end else begin
                        miss_count <= miss_count + 32'd1;
                        victim_way <= rr_mem[req_set];
                        wb_beat    <= {BEAT_W{1'b0}};
                        rf_beat    <= {BEAT_W{1'b0}};
                        if (dirty_mem[req_set][rr_mem[req_set]]) begin
                            state_q <= S_WB;
                        end else begin
                            state_q <= S_RF_REQ;
                        end
                    end
                end

                S_WB: begin
                    if (mem_wr_valid && mem_wr_ready) begin
                        if (wb_beat == BEAT_W'(BEATS - 1)) begin
                            state_q <= S_RF_REQ;
                        end else begin
                            wb_beat <= wb_beat + 1'b1;
                        end
                    end
                end

                S_RF_REQ: begin
                    if (mem_rd_valid && mem_rd_ready) begin
                        state_q <= S_RF_RSP;
                    end
                end

                S_RF_RSP: begin
                    if (mem_rsp_valid) begin
                        if (req_write && (rf_beat == req_beat)) begin
                            data_mem[req_set][victim_way][rf_beat] <=
                                merge_be(mem_rsp_data, req_wdata, req_be);
                        end else begin
                            data_mem[req_set][victim_way][rf_beat] <= mem_rsp_data;
                        end

                        if (!req_write && (rf_beat == req_beat)) begin
                            rsp_data_q <= mem_rsp_data;
                        end

                        if (rf_beat == BEAT_W'(BEATS - 1)) begin
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
