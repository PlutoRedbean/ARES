//=============================================================================
// ARES - Backend: M-mode CSR file, B16
//-----------------------------------------------------------------------------
// Purpose
//   Architectural storage and field masking for the v1 M-mode CSR subset
//   (Zicsr / ECALL / MRET / machine timer, software and external interrupts).
//   Reads are purely combinational
//   (`raddr` -> `rdata`/`raddr_ok`); all state is updated only through this
//   file's write ports, so the CSR Unit can read the old value in its
//   completion cycle while the architectural write happens later, on the
//   exclusive commit edge (backend.md section 16.2).
//
// Spec sources (authoritative)
//   backend.md section 16.1 - required CSR set + field semantics + reset values:
//       mstatus 0x300: MIE[3]/MPIE[7] R/W, MPP[12:11] fixed 2'b11, others 0
//       mie     0x304: MSIE[3]/MTIE[7]/MEIE[11] R/W, other bits read 0
//       mtvec   0x305: R/W, Direct only, MODE[1:0] forced 00, BASE[31:2]
//       mscratch 0x340: full 32-bit R/W
//       mepc    0x341: full 32-bit R/W, [1:0] forced 00 (RV32IM has no C)
//       mcause  0x342: full 32-bit R/W
//       mip     0x344: MSIP[3]/MTIP[7]/MEIP[11] mirror the SoC level inputs,
//                      software writes completely ignored, other bits 0
//       mhartid 0xF14: read-only HART_ID parameter (0 by default, 1 for hart1)
//       optional misa 0x301 / mtval 0x343 / mcycle 0xB00 + mcycleh 0xB80 are
//       compiled in only when ares_pkg::HAS_MISA / ares_pkg::HAS_MTVAL / ares_pkg::HAS_MCYCLE = 1.
//       All three are 0 in v1 (D-C0-13), so those four addresses are decoded
//       as NOT implemented (raddr_ok = 0) and their storage does not exist.
//   backend.md section 16.2 - the CSR Unit reads the old value and the commit
//       stage performs the write; this file therefore has a single write port
//       group (we/waddr/wdata) plus the trap-mret architectural updates.
//   backend.md section 16.3 - serializing CSR/MRET commit is exclusive.
//   backend.md section 17.1 - ECALL trap writes mepc/mcause and
//       MPIE<-MIE, MIE<-0, MPP<-M; MRET does MIE<-MPIE, MPIE<-1, MPP<-M.
//   plan section 5.15 - the same contract table.
//
// Update priority inside one clock cycle (documented contract, strictly
// resolved by the if/else-if chain below; a trap is a serializing commit event
// and can never legally coincide with a normal CSR commit, the priority only
// makes the outcome deterministic):
//   1. trap_we : mepc <- trap_mepc, mcause <- trap_mcause,
//                MPIE <- MIE, MIE <- 0, MPP <- M (MPP is fixed 2'b11)
//   2. mret_we : MIE <- MPIE, MPIE <- 1, MPP <- M
//   3. we      : normal commit write with the per-CSR field masks
//   timer_irq/software_irq/external_irq are level inputs of the same clock
//   domain; they are not registered here - mip.MSIP/MTIP/MEIP always equal the
//   corresponding inputs, and mip has no write path.
//
// FREE items exercised: FREE-02 (file layout), FREE-04 (read mux structure),
// FREE-10 (verification environment), FREE-12 (optional debug/extension CSRs
// behind a compile-time switch, never in a mandated path).
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */  // trap_mepc[1:0] is discarded on purpose (mepc is WARL-aligned)
module csr_file #(
    parameter logic [31:0] RESET_MTVEC = 32'h8000_0000,
    parameter logic [31:0] HART_ID      = 32'd0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        timer_irq,
    input  logic        software_irq,
    input  logic        external_irq,

    input  logic [11:0] raddr,
    output logic [31:0] rdata,
    output logic        raddr_ok,

    input  logic        we,
    input  logic [11:0] waddr,
    input  logic [31:0] wdata,

    input  logic        trap_we,
    input  logic [31:0] trap_mepc,
    input  logic [31:0] trap_mcause,
    input  logic        mret_we,

    output logic        mstatus_mie,
    output logic        mie_msie,
    output logic        mie_mtie,
    output logic        mie_meie,
    output logic        mip_msip,
    output logic        mip_mtip,
    output logic        mip_meip,
    output logic [31:0] mtvec,
    output logic [31:0] mepc
);
/* verilator lint_on UNUSEDSIGNAL */
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // CSR addresses (backend.md section 16.1)
    //-------------------------------------------------------------------------
    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MISA     = 12'h301;
    localparam logic [11:0] CSR_MIE      = 12'h304;
    localparam logic [11:0] CSR_MTVEC    = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;
    localparam logic [11:0] CSR_MCAUSE   = 12'h342;
    localparam logic [11:0] CSR_MTVAL    = 12'h343;
    localparam logic [11:0] CSR_MIP      = 12'h344;
    localparam logic [11:0] CSR_MCYCLE   = 12'hB00;
    localparam logic [11:0] CSR_MCYCLEH  = 12'hB80;
    localparam logic [11:0] CSR_MHARTID  = 12'hF14;

    //-------------------------------------------------------------------------
    // Architectural state.  MPP is not stored: it is hard-wired to 2'b11.
    //-------------------------------------------------------------------------
    logic        mstatus_mie_q;
    logic        mstatus_mpie_q;
    logic        mie_msie_q;
    logic        mie_mtie_q;
    logic        mie_meie_q;
    logic [31:0] mtvec_q;
    logic [31:0] mscratch_q;
    logic [31:0] mepc_q;
    logic [31:0] mcause_q;

    //-------------------------------------------------------------------------
    // Optional CSRs: storage only exists when the frozen switch is 1
    // (D-C0-13).  With all switches 0 the read mux below decodes 0x301/0x343/
    // 0xB00/0xB80 as unimplemented (raddr_ok = 0).
    //-------------------------------------------------------------------------
    logic [31:0] opt_misa_rdata;
    logic [31:0] opt_mtval_rdata;
    logic [31:0] opt_mcycle_lo_rdata;
    logic [31:0] opt_mcycle_hi_rdata;

    generate
        if (HAS_MISA) begin : g_misa
            // Fixed WARL identity: RV32 I/M.  Writes are ignored, no storage.
            assign opt_misa_rdata = 32'h4000_1100;
        end else begin : g_no_misa
            assign opt_misa_rdata = 32'h0;
        end

        if (HAS_MTVAL) begin : g_mtval
            logic [31:0] mtval_q;
            always_ff @(posedge clk) begin
                if (rst) begin
                    mtval_q <= 32'h0;
                end else if (trap_we) begin
                    mtval_q <= 32'h0;
                end else if (we && (waddr == CSR_MTVAL)) begin
                    mtval_q <= wdata;
                end
            end
            assign opt_mtval_rdata = mtval_q;
        end else begin : g_no_mtval
            assign opt_mtval_rdata = 32'h0;
        end

        if (HAS_MCYCLE) begin : g_mcycle
            // One 64-bit counter; a write to either half overrides that half's
            // increment for the cycle.
            logic [63:0] mcycle_q;
            always_ff @(posedge clk) begin
                if (rst) begin
                    mcycle_q <= 64'h0;
                end else begin
                    if (we && (waddr == CSR_MCYCLE)) begin
                        mcycle_q[31:0] <= wdata;
                    end else begin
                        mcycle_q[31:0] <= mcycle_q[31:0] + 32'd1;
                    end
                    if (we && (waddr == CSR_MCYCLEH)) begin
                        mcycle_q[63:32] <= wdata;
                    end else if (&mcycle_q[31:0]) begin
                        mcycle_q[63:32] <= mcycle_q[63:32] + 32'd1;
                    end
                end
            end
            assign opt_mcycle_lo_rdata = mcycle_q[31:0];
            assign opt_mcycle_hi_rdata = mcycle_q[63:32];
        end else begin : g_no_mcycle
            assign opt_mcycle_lo_rdata = 32'h0;
            assign opt_mcycle_hi_rdata = 32'h0;
        end
    endgenerate

    //-------------------------------------------------------------------------
    // State update: trap > mret > normal commit write (see the header).
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            mie_msie_q     <= 1'b0;
            mie_mtie_q     <= 1'b0;
            mie_meie_q     <= 1'b0;
            mtvec_q        <= {RESET_MTVEC[31:2], 2'b00};
            mscratch_q     <= 32'h0;
            mepc_q         <= 32'h0;
            mcause_q       <= 32'h0;
        end else if (trap_we) begin
            // ECALL / machine-timer interrupt entry (backend.md section 17).
            // MPP stays fixed at M; mepc[1:0] is forced 00 by the WARL rule.
            mstatus_mpie_q <= mstatus_mie_q;
            mstatus_mie_q  <= 1'b0;
            mepc_q         <= {trap_mepc[31:2], 2'b00};
            mcause_q       <= trap_mcause;
        end else if (mret_we) begin
            // MRET (backend.md section 17.1).
            mstatus_mie_q  <= mstatus_mpie_q;
            mstatus_mpie_q <= 1'b1;
        end else if (we) begin
            case (waddr)
                CSR_MSTATUS: begin
                    mstatus_mie_q  <= wdata[3];
                    mstatus_mpie_q <= wdata[7];
                end
                CSR_MIE: begin
                    mie_msie_q <= wdata[3];
                    mie_mtie_q <= wdata[7];
                    mie_meie_q <= wdata[11];
                end
                CSR_MTVEC: begin
                    mtvec_q <= {wdata[31:2], 2'b00};
                end
                CSR_MSCRATCH: begin
                    mscratch_q <= wdata;
                end
                CSR_MEPC: begin
                    mepc_q <= {wdata[31:2], 2'b00};
                end
                CSR_MCAUSE: begin
                    mcause_q <= wdata;
                end
                // mip / mhartid / unimplemented addresses: no storage changes.
                default: begin
                end
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Read path (combinational).  All unimplemented addresses answer
    // raddr_ok = 0 with rdata = 0, so an unsupported CSR access is visible to
    // the decoder (D-C0-01) instead of silently succeeding.
    //-------------------------------------------------------------------------
    always_comb begin
        rdata    = 32'h0;
        raddr_ok = 1'b1;
        case (raddr)
            CSR_MSTATUS: begin
                // [12:11]=MPP (fixed M), [7]=MPIE, [3]=MIE, everything else 0
                rdata = {19'h0, 2'b11, 3'h0, mstatus_mpie_q, 3'h0, mstatus_mie_q, 3'h0};
            end
            CSR_MIE: begin
                rdata       = 32'h0;
                rdata[3]    = mie_msie_q;
                rdata[7]    = mie_mtie_q;
                rdata[11]   = mie_meie_q;
            end
            CSR_MTVEC: begin
                rdata = mtvec_q;
            end
            CSR_MSCRATCH: begin
                rdata = mscratch_q;
            end
            CSR_MEPC: begin
                rdata = {mepc_q[31:2], 2'b00};
            end
            CSR_MCAUSE: begin
                rdata = mcause_q;
            end
            CSR_MIP: begin
                rdata       = 32'h0;
                rdata[3]    = software_irq;
                rdata[7]    = timer_irq;
                rdata[11]   = external_irq;
            end
            CSR_MHARTID: begin
                rdata = HART_ID;
            end
            CSR_MISA: begin
                rdata    = opt_misa_rdata;
                raddr_ok = HAS_MISA;
            end
            CSR_MTVAL: begin
                rdata    = opt_mtval_rdata;
                raddr_ok = HAS_MTVAL;
            end
            CSR_MCYCLE: begin
                rdata    = opt_mcycle_lo_rdata;
                raddr_ok = HAS_MCYCLE;
            end
            CSR_MCYCLEH: begin
                rdata    = opt_mcycle_hi_rdata;
                raddr_ok = HAS_MCYCLE;
            end
            default: begin
                rdata    = 32'h0;
                raddr_ok = 1'b0;
            end
        endcase
    end

    //-------------------------------------------------------------------------
    // Continuously visible fields
    //-------------------------------------------------------------------------
    assign mstatus_mie = mstatus_mie_q;
    assign mie_msie    = mie_msie_q;
    assign mie_mtie    = mie_mtie_q;
    assign mie_meie    = mie_meie_q;
    assign mip_msip    = software_irq;
    assign mip_mtip    = timer_irq;
    assign mip_meip    = external_irq;
    assign mtvec       = mtvec_q;
    assign mepc        = mepc_q;

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Field/implementation assertions (backend.md section 16.1)
    //-------------------------------------------------------------------------
    a_mtvec_direct: assert property (@(posedge clk) disable iff (rst)
        mtvec_q[1:0] == 2'b00);

    a_mepc_aligned: assert property (@(posedge clk) disable iff (rst)
        mepc_q[1:0] == 2'b00);

    a_rdata_stable: assert property (@(posedge clk) disable iff (rst)
        (raddr == CSR_MSTATUS)
        |-> (rdata == {19'h0, 2'b11, 3'h0, mstatus_mpie_q, 3'h0, mstatus_mie_q, 3'h0}));

    a_mie_read: assert property (@(posedge clk) disable iff (rst)
        (raddr == CSR_MIE) |-> (rdata[3] == mie_msie_q)
                           && (rdata[7] == mie_mtie_q)
                           && (rdata[11] == mie_meie_q)
                           && (rdata[31:12] == 20'h0)
                           && (rdata[6:4] == 3'h0)
                           && (rdata[10:8] == 3'h0)
                           && (rdata[2:0] == 3'h0));

    a_mip_read: assert property (@(posedge clk) disable iff (rst)
        (raddr == CSR_MIP) |-> (rdata[3] == software_irq)
                           && (rdata[7] == timer_irq)
                           && (rdata[11] == external_irq)
                           && (rdata[31:12] == 20'h0)
                           && (rdata[6:4] == 3'h0)
                           && (rdata[10:8] == 3'h0)
                           && (rdata[2:0] == 3'h0));

    a_mhartid_read: assert property (@(posedge clk) disable iff (rst)
        (raddr == CSR_MHARTID) |-> (raddr_ok && (rdata == HART_ID)));

    a_ok_only_implemented: assert property (@(posedge clk) disable iff (rst)
        raddr_ok |-> (raddr == CSR_MSTATUS) || (raddr == CSR_MIE)
                  || (raddr == CSR_MTVEC) || (raddr == CSR_MSCRATCH)
                  || (raddr == CSR_MEPC) || (raddr == CSR_MCAUSE)
                  || (raddr == CSR_MIP) || (raddr == CSR_MHARTID)
                  || (HAS_MISA   && (raddr == CSR_MISA))
                  || (HAS_MTVAL  && (raddr == CSR_MTVAL))
                  || (HAS_MCYCLE && ((raddr == CSR_MCYCLE) || (raddr == CSR_MCYCLEH))));

    a_opt_disabled: assert property (@(posedge clk) disable iff (rst)
        (!HAS_MISA   && (raddr == CSR_MISA))
        || (!HAS_MTVAL  && (raddr == CSR_MTVAL))
        || (!HAS_MCYCLE && ((raddr == CSR_MCYCLE) || (raddr == CSR_MCYCLEH)))
        |-> !raddr_ok);
`endif

endmodule
