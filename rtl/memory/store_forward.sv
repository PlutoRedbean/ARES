//=============================================================================
// ARES LSU - byte-wise store forwarding (L05)
//-----------------------------------------------------------------------------
// For one candidate load, compare its byte addresses against the older stores
// selected by the LQ entry's snapshot mask and return, per byte, the data of
// the CLOSEST older store (memory.md 4.2: the later matching store overrides
// the earlier one, per byte selecting the closest older store).
//
// The SQ is an ordered ring; logical age order is head -> tail (tail is the
// youngest).  Walking it from oldest to youngest and letting every match
// overwrite the previous value implements "last write wins" = closest older
// store, without an explicit age comparator.
//
// Additional outputs:
//   dep_ready   every older store of the mask has its address/data registered,
//               which is the condition to confirm the load's forwarding
//               snapshot and to start a lookup (memory.md 4.1).
//
// MMIO stores never forward (memory.md 3.1: the uncached path does not enter
// store forwarding); their address window cannot alias a cacheable load.
//
// Spec sources: memory.md 3.1 / 4.1 / 4.2.
// FREE items: FREE-02 (file organisation), FREE-04 (parallel compare tree).
// Self-check bench: rtl/memory/test/unit/tb_store_forward.sv
//=============================================================================
module store_forward (
    /* verilator lint_off UNUSEDSIGNAL */  // byte lane is selected by load_byte_mask
    input  logic [31:0]        load_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [3:0]         load_byte_mask,   // bytes this load needs
    input  logic [7:0]         older_mask,       // LQ snapshot of older stores
    input  logic [7:0]         sq_occupied,
    input  logic [7:0]         sq_addr_valid,    // address/data registered
    input  logic [7:0][31:0]   sq_addr,
    input  logic [7:0][31:0]   sq_data,          // AGU-aligned store data
    input  logic [7:0][3:0]    sq_byte_mask,
    input  logic [7:0]         sq_is_mmio,
    input  logic [2:0]         sq_head_ptr,
    input  logic [3:0]         sq_occupancy,
    output logic [3:0]         fwd_mask,
    output logic [31:0]        fwd_data,
    output logic               dep_ready
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // A store is a forwarding candidate when it is in the load's older set,
    // still occupied, cacheable and has its address/data registered.
    //-------------------------------------------------------------------------
    logic [7:0] eligible;

    always_comb begin
        for (int unsigned i = 0; i < 8; i++)
            eligible[i] = older_mask[i] && sq_occupied[i] && !sq_is_mmio[i]
                       && sq_addr_valid[i];
    end

    //-------------------------------------------------------------------------
    // Per-byte select: oldest -> youngest with last-match-wins.
    //
    // Naturally aligned accesses never split a byte across words, so comparing
    // the word address (addr[31:2]) plus the store's byte enable is the exact
    // byte-coverage test.
    //-------------------------------------------------------------------------
    always_comb begin
        for (int unsigned b = 0; b < 4; b++) begin
            fwd_mask[b]        = 1'b0;
            fwd_data[8*b +: 8] = 8'd0;
            for (int unsigned k = 0; k < 8; k++) begin
                logic [2:0] idx;
                idx = (sq_head_ptr + 3'(k)) & 3'd7;
                if ((k < {2'b0, sq_occupancy})
                    && load_byte_mask[b]          // never report bytes the load does not need
                    && eligible[idx]
                    && sq_byte_mask[idx][b]
                    && (sq_addr[idx][31:2] == load_addr[31:2])) begin
                    fwd_mask[b]        = 1'b1;
                    fwd_data[8*b +: 8] = sq_data[idx][8*b +: 8];
                end
            end
        end
    end

    // Only the bytes the load actually needs may be reported as forwarded.
    assign dep_ready = (((~older_mask) | sq_addr_valid) == 8'hFF);

`ifdef CONFIG_SIMULATION
    // Purely combinational module: immediate assertion, no clock.
    always_comb begin
        a_only_requested_bytes: assert ((fwd_mask & ~load_byte_mask) == 4'd0);
    end
`endif

endmodule
