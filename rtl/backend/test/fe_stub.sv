//=============================================================================
// ARES core verification - behavioural frontend stub (F0)
//-----------------------------------------------------------------------------
// Simulation-only fetch source for the backend / LSU and for the core ISA
// regression.  It obeys frontend_backend_contract.md sections 2-4 and nothing
// else: always-not-taken prediction, no BPU tables, no ICache, no FTQ.
//
// Why it exists (docs/core_verification_flow.md section 0): the backend and
// memory subsystem must be verifiable without the real frontend, and the
// cycle-level half of the FE/BE interface must stay in SystemVerilog so the
// contract assertions can run under --assert.
//
// Contract properties implemented here (flow doc section 3.1):
//   1. iq_valid is only 00/01/11 (no holes, slot 0 is the oldest)
//   2. iq_accept_count is the only consumption basis; pop is a contiguous prefix
//   3. with accept=0 the head entry and its metadata stay stable
//   4. backend_redirect_valid forces a same-cycle refetch from the new PC
//   5. pred_npc is the effective next PC (always pc+4), pred_meta is raw,
//      need_redirect is always 0 (the stub never stops fetching)
//   6. bpu_update_credit comes from registered state (constant 2; the stub has
//      no predictor to train and therefore drops the events)
//
// Instruction data comes from the shared DPI-C model (irom_read), so cpu-tests
// images and the simulated memory are reused unchanged.
//
// FREE items: FREE-02 (file layout), FREE-10 (verification environment).
// Run: see rtl/backend/test/README.md.
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */
module fe_stub #(
    parameter logic [31:0] RESET_PC = ares_pkg::RESET_PC
) (
    input  logic clk,
    input  logic rst,

    //---- instruction interface: FE -> BE (contract section 2) --------------
    output logic [1:0]            iq_valid,
    output ares_pkg::iq_entry_t   iq_inst [2],
    input  logic [1:0]            iq_accept_count,

    //---- redirect interface: BE -> FE (contract section 3) -----------------
    input  logic                           backend_redirect_valid,
    input  logic [31:0]                    backend_redirect_pc,
    input  ares_pkg::fe_redirect_kind_t    backend_redirect_kind,
    input  logic [ares_pkg::GHR_WIDTH-1:0] backend_redirect_ghr_before,
    input  logic                           backend_redirect_actual_taken,

    //---- BPU update interface: BE commit -> FE (contract section 4) --------
    output logic [1:0]            bpu_update_credit,
    input  logic [1:0]            bpu_update_valid,
    input  ares_pkg::bpu_update_t bpu_update [2]
);
/* verilator lint_on UNUSEDSIGNAL */

    import ares_pkg::*;

    import "DPI-C" function int irom_read(input int addr);

    //-------------------------------------------------------------------------
    // Predecode: the real CFI class carried to the backend (contract 2.1).
    // ECALL/MRET deliberately decode to CFI_NONE: they are not predictor
    // events (D-C0-09), they only ride the architectural redirect path.
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // only the opcode/register fields matter
    function automatic cfi_type_t classify(input logic [31:0] inst);
        logic [4:0] rd;
        logic [4:0] rs1;
        logic       rd_is_link;
        logic       rs1_is_link;
        begin
            rd          = inst[11:7];
            rs1         = inst[19:15];
            rd_is_link  = (rd == 5'd1) || (rd == 5'd5);
            rs1_is_link = (rs1 == 5'd1) || (rs1 == 5'd5);
            case (inst[6:0])
                7'h6f:   classify = rd_is_link ? CFI_CALL : CFI_DIRECT_JUMP;
                7'h67:   classify = rd_is_link ? CFI_CALL
                                               : (rs1_is_link ? CFI_RETURN
                                                              : CFI_INDIRECT_JUMP);
                7'h63:   classify = CFI_COND_BRANCH;
                default: classify = CFI_NONE;
            endcase
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    //-------------------------------------------------------------------------
    // Fetch pipeline: F0 (pc_f drives the instruction port) -> F1 (registered
    // instruction) -> 2-entry visible queue.  The stub never predicts taken,
    // so sequential fetch is all that is needed; the BRU recovery redirect
    // supplies every real control transfer.
    //-------------------------------------------------------------------------
    logic [31:0] pc_f;        // address presented to the instruction port
    logic        f1_valid;
    logic [31:0] f1_pc;
    logic [31:0] f1_inst;

    logic [1:0]  cnt;         // number of visible (valid) queue entries
    iq_entry_t   slot [2];    // slot[0] = oldest

    //-------------------------------------------------------------------------
    // Consumption
    //-------------------------------------------------------------------------
    wire        redirect       = backend_redirect_valid;
    // Contract 3: the backend guarantees accept_count == 0 on a redirect; the
    // stub masks defensively so a backend bug cannot corrupt the refetch.
    wire [1:0]  accept         = redirect ? 2'd0 : iq_accept_count;
    wire [1:0]  pop            = (accept <= cnt) ? accept : cnt;
    wire [1:0]  used_after_pop = cnt - pop;
    wire        room           = (used_after_pop < 2'd2);
    wire        push           = f1_valid && room;
    wire        capture        = (f1_valid ? push : 1'b1) && !redirect;
    wire [1:0]  cnt_next       = used_after_pop + (push ? 2'd1 : 2'd0);

    //-------------------------------------------------------------------------
    // Entry formation (always-not-taken)
    //-------------------------------------------------------------------------
    cfi_type_t  new_cfi;
    iq_entry_t  new_entry;
    always_comb begin
        new_cfi                         = classify(f1_inst);
        new_entry                       = '0;
        new_entry.pc                    = f1_pc;
        new_entry.inst                  = f1_inst;
        new_entry.pred_npc              = f1_pc + 32'd4;
        new_entry.pred_meta.pred_target = f1_pc + 32'd4;
        new_entry.pred_meta.pred_taken  = 1'b0;
        new_entry.pred_meta.pred_type   = new_cfi;
        new_entry.need_redirect         = 1'b0;
        new_entry.cfi_type              = new_cfi;
        new_entry.is_cfi                = (new_cfi != CFI_NONE);
        new_entry.valid                 = 1'b1;
    end

    //-------------------------------------------------------------------------
    // Queue next state: shift out the accepted prefix, append F1 at the tail
    //-------------------------------------------------------------------------
    iq_entry_t  shifted [2];
    iq_entry_t  slot_n [2];
    always_comb begin
        shifted[0] = (pop <= 2'd1) ? slot[pop[0]] : '0;   // pop==2 -> empty
        shifted[1] = (pop == 2'd0) ? slot[1] : '0;

        slot_n[0]  = (push && (used_after_pop == 2'd0)) ? new_entry : shifted[0];
        slot_n[1]  = (push && (used_after_pop == 2'd1)) ? new_entry : shifted[1];

        // iq_inst[i].valid must equal iq_valid[i] (contract section 2).
        slot_n[0].valid = (cnt_next >= 2'd1);
        slot_n[1].valid = (cnt_next == 2'd2);
    end

    assign iq_valid   = (cnt == 2'd2) ? 2'b11 : (cnt == 2'd1) ? 2'b01 : 2'b00;
    assign iq_inst[0] = slot[0];
    assign iq_inst[1] = slot[1];

    //-------------------------------------------------------------------------
    // State
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            cnt      <= 2'd0;
            slot[0]  <= '0;
            slot[1]  <= '0;
            f1_valid <= 1'b0;
            f1_pc    <= RESET_PC;
            f1_inst  <= 32'd0;
            pc_f     <= RESET_PC;
        end else if (redirect) begin
            // Contract 3: drop every not-yet-dispatched old-path instruction,
            // the in-flight fetch included, and restart at the backend PC.
            cnt      <= 2'd0;
            slot[0]  <= '0;
            slot[1]  <= '0;
            f1_valid <= 1'b0;
            pc_f     <= backend_redirect_pc;
        end else begin
            cnt     <= cnt_next;
            slot[0] <= slot_n[0];
            slot[1] <= slot_n[1];
            if (capture) begin
                f1_valid <= 1'b1;
                f1_pc    <= pc_f;
                f1_inst  <= 32'(irom_read(int'(pc_f)));
                pc_f     <= pc_f + 32'd4;
            end
        end
    end

    //-------------------------------------------------------------------------
    // The stub has no predictor FIFO; it always advertises a full 2-entry
    // credit window.  Constant, so it cannot form a BE->FE->BE loop.
    //-------------------------------------------------------------------------
    assign bpu_update_credit = 2'd2;

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Contract assertions (contract section 6 / flow doc section 5)
    //-------------------------------------------------------------------------
    a_no_hole: assert property (@(posedge clk) disable iff (rst)
        iq_valid != 2'b10);

    a_accept_prefix: assert property (@(posedge clk) disable iff (rst)
        iq_accept_count <= $countones(iq_valid));

    a_redirect_stops: assert property (@(posedge clk) disable iff (rst)
        backend_redirect_valid |-> (iq_accept_count == 2'd0));

    a_head_stable: assert property (@(posedge clk) disable iff (rst)
        (!backend_redirect_valid && iq_valid[0] && (iq_accept_count == 2'd0))
        |=> (iq_valid[0] && $stable(iq_inst[0].pc) && $stable(iq_inst[0].inst)
             && $stable(iq_inst[0].pred_npc) && $stable(iq_inst[0].pred_meta)));

    a_slot_valid: assert property (@(posedge clk) disable iff (rst)
        (iq_inst[0].valid == iq_valid[0]) && (iq_inst[1].valid == iq_valid[1]));

    a_pred_npc: assert property (@(posedge clk) disable iff (rst)
        iq_valid[0] |-> (iq_inst[0].pred_npc == iq_inst[0].pc + 32'd4));

    a_no_need_redirect0: assert property (@(posedge clk) disable iff (rst)
        iq_inst[0].valid |-> !iq_inst[0].need_redirect);

    a_no_need_redirect1: assert property (@(posedge clk) disable iff (rst)
        iq_inst[1].valid |-> !iq_inst[1].need_redirect);

    a_is_cfi0: assert property (@(posedge clk) disable iff (rst)
        iq_inst[0].valid |-> (iq_inst[0].is_cfi == (iq_inst[0].cfi_type != CFI_NONE)));

    a_is_cfi1: assert property (@(posedge clk) disable iff (rst)
        iq_inst[1].valid |-> (iq_inst[1].is_cfi == (iq_inst[1].cfi_type != CFI_NONE)));

    // The redirect PC is a single-cycle event: compare the next-cycle pc_f
    // against the value latched from the redirect cycle ($past), not against
    // whatever the producer drives in the following cycle.
    a_redirect_pc_used: assert property (@(posedge clk) disable iff (rst)
        backend_redirect_valid |=> (pc_f == $past(backend_redirect_pc)));
`endif

endmodule
