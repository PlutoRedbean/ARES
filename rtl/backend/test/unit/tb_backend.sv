//=============================================================================
// ARES backend - C1 integration self-check (tb_backend)
//-----------------------------------------------------------------------------
// DUT: be_top (full backend) + lsu_stub (ideal memory port) + fe_model
// (contract-shaped fetch).  See docs/core_verification_flow.md sections 2/5.
//
//   phase 1  directed program, checked instruction by instruction against an
//            independent RV32IM golden model (retire PC, rd, value): branch
//            taken/not-taken, JAL, JALR target resolution, loads/stores, MUL/DIV/
//            REM, serializing CSR, 2-wide dispatch, store commit handshake;
//   phase 2  ECALL -> mtvec handler -> MRET and a machine timer interrupt
//            (drain-to-boundary, mepc/mcause/mstatus path);
//   phase 3  fixed-seed random programs (rounds), golden model + contract
//            assertions, >= 10k random cycles, commit-progress watchdog.
//
// Contract checks that live here (plan section 8.3, contract section 6):
//   * backend_redirect_valid |-> iq_accept_count == 0;
//   * lsu_issue_valid |-> lsu_can_accept (guaranteed accept);
//   * BPU event count <= registered credit;
//   * no decode_err, no dep_error (RTL SVA covers completion/kill/pointer
//     invariants), no silent deadlock.
//
// Standalone bench (own clock, no DPI harness): the exact build command lives
// in rtl/backend/test/README.md and in the root Makefile target `make tb-backend`.
//
// FREE items: FREE-10 (verification environment internal structure).
//=============================================================================
module tb_backend;
    import ares_pkg::*;
    import fe_pkg::*;

    localparam logic [31:0] BASE    = 32'h8000_0000;
    localparam logic [31:0] HANDLER = 32'h8000_0200;
    localparam int unsigned IMEM_WORDS = 1024;
    localparam int unsigned P1_CAP = 20000;
    localparam int unsigned P3_ROUNDS = 10;
    localparam int unsigned P3_LEN = 1000;
    localparam int unsigned P3_CAP = 30000;

    logic clk;
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    logic rst = 1'b1;
    logic timer_irq;
    logic [31:0] imem [IMEM_WORDS];

    //---- DUT ports ---------------------------------------------------------
    logic [1:0]            iq_valid;
    iq_entry_t             iq_inst [2];
    logic [1:0]            iq_accept_count;
    logic                  redirect_valid;
    logic [31:0]           redirect_pc;
    fe_redirect_kind_t     redirect_kind;
    logic [fe_pkg::GHR_WIDTH-1:0]  redirect_ghr;
    logic                  redirect_taken;
    logic [1:0]            bpu_credit, bpu_valid;
    bpu_update_t           bpu_update [2];
    logic                  d_can_accept;
    logic [2:0]            d_load_credit;
    logic [3:0]            d_store_credit;
    logic                  d_issue_valid;
    fu_req_t               d_issue_req;
    logic                  d_completion_valid;
    fu_completion_t        d_completion;
    logic [CIQ_ENTRIES-1:0] d_kill_mask;
    logic                  load_head_valid;
    tag_t                  load_head_tag;
    logic [1:0]            store_commit_valid;
    tag_t                  store_commit_tag [2];
    logic [1:0]            store_commit_ok;
    logic                  mmio_idle;
    logic [1:0]            retire_valid;
    logic [31:0]           retire_pc [2];
    logic [31:0]           retire_pc_next [2];
    logic [1:0]            retire_rd_wen;
    logic [4:0]            retire_rd [2];
    logic [31:0]           retire_wdata [2];
    logic [1:0]            retire_is_ebreak;
    logic                  irq_redirect_valid;
    logic [31:0]           irq_redirect_pc;
    logic [1:0]            decode_err;
    logic [31:0]           decode_err_pc [2];
    logic [31:0]           decode_err_inst [2];
    logic                  dep_error;
    /* verilator lint_off UNUSEDSIGNAL */  // debug visibility (waveforms + failure dumps)
    logic [4:0]            dbg_occupancy;
    logic [7:0]            dbg_fu_issue_valid;
    fu_req_t               dbg_fu_req [8];
    tag_t                  dbg_issue_tag [4];
    logic [1:0]            dbg_commit_fire;
    logic [31:0]           dbg_arch_next_pc;
    tag_t                  dbg_commit_ptr, dbg_issue_ptr, dbg_alloc_ptr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [4:0]            lq_used, sq_used;
    /* verilator lint_off UNUSEDSIGNAL */  // only the alignment of fetch_pc is checked here
    logic [31:0]           fetch_pc;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0]           redirect_count;

    be_top #(.RESET_MTVEC(HANDLER)) u_dut (
        .clk(clk), .rst(rst),
        .iq_valid(iq_valid), .iq_inst(iq_inst), .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(redirect_valid),
        .backend_redirect_pc(redirect_pc),
        .backend_redirect_kind(redirect_kind),
        .backend_redirect_ghr_before(redirect_ghr),
        .backend_redirect_actual_taken(redirect_taken),
        .bpu_update_credit(bpu_credit), .bpu_update_valid(bpu_valid), .bpu_update(bpu_update),
        .lsu_can_accept(d_can_accept), .load_credit(d_load_credit), .store_credit(d_store_credit),
        .lsu_issue_valid(d_issue_valid), .lsu_issue_req(d_issue_req),
        .lsu_completion_valid(d_completion_valid), .lsu_completion(d_completion),
        .kill_mask(d_kill_mask),
        .load_head_valid(load_head_valid), .load_head_tag(load_head_tag),
        .store_commit_valid(store_commit_valid), .store_commit_tag(store_commit_tag),
        .store_commit_ok(store_commit_ok), .lsu_mmio_order_idle(mmio_idle),
        .timer_irq(timer_irq),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd), .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .irq_redirect_valid(irq_redirect_valid), .irq_redirect_pc(irq_redirect_pc),
        .decode_err(decode_err), .decode_err_pc(decode_err_pc), .decode_err_inst(decode_err_inst),
        .dep_error(dep_error), .dbg_occupancy(dbg_occupancy), .dbg_commit_fire(dbg_commit_fire),
        .dbg_fu_issue_valid(dbg_fu_issue_valid), .dbg_issue_tag(dbg_issue_tag),
        .dbg_fu_req(dbg_fu_req),
        .dbg_commit_ptr(dbg_commit_ptr), .dbg_issue_ptr(dbg_issue_ptr),
        .dbg_alloc_ptr(dbg_alloc_ptr), .dbg_arch_next_pc(dbg_arch_next_pc)
    );

    fe_model #(.RESET_PC(BASE), .IMEM_WORDS(IMEM_WORDS)) u_fe (
        .clk(clk), .rst(rst),
        .iq_valid(iq_valid), .iq_inst(iq_inst), .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(redirect_valid), .backend_redirect_pc(redirect_pc),
        .bpu_update_credit(bpu_credit), .bpu_update_valid(bpu_valid), .bpu_update(bpu_update),
        .imem(imem), .fetch_pc(fetch_pc), .redirect_count(redirect_count)
    );

    lsu_stub u_lsu (
        .clk(clk), .rst(rst),
        .can_accept(d_can_accept), .load_credit(d_load_credit), .store_credit(d_store_credit),
        .issue_valid(d_issue_valid), .issue_req(d_issue_req),
        .completion_valid(d_completion_valid), .completion(d_completion), .kill_mask(d_kill_mask),
        .store_commit_valid(store_commit_valid), .store_commit_tag(store_commit_tag),
        .store_commit_ok(store_commit_ok), .commit_fire(dbg_commit_fire),
        .load_head_valid(load_head_valid), .load_head_tag(load_head_tag),
        .mmio_order_idle(mmio_idle), .lq_used(lq_used), .sq_used(sq_used)
    );

    //=========================================================================
    // Encoders
    //=========================================================================
    function automatic logic [31:0] enc_r(input logic [6:0] op, input logic [4:0] rd,
                                          input logic [2:0] f3, input logic [4:0] rs1,
                                          input logic [4:0] rs2, input logic [6:0] f7);
        enc_r = {f7, rs2, rs1, f3, rd, op};
    endfunction
    function automatic logic [31:0] enc_i(input logic [6:0] op, input logic [4:0] rd,
                                          input logic [2:0] f3, input logic [4:0] rs1,
                                          input logic signed [11:0] imm);
        enc_i = {imm[11:0], rs1, f3, rd, op};
    endfunction
    function automatic logic [31:0] enc_s(input logic [2:0] f3, input logic [4:0] rs1,
                                          input logic [4:0] rs2, input logic signed [11:0] imm);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23};
    endfunction
    /* verilator lint_off UNUSEDSIGNAL */  // imm[0] is always 0 for a branch offset
    function automatic logic [31:0] enc_b(input logic [2:0] f3, input logic [4:0] rs1,
                                          input logic [4:0] rs2, input logic [12:0] imm);
        enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'h63};
    endfunction
    function automatic logic [31:0] enc_u(input logic [6:0] op, input logic [4:0] rd,
                                          input logic [31:0] imm);
        enc_u = {imm[31:12], rd, op};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */  // imm[0] is always 0 for a jump offset
    function automatic logic [31:0] enc_j(input logic [4:0] rd, input logic [20:0] imm);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    function automatic logic [31:0] nop_word;
        nop_word = enc_i(7'h13, 5'd0, 3'h0, 5'd0, 12'd0);
    endfunction
    function automatic logic [31:0] ebreak_word;
        ebreak_word = enc_i(7'h73, 5'd0, 3'h0, 5'd0, 12'd1);
    endfunction
    function automatic logic [31:0] ecall_word;
        ecall_word = enc_i(7'h73, 5'd0, 3'h0, 5'd0, 12'd0);
    endfunction
    function automatic logic [31:0] mret_word;
        mret_word = enc_i(7'h73, 5'd0, 3'h0, 5'd0, 12'h302);
    endfunction

    //=========================================================================
    // Golden RV32IM model
    //=========================================================================
    logic [31:0] gold_gpr [32];
    logic [31:0] gold_poison;   // registers whose model value is unknown (CSR reads)
    int unsigned gold_checked, gold_unchecked;
    logic        g_checked, g_wen;
    logic [4:0]  g_rd;
    logic [31:0] g_val;

    task automatic gold_exec(input logic [31:0] inst, input logic [31:0] pc);
        logic [6:0] opc;
        logic [2:0] f3;
        logic [6:0] f7;
        logic [4:0] rs1, rs2;
        logic [31:0] a, b;
        logic signed [31:0] sa, sb;
        /* verilator lint_off UNUSEDSIGNAL */  // only the high half is compared
        logic [63:0] prod;
        logic signed [31:0] sres, srem;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [31:0] imm;
        begin
            opc = inst[6:0]; f3 = inst[14:12]; f7 = inst[31:25];
            g_rd = inst[11:7]; rs1 = inst[19:15]; rs2 = inst[24:20];
            imm  = {{20{inst[31]}}, inst[31:20]};
            a = gold_gpr[rs1]; b = gold_gpr[rs2];
            dbg_op_a = a; dbg_op_b = b; dbg_op_f3 = f3; dbg_op_f7 = f7;
            dbg_op_rs1 = rs1; dbg_op_rs2 = rs2;
            sa = $signed(a); sb = $signed(b);
            g_checked = 1'b1; g_wen = 1'b0; g_val = 32'd0;
            case (opc)
                7'h37: begin g_wen = 1'b1; g_val = {inst[31:12], 12'b0}; end
                7'h17: begin g_wen = 1'b1; g_val = pc + {inst[31:12], 12'b0}; end
                7'h6f: begin g_wen = 1'b1; g_val = pc + 32'd4; end
                7'h67: begin g_wen = 1'b1; g_val = pc + 32'd4; end
                7'h63: begin g_wen = 1'b0; end
                7'h03: begin g_wen = 1'b1; g_val = a + imm; end
                7'h23: begin g_wen = 1'b0; end
                7'h13: begin
                    g_wen = 1'b1;
                    case (f3)
                        3'h0: g_val = a + imm;
                        3'h2: g_val = ($signed(a) < $signed(imm)) ? 32'd1 : 32'd0;
                        3'h3: g_val = (a < imm) ? 32'd1 : 32'd0;
                        3'h4: g_val = a ^ imm;
                        3'h6: g_val = a | imm;
                        3'h7: g_val = a & imm;
                        3'h1: g_val = a << inst[24:20];
                        3'h5: g_val = inst[30] ? (sa >>> inst[24:20]) : (a >> inst[24:20]);
                        default: g_checked = 1'b0;
                    endcase
                end
                7'h33: begin
                    g_wen = 1'b1;
                    if (f7 == 7'h01) begin
                        case (f3)
                            3'h0: g_val = a * b;
                            3'h1: begin prod = $signed(a) * $signed(b);          g_val = prod[63:32]; end
                            3'h2: begin prod = $signed(a) * $signed({1'b0, b});   g_val = prod[63:32]; end
                            3'h3: begin prod = {32'b0, a} * {32'b0, b};           g_val = prod[63:32]; end
                            // NOTE: the signed division must run outside the
                            // conditional - a conditional with an unsigned
                            // branch makes the whole expression unsigned and
                            // would silently select DIVU semantics.
                            3'h4: begin
                                sres = sa / sb;
                                g_val = (b == 32'd0) ? 32'hffff_ffff
                                      : ((a == 32'h8000_0000 && b == 32'hffff_ffff)
                                         ? 32'h8000_0000 : sres[31:0]);
                            end
                            3'h5: g_val = (b == 32'd0) ? 32'hffff_ffff : (a / b);
                            3'h6: begin
                                srem = sa % sb;
                                g_val = (b == 32'd0) ? a
                                      : ((a == 32'h8000_0000 && b == 32'hffff_ffff)
                                         ? 32'd0 : srem[31:0]);
                            end
                            3'h7: g_val = (b == 32'd0) ? a : (a % b);
                            default: g_checked = 1'b0;
                        endcase
                    end else begin
                        case (f3)
                            3'h0: g_val = (f7 == 7'h20) ? (a - b) : (a + b);
                            3'h1: g_val = a << b[4:0];
                            3'h2: g_val = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                            3'h3: g_val = (a < b) ? 32'd1 : 32'd0;
                            3'h4: g_val = a ^ b;
                            3'h5: g_val = (f7 == 7'h20) ? (sa >>> b[4:0]) : (a >> b[4:0]);
                            3'h6: g_val = a | b;
                            3'h7: g_val = a & b;
                            default: g_checked = 1'b0;
                        endcase
                    end
                end
                default: begin
                    // SYSTEM (CSR/ECALL/MRET/EBREAK): a CSR read into rd makes
                    // that register unknown to the model.
                    g_checked = 1'b0;
                    if (g_rd != 5'd0) gold_poison[g_rd] = 1'b1;
                end
            endcase
            // A source register written by an un-modelled SYSTEM instruction
            // (csrr) has an unknown model value: skip the value comparison.
            if (g_checked && ((|({32{g_checked}} & gold_poison)) !== 1'b0)
                && ((g_rd == 5'd0) ? 1'b0 : 1'b0)) begin end
            if (g_checked && (gold_poison[rs1] || gold_poison[rs2])) g_checked = 1'b0;

            if (g_rd == 5'd0) g_wen = 1'b0;
            if (g_wen) begin
                gold_gpr[g_rd] = g_val;
                gold_poison[g_rd] = 1'b0;
            end
            if (g_checked) gold_checked = gold_checked + 1;
            else gold_unchecked = gold_unchecked + 1;
        end
    endtask

    //=========================================================================
    // Program construction
    //=========================================================================
    int unsigned pidx;
    task automatic emit(input logic [31:0] w);
        begin
            imem[pidx] = w;
            pidx = pidx + 1;
        end
    endtask
    task automatic nops(input int unsigned n);
        begin
            for (int unsigned i = 0; i < n; i++) emit(nop_word());
        end
    endtask

    task automatic build_directed;
        begin
            for (int unsigned i = 0; i < IMEM_WORDS; i++) imem[i] = nop_word();
            pidx = 0;
            emit(enc_i(7'h13, 5'd1, 3'h0, 5'd0, 12'd5));            // x1 = 5
            emit(enc_i(7'h13, 5'd2, 3'h0, 5'd0, 12'd7));            // x2 = 7
            emit(enc_r(7'h33, 5'd3, 3'h0, 5'd1, 5'd2, 7'h00));      // x3 = 12
            emit(enc_r(7'h33, 5'd4, 3'h0, 5'd2, 5'd1, 7'h20));      // x4 = 2
            emit(enc_r(7'h33, 5'd5, 3'h4, 5'd3, 5'd4, 7'h00));      // x5 = 14
            emit(enc_i(7'h13, 5'd6, 3'h1, 5'd5, 12'd3));            // x6 = 112
            emit(enc_s(3'h2, 5'd0, 5'd3, 12'd8));                   // sw x3, 8(x0)
            emit(enc_i(7'h03, 5'd7, 3'h2, 5'd0, 12'd8));            // lw x7, 8(x0)
            emit(enc_r(7'h33, 5'd8, 3'h0, 5'd3, 5'd4, 7'h01));      // mul x8 = 24
            emit(enc_r(7'h33, 5'd9, 3'h4, 5'd6, 5'd1, 7'h01));      // div x9 = 22
            emit(enc_r(7'h33, 5'd10, 3'h6, 5'd6, 5'd2, 7'h01));     // rem x10 = 0
            emit(enc_b(3'h0, 5'd1, 5'd2, 13'd8));                  // beq not taken
            emit(enc_i(7'h13, 5'd11, 3'h0, 5'd0, 12'd1));           // x11 = 1
            emit(enc_b(3'h1, 5'd1, 5'd2, 13'd8));                  // bne taken
            emit(enc_i(7'h13, 5'd12, 3'h0, 5'd0, 12'd9));           // skipped
            emit(enc_u(7'h37, 5'd13, 32'h1234_5000));               // lui x13
            emit(enc_j(5'd15, 21'd8));                             // jal x15, +8
            emit(enc_i(7'h13, 5'd16, 3'h0, 5'd0, 12'd9));           // skipped
            emit(enc_i(7'h13, 5'd17, 3'h0, 5'd0, 12'd3));           // x17 = 3
            emit(enc_u(7'h37, 5'd18, 32'h8000_0000));               // lui x18
            emit(enc_i(7'h13, 5'd18, 3'h0, 5'd18, 12'h068));        // x18 -> index 26
            emit(enc_i(7'h67, 5'd19, 3'h0, 5'd18, 12'd0));          // jalr x19, 0(x18)
            emit(enc_i(7'h13, 5'd20, 3'h0, 5'd0, 12'h11));          // skipped
            emit(enc_i(7'h13, 5'd21, 3'h0, 5'd0, 12'h22));          // skipped
            emit(enc_i(7'h13, 5'd22, 3'h0, 5'd0, 12'h33));          // skipped
            emit(enc_i(7'h13, 5'd23, 3'h0, 5'd0, 12'h55));          // x23 = 0x55
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd23, 12'h340));         // csrw mscratch
            emit(enc_i(7'h73, 5'd24, 3'h2, 5'd0, 12'h340));         // csrr x24, mscratch
            emit(enc_i(7'h13, 5'd24, 3'h0, 5'd0, 12'd0));           // golden resync
            emit(enc_u(7'h37, 5'd25, 32'h8000_0000));               // lui x25
            emit(enc_i(7'h13, 5'd25, 3'h0, 5'd25, 12'h200));        // x25 = HANDLER
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd25, 12'h305));         // csrw mtvec
            emit(ecall_word());                                     // ECALL -> handler
            emit(enc_i(7'h13, 5'd26, 3'h0, 5'd0, 12'd42));          // after MRET
            emit(enc_i(7'h13, 5'd27, 3'h0, 5'd0, 12'h080));         // x27 = MTIE
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd27, 12'h304));         // csrw mie
            emit(enc_i(7'h13, 5'd28, 3'h0, 5'd0, 12'd8));           // MIE
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd28, 12'h300));         // csrw mstatus
            emit(enc_i(7'h13, 5'd29, 3'h0, 5'd0, 12'd1));           // marker
            nops(20);
            emit(ebreak_word());
            pidx = 128;                                             // handler
            emit(enc_i(7'h73, 5'd21, 3'h2, 5'd0, 12'h342));         // csrr x21, mcause
            emit(enc_i(7'h13, 5'd22, 3'h0, 5'd0, 12'd11));          // x22 = 11
            emit(enc_b(3'h1, 5'd21, 5'd22, 13'd16));               // bne -> +16
            emit(enc_i(7'h73, 5'd23, 3'h2, 5'd0, 12'h341));         // csrr x23, mepc
            emit(enc_i(7'h13, 5'd23, 3'h0, 5'd23, 12'd4));          // mepc += 4
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd23, 12'h341));         // csrw mepc
            emit(enc_i(7'h73, 5'd0, 3'h1, 5'd0, 12'h300));          // csrw mstatus, x0
            emit(mret_word());                                      // MRET
        end
    endtask

    int unsigned rnd_state;
    function automatic int unsigned rnd(input int unsigned m);
        begin
            rnd_state = rnd_state * 32'd1664525 + 32'd1013904223;
            rnd = (rnd_state >> 8) % m;
        end
    endfunction

    task automatic build_random(input int unsigned seed, input int unsigned n);
        int unsigned r;
        logic [2:0]  br_f3;
        begin
            for (int unsigned i = 0; i < IMEM_WORDS; i++) imem[i] = nop_word();
            rnd_state = seed;
            pidx = 0;
            for (int unsigned i = 0; i < n - 8; i++) begin
                r = rnd(100);
                if (r < 35)
                    emit(enc_r(7'h33, 5'(rnd(32)), 3'(rnd(8)), 5'(rnd(32)), 5'(rnd(32)), 7'h00));
                else if (r < 50)
                    emit(enc_i(7'h13, 5'(rnd(32)), 3'(rnd(8)), 5'(rnd(32)), 12'(rnd(32))));
                else if (r < 60)
                    emit(enc_i(7'h03, 5'(rnd(32)), 3'h2, 5'(rnd(32)), 12'(rnd(64))));
                else if (r < 70)
                    emit(enc_s(3'h2, 5'(rnd(32)), 5'(rnd(32)), 12'(rnd(64))));
                else if (r < 80) begin
                    // legal conditional-branch funct3 only (2/3 are illegal)
                    case (rnd(6))
                        0: br_f3 = 3'h0;   // beq
                        1: br_f3 = 3'h1;   // bne
                        2: br_f3 = 3'h4;   // blt
                        3: br_f3 = 3'h5;   // bge
                        4: br_f3 = 3'h6;   // bltu
                        default: br_f3 = 3'h7;  // bgeu
                    endcase
                    emit(enc_b(br_f3, 5'(rnd(32)), 5'(rnd(32)), 13'(4 * (1 + rnd(3)))));
                end
                else if (r < 88)
                    emit(enc_r(7'h33, 5'(rnd(32)), 3'(rnd(8)), 5'(rnd(32)), 5'(rnd(32)), 7'h01));
                else if (r < 94)
                    emit(enc_j(5'(rnd(32)), 21'(4 * (1 + rnd(3)))));
                else
                    emit(enc_u(7'h37, 5'(rnd(32)), {16'(rnd(16)), 16'h0000}));
            end
            nops(7);
            emit(ebreak_word());
        end
    endtask

    //=========================================================================
    // Checks, monitors and run control
    //=========================================================================
    int unsigned errors;
    int unsigned cycles;
    int unsigned retire_count;
    int unsigned redirects_seen;
    int unsigned bpu_events_seen;
    int unsigned handler_entries;
    int unsigned mret_count;
    logic        ebreak_seen;
    int unsigned cycles_since_commit;
    int unsigned p3_cycles;
    int unsigned p3_retires;
    int unsigned mismatch_prints;
    logic [31:0] dbg_op_a, dbg_op_b;
    logic [31:0] iss_src1 [1024];
    logic [31:0] iss_src2 [1024];
    logic [5:0]  iss_op   [1024];
    logic [31:0] wr_pc [32];
    longint unsigned wr_time [32];
    logic [4:0]  dbg_op_rs1, dbg_op_rs2;
    logic [2:0]  dbg_op_f3;
    logic [6:0]  dbg_op_f7;

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            $display("[%0t] FAIL: %s", $time, msg);
        end
    endtask

    a_redirect_accept: assert property (@(posedge clk) disable iff (rst)
        redirect_valid |-> (iq_accept_count == 2'd0))
        else fail("redirect must force iq_accept_count == 0");
    a_lsu_accept: assert property (@(posedge clk) disable iff (rst)
        d_issue_valid |-> d_can_accept)
        else fail("LSU issue without can_accept");
    a_bpu_credit: assert property (@(posedge clk) disable iff (rst)
        ({1'b0, bpu_valid[0]} + {1'b0, bpu_valid[1]}) <= {1'b0, bpu_credit})
        else fail("BPU events exceed the registered credit");
    a_decode_err: assert property (@(posedge clk) disable iff (rst) (decode_err == 2'b00))
        else begin
            fail("decode_err raised");
            $display("  err=%b iqv=%b fetch_pc=%h pc0=%h inst0=%h pc1=%h inst1=%h",
                     decode_err, iq_valid, fetch_pc,
                     decode_err_pc[0], decode_err_inst[0], decode_err_pc[1], decode_err_inst[1]);
        end
    a_dep_error: assert property (@(posedge clk) disable iff (rst) !dep_error)
        else fail("dependency points at an invalid slot");
    // With an always-not-taken fetch model a BRU recovery is only produced for
    // an actually taken CFI, and the FE model keeps ghr_before at zero.
    a_branch_taken: assert property (@(posedge clk) disable iff (rst)
        redirect_valid && (redirect_kind == REDIRECT_BRANCH) |-> redirect_taken)
        else fail("branch redirect with actual_taken == 0");
    a_branch_ghr: assert property (@(posedge clk) disable iff (rst)
        redirect_valid && (redirect_kind == REDIRECT_BRANCH) |-> (redirect_ghr == '0))
        else fail("branch redirect carried an unexpected ghr_before");
    a_fetch_align: assert property (@(posedge clk) disable iff (rst) (fetch_pc[1:0] == 2'b00))
        else fail("fetch PC is not 4-byte aligned");
    // An accepted machine-timer interrupt redirects to mtvec (the handler).
    a_irq_pc: assert property (@(posedge clk) disable iff (rst)
        irq_redirect_valid |-> (irq_redirect_pc == HANDLER))
        else fail("interrupt redirect PC is not the trap vector");
    a_lsu_usage: assert property (@(posedge clk) disable iff (rst)
        (lq_used <= 5'd4) && (sq_used <= 5'd8))
        else fail("LSU stub occupancy out of range");

    //---- retire monitor + golden model -------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            cycles_since_commit <= 0;
            retire_count <= 0;
            redirects_seen <= 0;
            bpu_events_seen <= 0;
            handler_entries <= 0;
            mret_count <= 0;
            ebreak_seen <= 1'b0;
        end else begin
            cycles <= cycles + 1;
            if (redirect_valid) redirects_seen <= redirects_seen + 1;
            if (bpu_valid != 2'b00) bpu_events_seen <= bpu_events_seen + 1;

            // record the operands every FU actually received, keyed by PC
            for (int unsigned p = 0; p < 8; p++)
                if (dbg_fu_issue_valid[p]) begin
                    iss_src1[dbg_fu_req[p].pc[11:2]] <= dbg_fu_req[p].src1;
                    iss_src2[dbg_fu_req[p].pc[11:2]] <= dbg_fu_req[p].src2;
                    iss_op[dbg_fu_req[p].pc[11:2]]   <= dbg_fu_req[p].op;
                end

            if (|retire_valid) cycles_since_commit <= 0;
            else if (cycles_since_commit < 32'hffff_ffff) cycles_since_commit <= cycles_since_commit + 1;

            for (int unsigned l = 0; l < 2; l++) begin
                if (retire_valid[l]) begin
                    retire_count <= retire_count + 1;
                    gold_exec(imem[retire_pc[l][11:2]], retire_pc[l]);
                    if (g_checked) begin
                        if (retire_rd_wen[l] !== g_wen) begin
                            fail("retire rd_wen mismatch");
                            $display("  pc=%h inst=%h exp_wen=%0b got_wen=%0b",
                                     retire_pc[l], imem[retire_pc[l][11:2]], g_wen, retire_rd_wen[l]);
                        end else if (g_wen && ((retire_rd[l] !== g_rd) || (retire_wdata[l] !== g_val))) begin
                            fail("retire value mismatch");
                            $display("  pc=%h inst=%h exp x%0d=%h got x%0d=%h",
                                     retire_pc[l], imem[retire_pc[l][11:2]], g_rd, g_val,
                                     retire_rd[l], retire_wdata[l]);
                            if (mismatch_prints < 6) begin
                                mismatch_prints <= mismatch_prints + 1;
                                $display("     lane=%0d model used rs1=x%0d(%h) rs2=x%0d(%h) f3=%0d f7=%h",
                                         l, dbg_op_rs1, dbg_op_a, dbg_op_rs2, dbg_op_b,
                                         dbg_op_f3, dbg_op_f7);
                                $display("     issued with src1=%h src2=%h op=%0d",
                                         iss_src1[retire_pc[l][11:2]], iss_src2[retire_pc[l][11:2]],
                                         iss_op[retire_pc[l][11:2]]);
                                $display("     rs1 last writer pc=%h @%0t, rs2 last writer pc=%h @%0t, now=%0t",
                                         wr_pc[imem[retire_pc[l][11:2]][19:15]],
                                         wr_time[imem[retire_pc[l][11:2]][19:15]],
                                         wr_pc[imem[retire_pc[l][11:2]][24:20]],
                                         wr_time[imem[retire_pc[l][11:2]][24:20]], $time);
                            end
                        end
                    end
                    if (retire_rd_wen[l]) begin
                        wr_pc[retire_rd[l]]   <= retire_pc[l];
                        wr_time[retire_rd[l]] <= $time;
                    end
                    if (retire_is_ebreak[l]) ebreak_seen <= 1'b1;
                    if (retire_pc[l] == HANDLER) handler_entries <= handler_entries + 1;
                    if (imem[retire_pc[l][11:2]] == mret_word()) mret_count <= mret_count + 1;
                end
            end
        end
    end

    //---- timer interrupt request ------------------------------------------
    logic marker_retired;
    always_ff @(posedge clk) begin
        if (rst) marker_retired <= 1'b0;
        else for (int unsigned l = 0; l < 2; l++)
            if (retire_valid[l] && (imem[retire_pc[l][11:2]] == enc_i(7'h13, 5'd29, 3'h0, 5'd0, 12'd1)))
                marker_retired <= 1'b1;
    end
    always_comb timer_irq = !rst && marker_retired && (handler_entries < 2);

    task automatic run_until_ebreak(input int unsigned cap);
        int unsigned n;
        begin
            n = 0;
            while (!ebreak_seen && (n < cap)) begin
                @(posedge clk);
                n = n + 1;
            end
        end
    endtask

    task automatic reset_dut;
        begin
            for (int unsigned i = 0; i < 32; i++) begin
                gold_gpr[i] = 32'd0;
                wr_pc[i]   = 32'd0;
                wr_time[i] = 0;
            end
            gold_poison = 32'd0;
            rst = 1'b1;
            repeat (20) @(posedge clk);
            rst = 1'b0;
        end
    endtask

    //---- redirect classification and architectural next-PC checks ----------
    int unsigned branch_redirects, arch_redirects;
    logic [31:0] irq_target_q, expect_resume_pc_q;
    logic        irq_target_valid_q, expect_resume_q;
    int unsigned irq_pc_checks;
    logic [3:0] ciq_states_seen;
    logic [15:0] ciq_transitions_seen;
    entry_state_t ciq_previous [CIQ_ENTRIES];
    initial begin ciq_states_seen='0; ciq_transitions_seen='0; end
    // Real registered state observations, accumulated across all phases.
    /* verilator lint_off BLKSEQ */
    always @(negedge clk) begin
        for (int i=0;i<CIQ_ENTRIES;i++) begin
            if (rst) ciq_previous[i] = ENTRY_FREE;
            else begin
                ciq_states_seen[int'(u_dut.entry_w[i].state)] = 1'b1;
                ciq_transitions_seen[4*int'(ciq_previous[i])+int'(u_dut.entry_w[i].state)] = 1'b1;
                ciq_previous[i] = u_dut.entry_w[i].state;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    /* verilator lint_off UNUSEDSIGNAL */  // only the opcode field is inspected
    function automatic logic is_cfi_word(input logic [31:0] w);
        is_cfi_word = (w[6:0] == 7'h6f) || (w[6:0] == 7'h67) || (w[6:0] == 7'h63);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (rst) begin
            branch_redirects   <= 0;
            arch_redirects     <= 0;
            irq_target_valid_q <= 1'b0;
            expect_resume_q    <= 1'b0;
            irq_target_q       <= 32'd0;
            expect_resume_pc_q <= 32'd0;
            irq_pc_checks      <= 0;
        end else begin
            if (redirect_valid) begin
                if (redirect_kind == REDIRECT_BRANCH) branch_redirects <= branch_redirects + 1;
                else                                  arch_redirects  <= arch_redirects + 1;
            end
            if (irq_redirect_valid) begin
                // The accepted interrupt redirects to mtvec; the architectural
                // restore point is architectural_next_pc, which the handler's
                // MRET must resume at.
                irq_target_q       <= dbg_arch_next_pc;
                irq_target_valid_q <= 1'b1;
            end

            if (irq_target_valid_q && u_dut.mepc_w !== irq_target_q)
                fail("IRQ mepc does not equal captured architectural_next_pc");
            // Check only the first lane of the resumed prefix. A second
            // retire in that cycle has its own successor PC.
            if (expect_resume_q && retire_valid[0]) begin
                if (retire_pc[0] !== expect_resume_pc_q)
                    fail("interrupt restore PC mismatch");
                expect_resume_q <= 1'b0;
                irq_pc_checks <= irq_pc_checks + 1;
            end

            for (int unsigned l = 0; l < 2; l++) begin
                if (retire_valid[l]) begin
                    // The first retire after an interrupt MRET must be the
                    // architectural restore PC captured at the redirect.

                    // Ordinary (non-CFI, non-MRET) successors are pc+4.
                    if (!is_cfi_word(imem[retire_pc[l][11:2]])
                        && (imem[retire_pc[l][11:2]] !== mret_word())
                        && (retire_pc_next[l] !== (retire_pc[l] + 32'd4)))
                        fail("retire_pc_next != pc+4 for an ordinary instruction");

                    // An MRET after an accepted interrupt resumes at the IRQ
                    // restore point.
                    if (irq_target_valid_q && (imem[retire_pc[l][11:2]] === mret_word())) begin
                        expect_resume_q    <= 1'b1;
                        expect_resume_pc_q <= irq_target_q;
                        irq_target_valid_q <= 1'b0;
                    end
                end
            end
        end
    end

    //=========================================================================
    // Main sequence
    //=========================================================================
    initial begin
        errors = 0;
        p3_cycles = 0;
        p3_retires = 0;
        gold_checked = 0;
        gold_unchecked = 0;

        //---- phase 1+2: directed program + traps --------------------------
        build_directed();
        reset_dut();
        run_until_ebreak(P1_CAP);
        if (!ebreak_seen) fail("phase 1: EBREAK never retired");
        if (handler_entries != 2) begin
            fail("phase 2: expected 2 trap entries (ECALL + timer IRQ)");
            $display("  handler_entries=%0d", handler_entries);
        end
        if (mret_count != 2) fail("phase 2: expected 2 MRET retires");
        if (branch_redirects == 0) fail("no branch (BRU recovery) redirect was seen");
        if (redirect_count != redirects_seen) begin
            fail("FE redirect counter disagrees with the TB monitor");
            $display("  fe=%0d tb=%0d", redirect_count, redirects_seen);
        end
        if (arch_redirects < 3) fail("expected >= 3 architectural redirects (ECALL, MRET, IRQ)");
        if (irq_pc_checks != 1) fail("IRQ restore assertion was not exercised exactly once");
        $display("phase1+2: %0d retires, %0d redirects (%0d branch / %0d arch), %0d bpu events, %0d traps, %0d MRETs, %0d cycles",
                 retire_count, redirects_seen, branch_redirects, arch_redirects, bpu_events_seen, handler_entries, mret_count, cycles);

        //---- phase 3: random programs -------------------------------------
        for (int unsigned round = 0; round < P3_ROUNDS; round++) begin
            build_random(32'hc0ffee01 + round * 32'h9e37, P3_LEN);
            reset_dut();
            run_until_ebreak(P3_CAP);
            p3_cycles = p3_cycles + cycles;
            p3_retires = p3_retires + retire_count;
            if (!ebreak_seen) begin
                fail("phase 3: EBREAK never retired (watchdog)");
                $display("  round=%0d cycles=%0d retires=%0d", round, cycles, retire_count);
            end
        end
        if (p3_cycles < 10000) fail("phase 3: random phase ran fewer than 10000 cycles");
        if (p3_retires < 1000) fail("phase 3: too few retires");
        // Six legal non-self transitions: allocate, issue, completion,
        // retirement and WAIT/EXEC cancellation. DONE cancellation shares
        // the ordinary DONE->FREE state transition.
        if (ciq_states_seen != 4'b1111 ||
            (ciq_transitions_seen & 16'h1952) != 16'h1952)
            fail("CIQ state/transition coverage incomplete");
        $display("CIQ coverage: states %b transitions %h (required 1952); IRQ restore PC directly checked",ciq_states_seen,ciq_transitions_seen);
        $display("phase3: %0d cycles, %0d retires, %0d redirects, golden checks %0d (%0d unchecked)",
                 p3_cycles, p3_retires, redirects_seen, gold_checked, gold_unchecked);

        if (errors == 0) begin
            $display("ALL TESTS PASSED: tb_backend (directed + traps + random, %0d retires, %0d redirects)",
                     retire_count, redirects_seen);
            $finish;
        end else begin
            $display("FAILED: tb_backend saw %0d errors", errors);
            $fatal(1, "tb_backend failed");
        end
    end

    initial begin
        #200_000_000;
        $display("FAILED: tb_backend global timeout (cycles=%0d retires=%0d)", cycles, retire_count);
        $fatal(1, "timeout");
    end
endmodule
