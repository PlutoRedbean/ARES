`include "autoconf.vh"

module BimodalRas#(parameter ADDR_WIDTH=32, parameter BTB_WIDTH=4, parameter DATA_WIDTH=32)(
    input                     clk,
    input                     rst,

    input                     req_valid,
    input  [ADDR_WIDTH - 1:0] fetch_pc,
    output                    resp_valid,
    output [ADDR_WIDTH - 1:0] resp_pc,
    output                    pred_taken,
    output [ADDR_WIDTH - 1:0] pred_target_pc,
    output                    btb_hit,
    output                    pred_is_return,

    input                     update_en,
    input  [ADDR_WIDTH - 1:0] update_pc,
    input                     update_is_return,
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    input                     update_is_branch,
`endif
    input  [ADDR_WIDTH - 1:0] update_target,
    input                     actual_taken
);

    localparam STK  = 2'b11;
    localparam WTK  = 2'b10;
    localparam WNTK = 2'b01;
    localparam SNTK = 2'b00;

    localparam ENTRIES = 1 << BTB_WIDTH;
    localparam TAG_WIDTH = ADDR_WIDTH - BTB_WIDTH - 2;

    (* ram_style = "distributed" *) reg valid [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [TAG_WIDTH-1:0] tag [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [ADDR_WIDTH-1:0] target [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [1:0] counter [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg is_return [0:ENTRIES-1];

    wire [BTB_WIDTH-1:0] pred_idx = fetch_pc[BTB_WIDTH+1:2];
    wire [BTB_WIDTH-1:0] update_idx = update_pc[BTB_WIDTH+1:2];
    wire [TAG_WIDTH-1:0] update_tag = update_pc[ADDR_WIDTH-1:BTB_WIDTH+2];
    wire [TAG_WIDTH-1:0] pred_tag = fetch_pc[ADDR_WIDTH-1:BTB_WIDTH+2];

    reg req_valid_r;
    reg [ADDR_WIDTH-1:0] req_pc_r;
    reg valid_r;
    reg [TAG_WIDTH-1:0] pred_tag_r;
    reg [TAG_WIDTH-1:0] tag_r;
    reg [ADDR_WIDTH-1:0] target_r;
    reg [1:0] counter_r;
    reg is_return_r;

    wire pred_hit = valid_r && (tag_r == pred_tag_r);

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    // Direct-mapped loop table, read in parallel with the Bimodal BTB.
    localparam LOOP_INDEX_WIDTH = 4;
    localparam LOOP_COUNT_WIDTH = 16;
    localparam LOOP_ENTRIES = 1 << LOOP_INDEX_WIDTH;
    localparam LOOP_TAG_WIDTH = ADDR_WIDTH - LOOP_INDEX_WIDTH - 2;

    reg                        loop_valid       [0:LOOP_ENTRIES-1];
    reg [LOOP_TAG_WIDTH-1:0]   loop_tag         [0:LOOP_ENTRIES-1];
    reg [LOOP_COUNT_WIDTH-1:0] loop_trip_count  [0:LOOP_ENTRIES-1];
    reg [LOOP_COUNT_WIDTH-1:0] loop_iter_count  [0:LOOP_ENTRIES-1];
    reg [1:0]                  loop_confidence  [0:LOOP_ENTRIES-1];
    reg                        loop_prediction  [0:LOOP_ENTRIES-1];

    wire [LOOP_INDEX_WIDTH-1:0] loop_pred_idx =
        fetch_pc[LOOP_INDEX_WIDTH+1:2];
    wire [LOOP_INDEX_WIDTH-1:0] loop_update_idx =
        update_pc[LOOP_INDEX_WIDTH+1:2];
    wire [LOOP_TAG_WIDTH-1:0] loop_pred_tag =
        fetch_pc[ADDR_WIDTH-1:LOOP_INDEX_WIDTH+2];
    wire [LOOP_TAG_WIDTH-1:0] loop_update_tag =
        update_pc[ADDR_WIDTH-1:LOOP_INDEX_WIDTH+2];
    wire loop_update_hit = loop_valid[loop_update_idx] &&
        (loop_tag[loop_update_idx] == loop_update_tag);
    wire [LOOP_COUNT_WIDTH-1:0] loop_iter_inc =
        (&loop_iter_count[loop_update_idx]) ?
        loop_iter_count[loop_update_idx] :
        loop_iter_count[loop_update_idx] + 1'b1;

    reg                      loop_valid_r;
    reg [LOOP_TAG_WIDTH-1:0] loop_pred_tag_r;
    reg [LOOP_TAG_WIDTH-1:0] loop_tag_r;
    reg [1:0]                loop_confidence_r;
    reg                      loop_prediction_r;

    wire loop_hit = loop_valid_r && (loop_tag_r == loop_pred_tag_r);
    wire loop_override = loop_hit && loop_confidence_r[1];
    wire direction_taken = loop_override ? loop_prediction_r : counter_r[1];
`else
    wire direction_taken = counter_r[1];
`endif

    assign resp_valid = req_valid_r;
    assign resp_pc = req_pc_r;
    assign btb_hit = pred_hit;
    assign pred_taken = pred_hit && direction_taken;
    assign pred_target_pc = target_r;
    assign pred_is_return = pred_hit && is_return_r;

    function [1:0] sat_update;
        input [1:0] old_counter;
        input taken;
        begin
            case ({taken, old_counter})
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
        end
    endfunction

    integer i;
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    integer j;
`endif
    always @(posedge clk) begin
        if (rst) begin
            req_valid_r <= 1'b0;
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i] <= 1'b0;
                counter[i] <= WNTK;
            end
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            for (j = 0; j < LOOP_ENTRIES; j = j + 1) begin
                loop_valid[j] <= 1'b0;
            end
`endif
        end else begin
            req_valid_r <= req_valid;
            req_pc_r <= fetch_pc;
            valid_r <= valid[pred_idx];
            pred_tag_r <= pred_tag;
            tag_r <= tag[pred_idx];
            counter_r <= counter[pred_idx];
            target_r <= target[pred_idx];
            is_return_r <= is_return[pred_idx];
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            loop_valid_r <= loop_valid[loop_pred_idx];
            loop_pred_tag_r <= loop_pred_tag;
            loop_tag_r <= loop_tag[loop_pred_idx];
            loop_confidence_r <= loop_confidence[loop_pred_idx];
            loop_prediction_r <= loop_prediction[loop_pred_idx];
`endif

            if (update_en) begin
                if (actual_taken) begin
                    valid[update_idx] <= 1'b1;
                    tag[update_idx] <= update_tag;
                    target[update_idx] <= update_target;
                    is_return[update_idx] <= update_is_return;
                end

                if (valid[update_idx]) begin
                    counter[update_idx] <= sat_update(counter[update_idx], actual_taken);
                end else if (actual_taken) begin
                    counter[update_idx] <= WTK;
                end

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
                if (update_is_branch) begin
                    if (loop_update_hit) begin
                        if (actual_taken) begin
                            loop_iter_count[loop_update_idx] <= loop_iter_inc;
                            loop_prediction[loop_update_idx] <=
                                (loop_trip_count[loop_update_idx] != 0) &&
                                (loop_iter_inc == loop_trip_count[loop_update_idx]) ?
                                1'b0 : 1'b1;
                        end else begin
                            if ((loop_iter_count[loop_update_idx] != 0) &&
                                (loop_iter_count[loop_update_idx] ==
                                 loop_trip_count[loop_update_idx])) begin
                                if (loop_confidence[loop_update_idx] != 2'b11) begin
                                    loop_confidence[loop_update_idx] <=
                                        loop_confidence[loop_update_idx] + 1'b1;
                                end
                            end else begin
                                loop_trip_count[loop_update_idx] <=
                                    loop_iter_count[loop_update_idx];
                                loop_confidence[loop_update_idx] <= 2'b00;
                            end
                            loop_iter_count[loop_update_idx] <= 0;
                            loop_prediction[loop_update_idx] <= 1'b1;
                        end
                    end else if (actual_taken && (update_target < update_pc)) begin
                        loop_valid[loop_update_idx] <= 1'b1;
                        loop_tag[loop_update_idx] <= loop_update_tag;
                        loop_trip_count[loop_update_idx] <= 0;
                        loop_iter_count[loop_update_idx] <= 1;
                        loop_confidence[loop_update_idx] <= 2'b00;
                        loop_prediction[loop_update_idx] <= 1'b1;
                    end
                end
`endif
            end
        end
    end

endmodule
