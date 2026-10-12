//=============================================================================
// ARES - Verilator test bench for the ported NPC (Mundus) RTL
//-----------------------------------------------------------------------------
// The DUT is the Chisel-generated "Mundus" core taken from
// ysyx-workbench/npc/vsrc.  It exposes the JYD style top level interface:
//
//   * an instruction port      : io_irom_addr (byte address) -> io_irom_data (64b)
//   * a peripheral/DRAM port   : io_perip_{valid,ready,rvalid,addr,wen,mask,
//                                          wdata,rdata}
//   * one level sensitive interrupt input
//
// The original npc test bench (vsrc/testbench/MundusNpc.v) drives an AXI4 port
// that the current Mundus generation no longer provides, so ARES owns this
// replacement model:
//
//   * IROM  : registered 64 bit fetch out of the DPI memory model, matching
//             CONFIG_IROM_READ_LATENCY = 1
//   * PERIP : in-order request/response model.  Writes are applied when the
//             request handshakes, reads are captured at handshake time and
//             returned through a two stage pipeline, which preserves both the
//             ordering and the bounded depth the LSU expects.
//
// Address decoding (IROM / DRAM / aliases / MMIO) lives in the C++ model
// (sim/csrc/memory.cpp) so that the memory map can be changed without
// touching the RTL.
//=============================================================================

`timescale 1ns / 1ps

module tb_mundus_npc (
  input clock,
  input reset
);

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  wire [31:0] irom_addr;
  wire [63:0] irom_data;

  wire        perip_valid;
  wire        perip_ready;
  wire        perip_rvalid;
  wire [31:0] perip_addr;
  wire [31:0] perip_wdata;
  wire [31:0] perip_rdata;
  wire        perip_wen;
  wire [ 1:0] perip_mask;

  Mundus u_mundus (
    .clock           (clock       ),
    .reset           (reset       ),
    .io_interrupt    (1'b0        ),
    .io_irom_addr    (irom_addr   ),
    .io_irom_data    (irom_data   ),
    .io_perip_valid  (perip_valid ),
    .io_perip_ready  (perip_ready ),
    .io_perip_rvalid (perip_rvalid),
    .io_perip_addr   (perip_addr  ),
    .io_perip_wen    (perip_wen   ),
    .io_perip_mask   (perip_mask  ),
    .io_perip_wdata  (perip_wdata ),
    .io_perip_rdata  (perip_rdata )
  );

  //--------------------------------------------------------------------------
  // Instruction port model: 8 byte aligned 64 bit fetch
  //--------------------------------------------------------------------------
  // CONFIG_IROM_READ_LATENCY = 1: the core consumes io_irom_data one clock
  // after it presents io_irom_addr.  This mirrors IROM_BMEM in the JYD top
  // (a synchronous BRAM), and getting it wrong shifts the fetched instruction
  // stream by one 8-byte block - which shows up as every PC relative result
  // (AUIPC / JAL link) being 8 bytes too small.
  import "DPI-C" function int irom_read(input int addr);

  reg [63:0] irom_data_q = 64'd0;

  always @(posedge clock) begin
    irom_data_q <= {irom_read(irom_addr + 32'd4), irom_read(irom_addr)};
  end

  assign irom_data = irom_data_q;

  //--------------------------------------------------------------------------
  // Peripheral port model
  //--------------------------------------------------------------------------
  // The peripheral follows perip_bridge.sv semantics:
  //   * a read returns the 32 bit word aligned to the request address; the
  //     LSU extracts the addressed byte / half word itself
  //   * a store carries the payload in the low lane, and the address plus the
  //     2 bit size mask (2'b10 word, 2'b01 half, 2'b00 byte) select the lanes
  // Reading the unaligned word or extracting bytes from a shifted payload
  // silently corrupts memory, which then leaks back in through cache refills.
  import "DPI-C" function int  perip_read(input int addr);
  import "DPI-C" function void perip_write(input int addr,
                                           input int data,
                                           input byte mask);

  // Two stage read response pipeline, matching perip_bridge.sv
  // (response_tag_r / response_tag_r2).  Keeping exactly two responses in
  // flight is part of the LSU contract: its completion queue is four entries
  // deep, and a deeper response pipeline lets it overflow.
  //
  //   * a write is applied when the request handshakes
  //   * a read captures its data at handshake time, so reads never observe a
  //     younger store than one accepted before them
  reg        resp_v1 = 1'b0;
  reg        resp_v2 = 1'b0;
  reg [31:0] resp_a1 = 32'd0;
  reg [31:0] resp_d1 = 32'd0;
  reg [31:0] resp_d2 = 32'd0;

  import "DPI-C" function void perip_trace(input int kind,
                                             input int addr,
                                             input int data);

  wire perip_accept = perip_valid && perip_ready;

  // perip_bridge keeps ready high for DRAM traffic; backpressure only appears
  // for MMIO ordering.  A response pipeline two deep (not a wider queue) is
  // what keeps the LSU completion queue bounded.
  assign perip_ready  = 1'b1;
  assign perip_rvalid = resp_v2;
  assign perip_rdata  = resp_d2;

  always @(posedge clock) begin
    if (reset) begin
      resp_v1 <= 1'b0;
      resp_v2 <= 1'b0;
      resp_d1 <= 32'd0;
      resp_d2 <= 32'd0;
    end
    else begin
      if (resp_v1) perip_trace(1, resp_a1, resp_d1);
      resp_v2 <= resp_v1;
      resp_d2 <= resp_d1;
      resp_v1 <= perip_accept && !perip_wen;
      if (perip_accept) begin
        perip_trace(0, perip_addr, perip_wen ? perip_wdata : 32'hdeadbeef);
        if (perip_wen) begin
          perip_write(perip_addr, perip_wdata, {6'b0, perip_mask});
        end
        else begin
          resp_a1 <= perip_addr;
          resp_d1 <= perip_read(perip_addr);
        end
      end
    end
  end

endmodule
