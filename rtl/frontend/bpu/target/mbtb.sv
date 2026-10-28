// Main BTB (mbtb), Region-BTB with a fixed 2-cycle prediction latency.
//
// Per docs/ubtb-mbtb-refactor-plan.md:
//   * region = 16B (= one fetch block), 64 sets x 4 ways, one CFI per way;
//   * a region's CFI share the tag and occupy distinct ways of one set;
//   * `lru` replacement (MBTB_WAYS*(MBTB_WAYS-1)/2 bits per set).
//
// mbtb is TARGET-ONLY: it carries no direction.  Conditional-branch direction is
// owned by loop > TAGE > bimodal/tournament (§2.3.1); the target chain is
// RAS > mbtb > ubtb.
//
// Timing structure (important):
//   * PREDICTION stays fixed at 2 levels and must not be pipelined further:
//       S0 request register -> S1 read SRAM + data register -> S2 combinational
//       filter/merge output.  pred_valid = r1_valid.
//   * UPDATE is a separate 4-stage background pipeline so the
//       `mbtb_mem -> match -> victim -> write` path is cut by registers:
//       U0 sample+address, U1 read the set and register all ways,
//       U2 match/victim/new-entry, U3 write back + LRU.
/* verilator lint_off UNUSEDSIGNAL */
module mbtb (
    input logic clk,
    input logic rst,

    // predict port (request at s0)
    input  logic                                 req_valid,
    input  logic [fe_pkg::ADDR_WIDTH - 1:0]      fetch_pc,

    // prediction result (valid 2 cycles after the request); targets only
    output logic                                 pred_valid,
    output logic [fe_pkg::ADDR_WIDTH - 1:0]      pred_pc,
    output logic              [ fe_pkg::FETCH_WIDTH-1:0]                         pred_cfi_valid,
    output fe_pkg::cfi_type_t [ fe_pkg::FETCH_WIDTH-1:0]                         pred_cfi_type,
    output logic              [ fe_pkg::FETCH_WIDTH-1:0][fe_pkg::ADDR_WIDTH-1:0] pred_target,

    // update port (commit level; trains every CFI)
    input logic                                  update_en,
    output logic update_ready,
    input logic [fe_pkg::ADDR_WIDTH - 1:0]       update_pc,
    input fe_pkg::cfi_type_t                     update_cfi_type,
    input logic [fe_pkg::ADDR_WIDTH - 1:0]       update_target
);
    import fe_pkg::*;

    localparam int unsigned WAY_IDX_W = (MBTB_WAYS > 1) ? $clog2(MBTB_WAYS) : 1;

    // One copy per read port: prediction reads two regions (lo/hi) and the
    // update path reads the set it is about to modify, so a single memory
    // would need 3 read ports and ADS would fall back to LUTRAM.  Each copy is
    // a simple dual-port (1R1W) memory holding one whole set per word, exactly
    // like tage_tag_array; a write is broadcast to all three copies.
    localparam int unsigned ENTRY_W = $bits(mbtb_entry_t);
    localparam int unsigned SET_W   = MBTB_WAYS * ENTRY_W;

    (* ram_style = "block" *)
    logic [SET_W-1:0] mbtb_lo_mem [MBTB_SET_NUM];   // read: prediction lo region
    (* ram_style = "block" *)
    logic [SET_W-1:0] mbtb_hi_mem [MBTB_SET_NUM];   // read: prediction hi region
    (* ram_style = "block" *)
    logic [SET_W-1:0] mbtb_up_mem [MBTB_SET_NUM];   // read: update pipeline

    logic [SET_W-1:0] lo_word_r, hi_word_r;
    // The update pipeline needs the set word it read (U1) and the same word one
    // stage later (U2) as the read-modify-write base; a single register would be
    // overwritten by the next update's read.
    logic [SET_W-1:0] up_word_u1, up_word_u2;
    logic [SET_W-1:0] upd_word;

    // triangular LRU matrix state, one per set
    logic [MBTB_LRU_BITS-1:0] lru [MBTB_SET_NUM];

    // index of pair (i,j), i<j
    function automatic int unsigned lru_bit(input int unsigned i, input int unsigned j);
        return i * (2 * MBTB_WAYS - 1 - i) / 2 + (j - i - 1);
    endfunction

    function automatic int unsigned lru_victim(input logic [MBTB_LRU_BITS-1:0] m);
        int unsigned w;
        lru_victim = 0;
        for (w = 0; w < MBTB_WAYS; w++) begin
            logic is_least;
            is_least = 1'b1;
            for (int j = 0; j < MBTB_WAYS; j++) begin
                if (j < w) begin
                    if (!m[lru_bit(j, w)]) is_least = 1'b0;
                end else if (j > w) begin
                    if (m[lru_bit(w, j)]) is_least = 1'b0;
                end
            end
            if (is_least) lru_victim = w;
        end
    endfunction

    function automatic logic [MBTB_LRU_BITS-1:0] lru_touch(
        input logic [MBTB_LRU_BITS-1:0] m, input int unsigned a);
        logic [MBTB_LRU_BITS-1:0] n;
        n = m;
        // m[i][j] == 1 means i is more recently used than j.
        for (int j = 0; j < MBTB_WAYS; j++) begin
            if (j < a) n[lru_bit(j, a)] = 1'b0;
            else if (j > a) n[lru_bit(a, j)] = 1'b1;
        end
        return n;
    endfunction

    // =======================================================================
    // PREDICTION: S0 / S1 / S2  (fixed 2-cycle latency)
    // =======================================================================
    logic                    r0_valid;
    logic [ADDR_WIDTH-1:0]   r0_pc;

    logic                    r1_valid;
    logic [ADDR_WIDTH-1:0]   r1_pc;
    mbtb_entry_t             way_lo_r1 [MBTB_WAYS];
    mbtb_entry_t             way_hi_r1 [MBTB_WAYS];

    logic [ADDR_WIDTH-1:0]     r0_region_lo;
    logic [ADDR_WIDTH-1:0]     r0_region_hi;
    logic [MBTB_IDX_WIDTH-1:0] r0_set_lo;
    logic [MBTB_IDX_WIDTH-1:0] r0_set_hi;

    assign r0_region_lo = r0_pc & ~ADDR_WIDTH'(MBTB_REGION_BYTES - 1);
    assign r0_region_hi = r0_region_lo + ADDR_WIDTH'(MBTB_REGION_BYTES);
    assign r0_set_lo    = r0_region_lo[MBTB_REGION_WIDTH+MBTB_IDX_WIDTH-1:MBTB_REGION_WIDTH];
    assign r0_set_hi    = r0_region_hi[MBTB_REGION_WIDTH+MBTB_IDX_WIDTH-1:MBTB_REGION_WIDTH];

    assign pred_valid = r1_valid;
    assign pred_pc    = r1_pc;

    always_comb begin
        logic [ADDR_WIDTH-1:0] region_lo;
        logic [ADDR_WIDTH-1:0] region_hi;
        logic [ADDR_WIDTH-1:0] cfi_pc;
        logic [ADDR_WIDTH-1:0] off;

        region_lo = r1_pc & ~ADDR_WIDTH'(MBTB_REGION_BYTES - 1);
        region_hi = region_lo + ADDR_WIDTH'(MBTB_REGION_BYTES);
        cfi_pc    = '0;
        off       = '0;

        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pred_cfi_valid[i] = 1'b0;
            pred_cfi_type[i]  = CFI_NONE;
            pred_target[i]    = '0;
        end

        for (int w = 0; w < MBTB_WAYS; w++) begin
            if (way_lo_r1[w].valid &&
                (way_lo_r1[w].tag == r1_pc[ADDR_WIDTH-1:MBTB_REGION_WIDTH+MBTB_IDX_WIDTH])) begin
                cfi_pc = region_lo + ADDR_WIDTH'({way_lo_r1[w].position, 2'b00});
                off    = cfi_pc - r1_pc;
                if (off < ADDR_WIDTH'(FETCH_WIDTH * INST_BYTES)) begin
                    pred_cfi_valid[off[3:2]] = 1'b1;
                    pred_cfi_type[off[3:2]]  = way_lo_r1[w].cfi_type;
                    pred_target[off[3:2]]    = {r1_pc[ADDR_WIDTH-1:MBTB_TARGET_WIDTH],
                                                way_lo_r1[w].target_lower};
                end
            end
            if (way_hi_r1[w].valid &&
                (way_hi_r1[w].tag == region_hi[ADDR_WIDTH-1:MBTB_REGION_WIDTH+MBTB_IDX_WIDTH])) begin
                cfi_pc = region_hi + ADDR_WIDTH'({way_hi_r1[w].position, 2'b00});
                off    = cfi_pc - r1_pc;
                if (off < ADDR_WIDTH'(FETCH_WIDTH * INST_BYTES)) begin
                    pred_cfi_valid[off[3:2]] = 1'b1;
                    pred_cfi_type[off[3:2]]  = way_hi_r1[w].cfi_type;
                    pred_target[off[3:2]]    = {r1_pc[ADDR_WIDTH-1:MBTB_TARGET_WIDTH],
                                                way_hi_r1[w].target_lower};
                end
            end
        end
    end

    // =======================================================================
    // UPDATE: U0 / U1 / U2 / U3  (independent background pipeline)
    // =======================================================================
    logic                        upd_valid_u0;
    logic [MBTB_TAG_WIDTH-1:0]   upd_tag_u0;
    logic [MBTB_IDX_WIDTH-1:0]   upd_set_u0;
    logic [MBTB_POS_WIDTH-1:0]   upd_pos_u0;
    cfi_type_t                   upd_type_u0;
    logic [ADDR_WIDTH-1:0]       upd_target_u0;

    logic                        upd_valid_u1;
    logic [MBTB_TAG_WIDTH-1:0]   upd_tag_u1;
    logic [MBTB_IDX_WIDTH-1:0]   upd_set_u1;
    logic [MBTB_POS_WIDTH-1:0]   upd_pos_u1;
    cfi_type_t                   upd_type_u1;
    logic [ADDR_WIDTH-1:0]       upd_target_u1;
    mbtb_entry_t                 upd_way_u1 [MBTB_WAYS];

    logic                        upd_valid_u2;
    logic [MBTB_IDX_WIDTH-1:0]   upd_set_u2;
    logic [WAY_IDX_W-1:0]        upd_way_u2;
    mbtb_entry_t                 upd_entry_u2;

    // launch source: an older pending request wins over the live input
    logic                        pend_valid;
    logic [ADDR_WIDTH-1:0]       pend_pc;
    cfi_type_t                   pend_type;
    logic [ADDR_WIDTH-1:0]       pend_target;

    wire [ADDR_WIDTH-1:0]   src_pc     = pend_valid ? pend_pc     : update_pc;
    wire cfi_type_t         src_type   = pend_valid ? pend_type   : update_cfi_type;
    wire [ADDR_WIDTH-1:0]   src_target = pend_valid ? pend_target : update_target;
    wire                    src_valid  = pend_valid | update_en;

    wire [ADDR_WIDTH-1:0]   src_region = src_pc & ~ADDR_WIDTH'(MBTB_REGION_BYTES - 1);
    wire [MBTB_TAG_WIDTH-1:0] src_tag  = src_region[ADDR_WIDTH-1:MBTB_REGION_WIDTH+MBTB_IDX_WIDTH];
    wire [MBTB_IDX_WIDTH-1:0] src_set  = src_region[MBTB_REGION_WIDTH+MBTB_IDX_WIDTH-1:MBTB_REGION_WIDTH];
    wire [MBTB_POS_WIDTH-1:0] src_pos  = MBTB_POS_WIDTH'((src_pc >> 2) & ((1 << MBTB_POS_WIDTH) - 1));

    // Same-set hazard: a not-yet-written update is in U0/U1/U2 (write is 4
    // cycles after launch).  Defer a same-set source (depth-1 pending buffer).
    wire upd_conflict = src_valid &&
                        ((upd_valid_u0 && (src_set == upd_set_u0)) ||
                         (upd_valid_u1 && (src_set == upd_set_u1)) ||
                         (upd_valid_u2 && (src_set == upd_set_u2)));
    wire upd_launch   = src_valid && !upd_conflict;
    assign update_ready = !pend_valid;

    logic                  upd_has_match;
    logic [WAY_IDX_W-1:0]  upd_match_way;
    logic [WAY_IDX_W-1:0]  upd_victim;
    mbtb_entry_t           upd_entry;

    always_comb begin
        upd_has_match = 1'b0;
        upd_match_way = '0;
        for (int w = 0; w < MBTB_WAYS; w++) begin
            if (upd_way_u1[w].valid &&
                (upd_way_u1[w].tag == upd_tag_u1) &&
                (upd_way_u1[w].position == upd_pos_u1) &&
                (upd_way_u1[w].cfi_type == upd_type_u1)) begin
                upd_has_match = 1'b1;
                upd_match_way = WAY_IDX_W'(w);
            end
        end

        upd_victim = WAY_IDX_W'(lru_victim(lru[upd_set_u1]));

        upd_entry.valid            = 1'b1;
        upd_entry.tag              = upd_tag_u1;
        upd_entry.cfi_type         = upd_type_u1;
        upd_entry.position         = upd_pos_u1;
        upd_entry.target_carry     = 1'b0;
        upd_entry.target_lower     = upd_target_u1[MBTB_TARGET_WIDTH-1:0];
        upd_entry.is_static_target = (upd_type_u1 != CFI_RETURN) &&
                                     (upd_type_u1 != CFI_INDIRECT_JUMP);
    end

    // =======================================================================
    // sequential
    // =======================================================================
    initial begin
        for (int s = 0; s < MBTB_SET_NUM; s++) begin
            mbtb_lo_mem[s] = '0;
            mbtb_hi_mem[s] = '0;
            mbtb_up_mem[s] = '0;
        end
    end

    // Unpack one set word into the per-way entries the pipeline logic uses.
    always_comb begin
        for (int w = 0; w < MBTB_WAYS; w++) begin
            way_lo_r1[w] = mbtb_entry_t'(lo_word_r[w*ENTRY_W +: ENTRY_W]);
            way_hi_r1[w] = mbtb_entry_t'(hi_word_r[w*ENTRY_W +: ENTRY_W]);
            upd_way_u1[w] = mbtb_entry_t'(up_word_u1[w*ENTRY_W +: ENTRY_W]);
        end
    end

    // Read-modify-write word for the update's target set.
    always_comb begin
        upd_word = up_word_u2;
        for (int w = 0; w < MBTB_WAYS; w++)
            if (w == upd_way_u2)
                upd_word[w*ENTRY_W +: ENTRY_W] = upd_entry_u2;
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            r0_valid <= 1'b0; r0_pc <= '0;
            r1_valid <= 1'b0; r1_pc <= '0;

            upd_valid_u0 <= 1'b0;
            upd_tag_u0 <= '0; upd_set_u0 <= '0; upd_pos_u0 <= '0;
            upd_type_u0 <= CFI_NONE; upd_target_u0 <= '0;

            upd_valid_u1 <= 1'b0;
            upd_tag_u1 <= '0; upd_set_u1 <= '0; upd_pos_u1 <= '0;
            upd_type_u1 <= CFI_NONE; upd_target_u1 <= '0;

            upd_valid_u2 <= 1'b0;
            upd_set_u2 <= '0; upd_way_u2 <= '0; upd_entry_u2 <= '0;

            pend_valid <= 1'b0;
            pend_pc <= '0; pend_type <= CFI_NONE; pend_target <= '0;

            // LRU state is small and reset here.  The entry array is NOT reset
            // through a per-entry loop: that creates one write port per entry
            // and stops ADS from inferring RAM.  It is zero-initialised below
            // (FPGA power-up / $readmemh style), exactly like tage_tag_array.
            for (int s = 0; s < MBTB_SET_NUM; s++) lru[s] <= '0;
        end else begin
            // ---------------- prediction S0 / S1 ----------------
            r0_valid <= req_valid;
            r0_pc    <= fetch_pc;

            r1_valid <= r0_valid;
            r1_pc    <= r0_pc;
            lo_word_r <= mbtb_lo_mem[r0_set_lo];
            hi_word_r <= mbtb_hi_mem[r0_set_hi];

            // ---------------- update U0 ----------------
            upd_valid_u0  <= upd_launch;
            upd_tag_u0    <= src_tag;
            upd_set_u0    <= src_set;
            upd_pos_u0    <= src_pos;
            upd_type_u0   <= src_type;
            upd_target_u0 <= src_target;

            if (pend_valid) begin
                if (upd_launch) begin
                    pend_valid <= update_en;
                    if (update_en) begin
                        pend_pc <= update_pc; pend_type <= update_cfi_type;
                        pend_target <= update_target;
                    end
                end
            end else if (update_en && !upd_launch) begin
                pend_valid <= 1'b1;
                pend_pc <= update_pc; pend_type <= update_cfi_type; pend_target <= update_target;
            end

            // ---------------- update U1: read the set ----------------
            upd_valid_u1  <= upd_valid_u0;
            upd_tag_u1    <= upd_tag_u0;
            upd_set_u1    <= upd_set_u0;
            upd_pos_u1    <= upd_pos_u0;
            upd_type_u1   <= upd_type_u0;
            upd_target_u1 <= upd_target_u0;
            up_word_u1 <= mbtb_up_mem[upd_set_u0];
            up_word_u2 <= up_word_u1;

            // ---------------- update U2: match / victim / entry ----------------
            upd_valid_u2 <= upd_valid_u1;
            upd_set_u2   <= upd_set_u1;
            upd_way_u2   <= upd_has_match ? upd_match_way : upd_victim;
            upd_entry_u2 <= upd_entry;

            // ---------------- update U3: write back + LRU ----------------
            if (upd_valid_u2) begin
                mbtb_lo_mem[upd_set_u2] <= upd_word;
                mbtb_hi_mem[upd_set_u2] <= upd_word;
                mbtb_up_mem[upd_set_u2] <= upd_word;
                lru[upd_set_u2] <= lru_touch(lru[upd_set_u2], int'(upd_way_u2));
            end
        end
    end

    /* verilator lint_on UNUSEDSIGNAL */
endmodule
