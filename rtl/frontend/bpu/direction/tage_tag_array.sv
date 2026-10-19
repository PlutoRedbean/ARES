// TAGE tagged-table storage (docs/tage-design.md §6.2).
//
// One table (T1..Tn): 4 banks x 256 sets x 4 slots, true dual port.
//   * port A: registered prediction read at rd_idx (both slots of the set);
//   * port B: combinational update lookup (for tag validation) + synchronous
//             write port.
// The ports are flat (one signal per field) because Verilator cannot pass
// arrays of packed structs through module ports.
`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
module tage_tag_array (
    input logic clk,
    input logic rst,

    // port A: prediction read (registered)
    input  logic                                                                    rd_en,
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                     rd_idx,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0]                                     rd_valid,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_TAG_WIDTH-1:0]         rd_tag,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_CTR_WIDTH-1:0]         rd_ctr,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_USEFUL_WIDTH-1:0]      rd_useful,

    // port B: update lookup (combinational) + synchronous write
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                     up_idx,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0]                                     up_valid,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_TAG_WIDTH-1:0]         up_tag,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_CTR_WIDTH-1:0]         up_ctr,
    output logic [  fe_pkg::TAGE_NUM_SLOTS-1:0][fe_pkg::TAGE_USEFUL_WIDTH-1:0]      up_useful,
    input  logic                                                                    wr_en,
    input  logic [fe_pkg::TAGE_INDEX_WIDTH-1:0]                                     wr_idx,
    input  logic [fe_pkg::TAGE_SLOT_WIDTH-1:0]                                      wr_slot,
    input  logic                                                                    wr_valid,
    input  logic [fe_pkg::TAGE_TAG_WIDTH-1:0]                                       wr_tag,
    input  logic [fe_pkg::TAGE_CTR_WIDTH-1:0]                                       wr_ctr,
    input  logic [fe_pkg::TAGE_USEFUL_WIDTH-1:0]                                    wr_useful
);
    import fe_pkg::*;

    localparam int unsigned BANK_W = $clog2(TAGE_NUM_BANKS);

    (* ram_style = "block" *)
    logic [TAGE_NUM_SLOTS-1:0]                        valid_mem [TAGE_NUM_BANKS][TAGE_SETS];
    logic [TAGE_NUM_SLOTS-1:0][   TAGE_TAG_WIDTH-1:0] tag_mem   [TAGE_NUM_BANKS][TAGE_SETS];
    logic [TAGE_NUM_SLOTS-1:0][   TAGE_CTR_WIDTH-1:0] ctr_mem   [TAGE_NUM_BANKS][TAGE_SETS];
    logic [TAGE_NUM_SLOTS-1:0][TAGE_USEFUL_WIDTH-1:0] useful_mem[TAGE_NUM_BANKS][TAGE_SETS];

    integer b, s;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (b = 0; b < TAGE_NUM_BANKS; b = b + 1)
            for (s = 0; s < TAGE_SETS; s = s + 1) begin
                // Only the valid flags are reset; tag/ctr/useful arrays are
                // left alone so they can be inferred as RAM (as in icache).
                valid_mem[b][s] <= '0;
            end
            rd_valid <= '0;
            rd_tag <= '0;
            rd_ctr <= '0;
            rd_useful <= '0;
        end else begin
            if (rd_en) begin
                rd_valid  <= valid_mem [rd_idx[BANK_W-1:0]][rd_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
                rd_tag    <= tag_mem   [rd_idx[BANK_W-1:0]][rd_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
                rd_ctr    <= ctr_mem   [rd_idx[BANK_W-1:0]][rd_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
                rd_useful <= useful_mem[rd_idx[BANK_W-1:0]][rd_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
            end
            if (wr_en) begin
                valid_mem[wr_idx[BANK_W-1:0]][wr_idx[TAGE_INDEX_WIDTH-1:BANK_W]][wr_slot] <= wr_valid;
                tag_mem[wr_idx[BANK_W-1:0]][wr_idx[TAGE_INDEX_WIDTH-1:BANK_W]][wr_slot] <= wr_tag;
                ctr_mem[wr_idx[BANK_W-1:0]][wr_idx[TAGE_INDEX_WIDTH-1:BANK_W]][wr_slot] <= wr_ctr;
                useful_mem[wr_idx[BANK_W-1:0]][wr_idx[TAGE_INDEX_WIDTH-1:BANK_W]][wr_slot] <= wr_useful;
            end
        end
    end

    // Port B read is combinational so the update logic can validate the entry.
    always_comb begin
        up_valid  = valid_mem [up_idx[BANK_W-1:0]][up_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
        up_tag    = tag_mem   [up_idx[BANK_W-1:0]][up_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
        up_ctr    = ctr_mem   [up_idx[BANK_W-1:0]][up_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
        up_useful = useful_mem[up_idx[BANK_W-1:0]][up_idx[TAGE_INDEX_WIDTH-1:BANK_W]];
    end
endmodule
`endif
