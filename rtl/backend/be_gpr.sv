//=============================================================================
// ARES backend - architectural register file (B09)
//-----------------------------------------------------------------------------
// 32 x 32-bit GPR with 8 issue read ports and 2 commit write ports.
//
// backend.md sections 1 / 14.4:
//   * x0 reads as zero and ignores writes;
//   * commit0 is older than commit1: when both write the same register the
//     younger (port 1) must win, which is exactly "apply port 0, then port 1";
//   * the issue side never relies on the RAM read-during-write behaviour: a
//     source with a live dependency reads the CIQ result instead, and the
//     dependency is retired at the same clock edge (backend.md 14.4/14.5), so
//     no write-through/bypass path is needed here.
//
// FREE items: FREE-03 (register-array implementation), FREE-04 (parallel mux).
//=============================================================================
module be_gpr (
    input  logic        clk,
    input  logic        rst,

    //---- issue read ports (backend.md 8.4) ---------------------------------
    input  logic [4:0]  raddr [ares_pkg::GPR_READ_PORTS],
    output logic [31:0] rdata [ares_pkg::GPR_READ_PORTS],

    //---- commit write ports (backend.md 14.4) ------------------------------
    input  logic [1:0]  we,
    input  logic [4:0]  waddr [2],
    input  logic [31:0] wdata [2]
);
    import ares_pkg::*;

    logic [31:0] regs [32];

    // Commit writes.  Port 1 (younger) is evaluated last, so it wins on a
    // same-rd collision; x0 is never written.
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int unsigned r = 0; r < 32; r++) regs[r] <= 32'd0;
        end else begin
            if (we[0] && waddr[0] != 5'd0) regs[waddr[0]] <= wdata[0];
            if (we[1] && waddr[1] != 5'd0) regs[waddr[1]] <= wdata[1];
        end
    end

    // Reads: x0 is constant zero (backend.md 1).
    always_comb begin
        for (int unsigned p = 0; p < GPR_READ_PORTS; p++)
            rdata[p] = (raddr[p] == 5'd0) ? 32'd0 : regs[raddr[p]];
    end

`ifdef CONFIG_SIMULATION
    // x0 must stay zero whatever the commit stage does.
    always_ff @(posedge clk) begin
        if (!rst) a_x0_zero : assert (regs[0] == 32'd0);
    end
`endif
endmodule
