//=============================================================================
// ARES - shared two-hart CoreMark mailbox (MMIO, uncached)
//-----------------------------------------------------------------------------
// A single MMIO device visible at 0xA000_3000 from BOTH harts.  It exists so a
// MULTITHREAD=2 CoreMark port can run one context per hart and still emit ONE
// report: hart1 publishes its per-context CRCs here, hart0 reads them after the
// DONE handshake and copies them into core_main's results[1].
//
// Why MMIO and not shared L2 memory:
//   * each hart's D-side is offset by C1_DATA_OFFSET (uniform +1 MiB), so the
//     two harts have no common data address;
//   * the private L1D caches are write-back and the shared L2 has no snoop or
//     invalidate path, so a mailbox in DRAM would be stale in one hart;
//   * MMIO bypasses the L1D, the L2 and the data offset (memory.md 3.1), and
//     its loads are commit-head serialized and non-speculative, so the
//     descriptor/GO and CRC/DONE handshakes need no cache maintenance.
//
// Register map (word offsets from 0xA000_3000):
//   0x00 GO         hart0 -> hart1 : descriptors valid, start the context
//   0x04 DONE       hart1 -> hart0 : result registers valid
//   0x08 ITER       iterations for this context
//   0x0C EXECS      algorithm bitmask
//   0x10 SIZE       per-algorithm block size (TOTAL_DATA_SIZE / #algorithms)
//   0x14..0x1C      seed1..seed3
//   0x20 CRCLIST
//   0x24 CRCMATRIX
//   0x28 CRCSTATE
//   0x2C CRCFINAL
//   0x30 ERR
//
// Both ports may read every register.  A same-register write collision is
// resolved in favour of port 0; software never produces that collision.
//=============================================================================
module ares_coremark_mbox (
    input  logic        clk,
    input  logic        rst,

    //---- hart0 device channel ----------------------------------------------
    input  logic        p0_req_valid,
    output logic        p0_req_ready,
    input  logic        p0_write,
    input  logic [31:0] p0_addr,
    input  logic [31:0] p0_wdata,
    input  logic [3:0]  p0_wstrb,
    output logic        p0_rsp_valid,
    input  logic        p0_rsp_ready,
    output logic [31:0] p0_rsp_data,

    //---- hart1 device channel ----------------------------------------------
    input  logic        p1_req_valid,
    output logic        p1_req_ready,
    input  logic        p1_write,
    input  logic [31:0] p1_addr,
    input  logic [31:0] p1_wdata,
    input  logic [3:0]  p1_wstrb,
    output logic        p1_rsp_valid,
    input  logic        p1_rsp_ready,
    output logic [31:0] p1_rsp_data
);
    localparam int unsigned NREGS = 16;

    logic [31:0] regs [NREGS];

    wire [3:0] p0_idx = p0_addr[5:2];
    wire [3:0] p1_idx = p1_addr[5:2];
    wire       p0_fire = p0_req_valid && p0_req_ready;
    wire       p1_fire = p1_req_valid && p1_req_ready;

    // One outstanding request per port, as required by the MMIO bridge.
    assign p0_req_ready = !p0_rsp_valid;
    assign p1_req_ready = !p1_rsp_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < NREGS; i++) regs[i] <= 32'h0;
            p0_rsp_valid <= 1'b0;
            p1_rsp_valid <= 1'b0;
            p0_rsp_data  <= 32'h0;
            p1_rsp_data  <= 32'h0;
        end else begin
            if (p0_rsp_valid && p0_rsp_ready) p0_rsp_valid <= 1'b0;
            if (p1_rsp_valid && p1_rsp_ready) p1_rsp_valid <= 1'b0;

            if (p0_fire) begin
                p0_rsp_valid <= 1'b1;
                p0_rsp_data  <= p0_write ? 32'h0 : regs[p0_idx];
            end
            if (p1_fire) begin
                p1_rsp_valid <= 1'b1;
                p1_rsp_data  <= p1_write ? 32'h0 : regs[p1_idx];
            end

            // Port 0 wins a same-register collision; writes are byte enabled.
            if (p0_fire && p0_write)
                for (int b = 0; b < 4; b++)
                    if (p0_wstrb[b]) regs[p0_idx][8*b +: 8] <= p0_wdata[8*b +: 8];
            if (p1_fire && p1_write && !(p0_fire && p0_write && (p0_idx == p1_idx)))
                for (int b = 0; b < 4; b++)
                    if (p1_wstrb[b]) regs[p1_idx][8*b +: 8] <= p1_wdata[8*b +: 8];
        end
    end
endmodule
