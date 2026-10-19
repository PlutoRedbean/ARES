// Fetch Target Queue.
//
// Single write port, combinational read.  In addition to the ring pointers it
// keeps a per-entry valid bitmap so that the BPU can, on an mbtb correction
// (docs/ubtb-mbtb-refactor-plan.md §7):
//   * tail-invalidate everything after a corrected entry (roll the write
//     pointer back) and suppress the in-flight wrong-path writes for 2 cycles
//     (poison), and
//   * rewrite an allocated entry's prediction fields in place.
// The correction port is inactive (corr_valid=0) in the current BPU, so the
// behaviour is identical to the plain ring when unused.
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

    // number of valid entries currently held (for the simulation model)
    output logic [$clog2(fe_pkg::FTQ_NUM_ENTRIES+1) - 1:0] occupancy,
    output logic alloc,
    output logic pop,
    // current write index (one-hot); the BPU shadow uses it for corrections
    output logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] wr_idx_oh,

    // ---- correction port (BPU mbtb correction, P3) ----
    input logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] corr_idx,  // one-hot entry to keep
    input logic corr_valid,
    output logic corr_hit,  // corr_idx still in the FTQ
    input logic corr_wr_en,  // in-place rewrite
    input logic [fe_pkg::FTQ_NUM_ENTRIES-1:0] corr_wr_idx,  // one-hot
    input fe_pkg::ftq_entry_t corr_wr_data,
    input logic [fe_pkg::ADDR_WIDTH-1:0] corr_start_pc,  // identity check

    // flush port
    /*
    * where flush signal comes from:
    * 1. IFU Predecode mismatch
    * 2. Backend redirect
    */
    input logic flush
);
    import fe_pkg::*;
    localparam int unsigned PTR_W = FTQ_NUM_ENTRIES;  // one-hot pointer width
    localparam int unsigned IDX_W = $clog2(FTQ_NUM_ENTRIES);  // storage index width

    localparam logic [PTR_W-1:0] PTR_RESET = {{(PTR_W - 1) {1'b0}}, 1'b1};

    // queue write/read ptr(implemented as one-hot code)
    logic [PTR_W - 1:0] wptr;
    logic [PTR_W - 1:0] rptr;

    // per-entry valid bitmap (set on write, cleared on read / flush / tail-kill)
    logic [PTR_W - 1:0] ftq_valid;

    // Fetch Target Queue (FTQ) storage
    ftq_entry_t ftq_mem[PTR_W];

    logic w_fire;
    logic r_fire;
    logic maybe_full;

    // post-correction write suppression window
    logic [1:0] poison;
    wire poison_active = (poison != '0);

    assign rvalid = ftq_valid[ridx];
    assign wready = ~maybe_full & ~poison_active;
    assign wr_idx_oh = wptr;

    assign w_fire = wvalid && wready;
    assign r_fire = rvalid && rready;
    assign alloc  = w_fire;
    assign pop    = r_fire;

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

    assign widx = oh2idx(wptr);
    assign ridx = oh2idx(rptr);

    // correction: index of the entry after corr_idx
    wire [PTR_W-1:0] n_corr = {corr_idx[PTR_W-2:0], corr_idx[PTR_W-1]};

    assign corr_hit = corr_valid && ftq_valid[oh2idx(
        corr_idx
    )] && (ftq_mem[oh2idx(
        corr_idx
    )].start_pc == corr_start_pc);

    // combinational read: rdata is valid in the same cycle as rvalid.  An
    // in-place correction write to the read index wins (IFU must see the new
    // prediction immediately).
    assign rdata = (corr_wr_en && (corr_wr_idx == rptr)
                    && (ftq_mem[ridx].start_pc == corr_start_pc))
                 ? corr_wr_data : ftq_mem[ridx];

    // next valid bitmap: write sets, read clears, correction clears the tail
    logic [PTR_W-1:0] valid_next;
    always_comb begin
        logic [PTR_W-1:0] p;
        logic             done;
        p = n_corr;
        done = 1'b0;
        valid_next = ftq_valid;
        if (w_fire) valid_next[widx] = 1'b1;
        if (r_fire) valid_next[ridx] = 1'b0;
        if (corr_valid && corr_hit) begin
            // clear [next(corr_idx) .. wptr), then stop
            for (int i = 0; i < PTR_W; i++) begin
                if (!done) begin
                    if (p == wptr) begin
                        done = 1'b1;
                    end else begin
                        valid_next[oh2idx(p)] = 1'b0;
                        p = {p[PTR_W-2:0], p[PTR_W-1]};
                    end
                end
            end
        end
    end

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    always_comb begin
        if (wptr == rptr)
            occupancy = maybe_full ? $clog2(FTQ_NUM_ENTRIES + 1)'(FTQ_NUM_ENTRIES) : '0;
        else if (widx >= ridx) occupancy = $clog2(FTQ_NUM_ENTRIES + 1)'(widx - ridx);
        else occupancy = $clog2(FTQ_NUM_ENTRIES + 1)'(FTQ_NUM_ENTRIES + widx - ridx);
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */

    always_ff @(posedge clk) begin
        if (rst) begin
            wptr       <= PTR_RESET;
            rptr       <= PTR_RESET;
            maybe_full <= 1'b0;
            ftq_valid  <= '0;
            poison     <= '0;
        end else if (flush) begin
            wptr       <= PTR_RESET;
            rptr       <= PTR_RESET;
            maybe_full <= 1'b0;
            ftq_valid  <= '0;
            poison     <= '0;
        end else begin
            ftq_valid <= valid_next;

            // poison countdown (2 cycles after a correction)
            if (corr_valid && corr_hit) poison <= 2'b10;
            else if (poison != '0) poison <= poison - 1'b1;

            if (corr_valid && corr_hit) begin
                // tail-invalidate: roll the write pointer back to corr_idx+1
                // `maybe_full` must only be cleared when the rollback actually
                // frees entries; if nothing is discarded (n_corr == wptr) the
                // queue keeps its full state, otherwise the subsequent writes
                // would wrap around and clobber still-unread entries.
                wptr       <= n_corr;
                maybe_full <= (n_corr == wptr) ? maybe_full : 1'b0;
                if (r_fire) rptr <= n_rptr;
            end else begin
                unique case ({
                    w_fire, r_fire
                })
                    2'b10:   maybe_full <= (n_wptr == rptr) ? 1'b1 : maybe_full;
                    2'b01:   maybe_full <= 1'b0;
                    default: maybe_full <= maybe_full;
                endcase
                if (w_fire) wptr <= n_wptr;
                if (r_fire) rptr <= n_rptr;
            end

            if (w_fire) ftq_mem[widx] <= wdata;
            if (corr_wr_en && ftq_valid[oh2idx(
                    corr_wr_idx
                )] && (ftq_mem[oh2idx(
                    corr_wr_idx
                )].start_pc == corr_start_pc)) begin
                ftq_mem[oh2idx(corr_wr_idx)] <= corr_wr_data;
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
