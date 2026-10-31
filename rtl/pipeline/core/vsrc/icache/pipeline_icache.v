//=============================================================================
// ARES pipeline SoC - single-issue instruction cache
//-----------------------------------------------------------------------------
// 1-wide, 4 KiB, 4-way, 32 B line, pseudo-LRU.  The core side is a simple
// request/response handshake with one instruction per response; the memory
// side is a native line-refill port (one 32-bit beat at a time by default).
//
// The cache is written in Verilog-2005 style on purpose: it is part of the
// rtl/pipeline tree and must compile in both Verilator and the Pango PDS flow
// without SystemVerilog types/interfaces or vendor IP.
//
// Geometry defaults to 32 sets x 4 ways x 32 B, matching the IROM refill
// adapter.  The word select is generate-based; the refill packing assumes
// 32-bit instruction words.
//=============================================================================
module pipeline_icache #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer LINE_BYTES = 32,
    parameter integer NR_SETS    = 32,
    parameter integer NR_WAYS    = 4,
    parameter integer BEAT_BYTES = 4,
    // 1: accept a new request every cycle while the current lookup hits.
    // 0: original serialised behaviour (accept only in S_IDLE), for A/B tests.
    parameter integer PIPE_HITS  = 1
) (
    input  wire        clk,
    input  wire        rst,

    // Core-side request/response (one instruction per response)
    input  wire        req_valid,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    output wire        req_ready,
    output wire        rsp_valid,
    output wire [DATA_WIDTH-1:0] rsp_data,
    input  wire        rsp_ready,
    input  wire        flush,

    // Native line-refill port
    output wire        refill_req_valid,
    output wire [ADDR_WIDTH-1:0] refill_req_addr,
    input  wire        refill_req_ready,
    input  wire        refill_rsp_valid,
    input  wire [DATA_WIDTH-1:0] refill_rsp_data,
    output wire        refill_rsp_ready,

    // Simulation/observability
    input  wire        stats_dump,
    output wire [63:0] hit_count,
    output wire [63:0] miss_count,
    output wire [63:0] refill_count,
    output wire [63:0] request_count
);
    localparam integer OFFSET_WIDTH = $clog2(LINE_BYTES);              // 5
    localparam integer INDEX_WIDTH  = $clog2(NR_SETS);                 // 5
    localparam integer TAG_WIDTH    = ADDR_WIDTH - OFFSET_WIDTH - INDEX_WIDTH; // 22
    localparam integer WAY_IDX_W    = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;     // 2
    localparam integer AGE_W        = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;     // 2
    localparam integer NR_INSTS     = LINE_BYTES / 4;                   // 8
    localparam integer LINE_BITS    = LINE_BYTES * 8;                   // 256
    localparam integer NR_BEATS     = LINE_BYTES / BEAT_BYTES;          // 8
    localparam integer BEAT_CNT_W   = $clog2(NR_BEATS + 1);             // 4
    localparam integer BEAT_SEL_W   = (NR_BEATS > 1) ? $clog2(NR_BEATS) : 1; // 3
    localparam integer WORD_OFF_W   = (NR_INSTS > 1) ? $clog2(NR_INSTS) : 1; // 3
    localparam integer DATA_IDX_W   = INDEX_WIDTH + WAY_IDX_W;          // 7

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_LOOK   = 3'd1;
    localparam [2:0] S_REFILL = 3'd2;
    localparam [2:0] S_FILL   = 3'd3;
    localparam [2:0] S_RELOOK = 3'd4;
    localparam [2:0] S_RESP   = 3'd5;

    reg [2:0] state;

    //-------------------------------------------------------------------------
    // Request address decode / latches
    //-------------------------------------------------------------------------
    wire [INDEX_WIDTH-1:0] req_index =
        req_addr[OFFSET_WIDTH+INDEX_WIDTH-1:OFFSET_WIDTH];
    wire [TAG_WIDTH-1:0] req_tag =
        req_addr[ADDR_WIDTH-1:ADDR_WIDTH-TAG_WIDTH];
    wire [WORD_OFF_W-1:0] req_word_off =
        req_addr[OFFSET_WIDTH-1:2];

    reg [ADDR_WIDTH-1:0]  req_pc_r;
    reg [TAG_WIDTH-1:0]   req_tag_r;
    reg [INDEX_WIDTH-1:0] req_index_r;
    reg [WORD_OFF_W-1:0]  req_word_off_r;

    reg [ADDR_WIDTH-1:0]  miss_line_base;
    reg [TAG_WIDTH-1:0]   miss_tag;
    reg [INDEX_WIDTH-1:0] miss_index;
    reg [WAY_IDX_W-1:0]   miss_way;

    //-------------------------------------------------------------------------
    // Directory: valid / tag / age, flattened to avoid per-set tiny RAMs
    //-------------------------------------------------------------------------
    reg [NR_SETS*NR_WAYS-1:0] valid_mem;
    reg [TAG_WIDTH-1:0]       tag_mem [0:NR_SETS*NR_WAYS-1];
    reg [AGE_W-1:0]           age_mem [0:NR_SETS*NR_WAYS-1];

    reg [NR_WAYS-1:0]         hit_vec;
    reg [WAY_IDX_W-1:0]       hit_way;
    reg                       hit;
    reg [WAY_IDX_W-1:0]       victim_way;

    integer hit_i;
    always @(*) begin
        hit_vec = {NR_WAYS{1'b0}};
        hit_way = {WAY_IDX_W{1'b0}};
        for (hit_i = 0; hit_i < NR_WAYS; hit_i = hit_i + 1) begin
            if (valid_mem[req_index_r*NR_WAYS + hit_i] &&
                (tag_mem[req_index_r*NR_WAYS + hit_i] == req_tag_r))
                hit_vec[hit_i] = 1'b1;
        end
        hit = |hit_vec;
        for (hit_i = 0; hit_i < NR_WAYS; hit_i = hit_i + 1) begin
            if (hit_vec[hit_i])
                hit_way = hit_i[WAY_IDX_W-1:0];
        end
    end

    integer vic_i;
    always @(*) begin
        victim_way = {WAY_IDX_W{1'b0}};
        for (vic_i = 0; vic_i < NR_WAYS; vic_i = vic_i + 1) begin
            if (age_mem[req_index_r*NR_WAYS + vic_i] == (NR_WAYS-1))
                victim_way = vic_i[WAY_IDX_W-1:0];
        end
    end

    //-------------------------------------------------------------------------
    // Refill staging (declared before the data array because the fill write
    // consumes the packed line)
    //-------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] refill_buf [0:NR_BEATS-1];
    reg [BEAT_CNT_W-1:0] beat_issue;
    reg [BEAT_CNT_W-1:0] beat_rsp;

    wire [LINE_BITS-1:0] refill_line;
    genvar gb;
    generate
        for (gb = 0; gb < NR_BEATS; gb = gb + 1) begin : g_refill_pack
            assign refill_line[gb*DATA_WIDTH + DATA_WIDTH - 1 : gb*DATA_WIDTH] =
                refill_buf[gb];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Data array: one line per {way,set}, single synchronous read port.
    //
    // The way is resolved before the RAM read: a combinational tag check on
    // the live request selects the read address.  This keeps one data copy
    // per way without reading all four ways in parallel.
    //-------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [LINE_BITS-1:0] data_mem [0:NR_SETS*NR_WAYS-1];
    reg [LINE_BITS-1:0] data_r;

    reg [NR_WAYS-1:0]   pre_hit_vec;
    reg [WAY_IDX_W-1:0] pre_hit_way;

    integer pre_i;
    always @(*) begin
        pre_hit_vec = {NR_WAYS{1'b0}};
        pre_hit_way = {WAY_IDX_W{1'b0}};
        for (pre_i = 0; pre_i < NR_WAYS; pre_i = pre_i + 1) begin
            if (valid_mem[req_index*NR_WAYS + pre_i] &&
                (tag_mem[req_index*NR_WAYS + pre_i] == req_tag))
                pre_hit_vec[pre_i] = 1'b1;
        end
        for (pre_i = 0; pre_i < NR_WAYS; pre_i = pre_i + 1) begin
            if (pre_hit_vec[pre_i])
                pre_hit_way = pre_i[WAY_IDX_W-1:0];
        end
    end

    // Response slot / request handshake.  Declared before rd_index because
    // PIPE_HITS can accept the next request in the same cycle a hit response
    // is committed.
    reg                  rsp_valid_r;
    reg [DATA_WIDTH-1:0] rsp_data_r;

    wire out_free      = !rsp_valid_r || rsp_ready;
    wire pipe_hit_look = (PIPE_HITS != 0) && (state == S_LOOK) && hit;
    wire pipe_resp     = (PIPE_HITS != 0) && (state == S_RESP);
    wire req_ready_w   = out_free &&
                         ((state == S_IDLE) || pipe_hit_look || pipe_resp);
    wire req_fire      = req_valid && req_ready_w;

    wire [DATA_IDX_W-1:0] rd_index =
        (state == S_IDLE)   ? {pre_hit_way, req_index} :
        (state == S_RELOOK) ? {miss_way, miss_index} :
        ((state == S_LOOK) || (state == S_RESP)) ?
            (req_fire ? {pre_hit_way, req_index} : {hit_way, req_index_r}) :
                              {miss_way, miss_index};

    wire fill_we = (state == S_FILL);

    always @(posedge clk) begin
        if (rst)
            data_r <= {LINE_BITS{1'b0}};
        else
            data_r <= data_mem[rd_index];
    end

    always @(posedge clk) begin
        if (fill_we)
            data_mem[{miss_way, miss_index}] <= refill_line;
    end

    // Word select: one DATA_WIDTH slice per instruction in the line.
    wire [DATA_WIDTH-1:0] word_sel [0:NR_INSTS-1];
    genvar gw;
    generate
        for (gw = 0; gw < NR_INSTS; gw = gw + 1) begin : g_word_sel
            assign word_sel[gw] =
                data_r[gw*DATA_WIDTH + DATA_WIDTH - 1 : gw*DATA_WIDTH];
        end
    endgenerate

    wire [DATA_WIDTH-1:0] selected_word = word_sel[req_word_off_r];

    assign refill_req_valid = (state == S_REFILL) &&
                              (beat_issue < NR_BEATS);
    assign refill_req_addr  = miss_line_base + (beat_issue * BEAT_BYTES);
    assign refill_rsp_ready = (state == S_REFILL);

    //-------------------------------------------------------------------------
    // Response commit
    //-------------------------------------------------------------------------
    wire commit_look = (state == S_LOOK) && hit && out_free;
    wire commit_resp = (state == S_RESP) && out_free;
    wire hit_commit  = commit_look || commit_resp;

    assign req_ready = req_ready_w;
    assign rsp_valid = rsp_valid_r;
    assign rsp_data  = rsp_data_r;

    //-------------------------------------------------------------------------
    // Counters
    //-------------------------------------------------------------------------
    reg [63:0] hit_count_r;
    reg [63:0] miss_count_r;
    reg [63:0] refill_count_r;
    reg [63:0] request_count_r;

    assign hit_count     = hit_count_r;
    assign miss_count    = miss_count_r;
    assign refill_count  = refill_count_r;
    assign request_count = request_count_r;

    //-------------------------------------------------------------------------
    // Main sequential FSM
    //-------------------------------------------------------------------------
    integer age_i;
    integer rst_i;

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            rsp_valid_r    <= 1'b0;
            rsp_data_r     <= {DATA_WIDTH{1'b0}};
            req_pc_r       <= {ADDR_WIDTH{1'b0}};
            req_tag_r      <= {TAG_WIDTH{1'b0}};
            req_index_r    <= {INDEX_WIDTH{1'b0}};
            req_word_off_r <= {WORD_OFF_W{1'b0}};
            miss_line_base <= {ADDR_WIDTH{1'b0}};
            miss_tag       <= {TAG_WIDTH{1'b0}};
            miss_index     <= {INDEX_WIDTH{1'b0}};
            miss_way       <= {WAY_IDX_W{1'b0}};
            beat_issue     <= {BEAT_CNT_W{1'b0}};
            beat_rsp       <= {BEAT_CNT_W{1'b0}};
            valid_mem      <= {NR_SETS*NR_WAYS{1'b0}};
            hit_count_r    <= 64'd0;
            miss_count_r   <= 64'd0;
            refill_count_r <= 64'd0;
            request_count_r<= 64'd0;
            for (rst_i = 0; rst_i < NR_SETS*NR_WAYS; rst_i = rst_i + 1)
                age_mem[rst_i] <= rst_i[AGE_W-1:0];
        end else if (flush) begin
            // Drop any in-flight request/response; keep cached lines.
            state       <= S_IDLE;
            rsp_valid_r <= 1'b0;
            beat_issue  <= {BEAT_CNT_W{1'b0}};
            beat_rsp    <= {BEAT_CNT_W{1'b0}};
        end else begin
            // Response consumption
            if (rsp_valid_r && rsp_ready)
                rsp_valid_r <= 1'b0;

            // Commit a hit into the response slot
            if (hit_commit) begin
                rsp_valid_r <= 1'b1;
                rsp_data_r  <= selected_word;
                hit_count_r <= hit_count_r + 64'd1;
            end

            // Request bookkeeping
            if (req_fire) begin
                req_pc_r       <= req_addr;
                req_tag_r      <= req_tag;
                req_index_r    <= req_index;
                req_word_off_r <= req_word_off;
                request_count_r<= request_count_r + 64'd1;
            end

            // Age update on hit: accessed way -> 0, ways that were more
            // recent than it age by one.  The ages stay a permutation, so the
            // victim (age NR_WAYS-1) is unique.
            if (hit_commit) begin
                for (age_i = 0; age_i < NR_WAYS; age_i = age_i + 1) begin
                    if (age_i[WAY_IDX_W-1:0] == hit_way)
                        age_mem[req_index_r*NR_WAYS + age_i] <= {AGE_W{1'b0}};
                    else if (age_mem[req_index_r*NR_WAYS + age_i] <
                             age_mem[req_index_r*NR_WAYS + hit_way])
                        age_mem[req_index_r*NR_WAYS + age_i] <=
                            age_mem[req_index_r*NR_WAYS + age_i] + 1'b1;
                end
            end

            // Fill: install the line and update tag/valid/age
            if (fill_we) begin
                valid_mem[miss_index*NR_WAYS + miss_way] <= 1'b1;
                tag_mem[miss_index*NR_WAYS + miss_way]   <= miss_tag;
                refill_count_r <= refill_count_r + 64'd1;
                for (age_i = 0; age_i < NR_WAYS; age_i = age_i + 1) begin
                    if (age_i[WAY_IDX_W-1:0] == miss_way)
                        age_mem[miss_index*NR_WAYS + age_i] <= {AGE_W{1'b0}};
                    else if (age_mem[miss_index*NR_WAYS + age_i] <
                             age_mem[miss_index*NR_WAYS + miss_way])
                        age_mem[miss_index*NR_WAYS + age_i] <=
                            age_mem[miss_index*NR_WAYS + age_i] + 1'b1;
                end
            end

            case (state)
                S_IDLE: begin
                    if (req_fire)
                        state <= S_LOOK;
                end

                S_LOOK: begin
                    if (hit) begin
                        if (out_free)
                            // In PIPE_HITS mode req_fire can accept the next
                            // request in this cycle; stay in S_LOOK for it.
                            state <= req_fire ? S_LOOK : S_IDLE;
                        else
                            state <= S_RESP;
                    end else begin
                        miss_line_base <= {req_pc_r[ADDR_WIDTH-1:OFFSET_WIDTH],
                                           {OFFSET_WIDTH{1'b0}}};
                        miss_tag       <= req_tag_r;
                        miss_index     <= req_index_r;
                        miss_way       <= victim_way;
                        beat_issue     <= {BEAT_CNT_W{1'b0}};
                        beat_rsp       <= {BEAT_CNT_W{1'b0}};
                        miss_count_r   <= miss_count_r + 64'd1;
                        state          <= S_REFILL;
                    end
                end

                S_REFILL: begin
                    if (refill_req_valid && refill_req_ready)
                        beat_issue <= beat_issue + 1'b1;

                    if (refill_rsp_valid && refill_rsp_ready) begin
                        refill_buf[beat_rsp[BEAT_SEL_W-1:0]] <= refill_rsp_data;
                        beat_rsp <= beat_rsp + 1'b1;
                        if (beat_rsp == (NR_BEATS-1))
                            state <= S_FILL;
                    end
                end

                S_FILL: begin
                    state <= S_RELOOK;
                end

                S_RELOOK: begin
                    state <= S_LOOK;
                end

                S_RESP: begin
                    if (out_free)
                        state <= req_fire ? S_LOOK : S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef __VERILATOR__
    // Pure Verilog: the SoC pulses stats_dump when the core retires EBREAK.
    always @(posedge clk) begin
        if (stats_dump)
            $display("ICACHE hits=%0d misses=%0d refills=%0d reqs=%0d",
                     hit_count_r, miss_count_r, refill_count_r, request_count_r);
    end
`endif
endmodule
