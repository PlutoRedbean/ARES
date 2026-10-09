// Multi-target BTB.
//
// Direction prediction lives in bpu/direction/*; this module only answers
// "which control-flow instructions does this fetch window contain, and what are
// their targets".  The response is 1-cycle pipelined so it lines up with the
// direction predictor.
//
// The table is a fully-associative uBTB keyed by the FETCH_WIDTH aligned block.
// Each entry holds up to FETCH_WIDTH CFI slots (a block of N instructions can
// contain at most N control-flow instructions), so a block with several
// branches no longer aliases into a single entry.  The per-entry `useful_cnt`
// plays the role of both the valid bit and an "always-taken" confidence
// counter (valid == useful_cnt > 0).  On replacement a dead entry
// (useful_cnt == 0) is preferred, otherwise the tree-PLRU way is evicted.
//
// A fetch window may start unaligned, in which case its tail reaches into the
// *next* block; the predictor therefore looks up both the block containing
// `fetch_pc` and the following block and merges their slots.
/* verilator lint_off UNUSEDSIGNAL */
module ubtb (
    input logic clk,
    input logic rst,

    // predict port
    input  logic                                                                    req_valid,
    input                      [fe_pkg::ADDR_WIDTH - 1:0]                          fetch_pc,
    output logic                                                                    resp_valid,
    output                     [fe_pkg::ADDR_WIDTH - 1:0]                          resp_pc,
    output logic               [ fe_pkg::FETCH_WIDTH-1:0]                          pred_cfi_valid,
    output fe_pkg::cfi_type_t [ fe_pkg::FETCH_WIDTH-1:0]                          pred_cfi_type,
    output logic               [ fe_pkg::FETCH_WIDTH-1:0][fe_pkg::ADDR_WIDTH-1:0] pred_target,

    // update port: only taken branches/jumps allocate a target
    input logic                                                  update_en,
    input                            [fe_pkg::ADDR_WIDTH - 1:0] update_pc,
    input logic                                                  actual_taken,
    input fe_pkg::btb_target_info_t                             update_target
);
    import fe_pkg::*;

    localparam int unsigned ENTRIES      = 1 << UBTB_WIDTH;
    localparam int unsigned OFFSET_WIDTH = $clog2(FETCH_WIDTH * INST_BYTES);
    localparam int unsigned TAG_WIDTH    = ADDR_WIDTH - OFFSET_WIDTH;
    localparam int unsigned BLOCK_BYTES  = FETCH_WIDTH * INST_BYTES;
    localparam int unsigned PLRU_BITS    = ENTRIES - 1;
    localparam int unsigned CFI_CNT_W    = $clog2(FETCH_WIDTH + 1);
    localparam int unsigned SLOT_OFF_W   = $clog2(2 * FETCH_WIDTH);

    (* ram_style = "distributed" *)
    btb_entry_t btb_mem[ENTRIES];

    logic [PLRU_BITS-1:0] plru;

    // ------ index -------

    logic [ADDR_WIDTH-1:0] pred_block_pc;
    logic [ADDR_WIDTH-1:0] pred_next_block_pc;
    logic [ADDR_WIDTH-1:0] update_block_pc;
    logic [TAG_WIDTH-1:0] pred_tag_lo;
    logic [TAG_WIDTH-1:0] pred_tag_hi;
    logic [TAG_WIDTH-1:0] update_tag;

    // implement a cross-block lookup to handle the issue
    // that fetch pc isn't aligned to the fetch block
    assign pred_block_pc      = fetch_pc & ~(BLOCK_BYTES - 1);
    assign pred_next_block_pc = pred_block_pc + BLOCK_BYTES;
    assign update_block_pc    = update_pc & ~(BLOCK_BYTES - 1);
    assign pred_tag_lo        = pred_block_pc[ADDR_WIDTH-1:OFFSET_WIDTH];
    assign pred_tag_hi        = pred_next_block_pc[ADDR_WIDTH-1:OFFSET_WIDTH];
    assign update_tag         = update_block_pc[ADDR_WIDTH-1:OFFSET_WIDTH];

    // ------ predict ------
    logic                  hit_lo;
    logic [UBTB_WIDTH-1:0] idx_lo;
    logic                  hit_hi;
    logic [UBTB_WIDTH-1:0] idx_hi;

    always_comb begin
        hit_lo = 1'b0;
        idx_lo = '0;
        hit_hi = 1'b0;
        idx_hi = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (btb_mem[i].useful_cnt != '0) begin
                if (btb_mem[i].tag == pred_tag_lo) begin
                    hit_lo = 1'b1;
                    idx_lo = UBTB_WIDTH'(i);
                end
                if (btb_mem[i].tag == pred_tag_hi) begin
                    hit_hi = 1'b1;
                    idx_hi = UBTB_WIDTH'(i);
                end
            end
        end
    end

    // map the CFI records of both blocks to the slots of this fetch window
    logic [FETCH_WIDTH-1:0] fetch_block_offset;
    assign fetch_block_offset = FETCH_WIDTH'(fetch_pc[OFFSET_WIDTH-1:2]);

    logic      [FETCH_WIDTH-1:0]                 pred_cfi_valid_comb;
    cfi_type_t [FETCH_WIDTH-1:0]                 pred_cfi_type_comb;
    logic      [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target_comb;

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            logic [SLOT_OFF_W-1:0] slot_offset;
            slot_offset            = SLOT_OFF_W'(fetch_block_offset) + SLOT_OFF_W'(i);
            pred_cfi_valid_comb[i] = 1'b0;
            pred_cfi_type_comb[i]  = CFI_NONE;
            pred_target_comb[i]    = '0;

            if (slot_offset < SLOT_OFF_W'(FETCH_WIDTH)) begin
                for (int r = 0; r < FETCH_WIDTH; r++) begin
                    if (hit_lo && (r < int'(btb_mem[idx_lo].cfi_count)) &&
                        (SLOT_OFF_W'(btb_mem[idx_lo].cfi[r].cfi_offset) == slot_offset)) begin
                        pred_cfi_valid_comb[i] = 1'b1;
                        pred_cfi_type_comb[i]  = btb_mem[idx_lo].cfi[r].cfi_type;
                        pred_target_comb[i]    = btb_mem[idx_lo].cfi[r].target_pc;
                    end
                end
            end else begin
                for (int r = 0; r < FETCH_WIDTH; r++) begin
                    if (hit_hi && (r < int'(btb_mem[idx_hi].cfi_count)) &&
                        (SLOT_OFF_W'(btb_mem[idx_hi].cfi[r].cfi_offset) +
                         SLOT_OFF_W'(FETCH_WIDTH) == slot_offset)) begin
                        pred_cfi_valid_comb[i] = 1'b1;
                        pred_cfi_type_comb[i]  = btb_mem[idx_hi].cfi[r].cfi_type;
                        pred_target_comb[i]    = btb_mem[idx_hi].cfi[r].target_pc;
                    end
                end
            end
        end
    end

    // 1-cycle pipelined response
    logic                                        req_valid_r;
    logic      [ ADDR_WIDTH-1:0]                 req_pc_r;
    logic      [FETCH_WIDTH-1:0]                 pred_cfi_valid_r;
    cfi_type_t [FETCH_WIDTH-1:0]                 pred_cfi_type_r;
    logic      [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target_r;

    assign resp_valid     = req_valid_r;
    assign resp_pc        = req_pc_r;
    assign pred_cfi_valid = pred_cfi_valid_r;
    assign pred_cfi_type  = pred_cfi_type_r;
    assign pred_target    = pred_target_r;

    // -------- update ---------
    logic                  update_has_match;
    logic [UBTB_WIDTH-1:0] update_match_idx;
    always_comb begin
        update_has_match = 1'b0;
        update_match_idx = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (btb_mem[i].tag == update_tag) begin
                update_has_match = 1'b1;
                update_match_idx = UBTB_WIDTH'(i);
            end
        end
    end

    // does the block entry already carry a CFI at this offset?
    logic                 update_record_match;
    logic [CFI_CNT_W-1:0] update_record_idx;
    always_comb begin
        update_record_match = 1'b0;
        update_record_idx   = '0;
        if (update_has_match) begin
            for (int r = 0; r < FETCH_WIDTH; r++) begin
                if ((r < btb_mem[update_match_idx].cfi_count) &&
                    (btb_mem[update_match_idx].cfi[r].cfi_offset == update_target.cfi_offset)) begin
                    update_record_match = 1'b1;
                    update_record_idx   = CFI_CNT_W'(r);
                end
            end
        end
    end

    logic update_record_info_match;
    assign update_record_info_match =
        update_record_match &&
        (btb_mem[update_match_idx].cfi[update_record_idx].target_pc == update_target.target_pc) &&
        (btb_mem[update_match_idx].cfi[update_record_idx].cfi_type == update_target.cfi_type);

    btb_cfi_t update_cfi;
    assign update_cfi = '{
            cfi_offset: update_target.cfi_offset,
            cfi_type: update_target.cfi_type,
            target_pc: update_target.target_pc
        };

    // ------- PLRU --------
    // tree-based pseudo-LRU over the ENTRIES ways
    logic [UBTB_WIDTH-1:0] plru_victim;
    always_comb begin
        int node;
        node = 0;
        plru_victim = '0;
        for (int level = 0; level < UBTB_WIDTH; level++) begin
            plru_victim = (plru_victim << 1) | UBTB_WIDTH'(plru[node]);
            node = (node << 1) + 1 + plru[node];
        end
    end

    // lowest-index entry whose useful counter has already decayed to 0
    logic                  has_useful_zero;
    logic [UBTB_WIDTH-1:0] useful_zero_idx;
    always_comb begin
        has_useful_zero = 1'b0;
        useful_zero_idx = '0;
        for (int i = 0; i < ENTRIES; i++) begin
            if (!has_useful_zero && (btb_mem[i].useful_cnt == '0)) begin
                has_useful_zero = 1'b1;
                useful_zero_idx = UBTB_WIDTH'(i);
            end
        end
    end

    // replacement victim: a dead entry if any, otherwise the PLRU way
    logic [UBTB_WIDTH-1:0] victim_way;
    assign victim_way = has_useful_zero ? useful_zero_idx : plru_victim;

    // mark the accessed way as most-recently-used in the PLRU tree
    function automatic logic [PLRU_BITS-1:0] plru_touch(input logic [PLRU_BITS-1:0] cur,
                                                        input logic [UBTB_WIDTH-1:0] way);
        logic [PLRU_BITS-1:0] next_plru;
        int node;
        next_plru = cur;
        node = 0;
        for (int level = UBTB_WIDTH - 1; level >= 0; level--) begin
            next_plru[node] = ~way[level];
            node = 2 * node + 1 + way[level];
        end
        return next_plru;
    endfunction

    logic                  plru_touch_en;
    logic [UBTB_WIDTH-1:0] plru_touch_way;
    logic [ PLRU_BITS-1:0] plru_next;

    assign plru_touch_en  = update_en && actual_taken;
    assign plru_touch_way = (actual_taken && !update_has_match) ? victim_way : update_match_idx;

    always_comb begin
        plru_next = plru;
        if (plru_touch_en) begin
            plru_next = plru_touch(plru_next, plru_touch_way);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            plru <= '0;
        end else begin
            plru <= plru_next;
        end
    end

    // --------- sequential ---------
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            req_valid_r      <= 1'b0;
            req_pc_r         <= '0;
            pred_cfi_valid_r <= '0;
            pred_cfi_type_r  <= '0;
            pred_target_r    <= '0;
            for (i = 0; i < ENTRIES; i = i + 1) begin
                btb_mem[i].useful_cnt <= '0;
                btb_mem[i].cfi_count  <= '0;
            end
        end else begin
            req_valid_r      <= req_valid;
            req_pc_r         <= fetch_pc;
            pred_cfi_valid_r <= pred_cfi_valid_comb;
            pred_cfi_type_r  <= pred_cfi_type_comb;
            pred_target_r    <= pred_target_comb;

            if (update_en) begin
                if (actual_taken) begin
                    if (!update_has_match) begin
                        // fresh block -> allocate the replacement victim with
                        // this single CFI
                        btb_mem[victim_way].useful_cnt <= 2'b01;
                        btb_mem[victim_way].tag        <= update_tag;
                        btb_mem[victim_way].cfi_count  <= CFI_CNT_W'(1);
                        btb_mem[victim_way].cfi[0]     <= update_cfi;
                    end else if (update_record_match) begin
                        if (update_record_info_match) begin
                            // same CFI, same target -> confidence +
                            btb_mem[update_match_idx].useful_cnt <=
                                (btb_mem[update_match_idx].useful_cnt == '1) ? '1 :
                                (btb_mem[update_match_idx].useful_cnt + 1'b1);
                        end else begin
                            // stale target/type -> rewrite the record
                            btb_mem[update_match_idx].cfi[update_record_idx] <= update_cfi;
                            btb_mem[update_match_idx].useful_cnt <= 2'b01;
                        end
                    end else begin
                        // a CFI at an offset the entry did not know yet
                        if (btb_mem[update_match_idx].cfi_count < CFI_CNT_W'(FETCH_WIDTH)) begin
                            btb_mem[update_match_idx].cfi[btb_mem[update_match_idx].cfi_count] <= update_cfi;
                            btb_mem[update_match_idx].cfi_count <= btb_mem[update_match_idx].cfi_count + 1'b1;
                        end else begin
                            // extremely rare (all slots already hold a CFI):
                            // replace the last record
                            btb_mem[update_match_idx].cfi[FETCH_WIDTH-1] <= update_cfi;
                        end
                        btb_mem[update_match_idx].useful_cnt <= 2'b01;
                    end
                end else begin
                    // predicted taken but actually not taken -> decay
                    if (update_has_match && update_record_match) begin
                        btb_mem[update_match_idx].useful_cnt <= btb_mem[update_match_idx].useful_cnt - 1'b1;
                    end
                end
            end
        end
    end

    /* verilator lint_on UNUSEDSIGNAL */
endmodule
