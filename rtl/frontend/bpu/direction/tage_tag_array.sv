// TAGE tagged-table storage (docs/tage-design.md §6.2).
//
// One table (T1..Tn): 1 << TAGE_INDEX_WIDTH sets, TAGE_NUM_SLOTS entries per
// set.  The bank bits are part of the flattened set index; they are not
// separate memories.
//
// Storage layout
// --------------
// Each set is one packed word: {slot[3], slot[2], slot[1], slot[0]}, where a
// slot is {valid, tag, ctr, useful}.  Two identical copies are kept:
//   * pred_mem: synchronous prediction read (port A);
//   * upd_mem : synchronous update read (port B).
// Writes are broadcast to both copies.  Each copy is a simple dual-port
// (1R1W) memory, so the arrays map to BRAM instead of flip-flops.
//
// The update read is deliberately registered.  Training is off the critical
// path, so a one-cycle read latency is free; it also removes the asynchronous
// second read port that prevented BRAM inference.  A one-entry bypass forwards
// the previous write into the current update read, which keeps back-to-back
// updates to the same set/slot correct.
//
// The data arrays are not reset on rst.  They are zero-initialised once via
// `initial` (FPGA/Verilator).  For an ASIC flow, replace this with an init FSM
// that writes zero words through the write port; do NOT reset the array with a
// per-entry for-loop, which creates one write port per entry.
`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
module tage_tag_array (
    input logic clk,
    input logic rst,

    // port A: prediction read (registered)
    input  logic                                                               rd_en,
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                rd_idx,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0]                                rd_valid,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_TAG_WIDTH-1:0]    rd_tag,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_CTR_WIDTH-1:0]    rd_ctr,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_USEFUL_WIDTH-1:0] rd_useful,

    // port B: update read (registered) + synchronous write
    input  logic                                                               up_rd_en,
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                up_idx,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0]                                up_valid,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_TAG_WIDTH-1:0]    up_tag,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_CTR_WIDTH-1:0]    up_ctr,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_USEFUL_WIDTH-1:0] up_useful,
    input  logic                                                               wr_en,
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                wr_idx,
    input  logic [fe_pkg::TAGE_SLOT_WIDTH-1:0]                                 wr_slot,
    input  logic                                                               wr_valid,
    input  logic [fe_pkg::TAGE_TAG_WIDTH-1:0]                                  wr_tag,
    input  logic [fe_pkg::TAGE_CTR_WIDTH-1:0]                                  wr_ctr,
    input  logic [fe_pkg::TAGE_USEFUL_WIDTH-1:0]                               wr_useful
);
    import fe_pkg::*;

    localparam int unsigned ENTRY_W = 1 + TAGE_TAG_WIDTH + TAGE_CTR_WIDTH + TAGE_USEFUL_WIDTH;
    localparam int unsigned SET_W   = TAGE_NUM_SLOTS * ENTRY_W;
    localparam int unsigned DEPTH   = 1 << TAGE_INDEX_WIDTH;

    // Two copies so prediction and update each get an independent synchronous
    // read port while a write is broadcast to both.
    (* ram_style = "block" *)
    logic [SET_W-1:0] pred_mem [DEPTH];
    (* ram_style = "block" *)
    logic [SET_W-1:0] upd_mem  [DEPTH];

    logic [SET_W-1:0] rd_set_r;
    logic [SET_W-1:0] up_set_r;
    logic [SET_W-1:0] up_set_eff;
    logic [SET_W-1:0] wr_set;

    // One-entry update bypass (previous write -> current update read).
    logic                        prev_wr_en;
    logic [TAGE_INDEX_WIDTH-1:0] prev_wr_idx;
    logic [TAGE_SLOT_WIDTH-1:0]  prev_wr_slot;
    logic [ENTRY_W-1:0]          prev_wr_entry;
    logic [TAGE_INDEX_WIDTH-1:0] up_idx_r;

    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            pred_mem[i] = '0;
            upd_mem[i]  = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_set_r      <= '0;
            up_set_r      <= '0;
            prev_wr_en    <= 1'b0;
            prev_wr_idx   <= '0;
            prev_wr_slot  <= '0;
            prev_wr_entry <= '0;
            up_idx_r      <= '0;
        end else begin
            if (rd_en) begin
                // Forward a same-set write to the prediction read.  The
                // tagged-table update is one cycle behind the commit event
                // (registered update read); without this bypass a prediction
                // in the write cycle would see the stale entry for one extra
                // cycle and lose accuracy relative to the unpipelined design.
                if (wr_en && (wr_idx == rd_idx))
                    rd_set_r <= wr_set;
                else
                    rd_set_r <= pred_mem[rd_idx];
            end
            if (up_rd_en) up_set_r <= upd_mem[up_idx];

            prev_wr_en    <= wr_en;
            prev_wr_idx   <= wr_idx;
            prev_wr_slot  <= wr_slot;
            prev_wr_entry <= {wr_valid, wr_tag, wr_ctr, wr_useful};
            if (up_rd_en) up_idx_r <= up_idx;

            if (wr_en) begin
                pred_mem[wr_idx] <= wr_set;
                upd_mem[wr_idx]  <= wr_set;
            end
        end
    end

    // The write index is always the same table index that produced the update
    // read (tage.sv writes m.idx[t] and reads m.idx[t]), so up_set_eff is the
    // current set for wr_idx.
    //
    // Keep the bypass merge in its own always_comb block.  `wr_set` depends on
    // `wr_slot`, which is produced by the training logic from `up_*`; sharing
    // one block with `up_set_eff` makes Verilator see a false combinational
    // loop from up_set_eff back through the update logic.
    always_comb begin
        up_set_eff = up_set_r;
        if (prev_wr_en && (prev_wr_idx == up_idx_r))
            up_set_eff[prev_wr_slot*ENTRY_W +: ENTRY_W] = prev_wr_entry;
    end

    // Merge the new slot into the current set for the write.
    always_comb begin
        wr_set = up_set_eff;
        wr_set[wr_slot*ENTRY_W +: ENTRY_W] = {wr_valid, wr_tag, wr_ctr, wr_useful};
    end

    // Unpack the prediction set (previous cycle's pred_mem read).
    always_comb begin
        for (int s = 0; s < TAGE_NUM_SLOTS; s++) begin
            rd_valid[s]  = rd_set_r[s*ENTRY_W + TAGE_TAG_WIDTH + TAGE_CTR_WIDTH
                                    + TAGE_USEFUL_WIDTH];
            rd_tag[s]    = rd_set_r[s*ENTRY_W + TAGE_CTR_WIDTH + TAGE_USEFUL_WIDTH
                                    +: TAGE_TAG_WIDTH];
            rd_ctr[s]    = rd_set_r[s*ENTRY_W + TAGE_USEFUL_WIDTH +: TAGE_CTR_WIDTH];
            rd_useful[s] = rd_set_r[s*ENTRY_W +: TAGE_USEFUL_WIDTH];
        end
    end

    // Unpack the bypassed update set.
    always_comb begin
        for (int s = 0; s < TAGE_NUM_SLOTS; s++) begin
            up_valid[s]  = up_set_eff[s*ENTRY_W + TAGE_TAG_WIDTH + TAGE_CTR_WIDTH
                                      + TAGE_USEFUL_WIDTH];
            up_tag[s]    = up_set_eff[s*ENTRY_W + TAGE_CTR_WIDTH + TAGE_USEFUL_WIDTH
                                      +: TAGE_TAG_WIDTH];
            up_ctr[s]    = up_set_eff[s*ENTRY_W + TAGE_USEFUL_WIDTH +: TAGE_CTR_WIDTH];
            up_useful[s] = up_set_eff[s*ENTRY_W +: TAGE_USEFUL_WIDTH];
        end
    end
endmodule
`endif
