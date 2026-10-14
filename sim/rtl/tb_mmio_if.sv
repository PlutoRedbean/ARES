//=============================================================================
// ARES core verification - MMIO bridge -> DPI-C model adapter
//-----------------------------------------------------------------------------
// Device-side model for the LSU MMIO bridge (memory.md section 3.1):
// single outstanding request, request/response both handshaken, and the write
// response only after the device side effect has actually happened.
//
// Contract implemented here (docs/core_verification_flow.md section 3.3):
//   * mmio_req_ready is low while an unconsumed response is pending, so a
//     second request can never overlap (a new request may only be accepted in
//     the same cycle the pending response is consumed)
//   * an MMIO write is applied at the request handshake (the DPI model performs
//     the device side effect); its response is asserted in the very next cycle
//   * an MMIO read returns the word aligned to the request address; the LSU
//     performs byte selection / extension itself
//   * mmio_rdata is registered and held stable until mmio_rsp_ready
//   * req_ready is never used as a completion indication
//
// FREE items: FREE-10 (verification environment structure).  Not synthesizable.
//=============================================================================
module tb_mmio_if (
    input  logic        clk,
    input  logic        rst,

    input  logic        mmio_req_valid,
    output logic        mmio_req_ready,
    input  logic        mmio_write,
    input  logic [31:0] mmio_addr,
    input  logic [31:0] mmio_wdata,
    input  logic [3:0]  mmio_wstrb,

    output logic        mmio_rsp_valid,
    input  logic        mmio_rsp_ready,
    output logic [31:0] mmio_rdata
);
    import "DPI-C" function int  perip_read(input int addr);
    import "DPI-C" function void perip_write(input int addr, input int data, input byte mask);

    logic        rsp_valid_q;
    logic [31:0] rdata_q;

    wire req_accept = mmio_req_valid && mmio_req_ready;
    wire rsp_fire   = rsp_valid_q && mmio_rsp_ready;

    // Single outstanding device transaction: the next request may only be
    // accepted once the pending response is gone (or is consumed this cycle).
    assign mmio_req_ready = !rst && (!rsp_valid_q || mmio_rsp_ready);
    assign mmio_rsp_valid = rsp_valid_q;
    assign mmio_rdata     = rdata_q;

    // Byte-lane device write: the model's perip_write takes a 2-bit size mask
    // and derives the byte enables from the address, so partial strobes are
    // issued one byte at a time.
    task automatic apply_write(input logic [31:0] addr,
                               input logic [31:0] data,
                               input logic [3:0]  strb);
        int i;
        begin
            if (strb == 4'hf) begin
                perip_write(int'(addr), int'(data), 8'h02);
            end else begin
                for (i = 0; i < 4; i++) begin
                    if (strb[i])
                        perip_write(int'(addr) + i, int'({24'd0, data[8*i +: 8]}), 8'h00);
                end
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rdata_q     <= 32'd0;
        end else begin
            if (rsp_fire)
                rsp_valid_q <= 1'b0;

            if (req_accept) begin
                // Side effect performed at this edge; the response asserted in
                // the next cycle is therefore a genuine completion.
                rsp_valid_q <= 1'b1;
                if (mmio_write) begin
                    apply_write(mmio_addr, mmio_wdata, mmio_wstrb);
                    rdata_q <= 32'd0;
                end else begin
                    rdata_q <= 32'(perip_read(int'(mmio_addr)));
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    a_rsp_after_req: assert property (@(posedge clk) disable iff (rst)
        req_accept |=> mmio_rsp_valid);
    a_rsp_stable: assert property (@(posedge clk) disable iff (rst)
        (rsp_valid_q && !mmio_rsp_ready) |=> (mmio_rsp_valid && $stable(mmio_rdata)));
    a_single_outstanding: assert property (@(posedge clk) disable iff (rst)
        (rsp_valid_q && !mmio_rsp_ready) |-> !mmio_req_ready);
`endif

endmodule
