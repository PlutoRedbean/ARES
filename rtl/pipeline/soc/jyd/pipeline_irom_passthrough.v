//=============================================================================
// ARES pipeline SoC - 1-cycle instruction-fetch passthrough
//-----------------------------------------------------------------------------
// Presents the same request/response contract as pipeline_icache, but reads
// the IROM directly with the original one-cycle timing.  It is the
// USE_ICACHE=0 baseline path and keeps the IFU handshake identical between
// cached and uncached builds.
//
// The IROM is a synchronous-read memory: the address presented in cycle N
// returns data in cycle N+1.  A held `pending` bit therefore doubles as the
// response-valid indication while `addr_q` keeps the IROM address stable when
// the core is not ready.
//=============================================================================
module pipeline_irom_passthrough #(
    parameter ADDR_WIDTH           = 32,
    parameter IROM_WORD_ADDR_WIDTH = 13
) (
    input  wire                         clk,
    input  wire                         rst,

    // Core-side request/response
    input  wire                         req_valid,
    input  wire [ADDR_WIDTH-1:0]        req_addr,
    output wire                         req_ready,
    output wire                         rsp_valid,
    output wire [31:0]                  rsp_data,
    input  wire                         rsp_ready,
    input  wire                         flush,

    // IROM side
    output wire [IROM_WORD_ADDR_WIDTH-1:0] irom_addr,
    input  wire [31:0]                     irom_data
);
    reg                              pending;
    reg  [IROM_WORD_ADDR_WIDTH-1:0]  addr_q;

    wire req_fire = req_valid && req_ready;

    // A new request may be accepted in the same cycle the previous response is
    // consumed, which preserves the original one-instruction-per-cycle flow.
    assign req_ready = !pending || rsp_ready;
    assign rsp_valid = pending;
    assign rsp_data  = irom_data;

    // Drive the new address while a request is being accepted; otherwise hold
    // the address that produced the currently valid response.
    assign irom_addr = (req_valid && req_ready)
                     ? req_addr[IROM_WORD_ADDR_WIDTH+1:2]
                     : addr_q;

    always @(posedge clk) begin
        if (rst || flush) begin
            pending <= 1'b0;
            addr_q  <= {IROM_WORD_ADDR_WIDTH{1'b0}};
        end else begin
            if (req_fire) begin
                addr_q  <= req_addr[IROM_WORD_ADDR_WIDTH+1:2];
                pending <= 1'b1;
            end else if (rsp_valid && rsp_ready) begin
                pending <= 1'b0;
            end
        end
    end
endmodule
