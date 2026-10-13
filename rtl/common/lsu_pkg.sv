//=============================================================================
// ARES - LSU internal package (C2)
//-----------------------------------------------------------------------------
// Small, purely combinational helpers shared by the memory subsystem modules:
// access size encoding, byte-enable masks, store-data alignment and the final
// load merge/select/extension used by the LQ.
//
// Scope note (SPEC-I3): ares_pkg.sv is the single shared package for
// *cross-subsystem* types (FE/BE/LSU/SoC).  The helpers below are LSU internal
// and are therefore kept here; they never appear on an interface that leaves
// the memory subsystem (lsu_top's ports only use ares_pkg types).
//
// This file must be elaborated after ares_pkg.sv - it lives in rtl/common/ so
// the sim/Makefile glob order (ares_pkg first, then common/*, then
// backend/*, memory/*) is preserved.
//
// Spec sources: memory.md sections 3 / 4.2 / 3.1 (byte lanes, extension).
// FREE items: FREE-02 (file organisation), FREE-04 (combinational structure).
//=============================================================================
package lsu_pkg;

    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Naturally aligned access size (misaligned accesses are out of scope for
    // v1: SPEC-A1 / D-C0-01 - the TB reports them, the RTL has no behaviour).
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {
        LSZ_BYTE = 2'd0,
        LSZ_HALF = 2'd1,
        LSZ_WORD = 2'd2
    } lsu_size_t;

    // Number of bytes of the access (1/2/4).
    function automatic logic [2:0] lsu_size_bytes(input lsu_size_t size);
        unique case (size)
            LSZ_BYTE: lsu_size_bytes = 3'd1;
            LSZ_HALF: lsu_size_bytes = 3'd2;
            default:  lsu_size_bytes = 3'd4;
        endcase
    endfunction

    // Byte enables inside the addressed 4-byte word for a naturally aligned
    // access (memory.md 3.1: little endian, natural alignment).
    function automatic logic [3:0] lsu_size_mask(input logic [1:0] addr_low,
                                                 input lsu_size_t size);
        unique case (size)
            LSZ_BYTE: lsu_size_mask = 4'b0001 << addr_low;
            LSZ_HALF: lsu_size_mask = 4'b0011 << addr_low;
            default:  lsu_size_mask = 4'b1111;
        endcase
    endfunction

    // Place the lowest size bytes of the store data into their byte lanes.
    function automatic logic [31:0] lsu_align_store_data(input logic [31:0] data,
                                                         input logic [1:0]  addr_low,
                                                         input lsu_size_t   size);
        unique case (size)
            LSZ_BYTE: lsu_align_store_data = {24'd0, data[7:0]}   << (8 * addr_low);
            LSZ_HALF: lsu_align_store_data = {16'd0, data[15:0]}  << (8 * addr_low);
            default:  lsu_align_store_data = data;
        endcase
    endfunction

    // Merge the cache/refill word with the byte-wise forwarded data
    // (memory.md 4.2: forwarded bytes win) and perform the LB/LH/LW/LBU/LHU
    // select + sign/zero extension.
    function automatic logic [31:0] lsu_merge_extract(input logic [31:0] word,
                                                      input logic [3:0]  fwd_mask,
                                                      input logic [31:0] fwd_data,
                                                      input logic        is_unsigned,
                                                      input logic [1:0]  addr_low,
                                                      input lsu_size_t   size);
        logic [31:0] merged;
        logic [31:0] shifted;
        begin
            for (int unsigned b = 0; b < 4; b++)
                merged[8*b +: 8] = fwd_mask[b] ? fwd_data[8*b +: 8] : word[8*b +: 8];

            shifted = merged >> (8 * addr_low);
            unique case (size)
                LSZ_BYTE: lsu_merge_extract = is_unsigned ? {24'd0, shifted[7:0]}
                                                          : {{24{shifted[7]}}, shifted[7:0]};
                LSZ_HALF: lsu_merge_extract = is_unsigned ? {16'd0, shifted[15:0]}
                                                          : {{16{shifted[15]}}, shifted[15:0]};
                default:  lsu_merge_extract = shifted;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // op_t classification (decode already guarantees the op/CFI agreement).
    //-------------------------------------------------------------------------
    function automatic logic lsu_op_is_load(input op_t op);
        lsu_op_is_load = op inside {OP_LB, OP_LH, OP_LW, OP_LBU, OP_LHU};
    endfunction

    function automatic logic lsu_op_is_store(input op_t op);
        lsu_op_is_store = op inside {OP_SB, OP_SH, OP_SW};
    endfunction

    function automatic lsu_size_t lsu_op_size(input op_t op);
        unique case (op)
            OP_LB, OP_LBU, OP_SB: lsu_op_size = LSZ_BYTE;
            OP_LH, OP_LHU, OP_SH: lsu_op_size = LSZ_HALF;
            default:              lsu_op_size = LSZ_WORD;
        endcase
    endfunction

    function automatic logic lsu_op_is_unsigned(input op_t op);
        lsu_op_is_unsigned = (op == OP_LBU) || (op == OP_LHU);
    endfunction

endpackage
