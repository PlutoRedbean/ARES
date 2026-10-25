//=============================================================================
// ARES - AXI4-Lite read bridge for the ICache -> L2 I port
//-----------------------------------------------------------------------------
// The ICache issues one 32-bit AXI read per instruction.  The L2 I port
// returns one 16-byte beat.  This bridge holds the current 16-byte beat and
// serves up to four consecutive AXI word reads from it, so an ICache line fill
// consumes one L2 read per 16 B instead of one per instruction.
//
// Read-only: the ICache never writes.  AXI write channels are tied inactive.
//=============================================================================
module axi_l2_bridge (
    input  logic clk,
    input  logic rst,

    axi_if.slave axi,

    //---- L2 instruction read port -----------------------------------------
    output logic         l2_rd_valid,
    input  logic         l2_rd_ready,
    output logic [ 31:0] l2_rd_addr,
    input  logic         l2_rsp_valid,
    output logic         l2_rsp_ready,
    input  logic [127:0] l2_rsp_data
);
    typedef enum logic [1:0] {
        S_IDLE,
        S_REQ,
        S_RSP,
        S_OUT
    } state_t;

    state_t state_q;
    logic [31:4] req_addr_q;
    logic [1:0]  req_word_q;
    logic [27:0] buf_tag_q;
    logic [127:0] buf_data_q;
    logic         buf_valid_q;

    assign axi.arready = (state_q == S_IDLE);
    assign axi.rvalid  = (state_q == S_OUT);
    assign axi.rdata   = buf_data_q[{req_word_q, 5'd0} +: 32];
    assign axi.rresp   = 1'b0;

    // The ICache is read-only.
    assign axi.awready = 1'b0;
    assign axi.wready  = 1'b0;
    assign axi.bvalid  = 1'b0;
    assign axi.bresp   = 1'b0;

    assign l2_rd_valid  = (state_q == S_REQ);
    assign l2_rd_addr   = {req_addr_q, 4'b0000};
    assign l2_rsp_ready = (state_q == S_RSP);

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q    <= S_IDLE;
            req_addr_q <= 28'h0;
            req_word_q <= 2'd0;
            buf_tag_q  <= 28'h0;
            buf_data_q <= 128'h0;
            buf_valid_q <= 1'b0;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (axi.arvalid && axi.arready) begin
                        req_addr_q <= axi.araddr[31:4];
                        req_word_q <= axi.araddr[3:2];
                        if (buf_valid_q && (buf_tag_q == axi.araddr[31:4])) begin
                            state_q <= S_OUT;
                        end else begin
                            state_q <= S_REQ;
                        end
                    end
                end

                S_REQ: begin
                    if (l2_rd_valid && l2_rd_ready) state_q <= S_RSP;
                end

                S_RSP: begin
                    if (l2_rsp_valid) begin
                        buf_tag_q   <= req_addr_q;
                        buf_data_q  <= l2_rsp_data;
                        buf_valid_q <= 1'b1;
                        state_q     <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (axi.rvalid && axi.rready) state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
