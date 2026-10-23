/* verilator lint_off UNUSEDSIGNAL */ // partial instruction/address fields are intentional
// Instruction Fetch Unit (IFU)
//  it pulls
// fetch targets from the FTQ (one entry per predicted Fetch Block) and pushes
// the fetched instructions into the IQ (the IFU-IDU interface).
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
    output logic [fe_pkg::GHR_WIDTH-1:0] fe_repair_ghr,
    output fe_pkg::bpu_update_t fe_repair_info,

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
        logic [ADDR_WIDTH-1:0] pc;
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

    // ------------------------------------------------
    // Stage F: fetch engine
    //
    // The icache returns the whole FETCH_WIDTH window in a single response
    // (it stitches a line-crossing window internally), so the fetch engine
    // no longer issues a second, crossing request.
    // ------------------------------------------------
    typedef enum logic {
        F_IDLE = 1'b0,
        F_RESP = 1'b1
    } fstate_t;
    fstate_t f_state;
    fstate_t f_nstate;

    logic [ADDR_WIDTH-1:0] f_pc;
    pred_meta_t f_pred_meta[FETCH_WIDTH];
    logic [FETCH_WIDTH-1:0] f_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0] f_cfi_type;
    logic poison_q;

    // ---- fetch FIFO ----
    fetch_block_t fetch_block_fifo[FB_DEPTH];
    logic [FB_CNT_W-1:0] fb_count;
    logic fb_wptr;
    logic fb_rptr;
    wire fb_empty = (fb_count == '0);
    wire fb_full = (fb_count == FB_CNT_W'(FB_DEPTH));

    wire icache_req_accept = icache_req_valid && icache_req_ready;
    wire icache_resp_accept = icache_resp_valid && icache_resp_ready;


    // fb_pop is driven by the Stage P load condition (see below).
    wire fb_pop;
    // Room for a push this cycle (a simultaneous pop frees a slot).
    wire f_can_push = (fb_count < FB_CNT_W'(FB_DEPTH)) || fb_pop;
    // Any outstanding response must be drained on/after a flush.
    wire f_resp_ready_ok = (ifu_flush || poison_q) ? 1'b1 : f_can_push;

    wire f_block_done = (f_state == F_RESP) && icache_resp_accept;
    wire fb_push = f_block_done && !poison_q && !ifu_flush && f_can_push;

    // Back-to-back fetch: when the current response is accepted this cycle, the
    // fetch engine may issue the next request in the SAME cycle (the icache is
    // in S_IDLE and accepts), removing the F_IDLE bubble so the block period
    // drops from 3 to 2 cycles.  Never start on a kill (poison/flush).
    wire f_back_to_back = (f_state == F_RESP) && icache_resp_accept && !poison_q && !ifu_flush;
    wire f_want_start = ((f_state == F_IDLE) || f_back_to_back) && !fb_full && ftq_rvalid && !ifu_flush &&
                        ftq_rdata.start_pc >= 32'h8000_0000 && ftq_rdata.start_pc < 32'h8000_8000;
    wire f_start = f_want_start && icache_req_ready;

    always_comb begin
        f_nstate = f_state;
        unique case (f_state)
            F_IDLE:  if (f_start) f_nstate = F_RESP;
            F_RESP:
            if (icache_resp_accept) begin
                if (poison_q || ifu_flush) f_nstate = F_IDLE;
                else if (f_start) f_nstate = F_RESP;
                else f_nstate = F_IDLE;
            end
            default: f_nstate = F_IDLE;
        endcase
    end

    assign ifu_rready        = f_start;
    assign icache_req_valid  = f_want_start;
    assign icache_req_addr   = ftq_rdata.start_pc;
    assign icache_resp_ready = (f_state == F_RESP) && f_resp_ready_ok;
    assign fetch_pc_out      = f_pc;

    wire f_drop_pending =
        ifu_flush && ((icache_req_valid && icache_req_ready) ||
                      ((f_state == F_RESP) && !icache_resp_valid));

    // ---- Stage F registers ----
    always_ff @(posedge clk) begin
        if (rst) begin
            f_state     <= F_IDLE;
            f_pc        <= RESET_VEC;
            poison_q    <= 1'b0;
            f_cfi_valid <= '0;
            f_cfi_type  <= '0;
            for (int i = 0; i < FETCH_WIDTH; i++) f_pred_meta[i] <= '0;
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
                fetch_block_fifo[fb_wptr].rmask          <= icache_resp_rmask;
                fetch_block_fifo[fb_wptr].pred_cfi_valid <= f_cfi_valid;
                fetch_block_fifo[fb_wptr].pred_cfi_type  <= f_cfi_type;
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    fetch_block_fifo[fb_wptr].inst[i]      <= icache_resp_data[i];
                    fetch_block_fifo[fb_wptr].pred_meta[i] <= f_pred_meta[i];
                end
                fb_wptr <= ~fb_wptr;
            end
            if (fb_pop && !fb_empty) fb_rptr <= ~fb_rptr;
            fb_count <= fb_count + FB_CNT_W'(fb_push) - FB_CNT_W'(fb_pop);
        end
    end

    // ------------------------------------------------
    // Stage P: pre-decode / check / IQ write (pipelined)
    //
    // Two decoupled sub-stages connected by the packed register `pd_r`:
    //   PD (pre-decode / latch): combinational whole-block pre-decode of the
    //       fetch-FIFO head `p_block`; latched into `pd_r` when it is free.
    //       The FIFO is popped here (fb_pop = pd_load).
    //   PC (check / IQ write): pure function of the registered `pd_r`:
    //       PredChecker, front-end redirect, IQ write handshake.
    // A block can be delivered every cycle (the old P_IDLE "load beat" is gone).
    // ------------------------------------------------
    typedef struct packed {
        fetch_block_t                      blk;
        logic [ADDR_WIDTH-1:0]             pre_pc;
        predecode_slot_t [FETCH_WIDTH-1:0] pre;
    } pd_reg_t;

    pd_reg_t pd_r;
    pd_reg_t pd_next;
    logic    pd_valid;

    fetch_block_t p_block;
    assign p_block = fetch_block_fifo[fb_rptr];

    // ---- Stage PD: combinational whole-block pre-decode ----
    slot_dec_t                   slot_dec         [FETCH_WIDTH];
    logic                        block_end_valid;
    logic      [FETCH_WIDTH-1:0] block_end_index;
    logic      [FETCH_WIDTH-1:0] fetch_block_mask;

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

    // Combinational pre-decode of the FIFO head into the pipeline register.
    always_comb begin
        pd_next.blk    = p_block;
        pd_next.pre_pc = p_block.pc;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            pd_next.pre[i].pc       = p_block.pc + ADDR_WIDTH'(i * INST_BYTES);
            pd_next.pre[i].valid    = fetch_block_mask[i];
            pd_next.pre[i].inrange  = (!block_end_valid) || (FETCH_WIDTH'(i) <= block_end_index);
            pd_next.pre[i].is_cfi   = slot_dec[i].is_cfi;
            pd_next.pre[i].is_jal   = slot_dec[i].is_jal;
            pd_next.pre[i].is_jalr  = slot_dec[i].is_jalr;
            pd_next.pre[i].is_ret   = (slot_dec[i].cfi_type == CFI_RETURN);
            pd_next.pre[i].cfi_type = slot_dec[i].cfi_type;
            if (slot_dec[i].is_jal) begin
                pd_next.pre[i].target = p_block.pc + ADDR_WIDTH'(i * INST_BYTES) +
                    jal_imm(p_block.inst[i]);
                pd_next.pre[i].target_valid = 1'b1;
            end else if (slot_dec[i].is_branch) begin
                pd_next.pre[i].target = p_block.pc + ADDR_WIDTH'(i * INST_BYTES) +
                    br_imm(p_block.inst[i]);
                pd_next.pre[i].target_valid = 1'b1;
            end else begin
                pd_next.pre[i].target       = '0;
                pd_next.pre[i].target_valid = 1'b0;
            end
        end
    end

    // ---- PD / PC handshake ----
    wire pc_wr = pd_valid && !flush && iq_wready;  // IQ write completes
    wire pc_kill = flush;  // back-end flush: drop
    wire pc_retire = pc_wr || pc_kill;  // pd_r frees this cycle
    wire pd_free = !pd_valid || pc_retire;  // pd_r usable this cycle
    wire pd_load = !fb_empty && pd_free && !ifu_flush;

    assign fb_pop = pd_load;

    always_ff @(posedge clk) begin
        if (rst) pd_valid <= 1'b0;
        else pd_valid <= pd_load || (pd_valid && !pc_retire);
    end

`ifdef SYNTHESIS
    // Wide register: no reset in synthesis (outputs are gated by pd_valid).
    always_ff @(posedge clk) if (pd_load) pd_r <= pd_next;
`else
    always_ff @(posedge clk)
        if (rst) pd_r <= '0;
        else if (pd_load) pd_r <= pd_next;
`endif

    // ------------------------------------------------
    // Stage PC: PredChecker / redirect / IQ write
    // ------------------------------------------------
    logic [FETCH_WIDTH-1:0] slot_error;
    logic [ADDR_WIDTH-1:0] effective_npc [FETCH_WIDTH];
    logic effective_taken [FETCH_WIDTH];
    always_comb begin
        for (int i=0; i<FETCH_WIDTH; i++) begin
            effective_npc[i] = pd_r.pre[i].pc + INST_BYTES;
            effective_taken[i] = 1'b0;
            if (pd_r.pre[i].is_jal) begin
                effective_npc[i] = pd_r.pre[i].target;
                effective_taken[i] = 1'b1;
            end else if (pd_r.pre[i].is_jalr) begin
                // No target prediction: keep fetching pc+4, never wait for BRU.
                effective_taken[i] = 1'b1;
                if (pd_r.blk.pred_meta[i].pred_taken &&
                    pd_r.blk.pred_meta[i].pred_type == pd_r.pre[i].cfi_type)
                    effective_npc[i] = pd_r.blk.pred_meta[i].pred_target;
            end else if (pd_r.pre[i].cfi_type == CFI_COND_BRANCH) begin
                effective_taken[i] = pd_r.blk.pred_meta[i].pred_type == CFI_COND_BRANCH &&
                                     pd_r.blk.pred_meta[i].pred_taken;
                if (effective_taken[i]) effective_npc[i] = pd_r.pre[i].target;
            end
            slot_error[i] = pd_r.pre[i].valid &&
                ((pd_r.blk.pred_meta[i].pred_type != pd_r.pre[i].cfi_type) ||
                 (pd_r.pre[i].is_jal && !pd_r.blk.pred_meta[i].pred_taken) ||
                 (pd_r.blk.pred_meta[i].pred_taken &&
                  effective_npc[i] != pd_r.blk.pred_meta[i].pred_target));
        end
    end
    always_comb begin
        err_valid = 1'b0;
        err_idx = '0;
        for (int i=FETCH_WIDTH-1; i>=0; i--)
            if (slot_error[i]) begin err_valid=1'b1; err_idx=SLOT_IDX_W'(i); end
    end
    // A local correction cannot retire until its entire valid prefix is kept.
    assign fe_redirect_valid = pc_wr && err_valid;
    assign fe_redirect_pc = effective_npc[err_idx];
    always_comb begin
        fe_repair_info = '0;
        fe_repair_info.update_pc = pd_r.pre[err_idx].pc;
        fe_repair_info.pred_meta = pd_r.blk.pred_meta[err_idx];
        fe_repair_info.actual_cfi_type = pd_r.pre[err_idx].cfi_type;
        fe_repair_info.actual_taken = effective_taken[err_idx];
        fe_repair_info.actual_target = effective_npc[err_idx];
        fe_repair_ghr = pd_r.blk.pred_meta[err_idx].ghr_before;
        if (pd_r.pre[err_idx].is_cfi)
            fe_repair_ghr = (fe_repair_ghr << 1) | GHR_WIDTH'(effective_taken[err_idx]);
    end
    assign iq_wvalid = pd_valid && !flush;
    always_comb begin
        for (int i=0; i<FETCH_WIDTH; i++) begin
            iq_wmask[i] = pd_r.pre[i].valid && (!err_valid || SLOT_IDX_W'(i) <= err_idx);
            iq_wdata[i] = '0;
            iq_wdata[i].pc = pd_r.pre[i].pc;
            iq_wdata[i].pred_npc = effective_npc[i];
            iq_wdata[i].pred_meta = pd_r.blk.pred_meta[i];
            iq_wdata[i].inst = pd_r.blk.inst[i];
            iq_wdata[i].valid = iq_wmask[i];
            iq_wdata[i].cfi_type = pd_r.pre[i].cfi_type;
            iq_wdata[i].is_cfi = pd_r.pre[i].is_cfi && iq_wmask[i];
        end
    end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
