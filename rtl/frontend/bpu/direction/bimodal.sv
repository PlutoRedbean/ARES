// 2-bit saturating-bm_pht direction predictor (Bimodal).
//
// Target prediction lives in bpu/target/ubtb.sv; this module only answers
// "taken / not-taken" and is 1-cycle pipelined so it lines up with the BTB.
//
// Because the front-end is 4-wide, a fetch request starts at a block base but
// the CFI the BTB reports can sit in any of the FETCH_WIDTH slots of the
// window.  The predictor therefore returns the direction of every slot (four
// consecutive PHT entries) and the BPU selects the one that belongs to the
// predicted CFI; this keeps the lookup index identical to the per-CFI training
// index.
/* verilator lint_off UNUSEDSIGNAL */
module bimodal #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned PHT_WIDTH  = 4
) (
    input logic clk,
    input logic rst,

    // predict port
    input  logic                            req_valid,
    input        [        ADDR_WIDTH - 1:0] fetch_pc,
    output logic                            resp_valid,
    output logic [fe_pkg::FETCH_WIDTH-1:0] pred_taken_slots,

    // update port
    input logic                    update_en,
    input       [ADDR_WIDTH - 1:0] update_pc,
    input logic                    actual_taken
);
    import fe_pkg::*;

    localparam int unsigned ENTRIES = 1 << PHT_WIDTH;

    localparam logic [1:0] STK = 2'b11;
    localparam logic [1:0] WTK = 2'b10;
    localparam logic [1:0] WNTK = 2'b01;
    localparam logic [1:0] SNTK = 2'b00;

    (* ram_style = "distributed" *)
    logic [          1:0] bm_pht     [ENTRIES];

    logic [PHT_WIDTH-1:0] pred_idx;
    logic [PHT_WIDTH-1:0] update_idx;

    assign pred_idx   = fetch_pc[PHT_WIDTH+1:2];
    assign update_idx = update_pc[PHT_WIDTH+1:2];

    // 1-cycle pipelined response
    logic                  req_valid_r;
    logic [ADDR_WIDTH-1:0] req_pc_r;
    logic [           1:0] counter_r   [FETCH_WIDTH];

    assign resp_valid = req_valid_r;

    always_comb begin
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            pred_taken_slots[s] = counter_r[s][1];
        end
    end

    function automatic logic [1:0] sat_update(input logic [1:0] old_counter, input logic taken);
        case ({
            taken, old_counter
        })
            3'b100:  sat_update = WNTK;
            3'b101:  sat_update = WTK;
            3'b110:  sat_update = STK;
            3'b111:  sat_update = STK;
            3'b000:  sat_update = SNTK;
            3'b001:  sat_update = SNTK;
            3'b010:  sat_update = WNTK;
            3'b011:  sat_update = WTK;
            default: sat_update = WNTK;
        endcase
    endfunction

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            req_valid_r <= 1'b0;
            for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                counter_r[i] <= WNTK;
            end
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bm_pht[i] <= WNTK;
            end
        end else begin
            req_valid_r <= req_valid;
            req_pc_r    <= fetch_pc;
            for (i = 0; i < FETCH_WIDTH; i = i + 1) begin
                counter_r[i] <= bm_pht[pred_idx+PHT_WIDTH'(i)];
            end

            if (update_en) begin
                bm_pht[update_idx] <= sat_update(bm_pht[update_idx], actual_taken);
            end
        end
    end

    /* verilator lint_on UNUSEDSIGNAL */
endmodule
