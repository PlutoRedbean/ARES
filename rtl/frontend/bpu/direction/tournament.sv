// Tournament branch direction predictor.
//
// Combines:
//   1. Gshare
//   2. Bimodal
//
// The tournament predictor maintains a 2-bit chooser counter per PC:
//
//   2'b00 / 2'b01 : choose Bimodal
//   2'b10 / 2'b11 : choose Gshare
//
// The prediction path is 1-cycle pipelined.
//
// For FETCH_WIDTH consecutive slots, each slot has its own chooser
// prediction, corresponding to the PC of that slot.

module tournament #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CHOOSER_WIDTH = 10
) (
    input logic clk,
    input logic rst,

    // predict

    input logic                  req_valid,
    input logic [ADDR_WIDTH-1:0] fetch_pc,

    output logic                  resp_valid,
    output logic [ADDR_WIDTH-1:0] resp_pc,

    output logic                   [fe_pkg::FETCH_WIDTH-1:0] pred_taken_slots,
    output fe_pkg::chooser_meta_t [fe_pkg::FETCH_WIDTH-1:0] chooser_meta,

    // speculative history control (forwarded to gshare)
    input logic                                      flush,
    input logic                                      spec_valid,
    input logic [$clog2(fe_pkg::FETCH_WIDTH+1)-1:0] spec_num,
    input logic                                      spec_taken,

    // update

    input logic                  update_en,    // any CFI: advances the GHR
    input logic                  is_branch,    // conditional branch: trains the tables
    input logic [ADDR_WIDTH-1:0] update_pc,
    input logic                  actual_taken,

    input logic update_gshare_taken,
    input logic update_bimodal_taken,
    input logic [fe_pkg::GHR_WIDTH-1:0] update_ghr
);

    import fe_pkg::*;

    localparam int unsigned ENTRIES = 1 << CHOOSER_WIDTH;

    typedef enum logic [1:0] {
        SBM = 2'b00,  // Strongly prefer Bimodal
        WBM = 2'b01,  // Weakly prefer Bimodal
        WG  = 2'b10,  // Weakly prefer Gshare
        SG  = 2'b11   // Strongly prefer Gshare
    } chooser_state_t;

    // chooser counters for the four consecutive slots
    chooser_state_t                   chooser_slots_r [FETCH_WIDTH];

    (* ram_style = "distributed" *)
    chooser_state_t                   chooser_pht     [    ENTRIES];

    // ------------------------------------------------------------
    // Instantiate component predictors
    // ------------------------------------------------------------

    logic           [FETCH_WIDTH-1:0] gshare_pred;
    logic           [FETCH_WIDTH-1:0] bimodal_pred;

    // Gshare additionally returns GHR information, but it is not
    // needed by the tournament selector itself.
    logic           [  GHR_WIDTH-1:0] gshare_pred_ghr;

    /* verilator lint_off PINCONNECTEMPTY */
    gshare #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_gshare (
        .clk(clk),
        .rst(rst),

        .req_valid(req_valid),
        .fetch_pc (fetch_pc),

        .resp_valid      (),
        .pred_taken_slots(gshare_pred),
        .pred_ghr        (gshare_pred_ghr),

        .flush     (flush),
        .spec_valid(spec_valid),
        .spec_num  (spec_num),
        .spec_taken(spec_taken),

        .update_en   (update_en),
        .is_branch   (is_branch),
        .update_pc   (update_pc),
        .actual_taken(actual_taken),
        .update_ghr  (update_ghr)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    /* verilator lint_off PINCONNECTEMPTY */
    bimodal #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .PHT_WIDTH (PHT_WIDTH)
    ) u_bimodal (
        .clk(clk),
        .rst(rst),

        .req_valid(req_valid),
        .fetch_pc (fetch_pc),

        .resp_valid      (),
        .pred_taken_slots(bimodal_pred),

        .update_en   (update_en && is_branch),
        .update_pc   (update_pc),
        .actual_taken(actual_taken)
    );
    /* verilator lint_on PINCONNECTEMPTY */


    // Chooser lookup
    logic [CHOOSER_WIDTH-1:0] pred_base_idx;

    assign pred_base_idx = fetch_pc[CHOOSER_WIDTH+1:2];

    // Metadata captured with each prediction so that the chooser and its
    // components can be trained with the state they actually used:
    //   - gshare_pred / bimodal_pred : the two component predictions
    //   - pred_ghr                   : the GHR gshare indexed with
    fe_pkg::chooser_meta_t [fe_pkg::FETCH_WIDTH-1:0] chooser_meta_out;

    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            chooser_meta_out[s] = '{
                update_gshare_taken: gshare_pred[s],
                update_bimodal_taken: bimodal_pred[s],
                pred_ghr: gshare_pred_ghr
            };
        end
    end

    assign chooser_meta = chooser_meta_out;
    // ------------------------------------------------------------
    // 1-cycle prediction pipeline
    // ------------------------------------------------------------

    logic                  req_valid_r;
    logic [ADDR_WIDTH-1:0] req_pc_r;

    assign resp_valid = req_valid_r;
    assign resp_pc    = req_pc_r;

    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            case (chooser_slots_r[s])
                SBM, WBM: begin
                    pred_taken_slots[s] = bimodal_pred[s];
                end

                WG, SG: begin
                    pred_taken_slots[s] = gshare_pred[s];
                end

                default: begin
                    pred_taken_slots[s] = bimodal_pred[s];
                end
            endcase
        end
    end


    function automatic chooser_state_t chooser_update(
        input chooser_state_t old_state, input logic gshare_taken, input logic bimodal_taken,
        input logic resolved_taken);

        logic gshare_correct;
        logic bimodal_correct;

        begin
            gshare_correct  = (gshare_taken == resolved_taken);
            bimodal_correct = (bimodal_taken == resolved_taken);

            case ({
                gshare_correct, bimodal_correct
            })

                // Both correct.
                2'b11: chooser_update = old_state;

                // Gshare correct, Bimodal wrong.
                2'b10: begin
                    case (old_state)
                        SBM: chooser_update = WBM;
                        WBM: chooser_update = WG;
                        WG: chooser_update = SG;
                        SG: chooser_update = SG;
                        default: chooser_update = WG;
                    endcase
                end

                // Bimodal correct, Gshare wrong.
                2'b01: begin
                    case (old_state)
                        SBM: chooser_update = SBM;
                        WBM: chooser_update = SBM;
                        WG: chooser_update = WBM;
                        SG: chooser_update = WG;
                        default: chooser_update = WBM;
                    endcase
                end

                // Both wrong.
                2'b00: chooser_update = old_state;

                default: chooser_update = old_state;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // sequential Logic
    // ------------------------------------------------------------

    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin

            req_valid_r <= 1'b0;
            req_pc_r    <= '0;

            // Weakly prefer Bimodal initially.
            for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                chooser_slots_r[i] <= WBM;
            end

            for (i = 0; i < ENTRIES; i = i + 1) begin
                chooser_pht[i] <= WBM;
            end

        end else begin
            req_valid_r <= req_valid;
            req_pc_r    <= fetch_pc;

            for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                chooser_slots_r[i] <= chooser_pht[pred_base_idx+CHOOSER_WIDTH'(i)];
            end

            // Chooser update (conditional branches only); read-modify-write at
            // update time so a shared entry is never clobbered by an older
            // in-flight prediction.
            if (update_en && is_branch) begin
                chooser_pht[update_pc[CHOOSER_WIDTH+1:2]] <= chooser_update(
                    chooser_pht[update_pc[CHOOSER_WIDTH+1:2]],
                    update_gshare_taken,
                    update_bimodal_taken,
                    actual_taken
                );

            end
        end
    end

endmodule
