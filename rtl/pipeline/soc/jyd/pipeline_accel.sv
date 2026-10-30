//=============================================================================
// ARES pipeline SoC - CoreMark accelerator MMIO wrapper
//-----------------------------------------------------------------------------
// Reuses the existing ARES accelerator engines without touching their
// datapaths:
//   * mtx9_engine   at 0xA000_1000 (9-PE INT16 matrix engine)
//   * state9_engine at 0xA000_2000 (token scanner)
//
// The wrapper only performs a simple 4 KiB page decode and one response
// register stage.  The engines are independently pipelined/multi-cycle, so
// this glue does not add a wide combinational path to the CPU.
//
// perip_bridge returns MMIO data two cycles after accepting the request
// (BRAM output register aligned).  The engines return host_rsp_valid one
// cycle after host_req_valid, so this module registers that response once
// more to match the bridge's response-tag pipeline.
//=============================================================================
module pipeline_accel (
    input  wire        clk,
    input  wire        rst,

    input  wire        req_valid,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [ 3:0] req_wstrb,

    output wire [31:0] rsp_data,
    output wire        rsp_valid
);

    localparam [19:0] MTX_PAGE = 20'hA0001;
    localparam [19:0] ST_PAGE  = 20'hA0002;

    wire mtx_sel = (req_addr[31:12] == MTX_PAGE);
    wire st_sel  = (req_addr[31:12] == ST_PAGE);

    wire        mtx_req_valid = req_valid && mtx_sel;
    wire        st_req_valid  = req_valid && st_sel;

    wire        mtx_req_ready;
    wire        st_req_ready;
    wire        mtx_rsp_valid;
    wire        st_rsp_valid;
    wire [31:0] mtx_rsp_data;
    wire [31:0] st_rsp_data;

    mtx9_engine u_mtx9_engine (
        .clk            (clk),
        .rst            (rst),
        .host_req_valid (mtx_req_valid),
        .host_req_ready (mtx_req_ready),
        .host_write     (req_write),
        .host_addr      (req_addr),
        .host_wdata     (req_wdata),
        .host_wstrb     (req_wstrb),
        .host_rsp_valid (mtx_rsp_valid),
        .host_rsp_data  (mtx_rsp_data)
    );

    state9_engine u_state9_engine (
        .clk            (clk),
        .rst            (rst),
        .host_req_valid (st_req_valid),
        .host_req_ready (st_req_ready),
        .host_write     (req_write),
        .host_addr      (req_addr),
        .host_wdata     (req_wdata),
        .host_wstrb     (req_wstrb),
        .host_rsp_valid (st_rsp_valid),
        .host_rsp_data  (st_rsp_data)
    );

    // Both engines accept every request, so the unused ready outputs are
    // intentionally left as wires for lint/elaboration visibility.
    wire unused_req_ready = mtx_req_ready & st_req_ready;

    // One extra register stage: engine response (T+1) -> bridge response (T+2).
    reg        rsp_valid_q;
    reg [31:0] rsp_data_q;

    always @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 32'd0;
        end else begin
            rsp_valid_q <= mtx_rsp_valid | st_rsp_valid;
            rsp_data_q  <= mtx_rsp_valid ? mtx_rsp_data : st_rsp_data;
        end
    end

    assign rsp_valid = rsp_valid_q;
    assign rsp_data  = rsp_data_q;

endmodule
