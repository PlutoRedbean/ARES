`include "autoconf.vh"

module TageDirection #(
    parameter ADDR_WIDTH = 32,
    parameter INDEX_WIDTH = 8,
    parameter TAG_WIDTH = 8,
    parameter HIST0 = 4,
    parameter HIST1 = 12,
    parameter HIST2 = 32,
    parameter HIST3 = 64,
    // Standalone lint elaborates this module with its defaults even when the
    // configured top-level predictor is Bimodal.  Keep the default large
    // enough for the three optional loop-predictor metadata bits; the Chisel
    // BlackBox still overrides this parameter with the exact configured size.
    parameter META_WIDTH = 137
) (
    input                       clk,
    input                       rst,

    input                       req_valid,
    input  [ADDR_WIDTH-1:0]     req_pc,
    input                       fast_base_taken,
    input                       fast_loop_override,
    input                       fast_loop_taken,
    input                       fast_direction_override,
    input                       fast_override_taken,
    input                       pipeline_flush,

    output                      resp_valid,
    output     [ADDR_WIDTH-1:0] resp_pc,
    output                      pred_taken,
    output reg [META_WIDTH-1:0] resp_meta,

    input                       update_en,
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    input  [ADDR_WIDTH-1:0]     update_pc,
`endif
    input                       update_actual_taken,
    input  [META_WIDTH-1:0]     update_meta,
    input                       recover_en,
    input                       recover_actual_taken,
    input  [META_WIDTH-1:0]     recover_meta,
    input                       update_skip_history,
    input                       restore_committed
);

    localparam PROVIDER_NONE = 3'd4;
    localparam HISTORY_BASE = 0;
    localparam INDEX_BASE = 64;
    localparam TAG_BASE = INDEX_BASE + 4 * INDEX_WIDTH;
    localparam PROVIDER_BASE = TAG_BASE + 4 * TAG_WIDTH;
    localparam LOOP_META_BASE = PROVIDER_BASE + 6;
    localparam ENTRY_WIDTH = TAG_WIDTH + 6;
    localparam ENTRY_VALID_BIT = ENTRY_WIDTH - 1;
    localparam ENTRY_TAG_MSB = ENTRY_WIDTH - 2;
    localparam ENTRY_COUNTER_MSB = 4;
    localparam ENTRY_USEFUL_MSB = 1;

    // A Simple Dual Port BRAM only has one synchronous read port.  Keep two
    // identical copies per tagged table so prediction and training can read
    // independently while all writes are broadcast to both copies.
    wire [ENTRY_WIDTH-1:0] table0_pred_rdata;
    wire [ENTRY_WIDTH-1:0] table1_pred_rdata;
    wire [ENTRY_WIDTH-1:0] table2_pred_rdata;
    wire [ENTRY_WIDTH-1:0] table3_pred_rdata;
    wire [ENTRY_WIDTH-1:0] table0_update_rdata;
    wire [ENTRY_WIDTH-1:0] table1_update_rdata;
    wire [ENTRY_WIDTH-1:0] table2_update_rdata;
    wire [ENTRY_WIDTH-1:0] table3_update_rdata;

    reg update_bypass_valid0;
    reg update_bypass_valid1;
    reg update_bypass_valid2;
    reg update_bypass_valid3;
    reg [ENTRY_WIDTH-1:0] update_bypass_data0;
    reg [ENTRY_WIDTH-1:0] update_bypass_data1;
    reg [ENTRY_WIDTH-1:0] update_bypass_data2;
    reg [ENTRY_WIDTH-1:0] update_bypass_data3;

    // The packed table implementation also returned the old entry on a
    // same-edge prediction read/write collision.  Keep the BRAM output on
    // the hit path directly instead of adding a forwarding mux after it.
    wire [ENTRY_WIDTH-1:0] q_entry0 = table0_pred_rdata;
    wire [ENTRY_WIDTH-1:0] q_entry1 = table1_pred_rdata;
    wire [ENTRY_WIDTH-1:0] q_entry2 = table2_pred_rdata;
    wire [ENTRY_WIDTH-1:0] q_entry3 = table3_pred_rdata;

    reg table0_we;
    reg table1_we;
    reg table2_we;
    reg table3_we;
    reg [INDEX_WIDTH-1:0] table0_waddr;
    reg [INDEX_WIDTH-1:0] table1_waddr;
    reg [INDEX_WIDTH-1:0] table2_waddr;
    reg [INDEX_WIDTH-1:0] table3_waddr;
    reg [ENTRY_WIDTH-1:0] table0_wdata;
    reg [ENTRY_WIDTH-1:0] table1_wdata;
    reg [ENTRY_WIDTH-1:0] table2_wdata;
    reg [ENTRY_WIDTH-1:0] table3_wdata;

    reg [63:0] global_history;
    reg [63:0] committed_history;
    reg [INDEX_WIDTH-1:0] index_fold0;
    reg [INDEX_WIDTH-1:0] index_fold1;
    reg [INDEX_WIDTH-1:0] index_fold2;
    reg [INDEX_WIDTH-1:0] index_fold3;
    reg [TAG_WIDTH-1:0] tag_fold0;
    reg [TAG_WIDTH-1:0] tag_fold1;
    reg [TAG_WIDTH-1:0] tag_fold2;
    reg [TAG_WIDTH-1:0] tag_fold3;
    reg [TAG_WIDTH-2:0] tag_alt_fold0;
    reg [TAG_WIDTH-2:0] tag_alt_fold1;
    reg [TAG_WIDTH-2:0] tag_alt_fold2;
    reg [TAG_WIDTH-2:0] tag_alt_fold3;

    reg q_valid;
    reg [ADDR_WIDTH-1:0] q_pc;
    reg [63:0] q_history;
    reg [INDEX_WIDTH-1:0] q_index0;
    reg [INDEX_WIDTH-1:0] q_index1;
    reg [INDEX_WIDTH-1:0] q_index2;
    reg [INDEX_WIDTH-1:0] q_index3;
    reg [TAG_WIDTH-1:0] q_hash_tag0;
    reg [TAG_WIDTH-1:0] q_hash_tag1;
    reg [TAG_WIDTH-1:0] q_hash_tag2;
    reg [TAG_WIDTH-1:0] q_hash_tag3;
    reg q_base_taken;
    reg q_loop_override;
    reg q_loop_taken;
    reg q_direction_override;
    reg q_override_taken;
    reg q_tables_ready;
    reg [3:0] use_alt_on_na;
    reg [17:0] age_counter;
    reg [INDEX_WIDTH-1:0] age_index;
    reg init_active;
    reg [INDEX_WIDTH-1:0] init_index;
    reg table_update_valid;
    reg table_age_valid;
    reg [META_WIDTH-1:0] table_update_meta;
    reg table_update_actual_taken;
    reg [INDEX_WIDTH-1:0] table_age_index;

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    localparam LOOP_SELECT_WIDTH = 5;
    localparam LOOP_SELECT_ENTRIES = 1 << LOOP_SELECT_WIDTH;
    reg [1:0] loop_select [0:LOOP_SELECT_ENTRIES-1];

    function [LOOP_SELECT_WIDTH-1:0] loop_select_index;
        input [ADDR_WIDTH-1:0] pc;
        integer bit_pos;
        reg [ADDR_WIDTH-1:0] shifted_pc;
        begin
            loop_select_index = {LOOP_SELECT_WIDTH{1'b0}};
            for (bit_pos = 2; bit_pos < ADDR_WIDTH;
                 bit_pos = bit_pos + LOOP_SELECT_WIDTH) begin
                shifted_pc = pc >> bit_pos;
                loop_select_index = loop_select_index ^
                    shifted_pc[LOOP_SELECT_WIDTH-1:0];
            end
        end
    endfunction
`endif

    function [INDEX_WIDTH-1:0] index_fold_next;
        input [INDEX_WIDTH-1:0] old_fold;
        input new_bit;
        input outgoing_bit;
        input integer history_length;
        reg [INDEX_WIDTH-1:0] shifted;
        begin
            shifted = {old_fold[INDEX_WIDTH-2:0], old_fold[INDEX_WIDTH-1]};
            shifted[0] = shifted[0] ^ new_bit;
            shifted[history_length % INDEX_WIDTH] =
                shifted[history_length % INDEX_WIDTH] ^ outgoing_bit;
            index_fold_next = shifted;
        end
    endfunction

    function [TAG_WIDTH-2:0] tag_alt_fold_next;
        input [TAG_WIDTH-2:0] old_fold;
        input new_bit;
        input outgoing_bit;
        input integer history_length;
        reg [TAG_WIDTH-2:0] shifted;
        begin
            shifted = {old_fold[TAG_WIDTH-3:0], old_fold[TAG_WIDTH-2]};
            shifted[0] = shifted[0] ^ new_bit;
            shifted[history_length % (TAG_WIDTH-1)] =
                shifted[history_length % (TAG_WIDTH-1)] ^ outgoing_bit;
            tag_alt_fold_next = shifted;
        end
    endfunction

    function [TAG_WIDTH-1:0] tag_fold_next;
        input [TAG_WIDTH-1:0] old_fold;
        input new_bit;
        input outgoing_bit;
        input integer history_length;
        reg [TAG_WIDTH-1:0] shifted;
        begin
            shifted = {old_fold[TAG_WIDTH-2:0], old_fold[TAG_WIDTH-1]};
            shifted[0] = shifted[0] ^ new_bit;
            shifted[history_length % TAG_WIDTH] =
                shifted[history_length % TAG_WIDTH] ^ outgoing_bit;
            tag_fold_next = shifted;
        end
    endfunction

    function [TAG_WIDTH-2:0] fold_history_tag_alt;
        input [63:0] history;
        input integer history_length;
        integer k;
        begin
            fold_history_tag_alt = {(TAG_WIDTH-1){1'b0}};
            for (k = 0; k < history_length; k = k + 1) begin
                fold_history_tag_alt[k % (TAG_WIDTH-1)] =
                    fold_history_tag_alt[k % (TAG_WIDTH-1)] ^ history[k];
            end
        end
    endfunction

    function [INDEX_WIDTH-1:0] fold_history_index;
        input [63:0] history;
        input integer history_length;
        integer k;
        begin
            fold_history_index = {INDEX_WIDTH{1'b0}};
            for (k = 0; k < history_length; k = k + 1) begin
                fold_history_index[k % INDEX_WIDTH] =
                    fold_history_index[k % INDEX_WIDTH] ^ history[k];
            end
        end
    endfunction

    function [TAG_WIDTH-1:0] fold_history_tag;
        input [63:0] history;
        input integer history_length;
        integer k;
        begin
            fold_history_tag = {TAG_WIDTH{1'b0}};
            for (k = 0; k < history_length; k = k + 1) begin
                fold_history_tag[k % TAG_WIDTH] =
                    fold_history_tag[k % TAG_WIDTH] ^ history[k];
            end
        end
    endfunction

    function [2:0] counter_update;
        input [2:0] old_counter;
        input taken;
        begin
            if (taken) begin
                counter_update = (&old_counter) ? old_counter : old_counter + 1'b1;
            end else begin
                counter_update = (|old_counter) ? old_counter - 1'b1 : old_counter;
            end
        end
    endfunction

    function [ENTRY_WIDTH-1:0] entry_make;
        input entry_valid;
        input [TAG_WIDTH-1:0] entry_tag;
        input [2:0] entry_counter;
        input [1:0] entry_useful;
        begin
            entry_make = {entry_valid, entry_tag, entry_counter,
                          entry_useful};
        end
    endfunction

    function [1:0] useful_update;
        input [1:0] old_useful;
        input provider_pred;
        input alternate_pred;
        input actual_taken;
        begin
            useful_update = old_useful;
            if (provider_pred != alternate_pred) begin
                if (provider_pred == actual_taken && old_useful != 2'b11)
                    useful_update = old_useful + 1'b1;
                else if (provider_pred != actual_taken && old_useful != 2'b00)
                    useful_update = old_useful - 1'b1;
            end
        end
    endfunction

    wire [TAG_WIDTH-1:0] q_entry_tag0 =
        q_entry0[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] q_entry_tag1 =
        q_entry1[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] q_entry_tag2 =
        q_entry2[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] q_entry_tag3 =
        q_entry3[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [2:0] q_counter0 = q_entry0[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] q_counter1 = q_entry1[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] q_counter2 = q_entry2[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] q_counter3 = q_entry3[ENTRY_COUNTER_MSB -: 3];

    wire hit0 = q_tables_ready && q_entry0[ENTRY_VALID_BIT] &&
        (q_entry_tag0 == q_hash_tag0);
    wire hit1 = q_tables_ready && q_entry1[ENTRY_VALID_BIT] &&
        (q_entry_tag1 == q_hash_tag1);
    wire hit2 = q_tables_ready && q_entry2[ENTRY_VALID_BIT] &&
        (q_entry_tag2 == q_hash_tag2);
    wire hit3 = q_tables_ready && q_entry3[ENTRY_VALID_BIT] &&
        (q_entry_tag3 == q_hash_tag3);

    reg [2:0] provider;
    reg [2:0] provider_counter;
    reg provider_prediction;
    reg alternate_prediction;
    reg tage_prediction;
    wire provider_weak = (provider_counter == 3'b011) ||
                         (provider_counter == 3'b100);

    always @(*) begin
        provider = PROVIDER_NONE;
        provider_counter = {2'b01, q_base_taken};
        provider_prediction = q_base_taken;
        alternate_prediction = q_base_taken;

        if (hit0) begin
            provider = 3'd0;
            provider_counter = q_counter0;
            provider_prediction = q_counter0[2];
        end
        if (hit1) begin
            alternate_prediction = (provider == 3'd0) ? q_counter0[2] : q_base_taken;
            provider = 3'd1;
            provider_counter = q_counter1;
            provider_prediction = q_counter1[2];
        end
        if (hit2) begin
            case (provider)
                3'd1: alternate_prediction = q_counter1[2];
                3'd0: alternate_prediction = q_counter0[2];
                default: alternate_prediction = q_base_taken;
            endcase
            provider = 3'd2;
            provider_counter = q_counter2;
            provider_prediction = q_counter2[2];
        end
        if (hit3) begin
            case (provider)
                3'd2: alternate_prediction = q_counter2[2];
                3'd1: alternate_prediction = q_counter1[2];
                3'd0: alternate_prediction = q_counter0[2];
                default: alternate_prediction = q_base_taken;
            endcase
            provider = 3'd3;
            provider_counter = q_counter3;
            provider_prediction = q_counter3[2];
        end

        if (provider == PROVIDER_NONE) begin
            tage_prediction = q_base_taken;
        end else if (provider_weak && use_alt_on_na[3]) begin
            tage_prediction = alternate_prediction;
        end else begin
            tage_prediction = provider_prediction;
        end
    end

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    wire [LOOP_SELECT_WIDTH-1:0] loop_select_pred_idx =
        loop_select_index(q_pc);
    wire use_loop_prediction = q_loop_override &&
        loop_select[loop_select_pred_idx][1];
    wire selected_prediction = use_loop_prediction ?
        q_loop_taken : tage_prediction;
`else
    wire selected_prediction = tage_prediction;
`endif
    wire final_prediction = q_direction_override ?
        q_override_taken : selected_prediction;
    // An internal S2 override flushes younger requests, but the corrected
    // branch itself must still enter speculative history.  External recovery
    // has higher priority in the sequential history update below.
    wire spec_advance = q_valid && !q_direction_override;

    assign resp_valid = q_valid;
    assign resp_pc = q_pc;
    assign pred_taken = final_prediction;

    always @(*) begin
        resp_meta = {META_WIDTH{1'b0}};
        resp_meta[HISTORY_BASE +: 64] = q_history;
        resp_meta[INDEX_BASE + 0*INDEX_WIDTH +: INDEX_WIDTH] = q_index0;
        resp_meta[INDEX_BASE + 1*INDEX_WIDTH +: INDEX_WIDTH] = q_index1;
        resp_meta[INDEX_BASE + 2*INDEX_WIDTH +: INDEX_WIDTH] = q_index2;
        resp_meta[INDEX_BASE + 3*INDEX_WIDTH +: INDEX_WIDTH] = q_index3;
        resp_meta[TAG_BASE + 0*TAG_WIDTH +: TAG_WIDTH] = q_hash_tag0;
        resp_meta[TAG_BASE + 1*TAG_WIDTH +: TAG_WIDTH] = q_hash_tag1;
        resp_meta[TAG_BASE + 2*TAG_WIDTH +: TAG_WIDTH] = q_hash_tag2;
        resp_meta[TAG_BASE + 3*TAG_WIDTH +: TAG_WIDTH] = q_hash_tag3;
        resp_meta[PROVIDER_BASE +: 3] = provider;
        resp_meta[PROVIDER_BASE + 3] = provider_prediction;
        resp_meta[PROVIDER_BASE + 4] = alternate_prediction;
        resp_meta[PROVIDER_BASE + 5] = tage_prediction;
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
        resp_meta[LOOP_META_BASE] = q_loop_override;
        resp_meta[LOOP_META_BASE + 1] = q_loop_taken;
        resp_meta[LOOP_META_BASE + 2] = tage_prediction;
`endif
    end

    wire [INDEX_WIDTH-1:0] request_index_fold0 = spec_advance ?
        index_fold_next(index_fold0, final_prediction, global_history[HIST0-1], HIST0) : index_fold0;
    wire [INDEX_WIDTH-1:0] request_index_fold1 = spec_advance ?
        index_fold_next(index_fold1, final_prediction, global_history[HIST1-1], HIST1) : index_fold1;
    wire [INDEX_WIDTH-1:0] request_index_fold2 = spec_advance ?
        index_fold_next(index_fold2, final_prediction, global_history[HIST2-1], HIST2) : index_fold2;
    wire [INDEX_WIDTH-1:0] request_index_fold3 = spec_advance ?
        index_fold_next(index_fold3, final_prediction, global_history[HIST3-1], HIST3) : index_fold3;
    wire [TAG_WIDTH-1:0] request_tag_fold0 = spec_advance ?
        tag_fold_next(tag_fold0, final_prediction, global_history[HIST0-1], HIST0) : tag_fold0;
    wire [TAG_WIDTH-1:0] request_tag_fold1 = spec_advance ?
        tag_fold_next(tag_fold1, final_prediction, global_history[HIST1-1], HIST1) : tag_fold1;
    wire [TAG_WIDTH-1:0] request_tag_fold2 = spec_advance ?
        tag_fold_next(tag_fold2, final_prediction, global_history[HIST2-1], HIST2) : tag_fold2;
    wire [TAG_WIDTH-1:0] request_tag_fold3 = spec_advance ?
        tag_fold_next(tag_fold3, final_prediction, global_history[HIST3-1], HIST3) : tag_fold3;
    wire [TAG_WIDTH-2:0] request_tag_alt_fold0 = spec_advance ?
        tag_alt_fold_next(tag_alt_fold0, final_prediction, global_history[HIST0-1], HIST0) : tag_alt_fold0;
    wire [TAG_WIDTH-2:0] request_tag_alt_fold1 = spec_advance ?
        tag_alt_fold_next(tag_alt_fold1, final_prediction, global_history[HIST1-1], HIST1) : tag_alt_fold1;
    wire [TAG_WIDTH-2:0] request_tag_alt_fold2 = spec_advance ?
        tag_alt_fold_next(tag_alt_fold2, final_prediction, global_history[HIST2-1], HIST2) : tag_alt_fold2;
    wire [TAG_WIDTH-2:0] request_tag_alt_fold3 = spec_advance ?
        tag_alt_fold_next(tag_alt_fold3, final_prediction, global_history[HIST3-1], HIST3) : tag_alt_fold3;
    wire [63:0] request_history = spec_advance ?
        {global_history[62:0], final_prediction} : global_history;

    wire [INDEX_WIDTH-1:0] req_pc_index_hash =
        req_pc[INDEX_WIDTH+1:2] ^ req_pc[2*INDEX_WIDTH+1:INDEX_WIDTH+2];
    wire [TAG_WIDTH-1:0] req_pc_tag_hash =
        req_pc[TAG_WIDTH+1:2] ^ req_pc[2*TAG_WIDTH+1:TAG_WIDTH+2];
    wire [INDEX_WIDTH-1:0] req_index0 = req_pc_index_hash ^ request_index_fold0;
    wire [INDEX_WIDTH-1:0] req_index1 = req_pc_index_hash ^ request_index_fold1 ^ {{(INDEX_WIDTH-1){1'b0}}, 1'b1};
    wire [INDEX_WIDTH-1:0] req_index2 = req_pc_index_hash ^ request_index_fold2 ^ {{(INDEX_WIDTH-2){1'b0}}, 2'b10};
    wire [INDEX_WIDTH-1:0] req_index3 = req_pc_index_hash ^ request_index_fold3 ^ {{(INDEX_WIDTH-2){1'b0}}, 2'b11};
    wire [TAG_WIDTH-1:0] req_hash_tag0 = req_pc_tag_hash ^ request_tag_fold0 ^ {request_tag_alt_fold0, 1'b0};
    wire [TAG_WIDTH-1:0] req_hash_tag1 = req_pc_tag_hash ^ request_tag_fold1 ^ {request_tag_alt_fold1, 1'b0} ^ {{(TAG_WIDTH-1){1'b0}}, 1'b1};
    wire [TAG_WIDTH-1:0] req_hash_tag2 = req_pc_tag_hash ^ request_tag_fold2 ^ {request_tag_alt_fold2, 1'b0} ^ {{(TAG_WIDTH-2){1'b0}}, 2'b10};
    wire [TAG_WIDTH-1:0] req_hash_tag3 = req_pc_tag_hash ^ request_tag_fold3 ^ {request_tag_alt_fold3, 1'b0} ^ {{(TAG_WIDTH-2){1'b0}}, 2'b11};

    wire [INDEX_WIDTH-1:0] incoming_update_index0 =
        update_meta[INDEX_BASE + 0*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] incoming_update_index1 =
        update_meta[INDEX_BASE + 1*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] incoming_update_index2 =
        update_meta[INDEX_BASE + 2*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] incoming_update_index3 =
        update_meta[INDEX_BASE + 3*INDEX_WIDTH +: INDEX_WIDTH];
    wire table_update_accept = update_en && !init_active;
    wire age_issue = !init_active && (&age_counter) && !update_en;
    wire update_read_request = table_update_accept || age_issue;
    wire [INDEX_WIDTH-1:0] update_read_addr0 = table_update_accept ?
        incoming_update_index0 : age_index;
    wire [INDEX_WIDTH-1:0] update_read_addr1 = table_update_accept ?
        incoming_update_index1 : age_index;
    wire [INDEX_WIDTH-1:0] update_read_addr2 = table_update_accept ?
        incoming_update_index2 : age_index;
    wire [INDEX_WIDTH-1:0] update_read_addr3 = table_update_accept ?
        incoming_update_index3 : age_index;

    // The BRAM read and this metadata register form the internal update
    // pipeline.  This preserves one update per cycle without lengthening the
    // prediction response path.
    wire [INDEX_WIDTH-1:0] update_index0 =
        table_update_meta[INDEX_BASE + 0*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] update_index1 =
        table_update_meta[INDEX_BASE + 1*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] update_index2 =
        table_update_meta[INDEX_BASE + 2*INDEX_WIDTH +: INDEX_WIDTH];
    wire [INDEX_WIDTH-1:0] update_index3 =
        table_update_meta[INDEX_BASE + 3*INDEX_WIDTH +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] update_tag0 =
        table_update_meta[TAG_BASE + 0*TAG_WIDTH +: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_tag1 =
        table_update_meta[TAG_BASE + 1*TAG_WIDTH +: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_tag2 =
        table_update_meta[TAG_BASE + 2*TAG_WIDTH +: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_tag3 =
        table_update_meta[TAG_BASE + 3*TAG_WIDTH +: TAG_WIDTH];
    wire [2:0] update_provider =
        table_update_meta[PROVIDER_BASE +: 3];
    wire update_provider_prediction =
        table_update_meta[PROVIDER_BASE + 3];
    wire update_alternate_prediction =
        table_update_meta[PROVIDER_BASE + 4];
    wire update_tage_prediction =
        table_update_meta[PROVIDER_BASE + 5];
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    wire update_loop_candidate = update_meta[LOOP_META_BASE];
    wire update_loop_prediction = update_meta[LOOP_META_BASE + 1];
    wire update_preloop_prediction = update_meta[LOOP_META_BASE + 2];
    wire [LOOP_SELECT_WIDTH-1:0] loop_select_update_idx =
        loop_select_index(update_pc);
`endif

    TageTable_BRAM table0_pred (
        .clka(clk), .wea(table0_we), .addra(table0_waddr),
        .dina(table0_wdata), .clkb(clk), .addrb(req_index0),
        .doutb(table0_pred_rdata));
    TageTable_BRAM table0_update (
        .clka(clk), .wea(table0_we), .addra(table0_waddr),
        .dina(table0_wdata), .clkb(clk), .addrb(update_read_addr0),
        .doutb(table0_update_rdata));
    TageTable_BRAM table1_pred (
        .clka(clk), .wea(table1_we), .addra(table1_waddr),
        .dina(table1_wdata), .clkb(clk), .addrb(req_index1),
        .doutb(table1_pred_rdata));
    TageTable_BRAM table1_update (
        .clka(clk), .wea(table1_we), .addra(table1_waddr),
        .dina(table1_wdata), .clkb(clk), .addrb(update_read_addr1),
        .doutb(table1_update_rdata));
    TageTable_BRAM table2_pred (
        .clka(clk), .wea(table2_we), .addra(table2_waddr),
        .dina(table2_wdata), .clkb(clk), .addrb(req_index2),
        .doutb(table2_pred_rdata));
    TageTable_BRAM table2_update (
        .clka(clk), .wea(table2_we), .addra(table2_waddr),
        .dina(table2_wdata), .clkb(clk), .addrb(update_read_addr2),
        .doutb(table2_update_rdata));
    TageTable_BRAM table3_pred (
        .clka(clk), .wea(table3_we), .addra(table3_waddr),
        .dina(table3_wdata), .clkb(clk), .addrb(req_index3),
        .doutb(table3_pred_rdata));
    TageTable_BRAM table3_update (
        .clka(clk), .wea(table3_we), .addra(table3_waddr),
        .dina(table3_wdata), .clkb(clk), .addrb(update_read_addr3),
        .doutb(table3_update_rdata));

    wire [ENTRY_WIDTH-1:0] update_entry0 = update_bypass_valid0 ?
        update_bypass_data0 : table0_update_rdata;
    wire [ENTRY_WIDTH-1:0] update_entry1 = update_bypass_valid1 ?
        update_bypass_data1 : table1_update_rdata;
    wire [ENTRY_WIDTH-1:0] update_entry2 = update_bypass_valid2 ?
        update_bypass_data2 : table2_update_rdata;
    wire [ENTRY_WIDTH-1:0] update_entry3 = update_bypass_valid3 ?
        update_bypass_data3 : table3_update_rdata;
    wire update_entry_valid0 = update_entry0[ENTRY_VALID_BIT];
    wire update_entry_valid1 = update_entry1[ENTRY_VALID_BIT];
    wire update_entry_valid2 = update_entry2[ENTRY_VALID_BIT];
    wire update_entry_valid3 = update_entry3[ENTRY_VALID_BIT];
    wire [TAG_WIDTH-1:0] update_entry_tag0 =
        update_entry0[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_entry_tag1 =
        update_entry1[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_entry_tag2 =
        update_entry2[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [TAG_WIDTH-1:0] update_entry_tag3 =
        update_entry3[ENTRY_TAG_MSB -: TAG_WIDTH];
    wire [2:0] update_counter0 =
        update_entry0[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] update_counter1 =
        update_entry1[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] update_counter2 =
        update_entry2[ENTRY_COUNTER_MSB -: 3];
    wire [2:0] update_counter3 =
        update_entry3[ENTRY_COUNTER_MSB -: 3];
    wire [1:0] update_useful0 =
        update_entry0[ENTRY_USEFUL_MSB -: 2];
    wire [1:0] update_useful1 =
        update_entry1[ENTRY_USEFUL_MSB -: 2];
    wire [1:0] update_useful2 =
        update_entry2[ENTRY_USEFUL_MSB -: 2];
    wire [1:0] update_useful3 =
        update_entry3[ENTRY_USEFUL_MSB -: 2];

    reg allocation_valid;
    reg [2:0] allocation_table;
    always @(*) begin
        allocation_valid = 1'b0;
        allocation_table = 3'd0;
        if (table_update_valid) begin
            case (update_provider)
                PROVIDER_NONE: begin
                    if (!update_entry_valid0 || update_useful0 == 0) begin allocation_valid = 1'b1; allocation_table = 0; end
                    else if (!update_entry_valid1 || update_useful1 == 0) begin allocation_valid = 1'b1; allocation_table = 1; end
                    else if (!update_entry_valid2 || update_useful2 == 0) begin allocation_valid = 1'b1; allocation_table = 2; end
                    else if (!update_entry_valid3 || update_useful3 == 0) begin allocation_valid = 1'b1; allocation_table = 3; end
                end
                3'd0: begin
                    if (!update_entry_valid1 || update_useful1 == 0) begin allocation_valid = 1'b1; allocation_table = 1; end
                    else if (!update_entry_valid2 || update_useful2 == 0) begin allocation_valid = 1'b1; allocation_table = 2; end
                    else if (!update_entry_valid3 || update_useful3 == 0) begin allocation_valid = 1'b1; allocation_table = 3; end
                end
                3'd1: begin
                    if (!update_entry_valid2 || update_useful2 == 0) begin allocation_valid = 1'b1; allocation_table = 2; end
                    else if (!update_entry_valid3 || update_useful3 == 0) begin allocation_valid = 1'b1; allocation_table = 3; end
                end
                3'd2: begin
                    if (!update_entry_valid3 || update_useful3 == 0) begin allocation_valid = 1'b1; allocation_table = 3; end
                end
                default: begin end
            endcase
        end
    end

    always @(*) begin
        table0_we = 1'b0;
        table1_we = 1'b0;
        table2_we = 1'b0;
        table3_we = 1'b0;
        table0_waddr = {INDEX_WIDTH{1'b0}};
        table1_waddr = {INDEX_WIDTH{1'b0}};
        table2_waddr = {INDEX_WIDTH{1'b0}};
        table3_waddr = {INDEX_WIDTH{1'b0}};
        table0_wdata = {ENTRY_WIDTH{1'b0}};
        table1_wdata = {ENTRY_WIDTH{1'b0}};
        table2_wdata = {ENTRY_WIDTH{1'b0}};
        table3_wdata = {ENTRY_WIDTH{1'b0}};

        if (init_active) begin
            table0_we = 1'b1;
            table1_we = 1'b1;
            table2_we = 1'b1;
            table3_we = 1'b1;
            table0_waddr = init_index;
            table1_waddr = init_index;
            table2_waddr = init_index;
            table3_waddr = init_index;
        end else if (table_age_valid) begin
            table0_we = 1'b1;
            table1_we = 1'b1;
            table2_we = 1'b1;
            table3_we = 1'b1;
            table0_waddr = table_age_index;
            table1_waddr = table_age_index;
            table2_waddr = table_age_index;
            table3_waddr = table_age_index;
            table0_wdata = update_entry0;
            table1_wdata = update_entry1;
            table2_wdata = update_entry2;
            table3_wdata = update_entry3;
            table0_wdata[ENTRY_USEFUL_MSB] = 1'b0;
            table1_wdata[ENTRY_USEFUL_MSB] = 1'b0;
            table2_wdata[ENTRY_USEFUL_MSB] = 1'b0;
            table3_wdata[ENTRY_USEFUL_MSB] = 1'b0;
        end else if (table_update_valid) begin
                case (update_provider)
                    3'd0: if (update_entry_valid0 &&
                        update_entry_tag0 == update_tag0) begin
                        table0_we = 1'b1;
                        table0_waddr = update_index0;
                        table0_wdata = entry_make(
                            update_entry_valid0, update_entry_tag0,
                            counter_update(update_counter0,
                                table_update_actual_taken),
                            useful_update(update_useful0,
                                update_provider_prediction,
                                update_alternate_prediction,
                                table_update_actual_taken));
                    end
                    3'd1: if (update_entry_valid1 &&
                        update_entry_tag1 == update_tag1) begin
                        table1_we = 1'b1;
                        table1_waddr = update_index1;
                        table1_wdata = entry_make(
                            update_entry_valid1, update_entry_tag1,
                            counter_update(update_counter1,
                                table_update_actual_taken),
                            useful_update(update_useful1,
                                update_provider_prediction,
                                update_alternate_prediction,
                                table_update_actual_taken));
                    end
                    3'd2: if (update_entry_valid2 &&
                        update_entry_tag2 == update_tag2) begin
                        table2_we = 1'b1;
                        table2_waddr = update_index2;
                        table2_wdata = entry_make(
                            update_entry_valid2, update_entry_tag2,
                            counter_update(update_counter2,
                                table_update_actual_taken),
                            useful_update(update_useful2,
                                update_provider_prediction,
                                update_alternate_prediction,
                                table_update_actual_taken));
                    end
                    3'd3: if (update_entry_valid3 &&
                        update_entry_tag3 == update_tag3) begin
                        table3_we = 1'b1;
                        table3_waddr = update_index3;
                        table3_wdata = entry_make(
                            update_entry_valid3, update_entry_tag3,
                            counter_update(update_counter3,
                                table_update_actual_taken),
                            useful_update(update_useful3,
                                update_provider_prediction,
                                update_alternate_prediction,
                                table_update_actual_taken));
                    end
                    default: begin end
                endcase

                if ((update_tage_prediction != table_update_actual_taken) &&
                    allocation_valid) begin
                    case (allocation_table)
                        3'd0: begin
                            table0_we = 1'b1;
                            table0_waddr = update_index0;
                            table0_wdata = entry_make(1'b1, update_tag0,
                                table_update_actual_taken ? 3'b100 : 3'b011,
                                2'b00);
                        end
                        3'd1: begin
                            table1_we = 1'b1;
                            table1_waddr = update_index1;
                            table1_wdata = entry_make(1'b1, update_tag1,
                                table_update_actual_taken ? 3'b100 : 3'b011,
                                2'b00);
                        end
                        3'd2: begin
                            table2_we = 1'b1;
                            table2_waddr = update_index2;
                            table2_wdata = entry_make(1'b1, update_tag2,
                                table_update_actual_taken ? 3'b100 : 3'b011,
                                2'b00);
                        end
                        3'd3: begin
                            table3_we = 1'b1;
                            table3_waddr = update_index3;
                            table3_wdata = entry_make(1'b1, update_tag3,
                                table_update_actual_taken ? 3'b100 : 3'b011,
                                2'b00);
                        end
                        default: begin end
                    endcase
                end
        end
    end

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    integer loop_i;
`endif
    reg [63:0] recovered_history;
    always @(*) begin
        recovered_history = update_skip_history ?
            recover_meta[HISTORY_BASE +: 64] :
            {recover_meta[62:0], recover_actual_taken};
    end

    always @(posedge clk) begin
        if (rst) begin
            q_valid <= 1'b0;
            q_tables_ready <= 1'b0;
            global_history <= 64'b0;
            committed_history <= 64'b0;
            index_fold0 <= 0;
            index_fold1 <= 0;
            index_fold2 <= 0;
            index_fold3 <= 0;
            tag_fold0 <= 0;
            tag_fold1 <= 0;
            tag_fold2 <= 0;
            tag_fold3 <= 0;
            tag_alt_fold0 <= 0;
            tag_alt_fold1 <= 0;
            tag_alt_fold2 <= 0;
            tag_alt_fold3 <= 0;
            use_alt_on_na <= 4'b1000;
            age_counter <= 0;
            age_index <= 0;
            init_active <= 1'b1;
            init_index <= 0;
            table_update_valid <= 1'b0;
            table_age_valid <= 1'b0;
            update_bypass_valid0 <= 1'b0;
            update_bypass_valid1 <= 1'b0;
            update_bypass_valid2 <= 1'b0;
            update_bypass_valid3 <= 1'b0;
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            for (loop_i = 0; loop_i < LOOP_SELECT_ENTRIES;
                 loop_i = loop_i + 1) begin
                // Try a mature loop prediction once; subsequent disagreements
                // train the selector toward whichever predictor was correct.
                loop_select[loop_i] <= 2'b10;
            end
`endif
        end else begin
            table_update_valid <= table_update_accept;
            table_age_valid <= age_issue;
            if (table_update_accept) begin
                table_update_meta <= update_meta;
                table_update_actual_taken <= update_actual_taken;
            end
            if (age_issue)
                table_age_index <= age_index;

            // Update reads need forwarding so consecutive updates to the
            // same entry accumulate instead of both consuming stale data.
            update_bypass_valid0 <= update_read_request &&
                table0_we && (table0_waddr == update_read_addr0);
            update_bypass_valid1 <= update_read_request &&
                table1_we && (table1_waddr == update_read_addr1);
            update_bypass_valid2 <= update_read_request &&
                table2_we && (table2_waddr == update_read_addr2);
            update_bypass_valid3 <= update_read_request &&
                table3_we && (table3_waddr == update_read_addr3);
            if (table0_we && (table0_waddr == update_read_addr0))
                update_bypass_data0 <= table0_wdata;
            if (table1_we && (table1_waddr == update_read_addr1))
                update_bypass_data1 <= table1_wdata;
            if (table2_we && (table2_waddr == update_read_addr2))
                update_bypass_data2 <= table2_wdata;
            if (table3_we && (table3_waddr == update_read_addr3))
                update_bypass_data3 <= table3_wdata;

            if (init_active) begin
                age_counter <= 0;
                age_index <= 0;
                if (&init_index) begin
                    init_active <= 1'b0;
                end else begin
                    init_index <= init_index + 1'b1;
                end
            end else if (age_issue) begin
                age_counter <= 0;
                age_index <= age_index + 1'b1;
            end else if (!(&age_counter)) begin
                age_counter <= age_counter + 1'b1;
            end

            if (pipeline_flush) begin
                q_valid <= 1'b0;
            end else begin
                q_valid <= req_valid;
            end

            if (req_valid && !pipeline_flush) begin
                q_pc <= req_pc;
                q_history <= request_history;
                q_index0 <= req_index0;
                q_index1 <= req_index1;
                q_index2 <= req_index2;
                q_index3 <= req_index3;
                q_hash_tag0 <= req_hash_tag0;
                q_hash_tag1 <= req_hash_tag1;
                q_hash_tag2 <= req_hash_tag2;
                q_hash_tag3 <= req_hash_tag3;
                q_base_taken <= fast_base_taken;
                q_loop_override <= fast_loop_override;
                q_loop_taken <= fast_loop_taken;
                q_direction_override <= fast_direction_override;
                q_override_taken <= fast_override_taken;
                q_tables_ready <= !init_active;
            end

`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
            if (update_en && update_loop_candidate &&
                (update_loop_prediction != update_preloop_prediction)) begin
                if (update_loop_prediction == update_actual_taken) begin
                    if (loop_select[loop_select_update_idx] != 2'b11) begin
                        loop_select[loop_select_update_idx] <=
                            loop_select[loop_select_update_idx] + 1'b1;
                    end
                end else if (loop_select[loop_select_update_idx] != 2'b00) begin
                    loop_select[loop_select_update_idx] <=
                        loop_select[loop_select_update_idx] - 1'b1;
                end
            end
`endif

            if (recover_en) begin
                global_history <= recovered_history;
                index_fold0 <= fold_history_index(recovered_history, HIST0);
                index_fold1 <= fold_history_index(recovered_history, HIST1);
                index_fold2 <= fold_history_index(recovered_history, HIST2);
                index_fold3 <= fold_history_index(recovered_history, HIST3);
                tag_fold0 <= fold_history_tag(recovered_history, HIST0);
                tag_fold1 <= fold_history_tag(recovered_history, HIST1);
                tag_fold2 <= fold_history_tag(recovered_history, HIST2);
                tag_fold3 <= fold_history_tag(recovered_history, HIST3);
                tag_alt_fold0 <= fold_history_tag_alt(recovered_history, HIST0);
                tag_alt_fold1 <= fold_history_tag_alt(recovered_history, HIST1);
                tag_alt_fold2 <= fold_history_tag_alt(recovered_history, HIST2);
                tag_alt_fold3 <= fold_history_tag_alt(recovered_history, HIST3);
            end else if (restore_committed) begin
                global_history <= committed_history;
                index_fold0 <= fold_history_index(committed_history, HIST0);
                index_fold1 <= fold_history_index(committed_history, HIST1);
                index_fold2 <= fold_history_index(committed_history, HIST2);
                index_fold3 <= fold_history_index(committed_history, HIST3);
                tag_fold0 <= fold_history_tag(committed_history, HIST0);
                tag_fold1 <= fold_history_tag(committed_history, HIST1);
                tag_fold2 <= fold_history_tag(committed_history, HIST2);
                tag_fold3 <= fold_history_tag(committed_history, HIST3);
                tag_alt_fold0 <= fold_history_tag_alt(committed_history, HIST0);
                tag_alt_fold1 <= fold_history_tag_alt(committed_history, HIST1);
                tag_alt_fold2 <= fold_history_tag_alt(committed_history, HIST2);
                tag_alt_fold3 <= fold_history_tag_alt(committed_history, HIST3);
            end else if (spec_advance) begin
                global_history <= request_history;
                index_fold0 <= request_index_fold0;
                index_fold1 <= request_index_fold1;
                index_fold2 <= request_index_fold2;
                index_fold3 <= request_index_fold3;
                tag_fold0 <= request_tag_fold0;
                tag_fold1 <= request_tag_fold1;
                tag_fold2 <= request_tag_fold2;
                tag_fold3 <= request_tag_fold3;
                tag_alt_fold0 <= request_tag_alt_fold0;
                tag_alt_fold1 <= request_tag_alt_fold1;
                tag_alt_fold2 <= request_tag_alt_fold2;
                tag_alt_fold3 <= request_tag_alt_fold3;
            end

            if (update_en) begin
                committed_history <= {committed_history[62:0], update_actual_taken};
            end

            if (table_update_valid) begin
                if ((update_provider != PROVIDER_NONE) &&
                    ((update_provider_prediction == update_alternate_prediction) == 1'b0)) begin
                    if ((update_provider_prediction != table_update_actual_taken) && (&use_alt_on_na) == 1'b0)
                        use_alt_on_na <= use_alt_on_na + 1'b1;
                    else if ((update_alternate_prediction != table_update_actual_taken) && (|use_alt_on_na))
                        use_alt_on_na <= use_alt_on_na - 1'b1;
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    always @(posedge clk) begin
        if (!rst) begin
            if (init_active &&
                (!table0_we || !table1_we || !table2_we || !table3_we ||
                 table0_waddr != init_index ||
                 table1_waddr != init_index ||
                 table2_waddr != init_index ||
                 table3_waddr != init_index ||
                 table0_wdata != {ENTRY_WIDTH{1'b0}} ||
                 table1_wdata != {ENTRY_WIDTH{1'b0}} ||
                 table2_wdata != {ENTRY_WIDTH{1'b0}} ||
                 table3_wdata != {ENTRY_WIDTH{1'b0}})) begin
                $error("TAGE packed-table initialization lost write priority");
            end
            if (q_valid && !q_tables_ready &&
                (provider != PROVIDER_NONE ||
                 tage_prediction != q_base_taken)) begin
                $error("TAGE used a tagged entry before initialization");
            end
            if (table_update_valid && table_age_valid)
                $error("TAGE update and aging reads overlapped");
        end
    end
`endif

endmodule
