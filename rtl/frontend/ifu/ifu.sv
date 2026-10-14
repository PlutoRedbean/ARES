// Instruction Fetch Unit (IFU) -- pipelined.
//
// After the BPU/IFU decoupling the IFU no longer owns a fetch PC: it pulls
// fetch targets from the FTQ (one entry per predicted Fetch Block) and pushes
// the fetched instructions into the IQ (the IFU-IDU interface).
//
// This version splits the work into two concurrent stages connected by a
// 2-entry fetch FIFO:
//
//   Stage F (fetch engine): FTQ pop -> icache request -> icache response ->
//                           push the fetched block into the FIFO.
//   Stage P (pre-decode / check / IQ write): pop the FIFO -> pre-decode ->
//                           check against the BPU prediction -> IQ write.
//
// The fetch engine can run ahead (up to the FIFO depth) while stage P is
// pre-decoding the previous block, hiding the icache latency behind the tail
// instead of serializing the two.
module ifu #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned RESET_VEC  = 32'h8000_0000
) (
    input logic clk,
    input logic rst,

    input logic                    flush,
    input logic [ADDR_WIDTH - 1:0] redirect_pc,

    // Fetch Target Queue read port
    input  logic               ftq_rvalid,
    output logic               ifu_rready,
    input  fe_pkg::ftq_entry_t ftq_rdata,

    // Instruction Queue write port (IFU -> IDU)
    output logic                                          iq_wvalid,
    output fe_pkg::iq_entry_t                             iq_wdata [fe_pkg::FETCH_WIDTH],
    output logic              [fe_pkg::FETCH_WIDTH - 1:0] iq_wmask,
    input  logic                                          iq_wready,

    // fetch target in flight (difftest/debug side-channel)
    output logic [ADDR_WIDTH - 1:0] fetch_pc_out,

    // front-end (predecode-vs-prediction) redirect
    output logic                    fe_redirect_valid,
    output logic [ADDR_WIDTH - 1:0] fe_redirect_pc,

    // icache request/response channel
    output logic                             icache_req_valid,
    output logic [         ADDR_WIDTH - 1:0] icache_req_addr,
    input  logic                             icache_req_ready,
    input  logic                             icache_resp_valid,
    input  logic [         ADDR_WIDTH - 1:0] icache_resp_data [fe_pkg::FETCH_WIDTH],
    input  logic [fe_pkg::FETCH_WIDTH - 1:0] icache_resp_rmask,
    output logic                             icache_resp_ready
);
    import fe_pkg::*;

    localparam int unsigned SLOT_IDX_W = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;
    localparam int unsigned FB_DEPTH   = 2;
    localparam int unsigned FB_CNT_W   = $clog2(FB_DEPTH + 1);

    // ------------------------------------------------
    // types
    // ------------------------------------------------
    typedef struct packed {
        cfi_type_t cfi_type;
        logic      is_cfi;
        logic      is_jal;
        logic      is_jalr;
        logic      is_branch;
    } slot_dec_t;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0] base_pc;
        logic [ADDR_WIDTH-1:0] target;
        cfi_type_t             cfi_type;
        logic                  valid;
        logic                  inrange;
        logic                  is_cfi;
        logic                  is_jal;
        logic                  is_jalr;
        logic                  is_ret;
        logic                  target_valid;
    } predecode_slot_t;

    typedef struct packed {
        logic [ADDR_WIDTH-1:0] pc;
        pred_meta_t [FETCH_WIDTH-1:0] pred_meta;
        logic [FETCH_WIDTH-1:0] pred_cfi_valid;
        cfi_type_t [FETCH_WIDTH-1:0] pred_cfi_type;
        logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] inst;
        logic [FETCH_WIDTH-1:0] rmask;
    } fetch_block_t;

    // ------------------------------------------------
    // redirect
    // ------------------------------------------------
    logic err_valid;
    logic [SLOT_IDX_W-1:0] err_idx;
    wire ifu_flush = flush | fe_redirect_valid;
    wire [ADDR_WIDTH-1:0] ifu_redirect_pc = flush ? redirect_pc : fe_redirect_pc;

    typedef enum logic {
        P_IDLE  = 1'b0,
        P_CHECK = 1'b1
    } pstate_t;
    pstate_t p_state;
    pstate_t p_nstate;

    // ------------------------------------------------
    // Stage F: fetch engine
    // ------------------------------------------------
    typedef enum logic [1:0] {
        F_IDLE  = '0,
        F_RESP,
        F_REQ2,
        F_RESP2
    } fstate_t;
    fstate_t f_state;
    fstate_t f_nstate;

    logic [ADDR_WIDTH-1:0] f_pc;
    logic [ADDR_WIDTH-1:0] f_second_pc;
    pred_meta_t f_pred_meta[FETCH_WIDTH];
    logic [FETCH_WIDTH-1:0] f_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0] f_cfi_type;
    logic [ADDR_WIDTH-1:0] f_inst[FETCH_WIDTH];  // first response (line crossing)
    logic [FETCH_WIDTH-1:0] f_first_rmask;
    logic poison_q;

    // ---- fetch FIFO ----
    fetch_block_t fetch_block_fifo[FB_DEPTH];
    logic [FB_CNT_W-1:0] fb_count;
    logic fb_wptr;
    logic fb_rptr;
    wire fb_empty = (fb_count == '0);
    wire fb_full = (fb_count == FB_CNT_W'(FB_DEPTH));

    // number of instructions in the incoming response
    logic [FETCH_WIDTH-1:0] f_resp_valid_cnt;
    always_comb begin
        f_resp_valid_cnt = '0;
        for (int i = 0; i < FETCH_WIDTH; i++)
        f_resp_valid_cnt = f_resp_valid_cnt + FETCH_WIDTH'(icache_resp_rmask[i]);
    end

    // instructions returned by the first response of a crossing block
    logic [FETCH_WIDTH-1:0] f_first_cnt;
    always_comb begin
        f_first_cnt = '0;
        for (int i = 0; i < FETCH_WIDTH; i++)
        f_first_cnt = f_first_cnt + FETCH_WIDTH'(f_first_rmask[i]);
    end

    // block assembled for the FIFO push (registered metadata + live response)
    logic [ ADDR_WIDTH-1:0] f_push_inst  [FETCH_WIDTH];
    logic [FETCH_WIDTH-1:0] f_push_rmask;
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            if ((f_state == F_RESP2) && (FETCH_WIDTH'(i) >= f_first_cnt)) begin
                f_push_inst[i]  = icache_resp_data[SLOT_IDX_W'(FETCH_WIDTH'(i)-f_first_cnt)];
                f_push_rmask[i] = icache_resp_rmask[SLOT_IDX_W'(FETCH_WIDTH'(i)-f_first_cnt)];
            end else if (f_state == F_RESP2) begin
                f_push_inst[i]  = f_inst[i];
                f_push_rmask[i] = f_first_rmask[i];
            end else begin
                f_push_inst[i]  = icache_resp_data[i];
                f_push_rmask[i] = icache_resp_rmask[i];
            end
        end
    end

    wire icache_req_accept = icache_req_valid && icache_req_ready;
    wire icache_resp_accept = icache_resp_valid && icache_resp_ready;

    // The checked block is always written to the IQ; a front-end redirect only
    // corrects where the *next* fetch starts.  Only a back-end flush suppresses
    // the write.

    wire fb_pop = (p_state == P_CHECK) && !flush && iq_wready;
    // Room for a push this cycle (a simultaneous pop frees a slot).
    wire f_can_push = (fb_count < FB_CNT_W'(FB_DEPTH)) || fb_pop;
    // A crossing first response never completes the block, so it needs no room.
    // Any outstanding response must be drained on/after a flush.
    wire f_resp_ready_ok = (ifu_flush || poison_q) ? 1'b1 :
        (f_state == F_RESP)  ? (f_can_push || !(&icache_resp_rmask)) :
        (f_state == F_RESP2) ? f_can_push : 1'b0;

    wire f_block_done =
        (f_state == F_RESP  && icache_resp_accept && (&icache_resp_rmask)) ||
        (f_state == F_RESP2 && icache_resp_accept);
    wire fb_push = f_block_done && !poison_q && !ifu_flush && f_can_push;


    wire f_want_start = (f_state == F_IDLE) && !fb_full && ftq_rvalid && !ifu_flush;
    wire f_start = f_want_start && icache_req_ready;

    always_comb begin
        f_nstate = f_state;
        unique case (f_state)
            F_IDLE: begin
                if (f_start) f_nstate = F_RESP;
            end
            F_RESP: begin
                if (icache_resp_accept) begin
                    if (poison_q || ifu_flush) f_nstate = F_IDLE;
                    else if (!(&icache_resp_rmask)) f_nstate = F_REQ2;
                    else f_nstate = F_IDLE;
                end
            end
            F_REQ2: begin
                if (ifu_flush && !icache_req_accept) f_nstate = F_IDLE;
                else if (icache_req_accept) f_nstate = F_RESP2;
            end
            F_RESP2: begin
                if (icache_resp_accept) f_nstate = F_IDLE;
            end
            default: f_nstate = F_IDLE;
        endcase
    end

    assign ifu_rready        = f_start;
    assign icache_req_valid  = f_want_start || (f_state == F_REQ2);
    assign icache_req_addr   = (f_state == F_REQ2) ? f_second_pc : ftq_rdata.start_pc;
    assign icache_resp_ready = ((f_state == F_RESP) || (f_state == F_RESP2)) && f_resp_ready_ok;
    assign fetch_pc_out      = f_pc;

    wire f_drop_pending =
        ifu_flush && ((icache_req_valid && icache_req_ready) ||
                      (((f_state == F_RESP) || (f_state == F_RESP2)) &&
                       !icache_resp_valid));

    // ---- Stage F registers ----
    always_ff @(posedge clk) begin
        if (rst) begin
            f_state       <= F_IDLE;
            f_pc          <= RESET_VEC;
            f_second_pc   <= '0;
            f_first_rmask <= '0;
            poison_q      <= 1'b0;
            for (int i = 0; i < FETCH_WIDTH; i++) begin
                f_pred_meta[i] <= '0;
                f_inst[i]      <= '0;
            end
            f_cfi_valid <= '0;
            f_cfi_type  <= '0;
        end else begin
            f_state <= f_nstate;

            if (f_drop_pending) poison_q <= 1'b1;
            else if (icache_resp_accept && poison_q) poison_q <= 1'b0;

            if (ifu_flush) f_pc <= ifu_redirect_pc;

            if (f_start) begin
                f_pc <= ftq_rdata.start_pc;
                for (int i = 0; i < FETCH_WIDTH; i++) f_pred_meta[i] <= ftq_rdata.pred_meta[i];
                f_cfi_valid <= ftq_rdata.pred_cfi_valid;
                f_cfi_type  <= ftq_rdata.pred_cfi_type;
            end

            // first response of a block (kept for a possible line-crossing merge)
            if (f_state == F_RESP && icache_resp_accept && !poison_q && !ifu_flush) begin
                f_first_rmask <= icache_resp_rmask;
                for (int i = 0; i < FETCH_WIDTH; i++) f_inst[i] <= icache_resp_data[i];
                if (!(&icache_resp_rmask))
                    f_second_pc <= f_pc + (ADDR_WIDTH'(f_resp_valid_cnt) << 2);
            end
        end
    end

    // ---- pipeline FIFO storage ----
    always_ff @(posedge clk) begin
        if (rst || ifu_flush) begin
            fb_count <= '0;
            fb_wptr  <= 1'b0;
            fb_rptr  <= 1'b0;
        end else begin
            if (fb_push) begin
                fetch_block_fifo[fb_wptr].pc             <= f_pc;
                fetch_block_fifo[fb_wptr].rmask          <= f_push_rmask;
                fetch_block_fifo[fb_wptr].pred_cfi_valid <= f_cfi_valid;
                fetch_block_fifo[fb_wptr].pred_cfi_type  <= f_cfi_type;
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    fetch_block_fifo[fb_wptr].inst[i]      <= f_push_inst[i];
                    fetch_block_fifo[fb_wptr].pred_meta[i] <= f_pred_meta[i];
                end
                fb_wptr <= ~fb_wptr;
            end
            if (fb_pop && !fb_empty) fb_rptr <= ~fb_rptr;
            fb_count <= fb_count + FB_CNT_W'(fb_push) - FB_CNT_W'(fb_pop);
        end
    end

    // ------------------------------------------------
    // Stage P: pre-decode / check / IQ write
    // ------------------------------------------------


    fetch_block_t p_block;
    assign p_block = fetch_block_fifo[fb_rptr];
    fetch_block_t                      p_block_r;

    predecode_slot_t                   predecode_r      [FETCH_WIDTH];
    logic            [ ADDR_WIDTH-1:0] predecode_pc_r;
    slot_dec_t                         slot_dec         [FETCH_WIDTH];
    logic                              block_end_valid;
    logic            [FETCH_WIDTH-1:0] block_end_index;
    logic            [FETCH_WIDTH-1:0] fetch_block_mask;

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            slot_dec[i].is_cfi    = 1'b0;
            slot_dec[i].is_jal    = 1'b0;
            slot_dec[i].is_jalr   = 1'b0;
            slot_dec[i].is_branch = 1'b0;
            slot_dec[i].cfi_type  = CFI_NONE;
            unique case (p_block.inst[i][6:0])
                7'b1101111: begin
                    slot_dec[i].is_cfi = 1'b1;
                    slot_dec[i].is_jal = 1'b1;
                    slot_dec[i].cfi_type = (p_block.inst[i][11:7] == 5'd1 ||
                                            p_block.inst[i][11:7] == 5'd5) ? CFI_CALL : CFI_DIRECT_JUMP;
                end
                7'b1100111: begin
                    slot_dec[i].is_cfi = 1'b1;
                    slot_dec[i].is_jalr = 1'b1;
                    slot_dec[i].cfi_type = (p_block.inst[i][11:7] == 5'd0 &&
                                            (p_block.inst[i][19:15] == 5'd1 ||
                                             p_block.inst[i][19:15] == 5'd5)) ? CFI_RETURN :
                                           ((p_block.inst[i][11:7] == 5'd1 ||
                                             p_block.inst[i][11:7] == 5'd5) ? CFI_CALL : CFI_INDIRECT_JUMP);
                end
                7'b1100011: begin
                    slot_dec[i].is_cfi    = 1'b1;
                    slot_dec[i].is_branch = 1'b1;
                    slot_dec[i].cfi_type  = CFI_COND_BRANCH;
                end
                default: ;
            endcase
        end
    end

    always_comb begin
        block_end_valid = 1'b0;
        block_end_index = '0;
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            // end the block at the first predicted-taken CFI; earlier
            // not-taken CFIs stay in the block and carry the per-CFI prefix
            // (reconstructs ghr_before from the block-start GHR).
            if (p_block.pred_meta[i].pred_taken) begin
                block_end_valid = 1'b1;
                block_end_index = FETCH_WIDTH'(i);
            end
        end
    end

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++)
        fetch_block_mask[i] = p_block.rmask[i] &&
                (!block_end_valid || (FETCH_WIDTH'(i) <= block_end_index));
    end

    function automatic logic [ADDR_WIDTH-1:0] jal_imm(input logic [INST_WIDTH-1:0] inst);
        jal_imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] br_imm(input logic [INST_WIDTH-1:0] inst);
        br_imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    endfunction

    always_comb begin
        p_nstate = p_state;
        unique case (p_state)
            P_IDLE:  if (!fb_empty && !ifu_flush) p_nstate = P_CHECK;
            P_CHECK: if (flush) p_nstate = P_IDLE;
 else if (iq_wready) p_nstate = P_IDLE;
            default: p_nstate = P_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            p_state        <= P_IDLE;
            predecode_pc_r <= '0;
            for (int i = 0; i < FETCH_WIDTH; i++) predecode_r[i] <= '0;
        end else begin
            p_state <= p_nstate;
            if (p_state == P_IDLE && !fb_empty && !ifu_flush) begin
                p_block_r         <= p_block;
                predecode_pc_r <= p_block.pc;
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    predecode_r[i].base_pc <= p_block.pc + ADDR_WIDTH'(i * INST_BYTES);
                    predecode_r[i].valid <= fetch_block_mask[i];
                    predecode_r[i].inrange <= (!block_end_valid) || (FETCH_WIDTH'(i) <= block_end_index);
                    predecode_r[i].is_cfi <= slot_dec[i].is_cfi;
                    predecode_r[i].is_jal <= slot_dec[i].is_jal;
                    predecode_r[i].is_jalr <= slot_dec[i].is_jalr;
                    predecode_r[i].is_ret <= (slot_dec[i].cfi_type == CFI_RETURN);
                    predecode_r[i].cfi_type <= slot_dec[i].cfi_type;
                    if (slot_dec[i].is_jal) begin
                        predecode_r[i].target <= p_block.pc + ADDR_WIDTH'(i * INST_BYTES) + jal_imm(
                            p_block.inst[i]
                        );
                        predecode_r[i].target_valid <= 1'b1;
                    end else if (slot_dec[i].is_branch) begin
                        predecode_r[i].target <= p_block.pc + ADDR_WIDTH'(i * INST_BYTES) + br_imm(
                            p_block.inst[i]
                        );
                        predecode_r[i].target_valid <= 1'b1;
                    end else begin
                        predecode_r[i].target       <= '0;
                        predecode_r[i].target_valid <= 1'b0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------
    // PredChecker
    // ------------------------------------------------
    logic [FETCH_WIDTH-1:0] slot_error;
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            slot_error[i] =
                (predecode_r[i].valid && predecode_r[i].is_jal &&
                    !p_block_r.pred_meta[i].pred_taken) ||
                (predecode_r[i].valid && predecode_r[i].is_ret &&
                    !p_block_r.pred_meta[i].pred_taken) ||
                (p_block_r.pred_cfi_valid[i] && predecode_r[i].inrange &&
                    !predecode_r[i].valid) ||
                (p_block_r.pred_cfi_valid[i] && predecode_r[i].valid &&
                    !predecode_r[i].is_cfi) ||
                (p_block_r.pred_meta[i].pred_taken && predecode_r[i].valid &&
                    predecode_r[i].is_cfi && predecode_r[i].target_valid &&
                    ((p_block_r.pred_cfi_type[i] != predecode_r[i].cfi_type) ||
                     (p_block_r.pred_meta[i].pred_target != predecode_r[i].target)));
        end
    end

    always_comb begin
        err_valid = 1'b0;
        err_idx   = '0;
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            if (slot_error[i]) begin
                err_valid = 1'b1;
                err_idx   = SLOT_IDX_W'(i);
            end
        end
    end

    assign fe_redirect_valid = (p_state == P_CHECK) && err_valid && !flush;
    assign fe_redirect_pc    = predecode_r[err_idx].target_valid
                             ? predecode_r[err_idx].target
                             : (predecode_pc_r + (ADDR_WIDTH'(err_idx + 1) * INST_BYTES));

    // ------------------------------------------------
    // IQ write port
    // ------------------------------------------------
    logic [FETCH_WIDTH-1:0] err_mask;
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            err_mask[i] = !err_valid || (FETCH_WIDTH'(i) <= FETCH_WIDTH'(err_idx));
            iq_wmask[i] = predecode_r[i].valid & err_mask[i];
        end
    end

    assign iq_wvalid = (p_state == P_CHECK) && !flush;

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            logic slot_pred_taken;
            logic err_slot;
            slot_pred_taken = p_block_r.pred_meta[i].pred_taken && iq_wmask[i];
            err_slot = err_valid && (SLOT_IDX_W'(i) == err_idx) &&
                predecode_r[i].target_valid;

            iq_wdata[i] = '{
                pc: predecode_r[i].base_pc,
                pred_meta: '{
`ifdef TOURNAMENT_ON
                    chooser_meta: p_block_r.pred_meta[i].chooser_meta,
`endif
`ifdef LOOP_PRED_ON
                    loop_override: p_block_r.pred_meta[i].loop_override,
`endif
                    pred_target: err_slot ? predecode_r[i].target
                                            : p_block_r.pred_meta[i].pred_target,
                    pred_taken : err_slot ? 1'b1 : slot_pred_taken,
                    cfi_prefix : p_block_r.pred_meta[i].cfi_prefix
                },
                inst: p_block_r.inst[i],
                valid: iq_wmask[i],
                cfi_type: predecode_r[i].cfi_type,
                is_cfi: predecode_r[i].is_cfi && iq_wmask[i]
            };
        end
    end

endmodule
