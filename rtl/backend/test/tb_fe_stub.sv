//=============================================================================
// ARES core verification - self-checking contract test for fe_stub.sv
//-----------------------------------------------------------------------------
// Drives the FE stub with a contract-legal consumer and checks, cycle by
// cycle, everything the backend is allowed to rely on (flow doc section 5):
//
//   * iq_valid is never 2'b10, iq_inst[i].valid always matches iq_valid[i]
//   * every visible entry carries pc / inst / cfi_type consistent with the
//     instruction memory image and pred_meta.pred_target == pc+4
//   * iq_accept_count is consumed as a contiguous prefix: the PC sequence of
//     all popped instructions is exactly pc, pc+4, pc+8, ... with a restart at
//     backend_redirect_pc after every redirect (no instruction lost, none
//     duplicated)
//   * accept=0 keeps the head and its metadata stable; accept=2 only happens
//     with two valid slots
//   * bpu_update_credit is constant 2
//   * a redirect empties the queue on the next cycle and refetches from the
//     redirect PC; redirect storms do not deadlock or corrupt the stream
//
// The stub's own SVA (fe_stub.sv) covers the same protocol from the producer
// side; this TB covers it from the consumer side.
//
// Harness: built through sim/Makefile as TOPNAME=tb_fe_stub, so ORIGINAL
// simulation main.cpp drives clock/reset and stops on the ebreak() below.
// Run: make tb-fe-stub   (see rtl/backend/test/README.md)
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_fe_stub (
    input clock,
    input reset
);
    import ares_pkg::*;
    import fe_pkg::*;

    import "DPI-C" function int  irom_read(input int addr);
    import "DPI-C" function void ebreak();

    wire clk = clock;
    wire rst = reset;

    //-------------------------------------------------------------------------
    // DUT connections
    //-------------------------------------------------------------------------
    logic [1:0]            iq_valid;
    iq_entry_t             iq_inst [2];
    logic [1:0]            iq_accept_count;

    logic                  backend_redirect_valid;
    logic [31:0]           backend_redirect_pc;
    fe_redirect_kind_t     backend_redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0]    backend_redirect_ghr_before;
    logic                  backend_redirect_actual_taken;

    logic [1:0]            bpu_update_credit;
    logic [1:0]            bpu_update_valid;
    bpu_update_t           bpu_update [2];

    assign backend_redirect_kind        = REDIRECT_BRANCH;
    assign backend_redirect_ghr_before  = '0;
    assign backend_redirect_actual_taken= 1'b0;
    assign bpu_update_valid             = 2'd0;
    assign bpu_update[0]                = '0;
    assign bpu_update[1]                = '0;

    fe_stub dut (
        .clk                          (clk),
        .rst                          (rst),
        .iq_valid                     (iq_valid),
        .iq_inst                      (iq_inst),
        .iq_accept_count              (iq_accept_count),
        .backend_redirect_valid       (backend_redirect_valid),
        .backend_redirect_pc          (backend_redirect_pc),
        .backend_redirect_kind        (backend_redirect_kind),
        .backend_redirect_ghr_before  (backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit            (bpu_update_credit),
        .bpu_update_valid             (bpu_update_valid),
        .bpu_update                    (bpu_update)
    );

    //-------------------------------------------------------------------------
    // Phase schedule (cycles counted after reset is released)
    //-------------------------------------------------------------------------
    localparam int unsigned PH_FILL_END  = 80;    // accept=0, queue must fill
    localparam int unsigned PH_RAND_END  = 560;   // pseudo-random pops + redirects
    localparam int unsigned PH_STORM_END = 640;   // redirect every other cycle
    localparam int unsigned PH_DONE      = 700;

    //-------------------------------------------------------------------------
    // Independent reference classifier (opcode + link register, written
    // separately from fe_stub.classify so a shared mistake cannot hide)
    //-------------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */  // only opcode/register fields are read
    function automatic cfi_type_t ref_classify(input logic [31:0] inst);
        logic [6:0] opcode;
        logic [4:0] rd;
        logic [4:0] rs1;
        begin
            opcode = inst[6:0];
            rd     = inst[11:7];
            rs1    = inst[19:15];
            if (opcode == 7'h6f) begin           // JAL
                ref_classify = ((rd == 5'd1) || (rd == 5'd5)) ? CFI_CALL
                                                              : CFI_DIRECT_JUMP;
            end else if (opcode == 7'h67) begin  // JALR
                if ((rd == 5'd1) || (rd == 5'd5))
                    ref_classify = CFI_CALL;
                else if ((rs1 == 5'd1) || (rs1 == 5'd5))
                    ref_classify = CFI_RETURN;
                else
                    ref_classify = CFI_INDIRECT_JUMP;
            end else if (opcode == 7'h63) begin  // BRANCH
                ref_classify = CFI_COND_BRANCH;
            end else begin
                ref_classify = CFI_NONE;
            end
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    //-------------------------------------------------------------------------
    // Bookkeeping
    //-------------------------------------------------------------------------
    int unsigned cyc;             // cycles since reset release
    int unsigned errors;
    int unsigned instr_count;     // instructions consumed by the fake backend
    int unsigned redirect_count;

    logic [31:0] ref_pc;          // PC the next popped instruction must carry
    logic        ref_armed;
    logic [31:0] stable_pc;       // head stability shadow
    logic [31:0] stable_inst;
    logic        stable_valid;
    logic        fill_ok;
    logic        done;

    logic [15:0] lfsr;
    always_ff @(posedge clk) begin
        if (rst) lfsr <= 16'hace1;
        else     lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            /* verilator lint_off BLKSEQ */  // task-local scoreboard update
            errors = errors + 1;
            /* verilator lint_on BLKSEQ */
            if (errors <= 20) $display("[cyc %0d] FAIL: %s", cyc, msg);
        end
    endtask

    //-------------------------------------------------------------------------
    // Consumer side stimulus: contract-legal accept + redirect schedule
    //-------------------------------------------------------------------------
    logic        drive_redirect;
    logic [31:0] drive_redirect_pc;
    logic [1:0]  desired_accept;

    always_comb begin
        drive_redirect    = 1'b0;
        drive_redirect_pc = 32'h8000_0000;
        desired_accept    = 2'd0;
        if (!rst) begin
            if (cyc < PH_FILL_END) begin
                desired_accept = 2'd0;
            end else if (cyc < PH_RAND_END) begin
                desired_accept = lfsr[1:0];
                drive_redirect = ((cyc % 37) == 0);
                drive_redirect_pc = 32'h8000_0000 + 32'({lfsr[11:0], 2'b00});
            end else if (cyc < PH_STORM_END) begin
                desired_accept = 2'd1;
                drive_redirect = ~cyc[0];
                drive_redirect_pc = 32'h8000_0000 + 32'({lfsr[9:0], 2'b00});
            end
        end
    end

    // The backend never accepts more than the available prefix; a redirect
    // cycle always has iq_accept_count == 0 (contract section 2/3).
    always_comb begin
        backend_redirect_valid = !rst && drive_redirect;
        backend_redirect_pc    = drive_redirect_pc & 32'hffff_fffc;
        iq_accept_count        = backend_redirect_valid ? 2'd0
                               : (desired_accept <= $countones(iq_valid))
                                 ? desired_accept
                                 : $countones(iq_valid);
    end

    //-------------------------------------------------------------------------
    // Checks and reference tracking
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            cyc            <= 0;
            errors         <= 0;
            instr_count    <= 0;
            redirect_count <= 0;
            ref_pc         <= RESET_PC;
            ref_armed      <= 1'b0;
            stable_valid   <= 1'b0;
            stable_pc      <= 32'd0;
            stable_inst    <= 32'd0;
            fill_ok        <= 1'b0;
            done           <= 1'b0;
        end else begin
            cyc <= cyc + 1;

            // ---- always-on protocol invariants -----------------------------
            check(iq_valid != 2'b10, "iq_valid is 2'b10 (hole)");
            check(iq_inst[0].valid == iq_valid[0], "slot0 valid != iq_valid[0]");
            check(iq_inst[1].valid == iq_valid[1], "slot1 valid != iq_valid[1]");
            check(bpu_update_credit == 2'd2, "bpu_update_credit != 2");
            check(!backend_redirect_valid || (iq_accept_count == 2'd0),
                  "accept != 0 while redirect is valid");

            if (iq_valid[0]) begin
                check(iq_inst[0].inst == 32'(irom_read(int'(iq_inst[0].pc))),
                      "fetched word != memory image");
                check(iq_inst[0].pred_meta.pred_target == (iq_inst[0].pc + 32'd4),
                      "pred_target != pc+4");
                check(iq_inst[0].cfi_type == ref_classify(iq_inst[0].inst),
                      "cfi_type != reference classification");
                check(iq_inst[0].is_cfi == (iq_inst[0].cfi_type != CFI_NONE),
                      "is_cfi disagrees with cfi_type");
            end
            if (iq_valid == 2'b11)
                check(iq_inst[1].pc == (iq_inst[0].pc + 32'd4),
                      "slot1 pc != slot0 pc + 4");

            // ---- head stability while accept=0 -----------------------------
            if (stable_valid) begin
                check(!(iq_valid[0] && (iq_inst[0].pc != stable_pc)),
                      "head pc changed while not consumed");
                check(!(iq_valid[0] && (iq_inst[0].inst != stable_inst)),
                      "head inst changed while not consumed");
            end

            // ---- pop tracking: the PC stream must be dense + ordered --------
            if (!backend_redirect_valid && (iq_accept_count != 2'd0) && iq_valid[0]) begin
                if (ref_armed)
                    check(iq_inst[0].pc == ref_pc, "popped PC out of sequence");
                if (iq_accept_count == 2'd2) begin
                    check(iq_valid == 2'b11, "accept=2 without two valid slots");
                    ref_pc <= iq_inst[1].pc + 32'd4;
                end else begin
                    ref_pc <= iq_inst[0].pc + 32'd4;
                end
                ref_armed    <= 1'b1;
                instr_count  <= instr_count + {30'd0, iq_accept_count};
            end

            // ---- redirect resynchronises the reference ---------------------
            // The redirected stream restarts at backend_redirect_pc; the
            // next-cycle "queue is empty" property is asserted at the bottom.
            if (backend_redirect_valid) begin
                ref_pc         <= backend_redirect_pc;
                ref_armed      <= 1'b1;
                redirect_count <= redirect_count + 1;
            end

            // ---- fill phase progress ---------------------------------------
            if ((cyc >= 4) && (iq_valid == 2'b11)) fill_ok <= 1'b1;
            if ((cyc == 8) && !fill_ok)
                check(1'b0, "queue did not reach iq_valid=11 within 8 cycles");
            if ((cyc == 8) && fill_ok)
                check(iq_inst[0].pc == RESET_PC, "first instruction is not RESET_PC");

            stable_valid <= (iq_valid[0] != 1'b0) && (iq_accept_count == 2'd0)
                            && !backend_redirect_valid;
            stable_pc    <= iq_inst[0].pc;
            stable_inst  <= iq_inst[0].inst;

            // ---- end of test ----------------------------------------------
            if ((cyc >= PH_DONE) && !done) begin
                done <= 1'b1;
                if (errors == 0) begin
                    $display("ALL TESTS PASSED: tb_fe_stub consumed %0d instructions, %0d redirects, %0d cycles",
                             instr_count, redirect_count, cyc);
                    ebreak();
                end else begin
                    $display("FAILED: tb_fe_stub saw %0d contract errors", errors);
                    $fatal(1, "tb_fe_stub contract violations");
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    // The one property that needs a next-cycle look: a redirect empties IQ.
    a_redirect_empties: assert property (@(posedge clk) disable iff (rst)
        backend_redirect_valid |=> (iq_valid == 2'b00));
`endif

endmodule
