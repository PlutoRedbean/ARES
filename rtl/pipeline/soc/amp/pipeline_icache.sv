//=============================================================================
// ARES pipeline SoC - per-hart instruction cache
//-----------------------------------------------------------------------------
// Direct-mapped instruction cache sitting between the core fetch port and the
// shared read-only IROM refill bus.  The core sees the original one-cycle
// fetch interface plus an "irom.ready" handshake: a hit asserts ready in the
// request cycle and returns the word one cycle later; a miss deasserts ready
// while the 64 B line is refilled through the shared IROM port.
//
// Geometry: LINES x (LINE_BYTES/4) words.  The default 256 x 64 B = 16 KiB
// covers the whole CoreMark text (about 13.8 KiB) with 256 distinct line
// indices, so after the cold fills only compulsory misses remain.
//
// No I-cache coherence: the SoC's code memory is a read-only IROM, so code is
// never modified at run time.  FENCE.I therefore has no line to invalidate.
//=============================================================================
`include "autoconf.vh"

module pipeline_icache #(
    parameter integer LINE_BYTES = 64,
    parameter integer LINES      = 256
) (
    input  wire        clk,
    input  wire        rst,

    // Core fetch port.  cpu_addr is the byte PC; cpu_data/cpu_ready follow
    // the core's one-cycle read contract.
    input  wire [31:0] cpu_addr,
    output wire [31:0] cpu_data,
    output wire        cpu_ready,

    // Shared IROM refill bus.  mem_req is held until the arbiter grants the
    // whole line; mem_gnt is level for LINE_WORDS cycles with mem_req_addr
    // advancing inside the arbiter.
    output wire        mem_req,
    output wire [`CONFIG_IROM_ADDR_WIDTH:0] mem_req_addr,
    input  wire        mem_gnt,
    input  wire [31:0] mem_data,

    // Simulation/measurement counters.
    output wire [31:0] stat_refills,
    output wire [31:0] stat_words
);
    localparam integer LINE_WORDS = LINE_BYTES / 4;
    localparam integer WORD_BITS  = $clog2(LINE_WORDS);
    localparam integer LINE_BITS  = $clog2(LINES);
    localparam integer TAG_BITS   = 32 - LINE_BITS - WORD_BITS - 2;
    localparam integer MEM_AW     = `CONFIG_IROM_ADDR_WIDTH + 1;
    localparam integer DATA_WORDS = LINES * LINE_WORDS;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_WAIT  = 2'd1;
    localparam [1:0] S_FILL  = 2'd2;
    localparam [1:0] S_DRAIN = 2'd3;

    wire [LINE_BITS-1:0] cpu_line = cpu_addr[LINE_BITS+WORD_BITS+1 : WORD_BITS+2];
    wire [WORD_BITS-1:0] cpu_word = cpu_addr[WORD_BITS+1 : 2];
    wire [TAG_BITS-1:0]  cpu_tag  = cpu_addr[31 : LINE_BITS+WORD_BITS+2];

    reg [31:0]          data_mem [0:DATA_WORDS-1];
    reg [TAG_BITS-1:0]  tag_mem  [0:LINES-1];
    reg [LINES-1:0]     valid_mem;

    reg [31:0] data_q;
    always @(posedge clk) begin
        data_q <= data_mem[{cpu_line, cpu_word}];
    end
    assign cpu_data = data_q;

    wire hit = valid_mem[cpu_line] && (tag_mem[cpu_line] == cpu_tag);

    reg [1:0]           state;
    reg [LINE_BITS-1:0] r_line;
    reg [TAG_BITS-1:0]  r_tag;
    reg [MEM_AW-1:0]    r_base;
    reg [WORD_BITS:0]   fill_cnt;
    reg                 pending_valid;
    reg [WORD_BITS-1:0] pending_word;
    reg                 req_r;
    reg [31:0]          refill_count;
    reg [31:0]          word_count;

    assign cpu_ready     = hit && (state == S_IDLE);
    assign mem_req       = req_r;
    assign mem_req_addr  = r_base;
    assign stat_refills  = refill_count;
    assign stat_words    = word_count;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            valid_mem     <= {LINES{1'b0}};
            req_r         <= 1'b0;
            pending_valid <= 1'b0;
            fill_cnt      <= {(WORD_BITS+1){1'b0}};
            refill_count  <= 32'd0;
            word_count    <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (!hit) begin
                        state         <= S_WAIT;
                        r_line        <= cpu_line;
                        r_tag         <= cpu_tag;
                        r_base        <= {cpu_addr[MEM_AW+1 : WORD_BITS+2],
                                          {WORD_BITS{1'b0}}};
                        req_r         <= 1'b1;
                        pending_valid <= 1'b0;
                    end
                end
                S_WAIT: begin
                    // The arbiter issues the line's first word in the cycle it
                    // grants; its data arrives one cycle later in S_FILL.
                    if (mem_gnt) begin
                        state         <= S_FILL;
                        fill_cnt      <= {{WORD_BITS{1'b0}}, 1'b1};
                        pending_valid <= 1'b1;
                        pending_word  <= {WORD_BITS{1'b0}};
                    end
                end
                S_FILL: begin
                    if (mem_gnt) begin
                        if (pending_valid) begin
                            data_mem[{r_line, pending_word}] <= mem_data;
                            word_count <= word_count + 32'd1;
                        end
                        pending_valid <= 1'b1;
                        pending_word  <= fill_cnt[WORD_BITS-1:0];
                        fill_cnt      <= fill_cnt + 1'b1;
                        if (fill_cnt == LINE_WORDS-1) begin
                            req_r <= 1'b0;
                            state <= S_DRAIN;
                        end
                    end
                end
                S_DRAIN: begin
                    // The last word's data arrives one cycle after the last
                    // grant cycle; then the line becomes visible.
                    if (pending_valid) begin
                        data_mem[{r_line, pending_word}] <= mem_data;
                        word_count <= word_count + 32'd1;
                    end
                    pending_valid <= 1'b0;
                    tag_mem[r_line]   <= r_tag;
                    valid_mem[r_line] <= 1'b1;
                    refill_count      <= refill_count + 32'd1;
                    state             <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
