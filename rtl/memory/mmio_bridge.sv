//=============================================================================
// ARES LSU - single outstanding MMIO device bridge (L11)
//-----------------------------------------------------------------------------
// Responsibility: the uncached-MMIO ordering point of the LSU (memory.md 3.1).
// One device channel is shared by the LQ (uncached Load) and by the oldest
// COMMITTED SQ entry (uncached Store):
//
//   * At most ONE device transaction is outstanding at any time.  While the
//     channel is idle the LQ request (the older operation) wins over the SQ
//     request, so a device access can never overtake an older one.
//   * A request is presented only while idle.  busy is set on the request
//     handshake (mmio_req_valid && mmio_req_ready) and cleared on the response
//     handshake (mmio_rsp_valid && busy).
//   * The accepted owner is REGISTERED.  A response is routed by that owner,
//     never by the requests present when it arrives:
//       owner == load  -> lq_rsp_valid  (LQ may complete the load)
//       owner == store -> sq_req_ack    (Write Ack = device side effect done;
//                                        SQ drain_takeover releases the entry)
//   * lq_req_ready / sq_req_ready are single-cycle "device accepted it" pulses
//     (SQ drain_start).  An un-accepted client keeps its fields stable.
//   * Reads are word aligned and carry wstrb = 4'h0; stores pass the SQ
//     data/strb through unchanged (memory.md 3.1: byte lanes, little endian).
//     Address bits [1:0] are forced to 00 so a small access can never look
//     like a partial-word device access.
//   * mmio_rsp_ready is tied high (interface section 12.4): every accepted
//     request is answered exactly once by the device; there is no response
//     backpressure and no device error/trap path in v1.
//
// Spec sources : docs/microarch/memory.md 3.1 (uncached MMIO: single
//                outstanding transaction, strict device order, Write Ack =
//                side effect complete, load completion only after the
//                response), 6.8 (same cycle priority/invariants);
//                rtl/memory/LSU_INTERFACES.md section 12 (frozen interface)
//                and section 7 (the M2a staging logic in lsu_top that this
//                module extracts verbatim), section 8 (verification rules).
// FREE items   : FREE-02 (file organisation - the M2a staging logic becomes
//                this module), FREE-04 (combinational structure: two parallel
//                grants + one owner-select mux, no priority chain), FREE-11
//                (no pipeline register is added - the port level latency and
//                handshake behaviour of the staging logic are preserved).
//
// Build / lint (repository root, explicit file list - one line per command):
// cmd: verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module mmio_bridge rtl/common/ares_pkg.sv rtl/memory/mmio_bridge.sv
//
// Self-check bench (rtl/memory/test/unit/tb_mmio_bridge.sv):
// cmd: verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module tb_mmio_bridge --Mdir sim/build/unit/tb_mmio_bridge -o tb_mmio_bridge rtl/common/ares_pkg.sv rtl/memory/mmio_bridge.sv rtl/memory/test/unit/tb_mmio_bridge.sv
//   sim/build/unit/tb_mmio_bridge/tb_mmio_bridge   (-o must be a file NAME: the generated make runs inside --Mdir)
//=============================================================================
module mmio_bridge (
    input  logic                    clk,
    input  logic                    rst,

    //---- LQ: uncached load (older operation, wins the arbitration) --------
    input  logic                    lq_req_valid,
    output logic                    lq_req_ready,      // device accepted it (1 cycle)
    input  logic [31:0]             lq_req_addr,       // word aligned (LQ produces)
    output logic                    lq_rsp_valid,      // 1 cycle, routed to the LQ
    input  logic [31:0]             lq_rsp_data,       // LQ-visible payload (device bus)

    //---- SQ: oldest COMMITTED uncached store ------------------------------
    input  logic                    sq_req_valid,
    output logic                    sq_req_ready,      // write accepted -> drain_start
    output logic                    sq_req_ack,        // Write Ack -> drain_takeover
    input  logic [31:0]             sq_req_addr,
    input  logic [31:0]             sq_req_data,
    input  logic [3:0]              sq_req_strb,

    //---- device channel (memory.md 3.1) -----------------------------------
    output logic                    mmio_req_valid,
    input  logic                    mmio_req_ready,
    output logic                    mmio_write,
    output logic [31:0]             mmio_addr,
    output logic [31:0]             mmio_wdata,
    output logic [3:0]              mmio_wstrb,
    input  logic                    mmio_rsp_valid,
    output logic                    mmio_rsp_ready,
    input  logic [31:0]             mmio_rsp_data,

    output logic                    busy               // outstanding (registered)
);

    //-------------------------------------------------------------------------
    // Owner state {busy, owner_store} (memory.md 3.1): IDLE while !busy; one
    // outstanding LOAD (owner_store = 0) or STORE (owner_store = 1) otherwise.
    // The owner is registered so that the response routing is a function of
    // the ACCEPTED request only.
    //-------------------------------------------------------------------------
    logic busy_r;
    logic owner_store_r;

    assign busy = busy_r;

    //-------------------------------------------------------------------------
    // Idle-cycle arbitration: the LQ (older) wins over the SQ.  Two parallel
    // grants, at most one of them high (FREE-04: no nested priority chain).
    //-------------------------------------------------------------------------
    logic lq_gnt;
    logic sq_gnt;

    assign lq_gnt = lq_req_valid && !busy_r;
    assign sq_gnt = sq_req_valid && !busy_r && !lq_req_valid;

    wire mmio_fire = (lq_gnt || sq_gnt) && mmio_req_ready;

    //---- single-cycle "accepted" pulses to the two clients ----------------
    assign lq_req_ready = lq_gnt && mmio_req_ready;
    assign sq_req_ready = sq_gnt && mmio_req_ready;

    //-------------------------------------------------------------------------
    // Device request: owner-selected payload.  Reads are word aligned with no
    // byte enables; stores pass the SQ payload through unchanged.
    //-------------------------------------------------------------------------
    assign mmio_req_valid = lq_gnt || sq_gnt;
    assign mmio_write     = sq_gnt;
    // Word aligned device address (interface section 12.3): bits [1:0] are
    // forced to 00 - a small access is handled inside the addressed word (LQ
    // extension / SQ byte lanes).  The mask is equivalent to
    // {addr[31:2], 2'b00} and keeps every address bit observable.
    wire [31:0] mmio_word_addr = (sq_gnt ? sq_req_addr : lq_req_addr) & 32'hFFFF_FFFC;
    assign mmio_addr      = mmio_word_addr;
    assign mmio_wstrb     = sq_gnt ? sq_req_strb : 4'h0;
    // Don't care for reads (wstrb = 4'h0); kept as a straight pass-through so
    // the extracted M2a datapath keeps its exact combinational behaviour.
    assign mmio_wdata     = sq_req_data;

    //-------------------------------------------------------------------------
    // Device response: routed by the REGISTERED owner, never back-pressured
    // (interface section 12.4 / 12.5).  The two routes are mutually exclusive
    // because owner_store_r is a single bit.
    //-------------------------------------------------------------------------
    assign mmio_rsp_ready = 1'b1;
    assign lq_rsp_valid   = mmio_rsp_valid && busy_r && !owner_store_r;
    assign sq_req_ack     = mmio_rsp_valid && busy_r &&  owner_store_r;

    //-------------------------------------------------------------------------
    // Busy register: set on the request handshake, cleared on the response
    // handshake (memory.md 3.1).  A request is only accepted while idle, so
    // the two events can never coincide.
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            busy_r        <= 1'b0;
            owner_store_r <= 1'b0;
        end else if (mmio_fire) begin
            busy_r        <= 1'b1;
            owner_store_r <= sq_gnt;
        end else if (mmio_rsp_valid && busy_r) begin
            busy_r        <= 1'b0;
        end
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Protocol assertions (interface section 12 point 6, section 8)
    //-------------------------------------------------------------------------
    // A response always belongs to an outstanding transaction.
    a_rsp_requires_busy: assert property (@(posedge clk) disable iff (rst)
        mmio_rsp_valid |-> busy_r);
    // Only one device request is presented, and only while idle.
    a_req_only_when_idle: assert property (@(posedge clk) disable iff (rst)
        mmio_req_valid |-> !busy_r);
    // The device address is word aligned for loads and stores.
    a_addr_word_aligned: assert property (@(posedge clk) disable iff (rst)
        mmio_req_valid |-> (mmio_addr[1:0] == 2'b00));
    // No client request is accepted while a transaction is outstanding.
    a_busy_blocks_accept: assert property (@(posedge clk) disable iff (rst)
        busy_r |-> (!lq_req_ready && !sq_req_ready));
    // Load response and Write Ack are mutually exclusive.
    a_rsp_owner_exclusive: assert property (@(posedge clk) disable iff (rst)
        !(lq_rsp_valid && sq_req_ack));
    // An accept pulse always coincides with a device request handshake.
    a_accept_implies_fire: assert property (@(posedge clk) disable iff (rst)
        (lq_req_ready || sq_req_ready) |-> (mmio_req_valid && mmio_req_ready));
    a_grant_exclusive: assert property (@(posedge clk) disable iff (rst)
        !(lq_req_ready && sq_req_ready));
    // Response routing follows the registered owner, not the live requests.
    a_lq_rsp_is_load: assert property (@(posedge clk) disable iff (rst)
        lq_rsp_valid |-> (!mmio_write && (mmio_wstrb == 4'h0)));
    a_ack_is_store: assert property (@(posedge clk) disable iff (rst)
        sq_req_ack |-> owner_store_r);
    // Payload pass-through: stores carry the SQ fields unchanged, reads never
    // carry byte enables.
    a_store_fields: assert property (@(posedge clk) disable iff (rst)
        mmio_write |-> ((mmio_wstrb == sq_req_strb) && (mmio_wdata == sq_req_data)));
    a_read_no_strb: assert property (@(posedge clk) disable iff (rst)
        !mmio_write |-> (mmio_wstrb == 4'h0));
    // The owner can never switch without passing through IDLE.
    a_owner_stable_while_busy: assert property (@(posedge clk) disable iff (rst)
        busy_r && $past(busy_r) |-> (owner_store_r == $past(owner_store_r)));
    // NOTE: while mmio_req_ready is low the owner-selected request (owner,
    // address, byte enables) must not move.  That freeze is a CLIENT
    // obligation (interface section 12 point 1: "an un-accepted client keeps
    // its fields stable") - the bridge is a pure combinational function of the
    // client payloads, so a client that re-points or withdraws a stalled
    // request legitimately changes mmio_*.  The freeze is verified from the
    // client side in tb_mmio_bridge phase 6 instead of being asserted here.
    // In lsu_top the LQ response payload comes straight from the device bus
    // (the bridge only routes the valid); a mis-wired integration must fail
    // loudly instead of delivering stale data.
    a_lq_rsp_data_from_device: assert property (@(posedge clk) disable iff (rst)
        lq_rsp_valid |-> (lq_rsp_data == mmio_rsp_data));
`endif

endmodule
