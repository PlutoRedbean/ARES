//=============================================================================
// ARES core verification - 128-bit memory bus -> DPI-C model adapter
//-----------------------------------------------------------------------------
// Timing model of the SoC-side slave for the CPU Cache Line Adapter
// (memory.md section 6.7).  The cycle-level protocol is SystemVerilog, the
// data lives in the shared C++ model (perip_read / perip_write), so cpu-tests
// images and the DRAM/MMIO model are reused unchanged.
//
// Contract implemented here (docs/core_verification_flow.md section 3.2):
//   * 16B per beat, 16B aligned, no burst, no ID
//   * one outstanding read: rd_ready is low until the response is consumed
//   * rsp_valid appears MEM_LATENCY+1 cycles after the read handshake and the
//     data is registered, so a stalled response never changes underneath
//   * a write is applied at the handshake edge; the DPI model normalises the
//     strobe to (addr & ~3) + lane, so the byte lanes are re-derived here from
//     mem_wr_be instead of being pushed as an unaligned payload
//   * same-cycle write and read are ordered write-first (program order in the
//     single clocked block below)
//
// Parameters:
//   MEM_LATENCY   read latency knob (>= 1), default 2 response cycles
//   STALL_PERIOD  0 = never backpressure; N = one stall cycle every N cycles
//                 (stresses MSHR / WB / Completion FIFO re-try paths)
//
// FREE items: FREE-10 (verification environment structure).  This model is
// NOT synthesizable and is only used by the core TBs.
//=============================================================================
module tb_mem_beat_if #(
    parameter int unsigned MEM_LATENCY  = 1,
    parameter int unsigned STALL_PERIOD = 0
) (
    input  logic         clk,
    input  logic         rst,

    //---- read channel (master: Cache Line Adapter / MSHR) ------------------
    input  logic         mem_rd_valid,
    output logic         mem_rd_ready,
    input  logic [31:0]  mem_rd_addr,
    output logic         mem_rsp_valid,
    input  logic         mem_rsp_ready,
    output logic [127:0] mem_rsp_data,

    //---- write channel (master: Cache Line Adapter / Writeback) ------------
    input  logic         mem_wr_valid,
    output logic         mem_wr_ready,
    input  logic [31:0]  mem_wr_addr,
    input  logic [127:0] mem_wr_data,
    input  logic [15:0]  mem_wr_be
);
    import "DPI-C" function int  perip_read(input int addr);
    import "DPI-C" function void perip_write(input int addr, input int data, input byte mask);

    //-------------------------------------------------------------------------
    // Optional periodic backpressure
    //-------------------------------------------------------------------------
    logic       stall;

    generate
        if (STALL_PERIOD == 0) begin : g_no_stall
            assign stall = 1'b0;
        end else begin : g_stall
            logic [7:0] stall_q;
            always_ff @(posedge clk) begin
                if (rst) stall_q <= 8'(STALL_PERIOD - 1);
                else if (stall_q == 8'd0) stall_q <= 8'(STALL_PERIOD - 1);
                else stall_q <= stall_q - 8'd1;
            end
            assign stall = (stall_q == 8'd0);
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Byte-lane write: one DPI call per enabled byte lane unless the whole
    // word is enabled, in which case a single word store is used (that is the
    // path refill / writeback traffic takes).
    //-------------------------------------------------------------------------
    task automatic write_word(input logic [31:0] addr,
                              input logic [31:0] data,
                              input logic [3:0]  be);
        int i;
        begin
            if (be == 4'hf) begin
                perip_write(int'(addr), int'(data), 8'h02);
            end else begin
                for (i = 0; i < 4; i++) begin
                    if (be[i])
                        perip_write(int'(addr) + i, int'({24'd0, data[8*i +: 8]}), 8'h00);
                end
            end
        end
    endtask

    task automatic write_beat(input logic [31:0]  addr,
                              input logic [127:0] data,
                              input logic [15:0]  be);
        int w;
        begin
            for (w = 0; w < 4; w++)
                write_word(addr + 32'(4 * w), data[32*w +: 32], be[4*w +: 4]);
        end
    endtask

    //-------------------------------------------------------------------------
    // Read channel
    //-------------------------------------------------------------------------
    logic         rd_busy;
    logic [31:0]  rd_addr_q;
    logic [7:0]   rd_wait_q;
    logic         rsp_valid_q;
    logic [127:0] rsp_data_q;

    wire rd_accept = mem_rd_valid && mem_rd_ready;
    wire rsp_fire  = rsp_valid_q && mem_rsp_ready;

    // A new request may be accepted in the same cycle the previous response
    // completes (single outstanding read, no overlap of payload phases).
    assign mem_rd_ready  = !rst && !stall && !rd_busy && (!rsp_valid_q || mem_rsp_ready);
    assign mem_rsp_valid = rsp_valid_q;
    assign mem_rsp_data  = rsp_data_q;

    //-------------------------------------------------------------------------
    // Write channel: applied at the handshake edge, before the read sample in
    // this block, which is what makes same-cycle write-first ordering hold.
    //-------------------------------------------------------------------------
    assign mem_wr_ready = !rst && !stall;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_busy     <= 1'b0;
            rd_addr_q   <= 32'd0;
            rd_wait_q   <= 8'd0;
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 128'd0;
        end else begin
            // 1) write acceptance (memory.md 6.7: write before read)
            if (mem_wr_valid && mem_wr_ready)
                write_beat(mem_wr_addr, mem_wr_data, mem_wr_be);

            // 2) response retirement
            if (rsp_fire)
                rsp_valid_q <= 1'b0;

            // 3) read progress
            if (rd_busy) begin
                if (rd_wait_q == 8'd0) begin
                    rsp_data_q  <= {perip_read(int'(rd_addr_q) + 12),
                                    perip_read(int'(rd_addr_q) + 8),
                                    perip_read(int'(rd_addr_q) + 4),
                                    perip_read(int'(rd_addr_q))};
                    rsp_valid_q <= 1'b1;
                    rd_busy     <= 1'b0;
                end else begin
                    rd_wait_q <= rd_wait_q - 8'd1;
                end
            end else if (rd_accept) begin
                rd_busy   <= 1'b1;
                rd_addr_q <= mem_rd_addr;
                rd_wait_q <= 8'(MEM_LATENCY - 1);
            end
        end
    end

`ifdef CONFIG_SIMULATION
    a_rd_addr_aligned: assert property (@(posedge clk) disable iff (rst)
        rd_accept |-> (mem_rd_addr[3:0] == 4'h0));
    a_wr_addr_aligned: assert property (@(posedge clk) disable iff (rst)
        (mem_wr_valid && mem_wr_ready) |-> (mem_wr_addr[3:0] == 4'h0));
    a_rsp_stable: assert property (@(posedge clk) disable iff (rst)
        (rsp_valid_q && !mem_rsp_ready) |=> (mem_rsp_valid && $stable(mem_rsp_data)));
`endif

endmodule
