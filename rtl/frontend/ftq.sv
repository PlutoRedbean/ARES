module ftq (
    input clk,
    input rst,
    // FTQ Write Port
    input logic wvalid,
    output logic wready,
    input fe_pkg::ftq_entry_t wdata,

    // FTQ Read Port
    output logic rvalid,
    input logic rready,
    output fe_pkg::ftq_entry_t rdata,

    // flush port
    /*
    * where flush signal comes from:
    * 1. IFU Predecode mismatch
    * 2. Backend redirect
    */
    input logic flush
);
    import fe_pkg::*;
    localparam int unsigned PTR_W = FTQ_NUM_ENTRIES;          // one-hot pointer width
    localparam int unsigned IDX_W = $clog2(FTQ_NUM_ENTRIES);  // storage index width

    // queue write/read ptr(implemented as one-hot code)
    logic [PTR_W - 1:0] wptr;
    logic [PTR_W - 1:0] rptr;

    // Fetch Target Queue (FTQ) storage
    ftq_entry_t ftq_mem[PTR_W];

    logic w_fire;
    logic r_fire;
    logic maybe_full;

    assign w_fire = wvalid && wready;
    assign r_fire = rvalid && rready;

    logic [PTR_W-1:0] n_wptr;
    logic [PTR_W-1:0] n_rptr;

    assign n_wptr = {wptr[PTR_W-2:0], wptr[PTR_W-1]};
    assign n_rptr = {rptr[PTR_W-2:0], rptr[PTR_W-1]};

    // one-hot pointer -> binary index
    function automatic logic [IDX_W-1:0] oh2idx(input logic [PTR_W-1:0] oh);
        oh2idx = '0;
        for (int i = 0; i < PTR_W; i++) begin
            if (oh[i]) oh2idx = IDX_W'(i);
        end
    endfunction

    logic [IDX_W-1:0] widx;
    logic [IDX_W-1:0] ridx;

    assign widx   = oh2idx(wptr);
    assign ridx   = oh2idx(rptr);

    // combinational read: rdata is valid in the same cycle as rvalid
    assign rdata  = ftq_mem[ridx];
    assign wready = ~maybe_full;
    assign rvalid = (wptr != rptr) || maybe_full;

    always_ff @(posedge clk) begin
        if (rst) begin
            maybe_full <= 1'b0;
        end else if (flush) begin
            maybe_full <= 1'b0;
        end else begin
            unique case ({
                w_fire, r_fire
            })
                2'b10:   maybe_full <= (n_wptr == rptr) ? 1'b1 : maybe_full;
                2'b01:   maybe_full <= 1'b0;
                default: maybe_full <= maybe_full;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wptr <= {{(PTR_W - 1) {1'b0}}, 1'b1};
            rptr <= {{(PTR_W - 1) {1'b0}}, 1'b1};
        end else if (flush) begin
            wptr <= {{(PTR_W - 1) {1'b0}}, 1'b1};
            rptr <= {{(PTR_W - 1) {1'b0}}, 1'b1};
        end else begin
            if (w_fire) begin
                ftq_mem[widx] <= wdata;
                wptr          <= n_wptr;
            end

            if (r_fire) begin
                rptr <= n_rptr;
            end
        end
    end

`ifndef SYNTHESIS
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    // synthesis-only debug: number of valid entries currently held in the FTQ
    logic [$clog2(FTQ_NUM_ENTRIES + 1) - 1:0] dbg_occ;
    always_comb begin
        if (wptr == rptr) dbg_occ = maybe_full ? FTQ_NUM_ENTRIES : '0;
        else if (widx >= ridx) dbg_occ = widx - ridx;
        else dbg_occ = FTQ_NUM_ENTRIES + widx - ridx;
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
    /* verilator lint_on UNUSEDSIGNAL */
`endif
endmodule
