//=============================================================================
// ARES backend - Branch Map Checkpoint (B05)
//-----------------------------------------------------------------------------
// One frozen 32-entry Producer Map snapshot per in-flight control transfer,
// indexed by CIQ slot (backend.md 15.2/15.3; plan section 5.5).
//
//   * a snapshot is written only when the CFI is successfully dispatched, and
//     it already contains the effect of the CFI's own rd (JAL/JALR link);
//   * it never changes afterwards - commit does not repair it;
//   * it is released when the branch commits normally or is squashed;
//   * the restore read port returns the raw frozen row; the validity check
//     against the surviving CIQ entries lives in be_flush (backend.md 15.3).
//
// FREE items: FREE-09 (register-array storage and two write ports).
//=============================================================================
module be_checkpoint (
    input  logic                    clk,
    input  logic                    rst,

    //---- snapshot write from dispatch (lane 0 / lane 1) --------------------
    input  logic [1:0]              cp_we,
    input  ares_pkg::tag_t                    cp_wslot [2],
    input  logic [31:0]             cp_wvalid [2],
    input  ares_pkg::tag_t                    cp_wtag [2][32],

    //---- release: CFI committed or squashed --------------------------------
    input  logic [ares_pkg::CIQ_ENTRIES-1:0]  cp_release,

    //---- raw row read for restore validation -------------------------------
    input  ares_pkg::tag_t                    rd_slot,
    output logic [31:0]             cp_rvalid,
    output ares_pkg::tag_t                    cp_rtag [32],

    //---- assertion visibility ----------------------------------------------
    output logic [ares_pkg::CIQ_ENTRIES-1:0]  cp_valid_out
);
    import ares_pkg::*;

    logic [31:0] cp_valid_q [CIQ_ENTRIES];
    tag_t        cp_tag_q   [CIQ_ENTRIES][32];

    logic [CIQ_ENTRIES-1:0] slot_hit0, slot_hit1;
    always_comb begin
        slot_hit0 = '0;
        slot_hit1 = '0;
        if (cp_we[0]) slot_hit0[cp_wslot[0].slot_index] = 1'b1;
        if (cp_we[1]) slot_hit1[cp_wslot[1].slot_index] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
                cp_valid_q[i] <= 32'd0;
                for (int unsigned r = 0; r < 32; r++) cp_tag_q[i][r] <= '0;
            end
        end else begin
            for (int unsigned i = 0; i < CIQ_ENTRIES; i++) begin
                if (cp_release[i]) cp_valid_q[i] <= 32'd0;   // write below wins
                if (slot_hit0[i]) cp_valid_q[i] <= cp_wvalid[0];
                if (slot_hit1[i]) cp_valid_q[i] <= cp_wvalid[1];
                for (int unsigned r = 0; r < 32; r++) begin
                    if (r == 0) begin
                        cp_valid_q[i][0] <= 1'b0;            // x0 is never a producer
                    end
                    if (slot_hit0[i]) cp_tag_q[i][r] <= cp_wtag[0][r];
                    if (slot_hit1[i]) cp_tag_q[i][r] <= cp_wtag[1][r];
                end
            end
        end
    end

    always_comb begin
        cp_rvalid = cp_valid_q[rd_slot.slot_index];
        for (int unsigned r = 0; r < 32; r++) cp_rtag[r] = cp_tag_q[rd_slot.slot_index][r];
        for (int unsigned i = 0; i < CIQ_ENTRIES; i++) cp_valid_out[i] = |cp_valid_q[i];
    end
endmodule
