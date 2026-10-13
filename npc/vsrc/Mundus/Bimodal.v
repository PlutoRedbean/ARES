`include "autoconf.vh"

module Bimodal#(ADDR_WIDTH=32,BTB_WIDTH=4,DATA_WIDTH=32)(
    input                     clk           ,
    input                     rst           ,

    // predict port
    input                     req_valid     ,
    input  [ADDR_WIDTH - 1:0] fetch_pc      ,
    output                    resp_valid    ,
    output [ADDR_WIDTH - 1:0] resp_pc       ,
    output                    pred_taken    ,
    output [ADDR_WIDTH - 1:0] pred_target_pc,
    output                    btb_hit       ,
    output                    pred_slot     ,
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    output                    pred_base_taken,
    output                    pred_is_branch,
    output                    pred_loop_override,
    output                    pred_loop_taken,
`endif

    // update port
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    input                     loop_restore   ,
`ifdef CONFIG_BP_TAGE
    input                     loop_spec_update_en,
    input  [ADDR_WIDTH - 1:0] loop_spec_update_pc,
    input                     loop_spec_update_taken,
`endif
`endif
    input                     update_en      ,
    input  [ADDR_WIDTH - 1:0] update_pc      ,
    input  [ADDR_WIDTH - 1:0] update_target  ,
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    input                     update_is_branch,
`endif
    input                     actual_taken
);

    localparam STK   = 2'b11;
    localparam WTK   = 2'b10;
    localparam WNTK  = 2'b01;
    localparam SNTK  = 2'b00;

    localparam ENTRIES   = 1 << BTB_WIDTH;
    localparam TAG_WIDTH = ADDR_WIDTH - BTB_WIDTH - 3;

    (* ram_style = "distributed" *) reg valid0 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg valid1 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [TAG_WIDTH-1:0] tag0 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [TAG_WIDTH-1:0] tag1 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [ADDR_WIDTH-1:0] target0 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [ADDR_WIDTH-1:0] target1 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [1:0] counter0 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg [1:0] counter1 [0:ENTRIES-1];
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    (* ram_style = "distributed" *) reg is_branch0 [0:ENTRIES-1];
    (* ram_style = "distributed" *) reg is_branch1 [0:ENTRIES-1];
`endif

    wire [BTB_WIDTH-1:0] pred_idx   = fetch_pc[BTB_WIDTH+2:3];
    wire [BTB_WIDTH-1:0] update_idx = update_pc[BTB_WIDTH+2:3];
    wire [TAG_WIDTH-1:0] update_tag = update_pc[ADDR_WIDTH-1:BTB_WIDTH+3];
    wire [TAG_WIDTH-1:0] pred_tag   = fetch_pc [ADDR_WIDTH-1:BTB_WIDTH+3];

    reg                  req_valid_r;
    reg [ADDR_WIDTH-1:0] req_pc_r;
    reg                  valid0_r;
    reg                  valid1_r;
    reg [TAG_WIDTH-1:0]  pred_tag_r;
    reg [TAG_WIDTH-1:0]  tag0_r;
    reg [TAG_WIDTH-1:0]  tag1_r;
    reg [ADDR_WIDTH-1:0] target0_r;
    reg [ADDR_WIDTH-1:0] target1_r;
    reg [1:0]            counter0_r;
    reg [1:0]            counter1_r;
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    reg                  is_branch0_r;
    reg                  is_branch1_r;
`endif

    wire hit0 = valid0_r && (tag0_r == pred_tag_r);
    wire hit1 = valid1_r && (tag1_r == pred_tag_r);
    wire select0 = !req_pc_r[2] && hit0;
    wire pred_hit = select0 || hit1;
    wire slot_r = !select0;
    wire [ADDR_WIDTH-1:0] target_r = select0 ? target0_r : target1_r;
    wire [1:0] counter_r = select0 ? counter0_r : counter1_r;
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    wire is_branch_r = select0 ? is_branch0_r : is_branch1_r;
`endif

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    // Small direct-mapped loop table.  The committed cursor learns a stable
    // trip count while the speculative cursor follows the frontend.
    localparam LOOP_INDEX_WIDTH = 5;
    localparam LOOP_COUNT_WIDTH = 16;
    localparam LOOP_ENTRIES = 1 << LOOP_INDEX_WIDTH;
    localparam LOOP_TAG_WIDTH = ADDR_WIDTH - LOOP_INDEX_WIDTH - 3;

    reg                        loop_valid       [0:LOOP_ENTRIES-1];
    reg [LOOP_TAG_WIDTH-1:0]   loop_tag         [0:LOOP_ENTRIES-1];
    reg [LOOP_COUNT_WIDTH-1:0] loop_trip_count  [0:LOOP_ENTRIES-1];
    reg [LOOP_COUNT_WIDTH-1:0] loop_commit_iter [0:LOOP_ENTRIES-1];
    reg [LOOP_COUNT_WIDTH-1:0] loop_spec_iter   [0:LOOP_ENTRIES-1];
    reg [1:0]                  loop_confidence  [0:LOOP_ENTRIES-1];
    reg                        loop_body_taken  [0:LOOP_ENTRIES-1];
    reg                        loop_slot        [0:LOOP_ENTRIES-1];

    wire [LOOP_INDEX_WIDTH-1:0] loop_pred_idx =
        fetch_pc[LOOP_INDEX_WIDTH+2:3];
    wire [LOOP_INDEX_WIDTH-1:0] loop_update_idx =
        update_pc[LOOP_INDEX_WIDTH+2:3];
    wire [LOOP_TAG_WIDTH-1:0] loop_pred_tag =
        fetch_pc[ADDR_WIDTH-1:LOOP_INDEX_WIDTH+3];
    wire [LOOP_TAG_WIDTH-1:0] loop_update_tag =
        update_pc[ADDR_WIDTH-1:LOOP_INDEX_WIDTH+3];
    wire loop_update_hit = loop_valid[loop_update_idx] &&
        (loop_tag[loop_update_idx] == loop_update_tag) &&
        (loop_slot[loop_update_idx] == update_pc[2]);
    wire [LOOP_INDEX_WIDTH-1:0] loop_resp_idx =
        req_pc_r[LOOP_INDEX_WIDTH+2:3];
    wire [LOOP_COUNT_WIDTH-1:0] loop_commit_inc =
        (&loop_commit_iter[loop_update_idx]) ?
        loop_commit_iter[loop_update_idx] :
        loop_commit_iter[loop_update_idx] + 1'b1;
    reg                       loop_valid_r;
    reg [LOOP_TAG_WIDTH-1:0]  loop_pred_tag_r;
    reg [LOOP_TAG_WIDTH-1:0]  loop_tag_r;
    reg [LOOP_COUNT_WIDTH-1:0] loop_trip_count_r;
    reg [LOOP_COUNT_WIDTH-1:0] loop_spec_iter_r;
    reg [1:0]                 loop_confidence_r;
    reg                       loop_body_taken_r;
    reg                       loop_slot_r;

`ifdef CONFIG_BP_TAGE
    wire [LOOP_INDEX_WIDTH-1:0] loop_spec_update_idx =
        loop_spec_update_pc[LOOP_INDEX_WIDTH+2:3];
    wire [LOOP_TAG_WIDTH-1:0] loop_spec_update_tag =
        loop_spec_update_pc[ADDR_WIDTH-1:LOOP_INDEX_WIDTH+3];
    wire loop_spec_update_hit = loop_valid[loop_spec_update_idx] &&
        (loop_tag[loop_spec_update_idx] == loop_spec_update_tag) &&
        (loop_slot[loop_spec_update_idx] == loop_spec_update_pc[2]);
    wire [LOOP_COUNT_WIDTH-1:0] loop_spec_update_inc =
        (&loop_spec_iter[loop_spec_update_idx]) ?
        loop_spec_iter[loop_spec_update_idx] :
        loop_spec_iter[loop_spec_update_idx] + 1'b1;
    wire [LOOP_COUNT_WIDTH-1:0] loop_spec_update_next =
        (loop_spec_update_taken == loop_body_taken[loop_spec_update_idx]) ?
        loop_spec_update_inc : {LOOP_COUNT_WIDTH{1'b0}};

`endif

    wire loop_hit = loop_valid_r && (loop_tag_r == loop_pred_tag_r) &&
        (loop_slot_r == slot_r);
    wire loop_override = loop_hit && loop_confidence_r[1] &&
        (loop_trip_count_r != 0);
    wire loop_prediction_r =
        (loop_spec_iter_r == loop_trip_count_r) ?
        !loop_body_taken_r : loop_body_taken_r;
    wire [LOOP_COUNT_WIDTH-1:0] loop_spec_inc =
        (&loop_spec_iter_r) ? loop_spec_iter_r : loop_spec_iter_r + 1'b1;
    wire direction_taken = loop_override ? loop_prediction_r : counter_r[1];
`else
    wire direction_taken = counter_r[1];
`endif

    assign resp_valid     = req_valid_r;
    assign resp_pc        = req_pc_r;
    assign btb_hit        = pred_hit;
    assign pred_taken     = pred_hit && direction_taken;
    assign pred_target_pc = target_r;
    assign pred_slot      = slot_r;
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
    assign pred_base_taken = counter_r[1];
    assign pred_is_branch = pred_hit && is_branch_r;
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    assign pred_loop_override = pred_hit && is_branch_r && loop_override;
    assign pred_loop_taken = loop_prediction_r;
`else
    assign pred_loop_override = 1'b0;
    assign pred_loop_taken = 1'b0;
`endif
`endif

    function [1:0] sat_update;
        input [1:0] old_counter;
        input       taken;
        begin
            case ({taken, old_counter})
                3'b100: sat_update = WNTK;
                3'b101: sat_update = WTK ;
                3'b110: sat_update = STK ;
                3'b111: sat_update = STK ;
                3'b000: sat_update = SNTK;
                3'b001: sat_update = SNTK;
                3'b010: sat_update = WNTK;
                3'b011: sat_update = WTK ;
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
            req_valid_r      <= 1'b0;
            // req_pc_r         <= {ADDR_WIDTH{1'b0}};
            // valid_r          <= 1'b0;
            // pred_tag_r       <= {TAG_WIDTH{1'b0}};
            // counter_r        <= WNTK;

            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid0[i] <= 1'b0;
                valid1[i] <= 1'b0;
                counter0[i] <= WNTK;
                counter1[i] <= WNTK;
            end
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            for (j = 0; j < LOOP_ENTRIES; j = j + 1) begin
                loop_valid[j] <= 1'b0;
            end
`endif
        end else begin
            req_valid_r <= req_valid;
            req_pc_r    <= fetch_pc;
            valid0_r    <= valid0[pred_idx];
            valid1_r    <= valid1[pred_idx];
            pred_tag_r  <= pred_tag;
            tag0_r      <= tag0[pred_idx];
            tag1_r      <= tag1[pred_idx];
            counter0_r  <= counter0[pred_idx];
            counter1_r  <= counter1[pred_idx];
            target0_r   <= target0[pred_idx];
            target1_r   <= target1[pred_idx];
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
            is_branch0_r <= is_branch0[pred_idx];
            is_branch1_r <= is_branch1[pred_idx];
`endif
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            loop_valid_r      <= loop_valid[loop_pred_idx];
            loop_pred_tag_r   <= loop_pred_tag;
            loop_tag_r        <= loop_tag[loop_pred_idx];
            loop_trip_count_r <= loop_trip_count[loop_pred_idx];
            loop_spec_iter_r <= loop_spec_iter[loop_pred_idx];
`ifdef CONFIG_BP_TAGE
            // S2 may advance the same entry on this edge.  Bypass at the
            // synchronous-read register input so the prediction output path
            // does not gain a PC comparator or an extra counter mux.
            if (loop_spec_update_en && loop_spec_update_hit &&
                (loop_spec_update_idx == loop_pred_idx) &&
                (loop_spec_update_tag == loop_pred_tag)) begin
                loop_spec_iter_r <= loop_spec_update_next;
            end
`endif
            loop_confidence_r <= loop_confidence[loop_pred_idx];
            loop_body_taken_r <= loop_body_taken[loop_pred_idx];
            loop_slot_r       <= loop_slot[loop_pred_idx];

            if (loop_restore) begin
                for (j = 0; j < LOOP_ENTRIES; j = j + 1) begin
                    loop_spec_iter[j] <= loop_commit_iter[j];
                end
`ifdef CONFIG_BP_TAGE
            end else begin
                if (loop_spec_update_en && loop_spec_update_hit) begin
                    loop_spec_iter[loop_spec_update_idx] <=
                        loop_spec_update_next;
                end
            end
`else
            end else if (req_valid_r && pred_hit && is_branch_r &&
                         loop_override) begin
                loop_spec_iter[loop_resp_idx] <=
                    (loop_prediction_r == loop_body_taken_r) ?
                    loop_spec_inc : {LOOP_COUNT_WIDTH{1'b0}};
            end
`endif
`endif

            if (update_en) begin
                if (update_pc[2]) begin
                    if (valid1[update_idx] && tag1[update_idx] == update_tag) begin
                        counter1[update_idx] <=
                            sat_update(counter1[update_idx], actual_taken);
                        if (actual_taken)
                            target1[update_idx] <= update_target;
                    end else if (actual_taken) begin
                        valid1[update_idx] <= 1'b1;
                        tag1[update_idx] <= update_tag;
                        target1[update_idx] <= update_target;
                        counter1[update_idx] <= WTK;
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
                        is_branch1[update_idx] <= update_is_branch;
`endif
                    end
                end else begin
                    if (valid0[update_idx] && tag0[update_idx] == update_tag) begin
                        counter0[update_idx] <=
                            sat_update(counter0[update_idx], actual_taken);
                        if (actual_taken)
                            target0[update_idx] <= update_target;
                    end else if (actual_taken) begin
                        valid0[update_idx] <= 1'b1;
                        tag0[update_idx] <= update_tag;
                        target0[update_idx] <= update_target;
                        counter0[update_idx] <= WTK;
`ifdef CONFIG_BRANCH_DIRECTION_METADATA
                        is_branch0[update_idx] <= update_is_branch;
`endif
                    end
                end

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
                if (update_is_branch) begin
                    if (loop_update_hit) begin
                        if (actual_taken == loop_body_taken[loop_update_idx]) begin
                            loop_commit_iter[loop_update_idx] <= loop_commit_inc;
                            if (!loop_confidence[loop_update_idx][1] || loop_restore) begin
                                loop_spec_iter[loop_update_idx] <= loop_commit_inc;
                            end
                        end else begin
                            if ((loop_commit_iter[loop_update_idx] != 0) &&
                                (loop_commit_iter[loop_update_idx] ==
                                 loop_trip_count[loop_update_idx])) begin
                                if (loop_confidence[loop_update_idx] != 2'b11) begin
                                    loop_confidence[loop_update_idx] <=
                                        loop_confidence[loop_update_idx] + 1'b1;
                                end
                            end else begin
                                if (loop_commit_iter[loop_update_idx] != 0) begin
                                    loop_trip_count[loop_update_idx] <=
                                        loop_commit_iter[loop_update_idx];
                                end
                                loop_confidence[loop_update_idx] <= 2'b00;
                            end
                            loop_commit_iter[loop_update_idx] <= 0;
                            if (!loop_confidence[loop_update_idx][1] || loop_restore) begin
                                loop_spec_iter[loop_update_idx] <= 0;
                            end
                        end
                    end else if (actual_taken) begin
                        loop_valid[loop_update_idx] <= 1'b1;
                        loop_tag[loop_update_idx] <= loop_update_tag;
                        loop_slot[loop_update_idx] <= update_pc[2];
                        loop_trip_count[loop_update_idx] <= 0;
                        loop_body_taken[loop_update_idx] <=
                            (update_target < update_pc);
                        loop_commit_iter[loop_update_idx] <=
                            (update_target < update_pc) ? 1 : 0;
                        loop_spec_iter[loop_update_idx] <=
                            (update_target < update_pc) ? 1 : 0;
                        loop_confidence[loop_update_idx] <= 2'b00;
                    end
                end
`endif
            end
        end
    end

endmodule
