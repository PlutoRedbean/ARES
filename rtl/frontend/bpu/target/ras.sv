// Return address stack (RAS).
//
// A call pushes its return address (pc+4), a return pops the top and uses it
// as the predicted target.  The top of the stack is exposed combinationally so
// the BPU can override a return's target.
//
// Speculation
// -----------
// The front-end predicts far ahead of the back-end, so the stack is updated
// *speculatively* when a call/return is predicted (at most one per predicted
// fetch block).  A redirect repairs the speculative pointer to the committed
// pointer, which is advanced only when the call/return resolves at EXU (this
// mirrors the gem5 ReturnAddrStack).  Stack contents above the committed
// pointer do not need restoring: they are overwritten by the correct path.
/* verilator lint_off UNUSEDSIGNAL */
module ras (
    input logic clk,
    input logic rst,

    // combinational top of the speculative stack (return target)
    output logic                           top_valid,
    output logic [fe_pkg::ADDR_WIDTH-1:0] top_addr,

    // speculative update along the predicted path (at most one per block)
    input logic                           spec_push,  // predicted call
    input logic                           spec_pop,   // predicted return
    input logic [fe_pkg::ADDR_WIDTH-1:0] spec_addr,  // call return address

    // request accepted: snapshot the speculative stack for later repair
    input logic                           req_valid,
    // redirect: drop speculative changes and resync to the committed stack.
    // For a branch redirect with TAGE metadata, `restore_valid` selects the
    // exact pre-block snapshot instead of the coarse committed-pointer resync.
    input logic                           flush,
    input logic                           restore_valid,
    input logic [5:0]                     restore_ptr,
    // internal S2 correction restart: the speculative path was discarded
    input logic                           corr,
    input logic [5:0]                     corr_ptr,
    input logic                           corr_push,
    input logic                           corr_pop,
    input logic [fe_pkg::ADDR_WIDTH-1:0]  corr_addr,

    // committed update when the call/return resolves
    input logic                           update_en,
    input logic                           update_push,
    input logic                           update_pop,
    input logic [fe_pkg::ADDR_WIDTH-1:0] update_addr
);
    import fe_pkg::*;
    localparam int unsigned IDX_W = (RAS_ENTRIES > 1) ? $clog2(RAS_ENTRIES) : 1;
    localparam int unsigned CNT_W = $clog2(RAS_ENTRIES + 1);
    // Mirrors fe_pkg::TAGE_CKPT_DEPTH / TAGE_CKPT_PTR_WIDTH (64 entries).
    localparam int unsigned RAS_CKPT_DEPTH = 64;
    localparam int unsigned RAS_CKPT_W     = 6;
    // Only the stack top can be read before a restored entry is overwritten by
    // a push, so a checkpoint saves just the top SNAP_ENTRIES entries instead
    // of the whole stack.  This cuts the checkpoint storage from
    // RAS_CKPT_DEPTH*RAS_ENTRIES to RAS_CKPT_DEPTH*SNAP_ENTRIES words.
    localparam int unsigned SNAP_ENTRIES   = 4;
    localparam int unsigned SNAP_W         = SNAP_ENTRIES * ADDR_WIDTH;
    // One checkpoint word: {sp, top0, top1, top2, top3}.  Packing the entries
    // into one word is what lets the snapshot array infer as a 1R1W RAM: the
    // unpacked [depth][entries] form has one write port per entry and one read
    // port per entry, which no RAM compiler can map.
    localparam int unsigned SNAP_TOTAL_W   = SNAP_W + CNT_W;

    logic [ADDR_WIDTH-1:0] ras_mem   [RAS_ENTRIES];
    logic [     CNT_W-1:0] sp_spec;
    logic [     CNT_W-1:0] sp_commit;

    // Top-of-stack speculative-state snapshots, indexed exactly like the TAGE
    // history checkpoints.  A wrong-path block can overwrite stack entries
    // below the committed pointer, so the coarse "resync to commit" alone
    // cannot repair an internal S2 redirect; the snapshot can.  Entry j holds
    // the address at depth (sp-1-j), i.e. the first entry a pop would read.
    (* ram_style = "distributed" *)
    logic [SNAP_TOTAL_W-1:0] snap_mem [RAS_CKPT_DEPTH];
    logic [SNAP_TOTAL_W-1:0] snap_wdata;
    logic [SNAP_TOTAL_W-1:0] snap_rdata;
    logic [   RAS_CKPT_W-1:0] ckpt_ptr;

    // The snapshot array is written before it is read (a checkpoint is taken
    // on every requested block), but zero-initialise it so simulation never
    // observes X on the first restore.  This is an initial, not a reset: a
    // per-entry reset loop would create one write port per checkpoint.
    initial begin
        for (int c = 0; c < RAS_CKPT_DEPTH; c++) snap_mem[c] = '0;
    end

    function automatic logic [IDX_W-1:0] snap_index(
        input logic [CNT_W-1:0] sp, input int unsigned j);
        snap_index = IDX_W'(sp - CNT_W'(j + 1));
    endfunction

    // Build the checkpoint word from the pre-update speculative state.  This
    // is the same value the old per-entry loop stored, just packed.
    always_comb begin
        snap_wdata = '0;
        snap_wdata[CNT_W-1:0] = sp_spec;
        for (int j = 0; j < SNAP_ENTRIES; j++)
            if (sp_spec > CNT_W'(j))
                snap_wdata[CNT_W + j*ADDR_WIDTH +: ADDR_WIDTH] =
                    ras_mem[snap_index(sp_spec, j)];
    end

    // Restore and corr are mutually exclusive, so they share one read port.
    wire [RAS_CKPT_W-1:0] snap_raddr =
        (flush && restore_valid) ? restore_ptr : corr_ptr;
    always_comb snap_rdata = snap_mem[snap_raddr];

    // top of the speculative stack (single dynamic read instead of a 128:1 mux)
    always_comb begin
        top_valid = (sp_spec != '0);
        top_addr  = (sp_spec != '0) ? ras_mem[IDX_W'(sp_spec - 1'b1)] : '0;
    end

    // next committed pointer (also used to resync on a redirect in the same
    // cycle the resolving call/return commits)
    logic [CNT_W-1:0] sp_commit_next;
    always_comb begin
        sp_commit_next = sp_commit;
        if (update_en) begin
            if (update_push && (sp_commit != CNT_W'(RAS_ENTRIES))) begin
                sp_commit_next = sp_commit + 1'b1;
            end else if (update_pop && (sp_commit != '0)) begin
                sp_commit_next = sp_commit - 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sp_spec   <= '0;
            sp_commit <= '0;
            ckpt_ptr  <= '0;
            // Do not reset the content of ras_mem / snap_mem here.  A
            // synchronous reset of the whole snapshot array unrolls into
            // thousands of memory write ports.  Both arrays are written before
            // they are read: entries below sp are always pushed, and a
            // checkpoint is snapshotted before it can be restored.
        end else begin
            // committed update (architecturally correct even if a redirect
            // happens in the same cycle)
            if (update_en && update_push && (sp_commit != CNT_W'(RAS_ENTRIES))) begin
                ras_mem[sp_commit[IDX_W-1:0]] <= update_addr;
            end
            sp_commit <= sp_commit_next;

            if (flush && restore_valid) begin
                // Restore the top of the speculative state before the resolving
                // block, then apply the actual call/return on this path.
                for (int j = 0; j < SNAP_ENTRIES; j++)
                    if (snap_rdata[CNT_W-1:0] > CNT_W'(j))
                        ras_mem[snap_index(snap_rdata[CNT_W-1:0], j)]
                            <= snap_rdata[CNT_W + j*ADDR_WIDTH +: ADDR_WIDTH];
                if (update_en && update_push
                    && (snap_rdata[CNT_W-1:0] != CNT_W'(RAS_ENTRIES))) begin
                    ras_mem[snap_rdata[IDX_W-1:0]] <= update_addr;
                    sp_spec <= snap_rdata[CNT_W-1:0] + 1'b1;
                end else if (update_en && update_pop
                             && (snap_rdata[CNT_W-1:0] != '0)) begin
                    sp_spec <= snap_rdata[CNT_W-1:0] - 1'b1;
                end else begin
                    sp_spec <= snap_rdata[CNT_W-1:0];
                end
                ckpt_ptr <= restore_ptr;
            end else if (flush) begin
                // Architectural redirect: resync the pointer to the committed
                // stack.  The checkpoint pointer keeps counting (same as TAGE).
                sp_spec <= sp_commit_next;
            end else if (corr) begin
                // Internal S2 restart: restore before the corrected block and
                // apply that block's final (merged) call/return.
                for (int j = 0; j < SNAP_ENTRIES; j++)
                    if (snap_rdata[CNT_W-1:0] > CNT_W'(j))
                        ras_mem[snap_index(snap_rdata[CNT_W-1:0], j)]
                            <= snap_rdata[CNT_W + j*ADDR_WIDTH +: ADDR_WIDTH];
                if (corr_push && (snap_rdata[CNT_W-1:0] != CNT_W'(RAS_ENTRIES))) begin
                    ras_mem[snap_rdata[IDX_W-1:0]] <= corr_addr;
                    sp_spec <= snap_rdata[CNT_W-1:0] + 1'b1;
                end else if (corr_pop && (snap_rdata[CNT_W-1:0] != '0)) begin
                    sp_spec <= snap_rdata[CNT_W-1:0] - 1'b1;
                end else begin
                    sp_spec <= snap_rdata[CNT_W-1:0];
                end
                ckpt_ptr <= corr_ptr;
            end else begin
                // speculative update along the predicted path
                if (spec_push && (sp_spec != CNT_W'(RAS_ENTRIES))) begin
                    ras_mem[sp_spec[IDX_W-1:0]] <= spec_addr;
                    sp_spec <= sp_spec + 1'b1;
                end else if (spec_pop && (sp_spec != '0)) begin
                    sp_spec <= sp_spec - 1'b1;
                end

                // Snapshot for the block being requested.  This mirrors the
                // TAGE checkpoint push (and its pointer rollback on restart).
                if (req_valid) begin
                    snap_mem[ckpt_ptr] <= snap_wdata;
                    ckpt_ptr <= ckpt_ptr + 1'b1;
                end
            end
        end
    end
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
