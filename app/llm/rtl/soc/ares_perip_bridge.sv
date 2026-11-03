`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ares_perip_bridge -- PERIP <- 128-bit L2 adapter with a fixed read latency.
//
// The ARES LSU accepts a PERIP request when perip.ready is high and consumes the
// read data two cycles later, at LS3 (lsu.scala: io.in.ready / ls3_valid /
// formatLoad).  The application memory subsystem answers in a variable number
// of cycles, so this bridge does not accept a load until its word is already in
// hand:
//
//   1. a load is held off with perip.ready = 0 while the L2 read is issued
//      (the LSU keeps the stable address and valid asserted);
//   2. the returned 128-bit beat is buffered and the load is accepted;
//   3. the buffered word is driven on perip.rdata with perip.rvalid exactly
//      two cycles after the accept, which is where the LSU samples it.
//
// Stores are accepted immediately and drained in the background; the PERIP
// idle output covers both the outstanding store and the read pipeline so the
// core's FENCE has a correct drain condition.
// -----------------------------------------------------------------------------
module ares_perip_bridge #(
  parameter logic [31:0] CACHE_BASE = 32'h8000_0000,
  parameter logic [31:0] CACHE_SIZE = 32'h4000_0000,
  parameter logic [31:0] UNC_BASE   = 32'h4000_0000
) (
  input  logic        clk,
  input  logic        rst,

  // Core PERIP port (Mundus lsu.scala contract).
  input  logic        perip_valid,
  output logic        perip_ready,
  input  logic        perip_wen,
  input  logic [31:0] perip_addr,
  input  logic [1:0]  perip_mask,
  input  logic [31:0] perip_wdata,
  output logic        perip_rvalid,
  output logic [31:0] perip_rdata,
  output logic        perip_idle,

  // Memory side: one 32-bit transaction at a time, byte strobes.
  output logic        req_valid,
  input  logic        req_ready,
  output logic        req_write,
  output logic [31:0] req_addr,
  output logic [31:0] req_wdata,
  output logic [3:0]  req_wstrb,
  input  logic        rsp_valid,
  output logic        rsp_ready,
  input  logic [31:0] rsp_rdata
);
  typedef enum logic [2:0] {
    P_IDLE, P_RD_REQ, P_RD_WAIT, P_WR_REQ, P_WR_WAIT
  } pstate_t;

  pstate_t     pstate_q;
  logic        buf_valid_q;
  logic [31:0] buf_addr_q, buf_data_q;
  logic [31:0] r_addr_q;      // translated address of the read in flight
  logic [31:0] r_addr_raw_q;  // PERIP address, for the buffer compare
  logic [31:0] w_addr_q, w_data_q;
  logic [3:0]  w_strb_q;

  // Two-stage response pipeline: accepted at N, data valid at N+2.
  logic        v0_q, v1_q;
  logic [31:0] d0_q, d1_q;

  // ------------------------------------------------------------ address view
  // Cached-alias application addresses are translated to the uncached alias so
  // the CPU and the miniTensor DMA share one physical view of memory.
  wire [31:0] xlate_addr = (perip_addr >= CACHE_BASE) &&
                           (perip_addr < (CACHE_BASE + CACHE_SIZE))
                           ? (perip_addr - (CACHE_BASE - UNC_BASE))
                           : perip_addr;

  // Mundus reports the access size as a 2-bit mask and keeps the store payload
  // in the low byte/half.  The data path works on byte strobes, so replicate
  // the payload into every lane and select with the strobes.
  logic [3:0]  req_wstrb_c;
  logic [31:0] req_wdata_c;

  always_comb begin
    unique case (perip_mask)
      2'b10: begin
        req_wstrb_c = 4'hF;
        req_wdata_c = perip_wdata;
      end
      2'b01: begin
        req_wstrb_c = perip_addr[1] ? 4'b1100 : 4'b0011;
        req_wdata_c = {2{perip_wdata[15:0]}};
      end
      2'b00: begin
        req_wstrb_c = 4'h1 << perip_addr[1:0];
        req_wdata_c = {4{perip_wdata[7:0]}};
      end
      default: begin
        req_wstrb_c = 4'h0;
        req_wdata_c = 32'd0;
      end
    endcase
  end

  wire read_req  = perip_valid && !perip_wen;
  wire write_req = perip_valid && perip_wen;
  wire buf_hit   = buf_valid_q && (buf_addr_q == perip_addr);
  wire accept_read = read_req && buf_hit && (pstate_q == P_IDLE);

  assign perip_rvalid = v1_q;
  assign perip_rdata  = d1_q;
  assign perip_ready  = (pstate_q == P_IDLE) && (write_req || accept_read);

  // Memory request channel: reads use the live (translated) PERIP address, a
  // write uses the latched one so it survives the PERIP request dropping.
  assign req_valid = (pstate_q == P_RD_REQ) || (pstate_q == P_WR_REQ);
  assign req_write = (pstate_q == P_WR_REQ);
  assign req_addr  = (pstate_q == P_WR_REQ) ? w_addr_q : r_addr_q;
  assign req_wdata = (pstate_q == P_WR_REQ) ? w_data_q : 32'd0;
  assign req_wstrb = (pstate_q == P_WR_REQ) ? w_strb_q : 4'h0;
  assign rsp_ready = (pstate_q == P_RD_WAIT) || (pstate_q == P_WR_WAIT);

  // A prefetched-but-unused line is not an outstanding memory operation, so
  // it does not block FENCE; the response pipeline does.
  assign perip_idle = (pstate_q == P_IDLE) && !v0_q && !v1_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      pstate_q    <= P_IDLE;
      buf_valid_q <= 1'b0;
      buf_addr_q  <= 32'd0;
      buf_data_q  <= 32'd0;
      r_addr_q    <= 32'd0;
      r_addr_raw_q <= 32'd0;
      w_addr_q    <= 32'd0;
      w_data_q    <= 32'd0;
      w_strb_q    <= 4'd0;
      v0_q        <= 1'b0;
      v1_q        <= 1'b0;
      d0_q        <= 32'd0;
      d1_q        <= 32'd0;
    end else begin
      // Response pipeline: d1 is presented at N+2 relative to the accept.
      v1_q <= v0_q;
      d1_q <= d0_q;
      v0_q <= accept_read;
      if (accept_read) d0_q <= buf_data_q;

      case (pstate_q)
        P_IDLE: begin
          if (write_req) begin
            w_addr_q <= xlate_addr;
            w_data_q <= req_wdata_c;
            w_strb_q <= req_wstrb_c;
            pstate_q <= P_WR_REQ;
          end else if (read_req && !buf_hit) begin
            r_addr_q     <= xlate_addr;
            r_addr_raw_q <= perip_addr;
            pstate_q <= P_RD_REQ;
          end
          // The buffer is one-shot: a later access always observes fresh
          // memory (MMIO registers must not be cached here).
          if (accept_read) buf_valid_q <= 1'b0;
        end
        P_RD_REQ: if (req_ready) pstate_q <= P_RD_WAIT;
        P_RD_WAIT: begin
          if (rsp_valid) begin
            buf_data_q  <= rsp_rdata;
            buf_addr_q  <= r_addr_raw_q;
            buf_valid_q <= 1'b1;
            pstate_q    <= P_IDLE;
          end
        end
        P_WR_REQ: if (req_ready) pstate_q <= P_WR_WAIT;
        P_WR_WAIT: if (rsp_valid) pstate_q <= P_IDLE;
        default: pstate_q <= P_IDLE;
      endcase
    end
  end
endmodule
