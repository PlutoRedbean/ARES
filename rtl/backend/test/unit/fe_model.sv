//=============================================================================
// ARES core verification - instruction fetch model for backend test benches
//-----------------------------------------------------------------------------
// Minimal, contract-shaped frontend used by tb_backend (C1) so the backend can
// be driven with real instruction words without the real frontend or the DPI
// harness (docs/core_verification_flow.md section 2).
//
// Contract properties (frontend_backend_contract.md section 2/3):
//   * iq_valid is only 00/01/11 - the two visible slots are always a
//     contiguous prefix of the instruction stream (no holes);
//   * iq_accept_count is the only consumption basis; a 4-deep staging queue is
//     refilled from the program image at the same rate;
//   * pred_npc is pc+4 (always-not-taken, like fe_stub) and pred_meta is raw;
//   * a backend redirect takes effect in the same cycle: the staged slots are
//     dropped and the fetch PC becomes backend_redirect_pc;
//   * bpu_update_credit is a constant registered value (2); training events are
//     counted but never trained (the model has no predictor).
//
// JALR is resolved through the normal BRU recovery path when its actual target
// differs from the predicted (pc+4) next PC.
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module fe_model #(
    parameter logic [31:0] RESET_PC           = ares_pkg::RESET_PC,
    parameter int unsigned IMEM_WORDS         = 1024
) (
    input  logic                        clk,
    input  logic                        rst,

    //---- instruction interface (contract section 2) ------------------------
    output logic [1:0]                  iq_valid,
    output fe_pkg::iq_entry_t         iq_inst [2],
    input  logic [1:0]                  iq_accept_count,

    //---- redirect (contract section 3) -------------------------------------
    input  logic                        backend_redirect_valid,
    input  logic [31:0]                 backend_redirect_pc,

    //---- BPU update (contract section 4) -----------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // no predictor in this model
    output logic [1:0]                  bpu_update_credit,
    input  logic [1:0]                  bpu_update_valid,
    input  fe_pkg::bpu_update_t       bpu_update [2],
    /* verilator lint_on UNUSEDSIGNAL */

    //---- program image and observation -------------------------------------
    input  logic [31:0]                 imem [IMEM_WORDS],
    output logic [31:0]                 fetch_pc,
    output logic [31:0]                 redirect_count
);
    import ares_pkg::*;
    import fe_pkg::*;

    localparam int unsigned IDX_BITS = $clog2(IMEM_WORDS);
    localparam int unsigned DEPTH    = 4;

    //-------------------------------------------------------------------------
    // Operand-less predecode: the actual CFI class (contract 2.1).  Must match
    // be_decode's classification exactly.
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // only the opcode/register fields matter
    function automatic cfi_type_t classify(input logic [31:0] inst);
        logic [4:0] rd, rs1;
        begin
            rd  = inst[11:7];
            rs1 = inst[19:15];
            case (inst[6:0])
                7'h6f:   classify = ((rd == 5'd1) || (rd == 5'd5)) ? CFI_CALL : CFI_DIRECT_JUMP;
                7'h67:   classify = ((rd == 5'd1) || (rd == 5'd5)) ? CFI_CALL
                                  : (((rs1 == 5'd1) || (rs1 == 5'd5)) ? CFI_RETURN
                                                                      : CFI_INDIRECT_JUMP);
                7'h63:   classify = CFI_COND_BRANCH;
                default: classify = CFI_NONE;
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    function automatic iq_entry_t make_entry(input logic [31:0] pc, input logic [31:0] inst);
        iq_entry_t e;
        cfi_type_t c;
        begin
            c                       = classify(inst);
            e                       = '0;
            e.valid                 = 1'b1;
            e.pc                    = pc;
            e.inst                  = inst;
            e.pred_npc = pc + 32'd4;
            e.pred_meta.pred_taken  = 1'b0;
            e.cfi_type              = c;
            e.is_cfi                = (c != CFI_NONE);
            make_entry              = e;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 4-deep staging queue: two visible slots plus two entries in reserve so
    // the queue can sustain two consumptions per cycle.
    //-------------------------------------------------------------------------
    iq_entry_t   q_q [DEPTH];
    logic [2:0]  cnt_q;
    logic [31:0] pc_q;
    logic [31:0] redirect_count_q;

    wire [IDX_BITS-1:0] idx_a = pc_q[IDX_BITS+1:2];
    wire [IDX_BITS-1:0] idx_b = idx_a + 1'b1;

    assign iq_valid  = {q_q[1].valid, q_q[0].valid};
    assign iq_inst[0] = q_q[0];
    assign iq_inst[1] = q_q[1];
    assign fetch_pc  = pc_q;
    assign bpu_update_credit = 2'd2;
    assign redirect_count = redirect_count_q;

    // Pop count: a redirect blanks the slots in the same cycle (contract 5).
    wire [2:0] pop_w  = backend_redirect_valid ? 3'd0 : {1'b0, iq_accept_count};
    wire [2:0] after_w = cnt_q - pop_w;
    wire [2:0] free_w  = 3'd4 - after_w;
    wire [2:0] nf_w    = (free_w > 3'd2) ? 3'd2 : free_w;

    iq_entry_t next_q [DEPTH];
    logic [2:0] idx_sel;
    always_comb begin
        for (int unsigned i = 0; i < DEPTH; i++) begin
            next_q[i]       = '0;
            next_q[i].valid = 1'b0;
            idx_sel         = 3'(i) + pop_w;
            if (idx_sel < 3'(DEPTH)) next_q[i] = q_q[idx_sel[1:0]];
        end
        // nf_w > 0 implies after_w < DEPTH, and nf_w > 1 implies after_w <= 2,
        // so the low index bits are exact here.
        if (nf_w > 3'd0) next_q[after_w[1:0]]             = make_entry(pc_q, imem[idx_a]);
        if (nf_w > 3'd1) next_q[after_w[1:0] + 2'd1]      = make_entry(pc_q + 32'd4, imem[idx_b]);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned i = 0; i < DEPTH; i++) q_q[i] <= '0;
            cnt_q            <= 3'd0;
            pc_q             <= RESET_PC;
            redirect_count_q <= 32'd0;
        end else if (backend_redirect_valid) begin
            for (int unsigned i = 0; i < DEPTH; i++) q_q[i] <= '0;
            cnt_q            <= 3'd0;
            pc_q             <= backend_redirect_pc;
            redirect_count_q <= redirect_count_q + 32'd1;
        end else begin
            for (int unsigned i = 0; i < DEPTH; i++) q_q[i] <= next_q[i];
            cnt_q <= after_w + nf_w;
            pc_q  <= pc_q + {27'd0, nf_w, 2'b00};
        end
    end

`ifdef CONFIG_SIMULATION
    // Contract assertions (contract section 6).  The old-path slots are dropped
    // at the *end* of the redirect cycle (contract 3/5), so they are empty on
    // the following cycle - during the event itself the BE guarantees
    // iq_accept_count = 0.
    a_no_hole  : assert property (@(posedge clk) disable iff (rst) (iq_valid != 2'b10));
    a_prefix   : assert property (@(posedge clk) disable iff (rst)
                     (iq_accept_count <= ({1'b0, iq_valid[0]} + {1'b0, iq_valid[1]})));
    a_redirect : assert property (@(posedge clk) disable iff (rst)
                     backend_redirect_valid |=> (iq_valid == 2'b00));
`endif
endmodule
