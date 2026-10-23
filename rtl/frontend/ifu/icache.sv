/* verilator lint_off UNUSEDSIGNAL */ // partial instruction/address fields are intentional
// Instruction cache sitting between the IFU fetch FSM and the backing memory
// bus.
//
// The IFU presents a fetch PC through a simple request/response handshake:
//   - `req_valid` / `req_ready` : the IFU offers a PC, the cache accepts it,
//   - `resp_valid` / `resp_ready`: the cache returns `FETCH_WIDTH` instructions
//                                 plus a valid mask.
//
// Pipelining / crossing:
//   A fetch window is `FETCH_WIDTH` instructions starting at the (word aligned)
//   request PC.  It can straddle two 32 B cache lines.  Rather than asking the
//   IFU to issue a second request (which used to pair the wrong prediction
//   metadata with the second response), the cache stitches the window out of
//   the current and the next line itself and returns it in ONE response with
//   `resp_rmask` fully set.  Both lines' set reads are launched together (two
//   BRAM ports) on the accept edge.
//
//   Latency: the line data array is a synchronous (block-RAM) read.  The set
//   index is driven and registered on the accept edge, so the data is available
//   in S_LOOK; the tag compare (metadata in FF/LUT) and way selection run in
//   S_LOOK and the response is registered the same cycle -> a 2-cycle hit path.
//   The response is driven by an independent output holding register
//   (`resp_valid_r`/`resp_data_r`/`resp_rmask_r`), NOT by the FSM state, so
//   `resp_valid` is held stable until `resp_ready`.  A request is accepted only
//   in S_IDLE, so the steady state is one response every two cycles for hits.
//
//   The `valid`/`age` metadata is reset; tag/data contents are not cleared.
//   FPGA data storage uses the explicit cache BRAM IP wrapper.
//
// The backing bus is selected by the `CONFIG_IO_USE_AXI macro:
//   - defined   : AXI4-Lite master (`icache_axi_bus`), one 32-bit word per beat,
//   - commented : miniTensor uncached read handshake (`icache_mt_bus`, see
//                 miniTensor.md 4.2.1), one 128-bit line beat.
//
// The cache is set-associative with a simple LRU (age counter) replacement.
module icache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned NR_SETS = 64,
    parameter int unsigned NR_WAYS = 4
) (
    input logic clk,
    input logic rst,

    // IFU Read Port
    output logic                    req_ready,   // cache idle, may accept a request
    input  logic                    req_valid,
    input  logic [ADDR_WIDTH - 1:0] req_addr,    // request PC
    output logic                    resp_valid,  // instruction data valid
    input  logic                    resp_ready,

    output logic [DATA_WIDTH - 1:0] resp_data[fe_pkg::FETCH_WIDTH],  // fetched instruction
    output logic [fe_pkg::FETCH_WIDTH - 1:0] resp_rmask,
    output logic refill,  // one-cycle miss/refill pulse

`ifdef CONFIG_IO_USE_AXI
    axi_if.master icache_axi_bus
`else
    miniTensor_if.master icache_mt_bus
`endif
);
    import fe_pkg::*;

    localparam int unsigned OFFSET_WIDTH = $clog2(LINE_BYTES);
    localparam int unsigned INDEX_WIDTH = $clog2(NR_SETS);
    localparam int unsigned TAG_WIDTH = ADDR_WIDTH - OFFSET_WIDTH - INDEX_WIDTH;
    localparam int unsigned NR_INSTS = LINE_BYTES / INST_BYTES;
    localparam int unsigned WAY_IDX_W = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;
    localparam int unsigned AGE_W = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;

    // Backing bus width and the number of bus beats per cache line.  The AXI
    // master moves one 32-bit instruction per beat; miniTensor moves a 16-byte
    // (128-bit) beat.  Both protocols are used through the abstract
    // bus_req_*/bus_rsp_* handshake below.
`ifdef CONFIG_IO_USE_AXI
    localparam int unsigned BUS_DATA_WIDTH = DATA_WIDTH;
`else
    localparam int unsigned BUS_DATA_WIDTH = 128;
`endif
    localparam int unsigned BUS_BEAT_BYTES = BUS_DATA_WIDTH / 8;
    localparam int unsigned BUS_BEAT_INSTS = BUS_BEAT_BYTES / INST_BYTES;
    localparam int unsigned NR_BEATS = (LINE_BYTES + BUS_BEAT_BYTES - 1) / BUS_BEAT_BYTES;
    localparam int unsigned NR_BEATS_W = (NR_BEATS > 1) ? $clog2(NR_BEATS) : 1;

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOOK,
        S_REFILL,
        S_FILL,
        S_RELOOK,  // let the synchronous read settle on the freshly written line
        S_RESP
    } state_t;

    state_t icache_state;
    state_t icache_n_state;

    // Metadata (valid/tag/age) lives in FF/LUT. Line data uses native
    // synchronous Block Memory Generator IP through icache_data_way.
    logic valid_mem[NR_SETS][NR_WAYS];
    logic [AGE_W-1:0] age_mem[NR_SETS][NR_WAYS];
    logic [TAG_WIDTH-1:0] tag_mem[NR_SETS][NR_WAYS];
    // Each way owns two identical SDP BRAM copies for concurrent line reads.

    logic [ADDR_WIDTH - 1:0] req_pc_r;


    logic [INDEX_WIDTH-1:0] rd_index_a_r;
    logic [INDEX_WIDTH-1:0] rd_index_b_r;
    logic [NR_INSTS-1:0][DATA_WIDTH-1:0] data_a_r[NR_WAYS];
    logic [NR_INSTS-1:0][DATA_WIDTH-1:0] data_b_r[NR_WAYS];

    logic resp_valid_r;
    logic [DATA_WIDTH - 1:0] resp_data_r[fe_pkg::FETCH_WIDTH];
    logic [fe_pkg::FETCH_WIDTH-1:0] resp_rmask_r;

    // ---- request decode (from req_pc_r) ----
    logic [ADDR_WIDTH - 1:0] line_a_base;
    logic [ADDR_WIDTH - 1:0] line_b_base;
    logic [TAG_WIDTH-1:0] tag_a;
    logic [TAG_WIDTH-1:0] tag_b;
    logic [INDEX_WIDTH-1:0] index_a;
    logic [INDEX_WIDTH-1:0] index_b;
    logic [OFFSET_WIDTH-3:0] word_off;  // word index in the line
    logic need_next;

    assign word_off    = req_pc_r[OFFSET_WIDTH-1:2];
    assign need_next   = (int'(word_off) + int'(FETCH_WIDTH)) > int'(NR_INSTS) &&
                       line_b_base < 32'h8000_8000;
    assign line_a_base = {req_pc_r[ADDR_WIDTH-1:OFFSET_WIDTH], {OFFSET_WIDTH{1'b0}}};
    assign line_b_base = line_a_base + ADDR_WIDTH'(LINE_BYTES);
    assign tag_a       = req_pc_r[ADDR_WIDTH-1-:TAG_WIDTH];
    assign index_a     = req_pc_r[OFFSET_WIDTH+:INDEX_WIDTH];
    assign tag_b       = line_b_base[ADDR_WIDTH-1-:TAG_WIDTH];
    assign index_b     = line_b_base[OFFSET_WIDTH+:INDEX_WIDTH];

    // next-line read address decoded directly from the incoming req_addr, so the
    // two BRAM read ports can be registered on the accept edge.
    logic [ADDR_WIDTH-1:0] req_line_b_base;
    assign req_line_b_base = {req_addr[ADDR_WIDTH-1:OFFSET_WIDTH], {OFFSET_WIDTH{1'b0}}}
                             + ADDR_WIDTH'(LINE_BYTES);

    // ---- hit detection ----
    logic hit_a;
    logic hit_b;
    logic [WAY_IDX_W-1:0] way_a;
    logic [WAY_IDX_W-1:0] way_b;

    always_comb begin
        hit_a = 1'b0;
        way_a = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (valid_mem[index_a][w] && tag_mem[index_a][w] == tag_a) begin
                hit_a = 1'b1;
                way_a = WAY_IDX_W'(w);
            end
        end
    end

    always_comb begin
        hit_b = 1'b0;
        way_b = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (valid_mem[index_b][w] && tag_mem[index_b][w] == tag_b) begin
                hit_b = 1'b1;
                way_b = WAY_IDX_W'(w);
            end
        end
    end

    wire all_hit = hit_a && (!need_next || hit_b);

    // ---- victim selection (oldest age) ----
    logic [WAY_IDX_W-1:0] victim_a;
    logic [WAY_IDX_W-1:0] victim_b;

    always_comb begin
        victim_a = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (age_mem[index_a][w] == AGE_W'(NR_WAYS - 1)) victim_a = WAY_IDX_W'(w);
        end
    end

    always_comb begin
        victim_b = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (age_mem[index_b][w] == AGE_W'(NR_WAYS - 1)) victim_b = WAY_IDX_W'(w);
        end
    end

    // ---- miss target (line A has priority; line B only when crossing) ----
    logic [   TAG_WIDTH-1:0] miss_tag;
    logic [ INDEX_WIDTH-1:0] miss_index;
    logic [ADDR_WIDTH - 1:0] miss_line_base;
    logic [ WAY_IDX_W - 1:0] miss_way;

    always_comb begin
        if (!hit_a) begin
            miss_tag       = tag_a;
            miss_index     = index_a;
            miss_line_base = line_a_base;
            miss_way       = victim_a;
        end else begin
            miss_tag       = tag_b;
            miss_index     = index_b;
            miss_line_base = line_b_base;
            miss_way       = victim_b;
        end
    end

    logic [   TAG_WIDTH-1:0] miss_tag_r;
    logic [ INDEX_WIDTH-1:0] miss_index_r;
    logic [ADDR_WIDTH - 1:0] miss_line_base_r;
    logic [ WAY_IDX_W - 1:0] miss_way_r;

    // ---- window assembly from the two lines ----
    logic [DATA_WIDTH - 1:0] asm_data[fe_pkg::FETCH_WIDTH];
    always_comb begin
        for (int i = 0; i < fe_pkg::FETCH_WIDTH; i++) begin
            int wi;
            wi = int'(word_off) + i;
            if (wi < int'(NR_INSTS)) asm_data[i] = data_a_r[way_a][wi];
            else asm_data[i] = data_b_r[way_b][wi-int'(NR_INSTS)];
        end
    end

    wire out_free = !resp_valid_r || resp_ready;
    wire commit = ((icache_state == S_LOOK) || (icache_state == S_RESP)) && all_hit && out_free;

    // --------------------
    // line refill bookkeeping
    // --------------------
    logic [NR_BEATS_W - 1:0] refill_cnt;
    logic req_sent;
    logic [NR_INSTS-1:0][DATA_WIDTH-1:0] refill_buf;

    logic bus_req_valid;
    logic bus_req_ready;
    logic [ADDR_WIDTH - 1:0] bus_req_addr;
    logic bus_rsp_valid;
    logic bus_rsp_ready;
    logic [BUS_DATA_WIDTH-1:0] bus_rsp_data;

`ifdef CONFIG_IO_USE_AXI
    assign icache_axi_bus.arvalid = bus_req_valid;
    assign icache_axi_bus.araddr = bus_req_addr;
    assign bus_req_ready = icache_axi_bus.arready;

    assign bus_rsp_valid = icache_axi_bus.rvalid;
    assign bus_rsp_data = icache_axi_bus.rdata;
    assign icache_axi_bus.rready = bus_rsp_ready;

    // the cache never writes
    assign icache_axi_bus.awaddr = '0;
    assign icache_axi_bus.awvalid = '0;
    assign icache_axi_bus.wdata = '0;
    assign icache_axi_bus.wstrb = '0;
    assign icache_axi_bus.wvalid = '0;
    assign icache_axi_bus.bready = '0;
`else
    assign icache_mt_bus.mem_rd_valid = bus_req_valid;
    assign icache_mt_bus.mem_rd_addr  = bus_req_addr;
    assign bus_req_ready = icache_mt_bus.mem_rd_ready;

    assign bus_rsp_valid = icache_mt_bus.mem_rsp_valid;
    assign bus_rsp_data  = icache_mt_bus.mem_rsp_data;
    assign icache_mt_bus.mem_rsp_ready = bus_rsp_ready;

    // the cache never writes
    assign icache_mt_bus.mem_wr_valid = 1'b0;
    assign icache_mt_bus.mem_wr_addr  = '0;
    assign icache_mt_bus.mem_wr_data  = '0;
    assign icache_mt_bus.mem_wr_be    = '0;
`endif

    // --------------------
    // FSM Transitions
    // --------------------
    logic refill_done;
    assign refill_done = req_sent && bus_rsp_valid && bus_rsp_ready &&
                         (refill_cnt == NR_BEATS_W'(NR_BEATS - 1));

    always_comb begin : g_icache_fsm
        icache_n_state = icache_state;
        unique case (icache_state)
            S_IDLE: if (req_valid && req_ready) icache_n_state = S_LOOK;
            S_LOOK:
            if (!all_hit) icache_n_state = S_REFILL;
            else if (out_free) icache_n_state = S_IDLE;
            else icache_n_state = S_RESP;
            S_REFILL: if (refill_done) icache_n_state = S_FILL;
            S_FILL: icache_n_state = S_RELOOK;
            S_RELOOK: icache_n_state = S_LOOK;  // re-look up with fresh data
            S_RESP: if (out_free) icache_n_state = S_IDLE;
            default: icache_n_state = S_IDLE;
        endcase
    end

    assign req_ready = (icache_state == S_IDLE);
    // miss/refill pulse: a request that is looked up without a full hit
    assign refill = (icache_state == S_LOOK) && !all_hit;

    // --------------------
    // backing bus read request / response
    // --------------------
    assign bus_req_valid = (icache_state == S_REFILL) && !req_sent;
    assign bus_req_addr = miss_line_base_r + (ADDR_WIDTH'(refill_cnt) << $clog2(
        ADDR_WIDTH'(BUS_BEAT_BYTES)
    ));
    assign bus_rsp_ready = (icache_state == S_REFILL) && req_sent;

    // --------------------
    // sequential logic
    // --------------------
    always_ff @(posedge clk) begin
        if (rst) icache_state <= S_IDLE;
        else icache_state <= icache_n_state;
    end

    wire [INDEX_WIDTH-1:0] rd_addr_a =
        (icache_state == S_IDLE) ? req_addr[OFFSET_WIDTH+:INDEX_WIDTH] : rd_index_a_r;
    wire [INDEX_WIDTH-1:0] rd_addr_b =
        (icache_state == S_IDLE) ? req_line_b_base[OFFSET_WIDTH+:INDEX_WIDTH] : rd_index_b_r;

    for (genvar w=0; w<NR_WAYS; w++) begin : g_way_data
        icache_data_way #(.INDEX_BITS(INDEX_WIDTH), .LINE_BITS(NR_INSTS*DATA_WIDTH)) u_data (
            .clk(clk), .rst(rst), .rd_addr_a(rd_addr_a), .rd_addr_b(rd_addr_b),
            .wr_addr(miss_index_r), .wr_en((icache_state==S_FILL) && (WAY_IDX_W'(w)==miss_way_r)),
            .wr_data(refill_buf), .rd_data_a(data_a_r[w]), .rd_data_b(data_b_r[w])
        );
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            req_pc_r <= '0;
            rd_index_a_r <= '0;
            rd_index_b_r <= '0;
            refill_cnt <= '0;
            req_sent <= 1'b0;
            resp_valid_r <= 1'b0;
            resp_rmask_r <= '0;
            for (int w = 0; w < fe_pkg::FETCH_WIDTH; w++) begin
                resp_data_r[w] <= '0;
            end
            for (int s = 0; s < NR_SETS; s++) begin
                for (int w = 0; w < NR_WAYS; w++) begin
                    // Only the metadata is reset; tag/data are left alone so the
                    // tag/data arrays can be inferred as RAM.
                    valid_mem[s][w] <= 1'b0;
                    age_mem[s][w]   <= AGE_W'(w);
                end
            end
        end else begin
            if (resp_valid_r && resp_ready) resp_valid_r <= 1'b0;

            // Latch the miss target while it is detected in S_LOOK, so the
            // refill address and the later fill are driven by registered signals
            // instead of the tag-compare / victim ripple of this cycle.
            if ((icache_state == S_LOOK) && !all_hit) begin
                miss_tag_r       <= miss_tag;
                miss_index_r     <= miss_index;
                miss_line_base_r <= miss_line_base;
                miss_way_r       <= miss_way;
            end

            unique case (icache_state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        req_pc_r     <= req_addr;
                        rd_index_a_r <= req_addr[OFFSET_WIDTH+:INDEX_WIDTH];
                        rd_index_b_r <= req_line_b_base[OFFSET_WIDTH+:INDEX_WIDTH];
                    end
                    refill_cnt <= '0;
                    req_sent   <= 1'b0;
                end

                S_REFILL: begin
                    if (!req_sent) begin
                        if (bus_req_valid && bus_req_ready) req_sent <= 1'b1;
                    end else if (bus_rsp_valid && bus_rsp_ready) begin
                        // a 128-bit miniTensor beat carries BUS_BEAT_INSTS
                        // instructions; an AXI beat carries one
                        for (int j = 0; j < BUS_BEAT_INSTS; j++) begin
                            refill_buf[int'(refill_cnt) * BUS_BEAT_INSTS + j]
                                <= bus_rsp_data[j*INST_WIDTH +: INST_WIDTH];
                        end
                        req_sent <= 1'b0;
                        if (refill_cnt != NR_BEATS_W'(NR_BEATS - 1))
                            refill_cnt <= refill_cnt + 1'b1;
                    end
                end

                S_FILL: begin
                    valid_mem[miss_index_r][miss_way_r] <= 1'b1;
                    tag_mem[miss_index_r][miss_way_r] <= miss_tag_r;
                    // icache_data_way writes the refill through each SDP copy's
                    // write port; this block only updates the directory.

                    // A crossing block can perform two refills back to back
                    // (line A, then line B) without returning through S_IDLE, so
                    // the beat counter must be reset here for the next refill.
                    refill_cnt <= '0;
                    req_sent <= 1'b0;

                    // update ages: the selected way is now the youngest (age
                    // 0), and all other ways.ages + 1
                    for (int w = 0; w < NR_WAYS; w++) begin
                        if (WAY_IDX_W'(w) == miss_way_r) age_mem[miss_index_r][w] <= '0;
                        else if (age_mem[miss_index_r][w] != AGE_W'(NR_WAYS - 1))
                            age_mem[miss_index_r][w] <= age_mem[miss_index_r][w] + 1'b1;
                    end
                end

                default: ;
            endcase

            // commit the assembled window into the output holding register.
            // Line A and line B always map to different sets (adjacent lines),
            // so the two age updates never touch the same set.
            if (commit) begin
                resp_valid_r <= 1'b1;

                for (int w = 0; w < fe_pkg::FETCH_WIDTH; w++) begin
                    resp_data_r[w] <= asm_data[w];
                    resp_rmask_r[w] <= req_pc_r + 32'(w*INST_BYTES) < 32'h8000_8000;
                end

                for (int w = 0; w < NR_WAYS; w++) begin
                    if (WAY_IDX_W'(w) == way_a) age_mem[index_a][w] <= '0;
                    else if (age_mem[index_a][w] != AGE_W'(NR_WAYS - 1))
                        age_mem[index_a][w] <= age_mem[index_a][w] + 1'b1;
                end

                if (need_next) begin
                    for (int w = 0; w < NR_WAYS; w++) begin
                        if (WAY_IDX_W'(w) == way_b) age_mem[index_b][w] <= '0;
                        else if (age_mem[index_b][w] != AGE_W'(NR_WAYS - 1))
                            age_mem[index_b][w] <= age_mem[index_b][w] + 1'b1;
                    end
                end
            end
        end
    end

    assign resp_valid = resp_valid_r;
    assign resp_rmask = resp_rmask_r;

    always_comb begin
        for (int w = 0; w < fe_pkg::FETCH_WIDTH; w++) resp_data[w] = resp_data_r[w];
    end

    always_comb begin
        // Skip the check while reset is asserted: the IFU request register may
        // still hold its power-up value (random under `+verilator+rand+reset`).
        if (!rst && req_valid && req_ready) begin
            assert (req_addr[1:0] == 2'b00)
            else $fatal("icache request address must be word-aligned");
        end
    end

endmodule

/* verilator lint_on UNUSEDSIGNAL */
