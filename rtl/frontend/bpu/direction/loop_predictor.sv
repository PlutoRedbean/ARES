// Loop predictor.
//
// Learns the trip count of small loops: while a branch is iterating inside its
// loop it predicts taken, and on the last iteration it predicts not-taken.
//
// Each entry carries a 2-bit confidence counter.  The loop prediction is only
// exposed to the BPU as a *high confidence* override when confidence[1] is set
// (i.e. the counter has reached at least 2).  A fresh or recently wrong entry
// therefore never overrides the base (tournament) predictor.
//
// Speculation
// -----------
// The front-end predicts blocks far ahead of the back-end, so the committed
// iteration index lags the branch being fetched.  Like the gem5 LoopPredictor
// the entry therefore keeps two counters:
//   * iter_commit : advanced when the branch resolves (used to learn the trip
//                   count and the confidence),
//   * iter_spec   : advanced when the branch is *predicted* along the fetch
//                   path (used for the prediction), and repaired to iter_commit
//                   on a redirect.
//
// The prediction path is 1-cycle pipelined so its response lines up with the
// tournament/gshare/bimodal predictors and the uBTB.
/* verilator lint_off UNUSEDSIGNAL */
module loop_predictor (
    input logic clk,
    input logic rst,

    // predict request port
    input  logic                           req_valid,
    output logic                           resp_valid,
    input  logic [fe_pkg::ADDR_WIDTH-1:0] fetch_pc,

    output logic [fe_pkg::FETCH_WIDTH-1:0] pred_taken,
    output logic [fe_pkg::FETCH_WIDTH-1:0] pred_valid,
    output logic [fe_pkg::FETCH_WIDTH-1:0] pred_high_conf,

    // speculative iteration update along the predicted fetch block
    input logic                            spec_valid,
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_branch,     // conditional branch slot
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_on_path,    // before the first taken CFI
    input logic [fe_pkg::FETCH_WIDTH-1:0] spec_pred_taken, // final direction of the slot

    // redirect: repair the speculative iteration counters
    input logic flush,

    // training
    input logic                           update_en,
    input logic [fe_pkg::ADDR_WIDTH-1:0] update_pc,
    input logic                           actual_taken,
    input logic                           is_branch
);
    import fe_pkg::*;

    localparam int unsigned IDX_WIDTH = $clog2(LOOP_ENTRIES);
    localparam int unsigned TAG_WIDTH = ADDR_WIDTH - IDX_WIDTH - 2;

    localparam logic [1:0] CONF_SAT = 2'b11;

    typedef struct packed {
        logic                       valid;
        logic [TAG_WIDTH-1:0]       tag;
        logic [LOOP_ITER_WIDTH-1:0] num_iter;     // learned trip count
        logic [LOOP_ITER_WIDTH-1:0] iter_commit;  // architectural iteration index
        logic [LOOP_ITER_WIDTH-1:0] iter_spec;    // speculative iteration index
        logic [1:0]                 confidence;   // 2-bit confidence counter
    } loop_entry_t;

    loop_entry_t                                        loop_table  [LOOP_ENTRIES];

    // Combinational read of the four slots of the current fetch block.
    logic        [FETCH_WIDTH-1:0]                      hit;
    logic        [FETCH_WIDTH-1:0][      IDX_WIDTH-1:0] pred_idx;
    logic        [FETCH_WIDTH-1:0][LOOP_ITER_WIDTH-1:0] num_iter_r;
    logic        [FETCH_WIDTH-1:0][LOOP_ITER_WIDTH-1:0] iter_spec_r;
    logic        [FETCH_WIDTH-1:0][                1:0] conf_r;

    generate
        for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_read
            wire [ADDR_WIDTH-1:0] slot_pc = fetch_pc + i * INST_BYTES;
            wire [ IDX_WIDTH-1:0] idx = slot_pc[IDX_WIDTH+1:2];
            wire [ TAG_WIDTH-1:0] tag = slot_pc[ADDR_WIDTH-1:IDX_WIDTH+2];

            assign hit[i] = loop_table[idx].valid && (loop_table[idx].tag == tag);
            assign pred_idx[i] = idx;
            assign num_iter_r[i] = loop_table[idx].num_iter;
            assign iter_spec_r[i] = loop_table[idx].iter_spec;
            assign conf_r[i] = loop_table[idx].confidence;
        end
    endgenerate

    logic [ ADDR_WIDTH-1:0]                      req_pc_r;

    // The speculative update of a block runs one cycle after its request, in
    // lock-step with the uBTB's per-slot CFI information.  The entry lookup it
    // needs is exactly the one performed for the prediction, so the read
    // results are pipelined here instead of re-reading the table combinationally
    // (which kept the request PC -> table read -> write path critical).
    logic [FETCH_WIDTH-1:0]                      spec_hit_r;
    logic [FETCH_WIDTH-1:0][      IDX_WIDTH-1:0] spec_idx_r;
    logic [FETCH_WIDTH-1:0][LOOP_ITER_WIDTH-1:0] spec_iter_r;

    // Registered response, one cycle after the request.
    always_ff @(posedge clk) begin
        if (rst) begin
            resp_valid     <= 1'b0;
            pred_valid     <= '0;
            pred_taken     <= '0;
            pred_high_conf <= '0;
            req_pc_r       <= '0;
            spec_hit_r     <= '0;
            spec_idx_r     <= '0;
            spec_iter_r    <= '0;
        end else begin
            resp_valid <= req_valid;
            req_pc_r <= fetch_pc;

            spec_hit_r <= hit;
            spec_idx_r <= pred_idx;
            spec_iter_r <= iter_spec_r;

            for (int i = 0; i < FETCH_WIDTH; i++) begin
                pred_valid[i] <= req_valid && hit[i] && (num_iter_r[i] != 0);
                pred_taken[i] <= req_valid && hit[i] && (num_iter_r[i] != 0)
                                 && (iter_spec_r[i] < num_iter_r[i] - 1'b1);
                pred_high_conf[i] <= req_valid && hit[i] && conf_r[i][1];
            end
        end
    end

    wire [IDX_WIDTH-1:0] upd_idx = update_pc[IDX_WIDTH+1:2];
    wire [TAG_WIDTH-1:0] upd_tag = update_pc[ADDR_WIDTH-1:IDX_WIDTH+2];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int j = 0; j < LOOP_ENTRIES; j++) begin
                loop_table[j] <= '0;
            end
        end else begin

            // ------------------------------------------------------------
            // 1) speculative iteration advance along the predicted path
            // ------------------------------------------------------------
            if (spec_valid) begin
                for (int s = 0; s < FETCH_WIDTH; s++) begin
                    if (spec_branch[s] && spec_on_path[s] && spec_hit_r[s]) begin
                        if (spec_pred_taken[s]) begin
                            loop_table[spec_idx_r[s]].iter_spec <= spec_iter_r[s] + 1'b1;
                        end else begin
                            loop_table[spec_idx_r[s]].iter_spec <= '0;
                        end
                    end
                end
            end

            // ------------------------------------------------------------
            // 2) commit update: learn trip count / confidence
            // ------------------------------------------------------------
            if (update_en && is_branch) begin
                if (loop_table[upd_idx].valid && loop_table[upd_idx].tag == upd_tag) begin
                    // Train the confidence counter with the direction the loop
                    // predictor would have produced for this committed
                    // iteration.  Only entries that know a trip count count.
                    if (loop_table[upd_idx].num_iter != 0) begin
                        if ((loop_table[upd_idx].iter_commit < loop_table[upd_idx].num_iter - 1'b1)
                            == actual_taken) begin
                            if (loop_table[upd_idx].confidence != CONF_SAT) begin
                                loop_table[upd_idx].confidence <= loop_table[upd_idx].confidence + 1'b1;
                            end
                        end else begin
                            loop_table[upd_idx].confidence <= '0;
                        end
                    end

                    if (!actual_taken) begin
                        // drop out of loop, record trip count
                        if (loop_table[upd_idx].iter_commit > 0) begin
                            loop_table[upd_idx].num_iter <= loop_table[upd_idx].iter_commit + 1'b1;
                        end
                        loop_table[upd_idx].iter_commit <= '0;
                    end else begin
                        // continue in loop, increment current iteration
                        if (loop_table[upd_idx].iter_commit < {LOOP_ITER_WIDTH{1'b1}}) begin
                            loop_table[upd_idx].iter_commit <= loop_table[upd_idx].iter_commit + 1'b1;
                        end
                    end
                end else if (actual_taken) begin
                    loop_table[upd_idx].valid       <= 1'b1;
                    loop_table[upd_idx].tag         <= upd_tag;
                    loop_table[upd_idx].num_iter    <= '0;
                    loop_table[upd_idx].iter_commit <= LOOP_ITER_WIDTH'(1);
                    loop_table[upd_idx].iter_spec   <= LOOP_ITER_WIDTH'(1);
                    loop_table[upd_idx].confidence  <= '0;
                end
            end

            // ------------------------------------------------------------
            // 3) redirect: drop the speculative path, resync the counters
            // ------------------------------------------------------------
            if (flush) begin
                for (int j = 0; j < LOOP_ENTRIES; j++) begin
                    loop_table[j].iter_spec <= loop_table[j].iter_commit;
                end
            end
        end
    end
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
