//=============================================================================
// ARES LSU - Input Register + pipelined AGU (L02)
//-----------------------------------------------------------------------------
// Address generation for one accepted Load/Store request (memory.md 3 / 3.1,
// interface frozen in rtl/memory/LSU_INTERFACES.md section 1).
//
// Pipeline (no ready / no backpressure: the scheduler has already reserved the
// LQ or SQ entry when issue_valid is asserted - guaranteed-accept):
//
//   C0  issue_valid / issue_req / issue_qidx accepted at the end of the cycle.
//       issue_kill is "kill_mask[tag]" of the SAME issue (LSU_INTERFACES.md
//       section 1 / memory.md 8): a killed operation leaves no trace here and
//       must not produce an output.
//   C1  input register + combinational address/attribute generation.
//   C2  AGU result registered at the end of C1; out_valid is high for the
//       whole C2 cycle (the "C1 computes/registers the address" step of the
//       3-cycle load path in memory.md 6.2).
//
// Datapath (single adder + parallel function lookups, FREE-04: no priority
// chain, no mux tree on the critical path):
//
//   out_addr        = issue_req.src1 + issue_req.imm   (32-bit wraparound)
//   out_size        = lsu_pkg::lsu_op_size(op)
//   out_byte_mask   = lsu_pkg::lsu_size_mask(addr[1:0], size)
//   out_store_data  = lsu_pkg::lsu_align_store_data(src2, addr[1:0], size)
//   out_is_unsigned = lsu_pkg::lsu_op_is_unsigned(op)
//   out_is_load/st  = lsu_pkg::lsu_op_is_load/store(op)
//   out_is_mmio     = ((addr & MMIO_MASK) == (MMIO_BASE & MMIO_MASK))
//
// The LQ/SQ reservation index (issue_qidx) and the CIQ tag travel with the
// request through both stages unchanged.
//
// Misaligned accesses are out of scope for v1 (SPEC-A1 / D-C0-01): the RTL
// defines no architectural behaviour for them (no split, no rounding), the
// CONFIG_SIMULATION assertion below reports them instead.
//
// Spec sources: memory.md 3 / 3.1 / 6.2; LSU_INTERFACES.md section 1.
// FREE items: FREE-02 (file organisation), FREE-04 (combinational structure).
// Self-check bench: rtl/memory/test/unit/tb_lsu_agu.sv
//
// Lint / build / run (Verilator 5.x, from the repository root; -o is relative
// to --Mdir, so the binary lands exactly at sim/build/unit/tb_lsu_agu/tb_lsu_agu):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//       -DCONFIG_SIMULATION --top-module lsu_agu \
//       rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/lsu_agu.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//       -Wno-TIMESCALEMOD -DCONFIG_SIMULATION --top-module tb_lsu_agu \
//       --Mdir sim/build/unit/tb_lsu_agu -o tb_lsu_agu \
//       rtl/common/ares_pkg.sv rtl/common/lsu_pkg.sv rtl/memory/lsu_agu.sv \
//       rtl/memory/test/unit/tb_lsu_agu.sv
//   $ sim/build/unit/tb_lsu_agu/tb_lsu_agu
//=============================================================================
module lsu_agu #(
    parameter logic [31:0] MMIO_BASE = 32'hA000_0000,  // SPEC-M7 placeholder: physical map
    parameter bit JYD_UNCACHED_WINDOWS = 1'b0, // approved JYD profile: docs/jyd_soc_integration.md
    parameter logic [31:0] MMIO_MASK = 32'hFF00_0000   // is_mmio = ((addr & MASK)==(BASE & MASK))
) (
    input  logic                       clk,
    input  logic                       rst,

    //---- issue port (reservation index travels with the request) ------------
    input  logic                       issue_valid,
    /* verilator lint_off UNUSEDSIGNAL */  // pc/pred_npc/csr_* belong to the scheduler
    input  ares_pkg::fu_req_t          issue_req,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [2:0]                 issue_qidx,      // reserved LQ(2b)/SQ(3b) slot
    input  logic                       issue_kill,      // kill_mask[tag] of this issue

    //---- AGU result (registered, valid in C2) -------------------------------
    output logic                       out_valid,
    output ares_pkg::tag_t             out_tag,
    output logic [2:0]                 out_qidx,
    output logic                       out_is_load,
    output logic                       out_is_store,
    output logic [31:0]                out_addr,
    output lsu_pkg::lsu_size_t         out_size,
    output logic [3:0]                 out_byte_mask,   // lsu_size_mask(addr[1:0], size)
    output logic [31:0]                out_store_data,  // lsu_align_store_data(src2, addr[1:0], size)
    output logic                       out_is_unsigned,
    output logic                       out_is_mmio
);
    import ares_pkg::*;
    import lsu_pkg::*;

    function automatic logic is_device_addr(input logic [31:0] addr);
        return ((addr & MMIO_MASK) == (MMIO_BASE & MMIO_MASK)) ||
            (JYD_UNCACHED_WINDOWS &&
             ((addr[31:18] == 14'b1000_0000_0011_00) ||
              ((addr[31:26] == 6'b1000_00) && (addr[25:22] != 4'd0))));
    endfunction

    //-------------------------------------------------------------------------
    // C1 input register
    //
    // The payload is captured unconditionally (no clock-enable mux); only the
    // valid bit is qualified, by the same-cycle kill.  A killed or idle issue
    // therefore never reaches the output stage.
    //-------------------------------------------------------------------------
    logic        c1_valid;
    tag_t        c1_tag;
    op_t         c1_op;
    logic [31:0] c1_src1;      // only the fields the AGU consumes are registered
    logic [31:0] c1_src2;      // (pc / pred_npc / csr_* stay in the scheduler)
    logic [31:0] c1_imm;
    logic [2:0]  c1_qidx;

    always_ff @(posedge clk) begin
        if (rst) begin
            c1_valid <= 1'b0;
            c1_tag   <= '0;
            c1_op    <= OP_ILLEGAL;
            c1_src1  <= 32'd0;
            c1_src2  <= 32'd0;
            c1_imm   <= 32'd0;
            c1_qidx  <= 3'd0;
        end else begin
            c1_valid <= issue_valid && !issue_kill;
            c1_tag   <= issue_req.tag;
            c1_op    <= issue_req.op;
            c1_src1  <= issue_req.src1;
            c1_src2  <= issue_req.src2;
            c1_imm   <= issue_req.imm;
            c1_qidx  <= issue_qidx;
        end
    end

    //-------------------------------------------------------------------------
    // C1 combinational AGU: one adder plus parallel attribute lookups.
    //-------------------------------------------------------------------------
    logic [31:0] c1_addr;
    lsu_size_t   c1_size;
    logic [3:0]  c1_byte_mask;
    logic [31:0] c1_store_data;
    logic        c1_is_load;
    logic        c1_is_store;
    logic        c1_is_unsigned;
    logic        c1_is_mmio;

    always_comb begin
        c1_addr        = c1_src1 + c1_imm;                            // wraps mod 2^32
        c1_size        = lsu_op_size(c1_op);
        c1_byte_mask   = lsu_size_mask(c1_addr[1:0], c1_size);
        c1_store_data  = lsu_align_store_data(c1_src2, c1_addr[1:0], c1_size);
        c1_is_load     = lsu_op_is_load(c1_op);
        c1_is_store    = lsu_op_is_store(c1_op);
        c1_is_unsigned = lsu_op_is_unsigned(c1_op);
        c1_is_mmio     = is_device_addr(c1_addr);
    end

    //-------------------------------------------------------------------------
    // C2 output register (out_valid high for the whole cycle)
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid       <= 1'b0;
            out_tag         <= '0;
            out_qidx        <= 3'd0;
            out_is_load     <= 1'b0;
            out_is_store    <= 1'b0;
            out_addr        <= 32'd0;
            out_size        <= LSZ_BYTE;
            out_byte_mask   <= 4'd0;
            out_store_data  <= 32'd0;
            out_is_unsigned <= 1'b0;
            out_is_mmio     <= 1'b0;
        end else begin
            out_valid       <= c1_valid;
            out_tag         <= c1_tag;
            out_qidx        <= c1_qidx;
            out_is_load     <= c1_is_load;
            out_is_store    <= c1_is_store;
            out_addr        <= c1_addr;
            out_size        <= c1_size;
            out_byte_mask   <= c1_byte_mask;
            out_store_data  <= c1_store_data;
            out_is_unsigned <= c1_is_unsigned;
            out_is_mmio     <= c1_is_mmio;
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol assertions
    //-------------------------------------------------------------------------
    // SPEC-A1 / D-C0-01: v1 supports naturally aligned accesses only.  The RTL
    // has no architectural behaviour for a misaligned one (it neither splits
    // nor rounds it), so simulation reports it here.
    a_natural_align: assert property (@(posedge clk) disable iff (rst)
        out_valid |-> ((out_size == LSZ_BYTE)
                    || ((out_size == LSZ_HALF) && (out_addr[0]   == 1'b0))
                    || ((out_size == LSZ_WORD) && (out_addr[1:0] == 2'b00))));

    // The registered window classification belongs to the registered address
    // (catches a field-registration / pipeline-depth mistake).
    a_mmio_window: assert property (@(posedge clk) disable iff (rst)
        out_valid |-> (out_is_mmio == is_device_addr(out_addr)));
`endif

endmodule
