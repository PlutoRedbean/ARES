/* verilator lint_off UNUSEDSIGNAL */
module gshare (
    input logic clk,
    input logic rst,

    // predict port
    input  logic                           req_valid,
    input  logic [ fe_pkg::ADDR_WIDTH-1:0] fetch_pc,
    output logic                           resp_valid,
    output logic [fe_pkg::FETCH_WIDTH-1:0] pred_taken_slots,
    output logic [  fe_pkg::GHR_WIDTH-1:0] pred_ghr,

    input logic [fe_pkg::GHR_WIDTH-1:0] predict_ghr,

    // update port
    input logic                          update_en,     // queued table-training event
    input logic                          is_branch,     // conditional branch: updates the PHT
    input logic [fe_pkg::ADDR_WIDTH-1:0] update_pc,
    input logic                          actual_taken,
    input logic [ fe_pkg::GHR_WIDTH-1:0] update_ghr
);

    import fe_pkg::*;

    localparam int unsigned ENTRIES = 1 << PHT_WIDTH;

    localparam logic [1:0] STK = 2'b11;
    localparam logic [1:0] WTK = 2'b10;
    localparam logic [1:0] WNTK = 2'b01;
    localparam logic [1:0] SNTK = 2'b00;

    (* ram_style = "distributed" *)
    logic [1:0] gshare_pht[ENTRIES];

    logic [PHT_WIDTH-1:0] pred_pc_idx;
    logic [PHT_WIDTH-1:0] update_pc_idx;
    logic [PHT_WIDTH-1:0] update_idx;

    assign pred_pc_idx   = fetch_pc[PHT_WIDTH+1:2];
    assign update_pc_idx = update_pc[PHT_WIDTH+1:2];
    assign update_idx    = update_pc_idx ^ PHT_WIDTH'(update_ghr);

    // 1-cycle pipelined response
    logic [ADDR_WIDTH-1:0] req_pc_r;
    logic [           1:0] counter_r [FETCH_WIDTH];

    // GHR that was used for the in-flight prediction; returned so the
    // tournament can train gshare with the exact index it predicted with
    logic [ GHR_WIDTH-1:0] req_ghr_r;

    assign pred_ghr = req_ghr_r;

    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            pred_taken_slots[s] = counter_r[s][1];
        end
    end

    // Saturating counter update

    function automatic logic [1:0] sat_update(input logic [1:0] old_counter, input logic taken);
        case ({
            taken, old_counter
        })
            3'b100: sat_update = WNTK;
            3'b101: sat_update = WTK;
            3'b110: sat_update = STK;
            3'b111: sat_update = STK;

            3'b000: sat_update = SNTK;
            3'b001: sat_update = SNTK;
            3'b010: sat_update = WNTK;
            3'b011: sat_update = WTK;

            default: sat_update = WNTK;
        endcase
    endfunction

    // Sequential logic

    always_ff @(posedge clk) begin
        if (rst) begin
            resp_valid <= 1'b0;
        end else begin
            resp_valid <= req_valid;
        end
    end

    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            req_ghr_r  <= '0;

            for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                counter_r[i] <= WNTK;
            end

            for (i = 0; i < ENTRIES; i = i + 1) begin
                gshare_pht[i] <= WNTK;
            end

        end else begin

            // -----------------------------
            // Prediction
            // -----------------------------

            if (req_valid) begin
                req_pc_r  <= fetch_pc;
                req_ghr_r <= predict_ghr;

                for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                    counter_r[i] <= gshare_pht[(pred_pc_idx+PHT_WIDTH'(i))^PHT_WIDTH'(predict_ghr)];
                end
            end

            // -----------------------------
            // Update
            // -----------------------------

            if (update_en) begin
                // only conditional branches train the PHT
                if (is_branch) begin
                    gshare_pht[update_idx] <= sat_update(gshare_pht[update_idx], actual_taken);
                end
            end
        end
    end

    /* verilator lint_on UNUSEDSIGNAL */
endmodule
