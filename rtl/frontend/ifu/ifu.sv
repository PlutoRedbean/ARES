// Instruction Fetch Unit (IFU).
//
// After the BPU/IFU decoupling the IFU no longer owns a fetch PC: it pulls
// fetch targets from the FTQ (one entry per predicted Fetch Block) and pushes
// the fetched instructions into the IQ (the IFU-IDU interface).
//
// The front-end is 4-wide: every FTQ entry describes a Fetch Block, the IFU
// asks the icache for up to FETCH_WIDTH instructions starting at `start_pc`, runs
// a pre-decode over the returned block and hands it over to the IQ.  When the
// BPU predicted the block's CFI taken the block is cut right behind it (the
// BPU's next PC is the target); otherwise the block runs to its end and the
// back-end redirects on any control-flow instruction that was not predicted.
// The unused slots are masked off with `iq_wmask`.
//
//   FTQ --(start_pc, pred_meta, cfi info)--> IFU
//   IFU --(pc)--> icache --> IFU --(Fetch Block)--> IQ --> IDU
//
// A redirect kills any in-flight icache request (poison/drain); the IQ and the
// FTQ are flushed by their own `flush` inputs.
module ifu #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned RESET_VEC  = 32'h8000_0000
) (
    input logic clk,
    input logic rst,

    input logic                    flush,
    input logic [ADDR_WIDTH - 1:0] redirect_pc,

    // Fetch Target Queue read port
    input  logic                ftq_rvalid,
    output logic                ifu_rready,
    input  fe_pkg::ftq_entry_t ftq_rdata,

    // Instruction Queue write port (IFU -> IDU)
    output logic                                            iq_wvalid,
    output fe_pkg::iq_entry_t                              iq_wdata [fe_pkg::FETCH_WIDTH],
    output logic               [fe_pkg::FETCH_WIDTH - 1:0] iq_wmask,
    input  logic                                            iq_wready,

    // fetch target in flight (difftest/debug side-channel)
    output logic [ADDR_WIDTH - 1:0] fetch_pc_out,

    // front-end (predecode-vs-prediction) redirect: flushes BPU/FTQ and the
    // IFU pipeline.  Valid for one cycle, together with the corrected PC.
    output logic                    fe_redirect_valid,
    output logic [ADDR_WIDTH - 1:0] fe_redirect_pc,

    // icache request/response channel
    output logic                              icache_req_valid,
    output logic [          ADDR_WIDTH - 1:0] icache_req_addr,
    input  logic                              icache_req_ready,
    input  logic                              icache_resp_valid,
    input  logic [          ADDR_WIDTH - 1:0] icache_resp_data [fe_pkg::FETCH_WIDTH],
    input  logic [fe_pkg::FETCH_WIDTH - 1:0] icache_resp_rmask,
    output logic                              icache_resp_ready
);
    import fe_pkg::*;

    typedef enum logic [2:0] {
        S_IDLE = '0,
        S_REQ,
        S_RESP,
        S_REQ_NEXT,
        S_RESP_NEXT,
        S_PRE_DECO,
        S_CHECK
    } state_t;

    localparam int unsigned SLOT_IDX_W = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH) : 1;

    // per-slot pre-decode classification (combinational)
    typedef struct packed {
        cfi_type_t cfi_type;
        logic      is_cfi;
        logic      is_jal;
        logic      is_jalr;
        logic      is_branch;
    } slot_dec_t;

    // per-slot pre-decode result, registered one cycle before the check
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] base_pc;
        logic [ADDR_WIDTH-1:0] target;
        cfi_type_t             cfi_type;
        logic                  valid;         // valid slot inside the block
        logic                  inrange;       // within predicted block range
        logic                  is_cfi;
        logic                  is_jal;
        logic                  is_jalr;
        logic                  is_ret;
        logic                  target_valid;  // direct target is computable
    } predecode_slot_t;

    // ------------------------------------------------
    // registers
    // ------------------------------------------------
    state_t ifu_state;
    state_t ifu_n_state;

    // fetch target and per-slot prediction latched from the FTQ
    logic [ADDR_WIDTH - 1:0] fetch_pc_r;
    pred_meta_t pred_meta_q[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0] pred_cfi_valid_q;
    cfi_type_t [FETCH_WIDTH - 1:0] pred_cfi_type_q;

    // ------------------------------------------------
    // assembled Fetch Block
    // ------------------------------------------------
    logic [ADDR_WIDTH - 1:0] fetch_block_inst[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0] fetch_block_rmask;

    // first icache response of a block that crosses a cache line boundary
    logic [FETCH_WIDTH - 1:0] first_response_rmask;

    // the response of an outstanding (pre-redirect) request must be dropped
    logic drop_pending;
    logic poison_q;

    logic capture_response;

    // front-end redirect (predecode-vs-prediction mismatch).  The error and the
    // corrected PC are produced by the predecode check stage below.
    logic err_valid;
    logic [SLOT_IDX_W-1:0] err_idx;

    // effective redirect applied inside the IFU; a back-end redirect has
    // priority over the front-end one.
    wire ifu_flush = flush | fe_redirect_valid;
    wire [ADDR_WIDTH-1:0] ifu_redirect_pc = flush ? redirect_pc : fe_redirect_pc;

    // ------------------------------------------------
    // icache request/response channel (driven to/from top.sv)
    // ------------------------------------------------
    wire issuing = (ifu_state == S_REQ) || (ifu_state == S_REQ_NEXT);
    wire waiting_response = (ifu_state == S_RESP) || (ifu_state == S_RESP_NEXT);

    assign icache_req_valid  = issuing;
    assign icache_resp_ready = waiting_response;

    wire req_accept = icache_req_valid && icache_req_ready;
    wire resp_accpet = icache_resp_valid && icache_resp_ready;

    // pop an FTQ entry only when the IQ can take the fetched block
    assign ifu_rready = (ifu_state == S_IDLE) && ftq_rvalid && iq_wready && !ifu_flush;

    // number of instructions returned by the first icache response
    logic [FETCH_WIDTH - 1:0] first_respond_valid_cnt;
    always_comb begin
        first_respond_valid_cnt = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            first_respond_valid_cnt = first_respond_valid_cnt + FETCH_WIDTH'(first_response_rmask[i]);
        end
    end

    // number of instructions in the incoming (current) response
    logic [FETCH_WIDTH - 1:0] resp_valid_cnt;
    always_comb begin
        resp_valid_cnt = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            resp_valid_cnt = resp_valid_cnt + FETCH_WIDTH'(icache_resp_rmask[i]);
        end
    end

    // a crossing block needs a second request that starts right at the next
    // cache line boundary
    logic [ADDR_WIDTH - 1:0] second_fetch_pc_r;

    always_ff @(posedge clk) begin
        if (ifu_state == S_RESP && capture_response)
            second_fetch_pc_r <= fetch_pc_r + (ADDR_WIDTH'(resp_valid_cnt) << 2);
    end

    assign icache_req_addr = (ifu_state == S_REQ_NEXT) ? second_fetch_pc_r : fetch_pc_r;

    // ---------------------
    // ifu state machine
    // ---------------------
    always_comb begin
        ifu_n_state = ifu_state;  // default: hold the current state
        unique case (ifu_state)
            S_IDLE: begin
                if (ifu_rready) ifu_n_state = S_REQ;
            end
            S_REQ: begin
                if (ifu_flush && !req_accept) ifu_n_state = S_IDLE;  // cancel request
                else if (req_accept) ifu_n_state = S_RESP;
            end
            S_RESP: begin
                if (resp_accpet) begin
                    if (poison_q || ifu_flush) ifu_n_state = S_IDLE;  // drop stale block
                    else if (!(&icache_resp_rmask)) ifu_n_state = S_REQ_NEXT;
                    else ifu_n_state = S_PRE_DECO;
                end
            end
            S_REQ_NEXT: begin
                if (ifu_flush && !req_accept) ifu_n_state = S_IDLE;
                else if (req_accept) ifu_n_state = S_RESP_NEXT;
            end
            S_RESP_NEXT: begin
                if (resp_accpet) begin
                    if (poison_q || ifu_flush) ifu_n_state = S_IDLE;
                    else ifu_n_state = S_PRE_DECO;
                end
            end
            S_PRE_DECO: begin
                // predecode results are registered here; the check (and possible
                // front-end redirect) happens in the next cycle (S_CHECK)
                if (ifu_flush) ifu_n_state = S_IDLE;
                else ifu_n_state = S_CHECK;
            end
            S_CHECK: begin
                // The checked block is always handed to the IQ (truncated at the
                // mispredicted slot); a front-end redirect only corrects where
                // the *next* fetch starts, so already-fetched instructions on
                // the correct path are not lost.
                if (ifu_flush) ifu_n_state = S_IDLE;
                else if (iq_wready) ifu_n_state = S_IDLE;
            end
            default: ifu_n_state = S_IDLE;
        endcase
    end

    // poison flag: a response belonging to a pre-redirect request must be
    // drained and discarded before a new request for the redirect pc.
    assign drop_pending =
        ifu_flush && ((issuing && req_accept) ||
                      (waiting_response && !icache_resp_valid));

    // an icache response may only be consumed while no redirect is pending
    assign capture_response = resp_accpet && !poison_q && !ifu_flush;

    always_ff @(posedge clk) begin
        if (rst) begin
            ifu_state            <= S_IDLE;
            fetch_pc_r           <= RESET_VEC;
            for (int i = 0; i < FETCH_WIDTH; i++) pred_meta_q[i] <= '0;
            pred_cfi_valid_q     <= '0;
            pred_cfi_type_q      <= '0;
            fetch_block_rmask    <= '0;
            first_response_rmask <= '0;
            poison_q             <= '0;
            for (int i = 0; i < FETCH_WIDTH; i++) fetch_block_inst[i] <= '0;
        end else begin
            ifu_state <= ifu_n_state;

            if (drop_pending) poison_q <= 1'b1;
            else if (resp_accpet && poison_q) poison_q <= 1'b0;

            if (ifu_flush) begin
                // keep the reported fetch target meaningful while the FTQ is
                // being refilled after a redirect
                fetch_pc_r <= ifu_redirect_pc;
            end else if (ifu_rready) begin
                fetch_pc_r <= ftq_rdata.start_pc;
                for (int i = 0; i < FETCH_WIDTH; i++) pred_meta_q[i] <= ftq_rdata.pred_meta[i];
                pred_cfi_valid_q <= ftq_rdata.pred_cfi_valid;
                pred_cfi_type_q  <= ftq_rdata.pred_cfi_type;
            end

            // latch the first response of the block
            if (ifu_state == S_RESP && capture_response) begin
                first_response_rmask <= icache_resp_rmask;
                fetch_block_rmask    <= icache_resp_rmask;
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    fetch_block_inst[i] <= icache_resp_data[i];
                end
            end

            // complete the block with the second response when the window
            // crossed a cache line boundary
            if (ifu_state == S_RESP_NEXT && capture_response) begin
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    if (FETCH_WIDTH'(i) >= first_respond_valid_cnt) begin
                        fetch_block_inst[i]  <= icache_resp_data[SLOT_IDX_W'(FETCH_WIDTH'(i) - first_respond_valid_cnt)];
                        fetch_block_rmask[i] <= icache_resp_rmask[SLOT_IDX_W'(FETCH_WIDTH'(i) - first_respond_valid_cnt)];
                    end
                end
            end
        end
    end

    // ------------------------------------------------
    // pre-decode: classify the control-flow instruction of every slot
    // ------------------------------------------------
    slot_dec_t slot_dec[FETCH_WIDTH];

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            slot_dec[i].is_cfi    = 1'b0;
            slot_dec[i].is_jal    = 1'b0;
            slot_dec[i].is_jalr   = 1'b0;
            slot_dec[i].is_branch = 1'b0;
            slot_dec[i].cfi_type  = CFI_NONE;

            unique case (fetch_block_inst[i][6:0])
                7'b1101111: begin  // JAL
                    slot_dec[i].is_cfi = 1'b1;
                    slot_dec[i].is_jal = 1'b1;
                    slot_dec[i].cfi_type = (fetch_block_inst[i][11:7] == 5'd1 ||
                                            fetch_block_inst[i][11:7] == 5'd5) ? CFI_CALL : CFI_DIRECT_JUMP;
                end
                7'b1100111: begin  // JALR
                    slot_dec[i].is_cfi = 1'b1;
                    slot_dec[i].is_jalr = 1'b1;
                    slot_dec[i].cfi_type = (fetch_block_inst[i][11:7] == 5'd0 &&
                                            (fetch_block_inst[i][19:15] == 5'd1 ||
                                             fetch_block_inst[i][19:15] == 5'd5)) ? CFI_RETURN :
                                           ((fetch_block_inst[i][11:7] == 5'd1 ||
                                             fetch_block_inst[i][11:7] == 5'd5) ? CFI_CALL : CFI_INDIRECT_JUMP);
                end
                7'b1100011: begin  // conditional branch
                    slot_dec[i].is_cfi    = 1'b1;
                    slot_dec[i].is_branch = 1'b1;
                    slot_dec[i].cfi_type  = CFI_BRANCH;
                end
                default: ;
            endcase
        end
    end

    // Only a CFI the BPU actually predicted taken closes the Fetch Block: the
    // BPU's next PC is then the target, so everything behind that CFI is off
    // the predicted path.  An *unpredicted* jump still falls through for the
    // front-end and is corrected by the back-end redirect, so the block may run
    // past it (and past a not-taken conditional branch).
    logic                   block_end_valid;
    logic [FETCH_WIDTH-1:0] block_end_index;

    always_comb begin
        block_end_valid = 1'b0;
        block_end_index = '0;
        for (int i = FETCH_WIDTH - 1; i >= 0; i--) begin
            if (pred_meta_q[i].pred_taken) begin
                block_end_valid = 1'b1;
                block_end_index = FETCH_WIDTH'(i);
            end
        end
    end

    // valid prefix of the block
    logic [FETCH_WIDTH - 1:0] fetch_block_mask;

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            fetch_block_mask[i] = fetch_block_rmask[i] &&
                                  (!block_end_valid || (FETCH_WIDTH'(i) <= block_end_index));
        end
    end

    // ------------------------------------------------
    // pre-decode pipeline register
    //
    // The block gathered in S_RESP/S_RESP_NEXT is classified in S_PRE_DECO and
    // the classification is registered here, so that the check against the BPU
    // prediction (and the IQ write) happen one cycle later, in S_CHECK.
    // ------------------------------------------------
    logic            [ADDR_WIDTH-1:0] predecode_pc_r;
    predecode_slot_t                  predecode_r    [FETCH_WIDTH];

    // J-type / B-type immediates (sign extended)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [ADDR_WIDTH-1:0] jal_imm(input logic [INST_WIDTH-1:0] inst);
        jal_imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] br_imm(input logic [INST_WIDTH-1:0] inst);
        br_imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (rst) begin
            predecode_pc_r <= '0;
            for (int i = 0; i < FETCH_WIDTH; i++) predecode_r[i] <= '0;
        end else begin
            // slot base PCs are captured together with the block, one cycle
            // early, so the target only needs a single 32-bit add
            if (ifu_state == S_RESP && capture_response) begin
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    predecode_r[i].base_pc <= fetch_pc_r + ADDR_WIDTH'(i * INST_BYTES);
                end
            end

            if (ifu_state == S_PRE_DECO && !ifu_flush) begin
                predecode_pc_r <= fetch_pc_r;
                for (int i = 0; i < FETCH_WIDTH; i++) begin
                    predecode_r[i].valid <= fetch_block_mask[i];
                    predecode_r[i].inrange <= (!block_end_valid) || (FETCH_WIDTH'(i) <= block_end_index);
                    predecode_r[i].is_cfi <= slot_dec[i].is_cfi;
                    predecode_r[i].is_jal <= slot_dec[i].is_jal;
                    predecode_r[i].is_jalr <= slot_dec[i].is_jalr;
                    predecode_r[i].is_ret <= (slot_dec[i].cfi_type == CFI_RETURN);
                    predecode_r[i].cfi_type <= slot_dec[i].cfi_type;

                    if (slot_dec[i].is_jal) begin
                        predecode_r[i].target <= predecode_r[i].base_pc + jal_imm(
                            fetch_block_inst[i]
                        );
                        predecode_r[i].target_valid <= 1'b1;
                    end else if (slot_dec[i].is_branch) begin
                        predecode_r[i].target <= predecode_r[i].base_pc + br_imm(
                            fetch_block_inst[i]
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
    // PredChecker: compare the pre-decode result against the BPU prediction
    // carried in the FTQ entry.  Five error classes are detected:
    //   1. JAL  not predicted taken
    //   2. RET  not predicted taken
    //   3. a CFI predicted on an invalid slot
    //   4. a CFI predicted on a valid non-CFI instruction
    //   5. the predicted target does not match the recomputed one
    // ------------------------------------------------
    logic [FETCH_WIDTH-1:0] slot_error;
`ifndef SYNTHESIS
    typedef enum logic [2:0] {
        ERR_NONE = '0,
        ERR_JAL,
        ERR_RET,
        ERR_CFI_INVALID_SLOT,
        ERR_CFI_NON_CFI,
        ERR_CFI_WRONG_TARGET
    } err_type_t;
    /* verilator lint_off UNUSEDSIGNAL */
    err_type_t err_type[FETCH_WIDTH];
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin : g_dbg_err_type
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            err_type[i] = ERR_NONE;
            if (predecode_r[i].valid && predecode_r[i].is_jal && !pred_meta_q[i].pred_taken) begin
                err_type[i] = ERR_JAL;
            end else if (predecode_r[i].valid && predecode_r[i].is_ret && !pred_meta_q[i].pred_taken) begin
                err_type[i] = ERR_RET;
            end else if (pred_cfi_valid_q[i] && predecode_r[i].inrange && !predecode_r[i].valid) begin
                err_type[i] = ERR_CFI_INVALID_SLOT;
            end else if (pred_cfi_valid_q[i] && predecode_r[i].valid && !predecode_r[i].is_cfi) begin
                err_type[i] = ERR_CFI_NON_CFI;
            end else if(pred_meta_q[i].pred_taken && predecode_r[i].valid && predecode_r[i].is_cfi &&
                    predecode_r[i].target_valid &&
                    ((pred_cfi_type_q[i] != predecode_r[i].cfi_type) ||
                     (pred_meta_q[i].pred_target != predecode_r[i].target))) begin
                err_type[i] = ERR_CFI_WRONG_TARGET;
            end
        end
    end
`endif

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            slot_error[i] =
            // 1. JAL inside the block but not predicted taken
            (predecode_r[i].valid && predecode_r[i].is_jal && !pred_meta_q[i].pred_taken) ||
            // 2. RET inside the block but not predicted taken
            (predecode_r[i].valid && predecode_r[i].is_ret && !pred_meta_q[i].pred_taken) ||
            // 3. a CFI predicted on an invalid slot
            (pred_cfi_valid_q[i] && predecode_r[i].inrange && !predecode_r[i].valid) ||
            // 4. a CFI predicted on a valid non-CFI instruction
            (pred_cfi_valid_q[i] && predecode_r[i].valid && !predecode_r[i].is_cfi) ||
            // 5. a direct CFI predicted taken with the wrong type or
            //    target (indirect targets cannot be recomputed here)
            (pred_meta_q[i].pred_taken && predecode_r[i].valid && predecode_r[i].is_cfi &&
                 predecode_r[i].target_valid &&
                 ((pred_cfi_type_q[i] != predecode_r[i].cfi_type) ||
                  (pred_meta_q[i].pred_target != predecode_r[i].target)));
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

    // front-end redirect: fired in the cycle after the pre-decode register
    // (i.e. S_CHECK).  A back-end redirect always wins.
    assign fe_redirect_valid = (ifu_state == S_CHECK) && err_valid && !flush;
    assign fe_redirect_pc    = predecode_r[err_idx].target_valid
                             ? predecode_r[err_idx].target
                             : (predecode_pc_r + (ADDR_WIDTH'(err_idx + 1) * INST_BYTES));

    // ------------------------------------------------
    // IQ write port.  The checked block is always handed over; on a prediction
    // error it is truncated right after the mispredicted slot (that slot still
    // executes) and the next fetch is redirected.
    // ------------------------------------------------
    logic [FETCH_WIDTH-1:0] err_mask;
    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            err_mask[i] = !err_valid || (FETCH_WIDTH'(i) <= FETCH_WIDTH'(err_idx));
            iq_wmask[i] = predecode_r[i].valid & err_mask[i];
        end
    end

    assign iq_wvalid    = (ifu_state == S_CHECK) && !flush;
    assign fetch_pc_out = fetch_pc_r;

    always_comb begin
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            // the per-slot prediction only applies to the slots that survive
            logic slot_pred_taken;
            logic err_slot;
            slot_pred_taken = pred_meta_q[i].pred_taken && iq_wmask[i];
            // the mispredicted slot carries the corrected prediction so the
            // back-end does not immediately redirect again
            err_slot = err_valid && (SLOT_IDX_W'(i) == err_idx) && predecode_r[i].target_valid;

            iq_wdata[i] = '{
                pc: predecode_r[i].base_pc,
                pred_meta: '{
`ifdef TOURNAMENT_ON
                    chooser_meta: pred_meta_q[i].chooser_meta,
                    loop_override: pred_meta_q[i].loop_override,
`endif
                    pred_target: err_slot ? predecode_r[i].target : pred_meta_q[i].pred_target,
                    pred_taken : err_slot ? 1'b1 : slot_pred_taken
                },
                inst: fetch_block_inst[i],
                valid: iq_wmask[i],
                cfi_type: predecode_r[i].cfi_type,
                is_cfi: predecode_r[i].is_cfi && iq_wmask[i]
            };
        end
    end

endmodule
