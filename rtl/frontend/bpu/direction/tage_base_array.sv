// TAGE base table T0 (docs/tage-design.md §6.1).
//
// 4 banks x 1024 entries x 2-bit saturating counter, banked by instruction
// slot.  Prediction reads all banks in one cycle (registered); the update write
// port is one bank/index per cycle.
`include "ares_autoconf.vh"
`ifdef CONFIG_FE_TAGE
module tage_base_array (
    input logic clk,
    input logic rst,

    input  logic                                                                      rd_en,
    input  logic [fe_pkg::TAGE_BASE_NUM_BANKS-1:0][fe_pkg::TAGE_BASE_INDEX_WIDTH-1:0] rd_idx,
    output logic [fe_pkg::TAGE_BASE_NUM_BANKS-1:0][                              1:0] rd_ctr,

    input logic                                     wr_en,
    input logic [   fe_pkg::TAGE_SLOT_ID_WIDTH-1:0] wr_bank,
    input logic [fe_pkg::TAGE_BASE_INDEX_WIDTH-1:0] wr_idx,
    input logic [                              1:0] wr_ctr
);
    import fe_pkg::*;

    (* ram_style = "distributed" *)
    logic [1:0] mem[TAGE_BASE_NUM_BANKS][TAGE_BASE_ENTRIES_PER_BANK];

    integer b;
    always_ff @(posedge clk) begin
        if (rst) begin
            // The base counters are data, not flags: do not reset the array
            // (it should be inferred as RAM).  Only the output register is
            // reset; Verilator zero-initialises the counters to SNTK.
            rd_ctr <= '0;
        end else begin
            if (rd_en)
                for (b = 0; b < TAGE_BASE_NUM_BANKS; b = b + 1) rd_ctr[b] <= mem[b][rd_idx[b]];
            if (wr_en) mem[wr_bank][wr_idx] <= wr_ctr;
        end
    end
endmodule
`endif
