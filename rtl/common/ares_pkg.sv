//=============================================================================
// ARES - shared package (core scope)
//-----------------------------------------------------------------------------
// Single source of truth for every cross-module type and parameter of the
// RV32IM core (Frontend / Backend / LSU).  See docs/implementation_plan.md
// section 5.19 (SPEC-I3) - no module may redeclare these types locally.
//
// Spec sources:
//   frontend_backend_contract.md  sections 2.1 / 3 / 4   (IQ / Redirect / BPU)
//   backend.md                    sections 3.1 / 4 / 9 / 10 / 11 / 16 / 17
//   memory.md                     sections 3 / 5 / 6.1
//   frontend.md                   sections 3.2 / 3.4 / 4.3
//
// FREE items exercised here (see docs/implementation_plan.md section 7.7 and
// docs/c0_decisions.md):
//   FREE-01  concrete encoding values of op_t / fu_type_t / entry_state_t /
//            exception_cause_t (all spec-listed values are covered)
//   FREE-02  file organisation (this package merges the planned B01 + F01)
//   FREE-05  MUL_LATENCY initial value (parameterised, change is local)
//
// C0 decision record: docs/c0_decisions.md (D-C0-01 .. D-C0-09).
// Layout rule: NO `ifdef may change a cross-boundary field layout (SPEC-C5).
//=============================================================================
package ares_pkg;

    //-------------------------------------------------------------------------
    // 1. Architecture / pipeline parameters
    //-------------------------------------------------------------------------
    // This package is shared by FE / BE / LSU / SoC and every consumer only
    // uses a subset of the parameters; UNUSEDPARAM is therefore expected.
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned XLEN              = 32;
    localparam int unsigned ADDR_WIDTH        = 32;
    localparam int unsigned INST_WIDTH        = 32;

    localparam int unsigned FETCH_WIDTH       = 4;     // frontend.md section 1
    localparam int unsigned DECODE_WIDTH      = 2;     // contract section 2
    localparam int unsigned DISPATCH_WIDTH    = 2;     // backend.md section 5.1
    localparam int unsigned ISSUE_WIDTH_MAX   = 4;     // backend.md section 8
    localparam int unsigned COMMIT_WIDTH      = 2;     // backend.md section 14.1

    // CIQ (backend.md section 3/4) - valid-only slot lifetime, no generation.
    localparam int unsigned CIQ_ENTRIES       = 16;
    localparam int unsigned CIQ_SLOT_BITS     = 4;

    // GPR (backend.md section 1)
    localparam int unsigned GPR_ADDR_WIDTH    = 5;
    localparam int unsigned GPR_READ_PORTS    = 8;
    localparam int unsigned GPR_WRITE_PORTS   = 2;

    // LSU / memory (memory.md sections 3 / 5 / 6.1)
    localparam int unsigned LQ_ENTRIES        = 4;
    localparam int unsigned SQ_ENTRIES        = 8;
    localparam int unsigned MSHR_ENTRIES      = 2;
    localparam int unsigned WB_ENTRIES        = 2;
    localparam int unsigned MEM_WQ_ENTRIES    = 4;     // Fabric write queue
    localparam int unsigned MEM_BEAT_BYTES    = 16;    // 128-bit memory bus beat

    // DCache geometry (memory.md section 6.1).
    //
    // LINE_BYTES comes from the configuration menu (configs/Kconfig, driven by
    // "make menuconfig"); the fallback is the frozen C0 default so that a bare
    // elaboration without the generated defines still works.  The value only
    // changes internal geometry (LINE_BEATS / ROWS_PER_LINE / MSHR / WB /
    // line-adapter datapaths) - never a cross-boundary field layout, so
    // SPEC-C5 ("no ifdef may change a shared layout") is not affected.
    localparam int unsigned DCACHE_SIZE_BYTES = 8192;
    localparam int unsigned DCACHE_NUM_WAYS   = 2;
`ifdef CONFIG_LINE_BYTES
    localparam int unsigned LINE_BYTES = `CONFIG_LINE_BYTES;
`else
    localparam int unsigned LINE_BYTES = 32;
`endif
    localparam int unsigned LINE_BEATS = LINE_BYTES / MEM_BEAT_BYTES;
    localparam int unsigned ROWS_PER_LINE = LINE_BYTES / 8;
    localparam int unsigned DCACHE_NUM_SETS = DCACHE_SIZE_BYTES / (DCACHE_NUM_WAYS * LINE_BYTES);
    localparam int unsigned DCACHE_INDEX_BITS = $clog2(DCACHE_NUM_SETS);
    localparam int unsigned DCACHE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam int unsigned DCACHE_TAG_BITS = ADDR_WIDTH - DCACHE_INDEX_BITS - DCACHE_OFFSET_BITS;

    // M extension (backend.md section 9.4): fully pipelined MUL, II = 1.
    // Configured through "make menuconfig" (2 or 3 stages); the fallback is
    // the frozen C0 default (3 = extra timing margin for the >200 MHz goal).
    // Neither value changes an external handshake or throughput contract -
    // only the internal pipeline depth.
`ifdef CONFIG_MUL_LATENCY
    localparam int unsigned MUL_LATENCY = `CONFIG_MUL_LATENCY;
`else
    localparam int unsigned MUL_LATENCY = 3;
`endif

    //-------------------------------------------------------------------------
    // Optional CSR switches (SPEC-A13, docs/c0_decisions.md D-C0-13)
    //-------------------------------------------------------------------------
    // Frozen decision: all three optional M-extension CSRs are DISABLED in
    // v1.  They are deliberately NOT menu-configurable - enabling one makes a
    // new CSR address architecturally legal, which is ISA visible and has to
    // go through review, unlike the internal parameters of D-C0-12.
    //
    // When a switch is 0, an access to that CSR address (0x301 / 0x343 /
    // 0xB00 / 0xB80) is an *unsupported CSR access*: decode_err per D-C0-01
    // (simulation reports it; never a silent read-success and never a NOP).
    // v1 has no illegal-instruction trap.  Required CSRs are unaffected.
    localparam bit HAS_MISA    = 1'b0;
    localparam bit HAS_MTVAL   = 1'b0;
    localparam bit HAS_MCYCLE  = 1'b0;

    // Reset PC (contract section 1).  RESET_MTVEC is owned by the SoC top
    // (SPEC-M8) and is therefore NOT frozen here; the core TB supplies it.
    localparam logic [ADDR_WIDTH-1:0] RESET_PC = 32'h8000_0000;
    /* verilator lint_on UNUSEDPARAM */

    //-------------------------------------------------------------------------
    // 2. CIQ tag / entry state (backend.md sections 3.1 / 4)
    //-------------------------------------------------------------------------
    typedef struct packed {
        logic [CIQ_SLOT_BITS-1:0] slot_index;
    } tag_t;

    // backend.md names these FREE/WAIT/EXEC/DONE; the shared package prefixes
    // them to avoid polluting the namespace of every importer.
    typedef enum logic [1:0] {
        ENTRY_FREE = 2'd0,
        ENTRY_WAIT = 2'd1,
        ENTRY_EXEC = 2'd2,
        ENTRY_DONE = 2'd3
    } entry_state_t;

    //-------------------------------------------------------------------------
    // 3. Functional units (backend.md section 9)
    //-------------------------------------------------------------------------
    // 4 bits leave room for the future CV-X-IF port (SPEC-M6) without
    // changing the cross-boundary layout later.
    typedef enum logic [3:0] {
        FU_ALU0 = 4'd0,
        FU_ALU1 = 4'd1,
        FU_BRU  = 4'd2,
        FU_SMUL = 4'd3,
        FU_MUL  = 4'd4,
        FU_DIV  = 4'd5,
        FU_CSR  = 4'd6,
        FU_LSU  = 4'd7
    } fu_type_t;

    //-------------------------------------------------------------------------
    // 4. Operations (FREE-01; covers RV32IM + Zicsr + ECALL/EBREAK/MRET)
    //-------------------------------------------------------------------------
    typedef enum logic [5:0] {
        // U-type
        OP_LUI     = 6'd0,
        OP_AUIPC   = 6'd1,
        // jumps
        OP_JAL     = 6'd2,
        OP_JALR    = 6'd3,
        // conditional branches
        OP_BEQ     = 6'd4,
        OP_BNE     = 6'd5,
        OP_BLT     = 6'd6,
        OP_BGE     = 6'd7,
        OP_BLTU    = 6'd8,
        OP_BGEU    = 6'd9,
        // loads
        OP_LB      = 6'd10,
        OP_LH      = 6'd11,
        OP_LW      = 6'd12,
        OP_LBU     = 6'd13,
        OP_LHU     = 6'd14,
        // stores
        OP_SB      = 6'd15,
        OP_SH      = 6'd16,
        OP_SW      = 6'd17,
        // OP-IMM
        OP_ADDI    = 6'd18,
        OP_SLTI    = 6'd19,
        OP_SLTIU   = 6'd20,
        OP_XORI    = 6'd21,
        OP_ORI     = 6'd22,
        OP_ANDI    = 6'd23,
        OP_SLLI    = 6'd24,
        OP_SRLI    = 6'd25,
        OP_SRAI    = 6'd26,
        // OP
        OP_ADD     = 6'd27,
        OP_SUB     = 6'd28,
        OP_SLL     = 6'd29,
        OP_SLT     = 6'd30,
        OP_SLTU    = 6'd31,
        OP_XOR     = 6'd32,
        OP_SRL     = 6'd33,
        OP_SRA     = 6'd34,
        OP_OR      = 6'd35,
        OP_AND     = 6'd36,
        // M extension
        OP_MUL     = 6'd37,
        OP_MULH    = 6'd38,
        OP_MULHSU  = 6'd39,
        OP_MULHU   = 6'd40,
        OP_DIV     = 6'd41,
        OP_DIVU    = 6'd42,
        OP_REM     = 6'd43,
        OP_REMU    = 6'd44,
        // Zicsr
        OP_CSRRW   = 6'd45,
        OP_CSRRS   = 6'd46,
        OP_CSRRC   = 6'd47,
        OP_CSRRWI  = 6'd48,
        OP_CSRRSI  = 6'd49,
        OP_CSRRCI  = 6'd50,
        // SYSTEM / MISC-MEM
        OP_ECALL   = 6'd51,
        OP_EBREAK  = 6'd52,
        OP_MRET    = 6'd53,
        OP_FENCE   = 6'd54,
        // Decode could not map the encoding (SPEC-A1/M17: simulated error,
        // no architectural trap in v1 - see docs/c0_decisions.md D-C0-01).
        OP_ILLEGAL = 6'd55
    } op_t;

    //-------------------------------------------------------------------------
    // 5. Exception causes (backend.md sections 11 / 16.1 / 17)
    //-------------------------------------------------------------------------
    typedef enum logic [31:0] {
        EXC_NONE          = 32'h0000_0000,
        EXC_ECALL_M       = 32'd11,
        EXC_MACHINE_TIMER = 32'h8000_0007
    } exception_cause_t;

    //-------------------------------------------------------------------------
    // 10. CIQ entry (backend.md section 4)
    //-------------------------------------------------------------------------
    typedef struct packed {
        logic         valid;
        entry_state_t state;

        logic [ADDR_WIDTH-1:0] pc;
        logic [ADDR_WIDTH-1:0] pred_npc;
        fe_pkg::pred_meta_t    pred_meta;
        fe_pkg::cfi_type_t     actual_cfi_type;
        logic [ADDR_WIDTH-1:0] actual_npc;
        logic                  actual_taken;
        logic [ADDR_WIDTH-1:0] actual_target;

        fu_type_t fu_type;
        op_t      op;

        logic [4:0] rd;
        logic       rd_wen;

        logic [4:0] rs1;
        logic       src1_used;
        logic       src1_dep_valid;
        tag_t       src1_dep_tag;

        logic [4:0] rs2;
        logic       src2_used;
        logic       src2_dep_valid;
        tag_t       src2_dep_tag;

        logic [31:0] imm;
        logic [31:0] result;

        logic [11:0] csr_addr;
        logic        csr_write_en;
        logic [31:0] csr_write_data;
        logic        is_serializing;

        logic             exception;
        exception_cause_t exception_cause;
        logic [31:0]      exception_tval;

        logic is_branch;
        logic is_load;
        logic is_store;
        logic is_csr;
        logic is_fence;
    } queue_entry_t;

    //-------------------------------------------------------------------------
    // 11. FU request / completion (backend.md sections 10 / 11)
    //-------------------------------------------------------------------------
    typedef struct packed {
        tag_t tag;
        op_t  op;

        logic [31:0] src1;
        logic [31:0] src2;
        logic [31:0] imm;
        logic [31:0] pc;
        logic [31:0] pred_npc;      // BRU only
        logic [11:0] csr_addr;      // CSR only
        logic        csr_write_en;  // CSR only
    } fu_req_t;

    typedef struct packed {
        tag_t        tag;
        logic [31:0] result;

        logic             exception;
        exception_cause_t cause;
        logic [31:0]      tval;
    } fu_completion_t;

endpackage
