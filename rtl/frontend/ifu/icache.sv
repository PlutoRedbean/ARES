// Instruction cache sitting between the IFU fetch FSM and the AXI master bus.
//
// The IFU presents a single fetch address through a simple request/response
// handshake:
//   - `req_valid` / `req_ready` : the IFU offers a PC, the cache accepts it,
//   - `resp_valid` / `resp_ready`: the cache returns the 32-bit instruction.
//
// A request is looked up in the cache.  On a hit the instruction word is
// returned after a short fixed latency; on a miss a whole line is fetched from
// memory word-by-word over the AXI4-Lite master port (the memory model has no
// bursts) and then the requested word is returned.
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

    axi_if.master icache_axi_bus
);
    import fe_pkg::*;

    localparam int unsigned OFFSET_WIDTH = $clog2(LINE_BYTES);
    localparam int unsigned INDEX_WIDTH = $clog2(NR_SETS);
    localparam int unsigned TAG_WIDTH = ADDR_WIDTH - OFFSET_WIDTH - INDEX_WIDTH;
    // localparam int unsigned INST_BYTES = DATA_WIDTH / 8;
    localparam int unsigned NR_INSTS = LINE_BYTES / INST_BYTES;
    localparam int unsigned NR_INSTS_W = (NR_INSTS > 1) ? $clog2(NR_INSTS) : 1;
    localparam int unsigned WAY_IDX_W = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;
    localparam int unsigned AGE_W = (NR_WAYS > 1) ? $clog2(NR_WAYS) : 1;

    typedef enum logic [2:0] {
        S_IDLE,
        S_CHECK,
        S_REFILL,
        S_FILL,
        S_RESP
    } state_t;

    state_t icache_state;
    state_t icache_n_state;

    typedef struct packed {
        logic valid;
        logic [TAG_WIDTH-1:0] tag;
        logic [NR_INSTS-1:0][DATA_WIDTH-1:0] data;
        logic [AGE_W-1:0] age;
    } cache_line_t;

    cache_line_t icache_mem[NR_SETS][NR_WAYS];

    // registered request (the two low byte-offset bits are unused because
    // instructions are word aligned)

    /* verilator lint_off UNUSEDSIGNAL */
    logic [ADDR_WIDTH - 1:0] req_addr_r;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [TAG_WIDTH-1:0] req_tag;
    logic [INDEX_WIDTH-1:0] req_index;
    logic [OFFSET_WIDTH-3:0] word_offset;

    // line refill bookkeeping
    logic [ADDR_WIDTH - 1:0] line_base;
    logic [NR_INSTS_W - 1:0] refill_cnt;
    logic ar_sent;
    logic [NR_INSTS-1:0][DATA_WIDTH-1:0] refill_buf;
    logic [WAY_IDX_W - 1:0] sel_way;

    assign req_tag = req_addr_r[ADDR_WIDTH-1-:TAG_WIDTH];
    assign req_index = req_addr_r[OFFSET_WIDTH+:INDEX_WIDTH];
    assign word_offset = req_addr_r[OFFSET_WIDTH-1:2];

    assign line_base = {req_addr_r[ADDR_WIDTH-1:OFFSET_WIDTH], {OFFSET_WIDTH{1'b0}}};

    // --------------------
    // hit / victim detection
    // --------------------
    logic hit;
    logic [WAY_IDX_W - 1:0] hit_way;

    always_comb begin
        hit     = 1'b0;
        hit_way = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (icache_mem[req_index][w].valid && icache_mem[req_index][w].tag == req_tag) begin
                hit     = 1'b1;
                hit_way = WAY_IDX_W'(w);
            end
        end
    end

    logic [WAY_IDX_W - 1:0] victim_way;

    always_comb begin
        victim_way = '0;
        for (int w = 0; w < NR_WAYS; w++) begin
            if (icache_mem[req_index][w].age == AGE_W'(NR_WAYS - 1)) victim_way = WAY_IDX_W'(w);
        end
    end

    // --------------------
    // FSM Transitions
    // --------------------
    logic refill_done;
    assign refill_done = ar_sent && icache_axi_bus.rvalid &&
                       icache_axi_bus.rready && (refill_cnt == NR_INSTS_W'(NR_INSTS - 1));

    always_comb begin : g_icache_fsm
        icache_n_state = icache_state;
        unique case (icache_state)
            S_IDLE:   if (req_valid && req_ready) icache_n_state = S_CHECK;
            S_CHECK:  icache_n_state = hit ? S_RESP : S_REFILL;
            S_REFILL: if (refill_done) icache_n_state = S_FILL;
            S_FILL:   icache_n_state = S_RESP;
            S_RESP:   if (resp_ready) icache_n_state = S_IDLE;
            default:  icache_n_state = S_IDLE;
        endcase
    end

    assign req_ready = (icache_state == S_IDLE);

    // --------------------
    // AXI4-Lite read channel
    // --------------------
    assign icache_axi_bus.arvalid = (icache_state == S_REFILL) && !ar_sent;
    assign icache_axi_bus.araddr = line_base + (refill_cnt * INST_BYTES);
    assign icache_axi_bus.rready = (icache_state == S_REFILL) && ar_sent;

    // the cache never writes
    assign icache_axi_bus.awaddr = '0;
    assign icache_axi_bus.awvalid = '0;
    assign icache_axi_bus.wdata = '0;
    assign icache_axi_bus.wstrb = '0;
    assign icache_axi_bus.wvalid = '0;
    assign icache_axi_bus.bready = '0;

    // --------------------
    // sequential logic
    // --------------------
    always_ff @(posedge clk) begin
        if (rst) icache_state <= S_IDLE;
        else icache_state <= icache_n_state;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            req_addr_r <= '0;
            refill_cnt <= '0;
            ar_sent    <= 1'b0;
            sel_way    <= '0;
            resp_valid <= 1'b0;
            for (int w = 0; w < fe_pkg::FETCH_WIDTH; w++) begin
                resp_data[w]  <= '0;
                resp_rmask[w] <= 1'b0;
            end
            for (int s = 0; s < NR_SETS; s++) begin
                for (int w = 0; w < NR_WAYS; w++) begin
                    icache_mem[s][w].valid <= 1'b0;
                    icache_mem[s][w].tag   <= '0;
                    icache_mem[s][w].data  <= '0;
                    icache_mem[s][w].age   <= AGE_W'(w);
                end
            end
        end else begin
            resp_valid <= 0;
            unique case (icache_state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        req_addr_r <= req_addr;
                    end
                    refill_cnt <= '0;
                    ar_sent    <= 1'b0;
                end

                S_CHECK: begin
                    if (hit) begin
                        sel_way <= hit_way;
                        for (int w = 0; w < NR_WAYS; w++) begin
                            if (WAY_IDX_W'(w) == hit_way) icache_mem[req_index][w].age <= '0;
                            else if (icache_mem[req_index][w].age != AGE_W'(NR_WAYS - 1))
                                icache_mem[req_index][w].age <= icache_mem[req_index][w].age + 1'b1;
                        end
                    end else begin
                        sel_way <= victim_way;
                    end
                end

                S_REFILL: begin
                    if (!ar_sent) begin
                        if (icache_axi_bus.arvalid && icache_axi_bus.arready) ar_sent <= 1'b1;
                    end else if (icache_axi_bus.rvalid && icache_axi_bus.rready) begin
                        refill_buf[refill_cnt] <= icache_axi_bus.rdata;
                        ar_sent <= 1'b0;
                        if (refill_cnt != NR_INSTS_W'(NR_INSTS - 1))
                            refill_cnt <= refill_cnt + 1'b1;
                    end
                end

                S_FILL: begin

                    icache_mem[req_index][sel_way].valid <= 1'b1;
                    icache_mem[req_index][sel_way].tag   <= req_tag;
                    icache_mem[req_index][sel_way].data  <= refill_buf;

                    // update ages: the selected way is now the youngest (age
                    // 0), and all other ways.ages + 1
                    for (int w = 0; w < NR_WAYS; w++) begin
                        if (WAY_IDX_W'(w) == sel_way) icache_mem[req_index][w].age <= '0;
                        else if (icache_mem[req_index][w].age != AGE_W'(NR_WAYS - 1))
                            icache_mem[req_index][w].age <= icache_mem[req_index][w].age + 1'b1;
                    end
                end

                S_RESP: begin
                    resp_valid <= 1'b1;
                    // A fetch window may start close to the end of a cache
                    // line; only the words that stay inside the line are
                    // returned, the remaining slots are masked off by
                    // `resp_rmask` and the IFU re-issues a request for the
                    // following line.
                    for (int w = 0; w < fe_pkg::FETCH_WIDTH; w++) begin
                        if (int'(word_offset) + w < int'(NR_INSTS)) begin
                            resp_data[w] <= icache_mem[req_index][sel_way].data[word_offset+(OFFSET_WIDTH-2)'(w)];
                            resp_rmask[w] <= 1'b1;
                        end else begin
                            resp_data[w]  <= '0;
                            resp_rmask[w] <= 1'b0;
                        end
                    end
                end

            endcase
        end
    end


    always_comb begin
        assert (req_addr[1:0] == 2'b00)
        else $fatal("icache request address must be word-aligned");
    end

endmodule
