// Micro BTB (ubtb), rewritten per docs/ubtb-mbtb-refactor-plan.md (R1/R4/R5).
//
// Small, fast target predictor.  It is keyed by a 32B region and stores at most
// two taken CFI per region (`slot[2]`).  A slot has NO `taken` field: direction
// is owned by the direction predictor, and slot[0]/slot[1] participate in
// `pred_taken` independently (R1).
//
// Storage is split into UBTB_BANKS x UBTB_WAYS (bank = tag low bits) so the
// fully-associative tag compare and the CFI select are shallow and can be
// reduced one-hot instead of through a wide priority mux (R6 timing).
//
// `useful_cnt` is PER-SLOT (R4): valid == useful_cnt > 0.
//
// Timing structure (important):
//   * PREDICTION is a single registered level and must NOT be pipelined further:
//       request -> read btb_mem / one-hot map -> response register.
//   * UPDATE is a separate 4-stage background pipeline so the
//       `btb_mem -> match/PLRU/victim -> btb_mem.D` path is cut by registers:
//       U0 sample+address, U1 read the bank + PLRU and register, U2 match /
//       victim / new entry, U3 write back + PLRU touch.
//     Update latency is 4 cycles and does not affect prediction latency.
/* verilator lint_off UNUSEDSIGNAL */
module ubtb (
    input logic clk,
    input logic rst,

    // predict port
    input  logic                                                                 req_valid,
    input                     [fe_pkg::ADDR_WIDTH - 1:0]                         fetch_pc,
    output logic                                                                 resp_valid,
    output                    [fe_pkg::ADDR_WIDTH - 1:0]                         resp_pc,
    output logic              [ fe_pkg::FETCH_WIDTH-1:0]                         pred_cfi_valid,
    output fe_pkg::cfi_type_t [ fe_pkg::FETCH_WIDTH-1:0]                         pred_cfi_type,
    output logic              [ fe_pkg::FETCH_WIDTH-1:0][fe_pkg::ADDR_WIDTH-1:0] pred_target,

    // update port: only taken branches/jumps allocate a target
    input logic                                                update_en,
    output logic update_ready,
    input                           [fe_pkg::ADDR_WIDTH - 1:0] update_pc,
    input logic                                                actual_taken,
    input logic                                                update_pred_taken,
    input fe_pkg::btb_target_info_t                            update_target
);
    import fe_pkg::*;

    localparam int unsigned WAY_IDX_W  = (UBTB_WAYS > 1) ? $clog2(UBTB_WAYS) : 1;
    localparam int unsigned SLOT_IDX_W = (UBTB_SLOT_NUM > 1) ? $clog2(UBTB_SLOT_NUM) : 1;
    localparam int unsigned PLRU_BITS  = UBTB_WAYS - 1;
    localparam int unsigned POS_MASK_W = UBTB_POS_WIDTH;

    (* ram_style = "distributed" *)
    ubtb_entry_t btb_mem [UBTB_BANKS][UBTB_WAYS];

    // per-bank tree-PLRU state
    logic [UBTB_BANKS-1:0][PLRU_BITS-1:0] plru;

    // ------- PLRU helpers -------
    function automatic logic [WAY_IDX_W-1:0] plru_victim_fn(input logic [PLRU_BITS-1:0] cur);
        logic [WAY_IDX_W-1:0] vic;
        int node;
        vic  = '0;
        node = 0;
        for (int level = 0; level < WAY_IDX_W; level++) begin
            vic  = (vic << 1) | WAY_IDX_W'(cur[node]);
            node = (node << 1) + 1 + cur[node];
        end
        return vic;
    endfunction

    function automatic logic [PLRU_BITS-1:0] plru_touch(input logic [PLRU_BITS-1:0] cur,
                                                        input logic [WAY_IDX_W-1:0] way);
        logic [PLRU_BITS-1:0] next_plru;
        int node;
        next_plru = cur;
        node = 0;
        for (int level = WAY_IDX_W - 1; level >= 0; level--) begin
            next_plru[node] = ~way[level];
            node = 2 * node + 1 + way[level];
        end
        return next_plru;
    endfunction

    // =======================================================================
    // PREDICTION: single registered level (do NOT add pipeline stages)
    // =======================================================================
    logic [ADDR_WIDTH-1:0] pred_region_lo;
    logic [ADDR_WIDTH-1:0] pred_region_hi;
    logic [UBTB_TAG_WIDTH-1:0] pred_tag_lo;
    logic [UBTB_TAG_WIDTH-1:0] pred_tag_hi;

    assign pred_region_lo = fetch_pc & ~ADDR_WIDTH'(UBTB_REGION_BYTES - 1);
    assign pred_region_hi = pred_region_lo + ADDR_WIDTH'(UBTB_REGION_BYTES);
    assign pred_tag_lo    = pred_region_lo[ADDR_WIDTH-1:UBTB_REGION_WIDTH];
    assign pred_tag_hi    = pred_region_hi[ADDR_WIDTH-1:UBTB_REGION_WIDTH];

    logic      [FETCH_WIDTH-1:0]                 pred_cfi_valid_comb;
    cfi_type_t [FETCH_WIDTH-1:0]                 pred_cfi_type_comb;
    logic      [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target_comb;

    always_comb begin
        logic [ADDR_WIDTH-1:0] cfi_pc;
        logic [ADDR_WIDTH-1:0] off;
        cfi_pc = '0;
        off    = '0;

        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pred_cfi_valid_comb[i] = 1'b0;
            pred_cfi_type_comb[i]  = CFI_NONE;
            pred_target_comb[i]    = '0;
        end

        for (int b = 0; b < UBTB_BANKS; b++) begin
            for (int w = 0; w < UBTB_WAYS; w++) begin
                if (btb_mem[b][w].tag == pred_tag_lo) begin
                    for (int s = 0; s < UBTB_SLOT_NUM; s++) begin
                        if (btb_mem[b][w].slot[s].useful_cnt != '0) begin
                            cfi_pc = pred_region_lo
                                   + ADDR_WIDTH'({btb_mem[b][w].slot[s].position, 2'b00});
                            off = cfi_pc - fetch_pc;
                            if (off < ADDR_WIDTH'(FETCH_WIDTH * INST_BYTES)) begin
                                pred_cfi_valid_comb[off[3:2]] = 1'b1;
                                pred_cfi_type_comb[off[3:2]]  = btb_mem[b][w].slot[s].cfi_type;
                                pred_target_comb[off[3:2]]    = btb_mem[b][w].slot[s].target;
                            end
                        end
                    end
                end
                if (btb_mem[b][w].tag == pred_tag_hi) begin
                    for (int s = 0; s < UBTB_SLOT_NUM; s++) begin
                        if (btb_mem[b][w].slot[s].useful_cnt != '0) begin
                            cfi_pc = pred_region_hi
                                   + ADDR_WIDTH'({btb_mem[b][w].slot[s].position, 2'b00});
                            off = cfi_pc - fetch_pc;
                            if (off < ADDR_WIDTH'(FETCH_WIDTH * INST_BYTES)) begin
                                pred_cfi_valid_comb[off[3:2]] = 1'b1;
                                pred_cfi_type_comb[off[3:2]]  = btb_mem[b][w].slot[s].cfi_type;
                                pred_target_comb[off[3:2]]    = btb_mem[b][w].slot[s].target;
                            end
                        end
                    end
                end
            end
        end
    end

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

    // =======================================================================
    // UPDATE: U0 / U1 / U2 / U3 (independent background pipeline)
    // =======================================================================
    // launch source: an older pending request wins over the live input
    logic                  pend_valid;
    logic [ADDR_WIDTH-1:0] pend_pc;
    logic [ADDR_WIDTH-1:0] pend_target;
    cfi_type_t             pend_type;
    logic                  pend_taken;
    logic                  pend_pred_taken;

    wire [ADDR_WIDTH-1:0] src_pc         = pend_valid ? pend_pc         : update_pc;
    wire [ADDR_WIDTH-1:0] src_target     = pend_valid ? pend_target     : update_target.target_pc;
    wire cfi_type_t       src_type       = pend_valid ? pend_type       : update_target.cfi_type;
    wire                  src_taken      = pend_valid ? pend_taken      : actual_taken;
    wire                  src_pred_taken = pend_valid ? pend_pred_taken : update_pred_taken;
    wire                  src_valid      = pend_valid | update_en;

    wire [ADDR_WIDTH-1:0]      src_region = src_pc & ~ADDR_WIDTH'(UBTB_REGION_BYTES - 1);
    wire [UBTB_TAG_WIDTH-1:0]  src_tag    = src_region[ADDR_WIDTH-1:UBTB_REGION_WIDTH];
    wire [UBTB_BANK_SEL_WIDTH-1:0] src_bank = src_tag[UBTB_BANK_SEL_WIDTH-1:0];
    wire [POS_MASK_W-1:0]      src_pos    = POS_MASK_W'((src_pc >> 2) & ((1 << UBTB_POS_WIDTH) - 1));

    // U0 registers
    logic                          upd_valid_u0;
    logic [UBTB_BANK_SEL_WIDTH-1:0] upd_bank_u0;
    logic [UBTB_TAG_WIDTH-1:0]     upd_tag_u0;
    logic [UBTB_POS_WIDTH-1:0]     upd_pos_u0;
    cfi_type_t                     upd_type_u0;
    logic [ADDR_WIDTH-1:0]         upd_target_u0;
    logic                          upd_taken_u0, upd_pred_taken_u0;

    // U1 registers
    logic                          upd_valid_u1;
    logic [UBTB_BANK_SEL_WIDTH-1:0] upd_bank_u1;
    logic [UBTB_TAG_WIDTH-1:0]     upd_tag_u1;
    logic [UBTB_POS_WIDTH-1:0]     upd_pos_u1;
    cfi_type_t                     upd_type_u1;
    logic [ADDR_WIDTH-1:0]         upd_target_u1;
    logic                          upd_taken_u1, upd_pred_taken_u1;
    ubtb_entry_t                   upd_way_u1 [UBTB_WAYS];
    logic [PLRU_BITS-1:0]          upd_plru_u1;

    // U2 registers
    logic                          upd_valid_u2;
    logic [UBTB_BANK_SEL_WIDTH-1:0] upd_bank_u2;
    logic [WAY_IDX_W-1:0]          upd_way_u2;
    ubtb_entry_t                   upd_entry_u2;
    logic                          upd_wr_en_u2;
    logic                          upd_plru_we_u2;
    logic [PLRU_BITS-1:0]          upd_plru_u2;

    // Same-bank hazard: a not-yet-written update is in U0/U1/U2 (write is 4
    // cycles after launch).  Defer a same-bank source (depth-1 pending buffer).
    wire upd_conflict = src_valid &&
                        ((upd_valid_u0 && (src_bank == upd_bank_u0)) ||
                         (upd_valid_u1 && (src_bank == upd_bank_u1)) ||
                         (upd_valid_u2 && (src_bank == upd_bank_u2)));
    wire upd_launch   = src_valid && !upd_conflict;
    // The single pending slot must never silently overwrite a training event.
    assign update_ready = !pend_valid;

    // U2 combinational match / victim / new entry (reads only U1 registers)
    logic                 upd_has_match;
    logic [WAY_IDX_W-1:0] upd_match_way;
    logic                 upd_slot_match;
    logic [SLOT_IDX_W-1:0] upd_slot_idx;
    logic                 upd_info_match;
    logic                 upd_has_free;
    logic [SLOT_IDX_W-1:0] upd_free_idx;
    logic                 upd_has_dead;
    logic [WAY_IDX_W-1:0] upd_dead_idx;
    logic [WAY_IDX_W-1:0] upd_victim;
    logic [WAY_IDX_W-1:0] upd_way_sel;
    logic                 upd_wr_en;
    logic                 upd_plru_we;
    ubtb_entry_t          upd_entry;
    logic [PLRU_BITS-1:0] upd_plru_next;

    always_comb begin
        ubtb_slot_t new_slot;

        upd_has_match  = 1'b0;
        upd_match_way  = '0;
        upd_slot_match = 1'b0;
        upd_slot_idx   = '0;
        upd_has_free   = 1'b0;
        upd_free_idx   = '0;
        upd_has_dead   = 1'b0;
        upd_dead_idx   = '0;
        upd_wr_en      = 1'b0;
        upd_plru_we    = 1'b0;
        upd_plru_next  = upd_plru_u1;
        upd_entry      = upd_way_u1[0];

        for (int w = 0; w < UBTB_WAYS; w++) begin
            if (upd_way_u1[w].tag == upd_tag_u1) begin
                upd_has_match = 1'b1;
                upd_match_way = WAY_IDX_W'(w);
            end
            if ((upd_way_u1[w].slot[0].useful_cnt == '0) &&
                (upd_way_u1[w].slot[1].useful_cnt == '0) && !upd_has_dead) begin
                upd_has_dead = 1'b1;
                upd_dead_idx = WAY_IDX_W'(w);
            end
        end

        if (upd_has_match) begin
            for (int s = 0; s < UBTB_SLOT_NUM; s++) begin
                if (!upd_slot_match &&
                    (upd_way_u1[upd_match_way].slot[s].position == upd_pos_u1)) begin
                    upd_slot_match = 1'b1;
                    upd_slot_idx   = SLOT_IDX_W'(s);
                end
                if (!upd_has_free &&
                    (upd_way_u1[upd_match_way].slot[s].useful_cnt == '0)) begin
                    upd_has_free = 1'b1;
                    upd_free_idx = SLOT_IDX_W'(s);
                end
            end
        end

        upd_info_match = upd_slot_match &&
            (upd_way_u1[upd_match_way].slot[upd_slot_idx].target == upd_target_u1) &&
            (upd_way_u1[upd_match_way].slot[upd_slot_idx].cfi_type == upd_type_u1);

        upd_victim = upd_has_dead ? upd_dead_idx : plru_victim_fn(upd_plru_u1);
        upd_way_sel = upd_has_match ? upd_match_way : upd_victim;

        new_slot.position         = upd_pos_u1;
        new_slot.cfi_type         = upd_type_u1;
        new_slot.is_static_target = (upd_type_u1 != CFI_RETURN) &&
                                    (upd_type_u1 != CFI_INDIRECT_JUMP);
        new_slot.target           = upd_target_u1;
        new_slot.useful_cnt       = 2'b01;

        upd_entry = upd_way_u1[upd_way_sel];

        if (upd_taken_u1) begin
            if (!upd_has_match) begin
                upd_entry.tag             = upd_tag_u1;
                upd_entry.slot[0]         = new_slot;
                upd_entry.slot[1].useful_cnt = '0;
                upd_wr_en   = 1'b1;
                upd_plru_we = 1'b1;
                upd_plru_next = plru_touch(upd_plru_u1, upd_victim);
            end else if (upd_slot_match) begin
                if (upd_info_match) begin
                    if (upd_way_u1[upd_match_way].slot[upd_slot_idx].useful_cnt != '1) begin
                        upd_entry.slot[upd_slot_idx].useful_cnt =
                            upd_way_u1[upd_match_way].slot[upd_slot_idx].useful_cnt + 1'b1;
                    end
                end else begin
                    upd_entry.slot[upd_slot_idx] = new_slot;
                end
                upd_wr_en     = 1'b1;
                upd_plru_we   = 1'b1;
                upd_plru_next = plru_touch(upd_plru_u1, upd_match_way);
            end else if (upd_has_free) begin
                upd_entry.slot[upd_free_idx] = new_slot;
                upd_wr_en     = 1'b1;
                upd_plru_we   = 1'b1;
                upd_plru_next = plru_touch(upd_plru_u1, upd_match_way);
            end else begin
                if (upd_way_u1[upd_match_way].slot[0].useful_cnt
                    <= upd_way_u1[upd_match_way].slot[1].useful_cnt) begin
                    upd_entry.slot[0] = new_slot;
                end else begin
                    upd_entry.slot[1] = new_slot;
                end
                upd_wr_en     = 1'b1;
                upd_plru_we   = 1'b1;
                upd_plru_next = plru_touch(upd_plru_u1, upd_match_way);
            end
        end else if (upd_pred_taken_u1) begin
            if (upd_has_match && upd_slot_match &&
                (upd_way_u1[upd_match_way].slot[upd_slot_idx].useful_cnt != '0)) begin
                upd_entry.slot[upd_slot_idx].useful_cnt =
                    upd_way_u1[upd_match_way].slot[upd_slot_idx].useful_cnt - 1'b1;
                upd_wr_en = 1'b1;
            end
        end
    end

    // =======================================================================
    // sequential: prediction register + update pipeline + write-back
    // =======================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            req_valid_r      <= 1'b0;
            req_pc_r         <= '0;
            pred_cfi_valid_r <= '0;
            pred_cfi_type_r  <= '0;
            pred_target_r    <= '0;

            upd_valid_u0 <= 1'b0;
            upd_bank_u0 <= '0; upd_tag_u0 <= '0; upd_pos_u0 <= '0;
            upd_type_u0 <= CFI_NONE; upd_target_u0 <= '0;
            upd_taken_u0 <= 1'b0; upd_pred_taken_u0 <= 1'b0;

            upd_valid_u1 <= 1'b0;
            upd_bank_u1 <= '0; upd_tag_u1 <= '0; upd_pos_u1 <= '0;
            upd_type_u1 <= CFI_NONE; upd_target_u1 <= '0;
            upd_taken_u1 <= 1'b0; upd_pred_taken_u1 <= 1'b0;
            upd_plru_u1 <= '0;

            upd_valid_u2 <= 1'b0;
            upd_bank_u2 <= '0; upd_way_u2 <= '0; upd_entry_u2 <= '0;
            upd_wr_en_u2 <= 1'b0; upd_plru_we_u2 <= 1'b0; upd_plru_u2 <= '0;

            pend_valid <= 1'b0;
            pend_pc <= '0; pend_target <= '0; pend_type <= CFI_NONE;
            pend_taken <= 1'b0; pend_pred_taken <= 1'b0;

            for (int b = 0; b < UBTB_BANKS; b++) begin
                plru[b] <= '0;
                for (int w = 0; w < UBTB_WAYS; w++) begin
                    btb_mem[b][w].tag <= '0;
                    for (int s = 0; s < UBTB_SLOT_NUM; s++) begin
                        btb_mem[b][w].slot[s].useful_cnt <= '0;
                    end
                end
            end
        end else begin
            // ---------------- prediction register ----------------
            req_valid_r <= req_valid;
            if (req_valid) begin
                req_pc_r         <= fetch_pc;
                pred_cfi_valid_r <= pred_cfi_valid_comb;
                pred_cfi_type_r  <= pred_cfi_type_comb;
                pred_target_r    <= pred_target_comb;
            end

            // ---------------- update U0 ----------------
            upd_valid_u0      <= upd_launch;
            upd_bank_u0       <= src_bank;
            upd_tag_u0        <= src_tag;
            upd_pos_u0        <= src_pos;
            upd_type_u0       <= src_type;
            upd_target_u0     <= src_target;
            upd_taken_u0      <= src_taken;
            upd_pred_taken_u0 <= src_pred_taken;

            // pending buffer (depth 1)
            if (pend_valid) begin
                if (upd_launch) begin
                    pend_valid <= update_en;
                    if (update_en) begin
                        pend_pc <= update_pc; pend_target <= update_target.target_pc;
                        pend_type <= update_target.cfi_type; pend_taken <= actual_taken;
                        pend_pred_taken <= update_pred_taken;
                    end
                end
                // else: still conflicted -> hold
            end else if (update_en && !upd_launch) begin
                pend_valid <= 1'b1;
                pend_pc <= update_pc; pend_target <= update_target.target_pc;
                pend_type <= update_target.cfi_type; pend_taken <= actual_taken;
                pend_pred_taken <= update_pred_taken;
            end

            // ---------------- update U1: read the bank + PLRU ----------------
            upd_valid_u1      <= upd_valid_u0;
            upd_bank_u1       <= upd_bank_u0;
            upd_tag_u1        <= upd_tag_u0;
            upd_pos_u1        <= upd_pos_u0;
            upd_type_u1       <= upd_type_u0;
            upd_target_u1     <= upd_target_u0;
            upd_taken_u1      <= upd_taken_u0;
            upd_pred_taken_u1 <= upd_pred_taken_u0;
            upd_plru_u1       <= plru[upd_bank_u0];
            for (int w = 0; w < UBTB_WAYS; w++) begin
                upd_way_u1[w] <= btb_mem[upd_bank_u0][w];
            end

            // ---------------- update U2: match / victim / entry ----------------
            upd_valid_u2   <= upd_valid_u1;
            upd_bank_u2    <= upd_bank_u1;
            upd_way_u2     <= upd_way_sel;
            upd_entry_u2   <= upd_entry;
            upd_wr_en_u2   <= upd_valid_u1 && upd_wr_en;
            upd_plru_we_u2 <= upd_valid_u1 && upd_plru_we;
            upd_plru_u2    <= upd_plru_next;

            // ---------------- update U3: write back + PLRU ----------------
            if (upd_wr_en_u2) begin
                btb_mem[upd_bank_u2][upd_way_u2] <= upd_entry_u2;
            end
            if (upd_plru_we_u2) begin
                plru[upd_bank_u2] <= upd_plru_u2;
            end
        end
    end

    /* verilator lint_on UNUSEDSIGNAL */
endmodule
