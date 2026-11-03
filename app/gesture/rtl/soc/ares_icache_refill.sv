`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ares_icache_refill -- ARES IROM refill adapter for the pipeline_icache.
//
// pipeline_icache asks for one 32-bit IROM word per beat (8 beats per 32 B
// line).  The application memory subsystem is a 128-bit beat L2, so this
// adapter buffers one 16 B line and hands out its four words one beat at a
// time.  Every line fill therefore costs two L2 reads, which is exactly the
// traffic of the original 16 B-beat L1I it replaces.
//
// Read-only: the instruction side never writes.
// -----------------------------------------------------------------------------
module ares_icache_refill (
  input  logic         clk,
  input  logic         rst,

  // pipeline_icache refill port (one 32-bit word per handshake)
  input  logic         refill_req_valid,
  input  logic [31:0]  refill_req_addr,
  output logic         refill_req_ready,
  output logic         refill_rsp_valid,
  output logic [31:0]  refill_rsp_data,
  input  logic         refill_rsp_ready,

  // L2 beat port (128 bit)
  output logic         l2_req_valid,
  input  logic         l2_req_ready,
  output logic [31:0]  l2_req_addr,
  input  logic         l2_rsp_valid,
  output logic         l2_rsp_ready,
  input  logic [127:0] l2_rsp_rdata
);
  typedef enum logic [1:0] {R_IDLE, R_REQ, R_WAIT} rstate_t;
  rstate_t rstate_q;

  logic         buf_valid_q;
  logic [27:0]  buf_line_q;
  logic [127:0] buf_data_q;
  // Line of the L2 read in flight.  The ICache may redirect to a new line
  // while the read is outstanding, so the buffered data must be tagged with
  // the address that produced it, not with the live request.
  logic [27:0]  r_line_q;

  wire [27:0] req_line = refill_req_addr[31:4];
  wire        line_hit = buf_valid_q && (buf_line_q == req_line);

  // A beat is served in the cycle it is requested once its line is buffered.
  assign refill_req_ready = line_hit;
  assign refill_rsp_valid = refill_req_valid && refill_req_ready;
  assign refill_rsp_data  = buf_data_q[refill_req_addr[3:2]*32 +: 32];

  assign l2_req_valid = (rstate_q == R_REQ);
  assign l2_req_addr  = {refill_req_addr[31:4], 4'b0000};
  assign l2_rsp_ready = (rstate_q == R_WAIT);

  always_ff @(posedge clk) begin
    if (rst) begin
      rstate_q    <= R_IDLE;
      buf_valid_q <= 1'b0;
      buf_line_q  <= 28'd0;
      buf_data_q  <= 128'd0;
      r_line_q    <= 28'd0;
    end else begin
      case (rstate_q)
        R_IDLE: begin
          if (refill_req_valid && !line_hit) begin
            r_line_q <= req_line;
            rstate_q <= R_REQ;
          end
        end
        R_REQ: begin
          if (l2_req_ready) rstate_q <= R_WAIT;
        end
        R_WAIT: begin
          if (l2_rsp_valid) begin
            buf_data_q  <= l2_rsp_rdata;
            buf_line_q  <= r_line_q;
            buf_valid_q <= 1'b1;
            rstate_q    <= R_IDLE;
          end
        end
        default: rstate_q <= R_IDLE;
      endcase
    end
  end
endmodule
