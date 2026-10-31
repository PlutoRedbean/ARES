//=============================================================================
// ARES pipeline SoC - shared IROM refill arbiter
//-----------------------------------------------------------------------------
// One read port shared by the per-hart instruction caches.  A grant covers a
// complete line burst (LINE_WORDS consecutive word addresses), so a cache
// never observes a half-refilled line.  Round-robin arbitration keeps one hot
// hart from starving the others; hits inside the caches do not touch the bus.
//
// The owner holds req for the whole burst.  If it drops req (the core
// redirected and the cache flushed), the burst is aborted immediately:
// otherwise the cache could mistake the stale grant for a new line's refill.
//=============================================================================
`include "autoconf.vh"

module pipeline_irom_arbiter #(
    parameter integer MASTERS    = 2,
    parameter integer LINE_WORDS = 16,
    parameter integer ADDR_W     = `CONFIG_IROM_ADDR_WIDTH + 1
) (
    input  wire                          clk,
    input  wire                          rst,

    input  wire [MASTERS-1:0]            req,
    input  wire [MASTERS-1:0][ADDR_W-1:0] req_addr,
    output wire [MASTERS-1:0]            gnt,
    output wire [ADDR_W-1:0]             bank_addr
);
    localparam integer CNT_BITS = $clog2(LINE_WORDS + 1);
    localparam integer SEL_BITS = (MASTERS > 1) ? $clog2(MASTERS) : 1;

    reg                 busy;
    reg [SEL_BITS-1:0]  sel;
    reg [SEL_BITS-1:0]  last;
    reg [CNT_BITS-1:0]  cnt;

    reg [SEL_BITS-1:0]  sel_next;
    reg                 found;
    integer i;
    integer idx;

    always @(*) begin
        sel_next = {SEL_BITS{1'b0}};
        found    = 1'b0;
        for (i = 1; i <= MASTERS; i = i + 1) begin
            idx = (last + i) % MASTERS;
            if (!found && req[idx]) begin
                sel_next = idx[SEL_BITS-1:0];
                found    = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            sel  <= {SEL_BITS{1'b0}};
            last <= {SEL_BITS{1'b0}};
            cnt  <= {CNT_BITS{1'b0}};
        end else if (!busy) begin
            if (|req) begin
                busy <= 1'b1;
                sel  <= sel_next;
                last <= sel_next;
                cnt  <= {CNT_BITS{1'b0}};
            end
        end else if (!req[sel]) begin
            // The owner aborted (flush); do not keep granting a stale burst.
            busy <= 1'b0;
        end else begin
            cnt <= cnt + 1'b1;
            if (cnt == LINE_WORDS-1) begin
                busy <= 1'b0;
            end
        end
    end

    assign gnt      = busy ? ({{(MASTERS-1){1'b0}}, 1'b1} << sel) : {MASTERS{1'b0}};
    assign bank_addr = busy ? (req_addr[sel] + cnt) : {ADDR_W{1'b0}};
endmodule
