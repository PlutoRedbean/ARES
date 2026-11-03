`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ares_core_complex -- one ARES (Mundus) nine-stage core plus one miniTensor.
//
// The core package under rtl/core is the ARES mainline core: IF1/IF2 request
// and response, ID, ISS, EX1-EX4 and WB, with the 16-entry Bimodal/BTB + 8-deep
// RAS front end and the write-through L1 D-cache.  The application baseline
// keeps the data view uncached: every application address (IROM 0x0000_0000,
// scratch 0x1000_0000, DDR 0x8000_0000, MMIO 0xD000_0000, miniTensor
// 0xE000_0000) is outside the core's 0x8010_0000-0x8013_FFFF cacheable window,
// so loads and stores leave the core through PERIP as single 32-bit
// transactions and the CPU and the miniTensor DMA share one physical view.
//
// Instruction fetch goes through the ARES 4-way I-cache, refilled from the
// 128-bit L2 by ares_icache_refill.
// -----------------------------------------------------------------------------
module ares_core_complex #(
  parameter int unsigned ICACHE_SETS       = 32,
  parameter int unsigned ICACHE_WAYS       = 4,
  parameter int unsigned ICACHE_LINE_BYTES = 32
) (
  input  logic         clk,
  input  logic         rst,

  // Memory port (128-bit L2 beats).
  output logic         l2_req_valid,
  input  logic         l2_req_ready,
  output logic         l2_req_write,
  output logic [31:0]  l2_req_addr,
  output logic [127:0] l2_req_wdata,
  output logic [15:0]  l2_req_wstrb,
  input  logic         l2_rsp_valid,
  output logic         l2_rsp_ready,
  input  logic [127:0] l2_rsp_rdata,

  input  logic         irq_timer,
  output logic         mt_irq,

  output logic [31:0]  dbg_pc,
  output logic [31:0]  dbg_instr,
  output logic         dbg_commit,
  output logic         dbg_halt,
  output logic [31:0]  dbg_pc_f,
  output logic         dbg_ifid_valid,
  output logic         dbg_idex_valid,
  output logic         dbg_exmem_valid,
  output logic         dbg_memwb_valid,
  output logic         dbg_if_pending
);
  import ares_pkg::*;

  // ------------------------------------------------------- ARES core ports
  logic        irom_req_valid, irom_req_ready, irom_rsp_valid, irom_rsp_ready, irom_flush;
  logic [31:0] irom_req_addr, irom_rsp_data;

  logic        perip_valid, perip_ready, perip_rvalid, perip_wen, perip_idle;
  logic [1:0]  perip_mask;
  logic [31:0] perip_addr, perip_wdata, perip_rdata;

  logic        retire_valid, retire_rd_wen, retire_is_ebreak;
  logic [31:0] retire_pc, retire_pc_next, retire_wdata;
  logic [4:0]  retire_rd;

  // Mundus starts at the address programmed in rtl/core/Mundus_PC.v (the
  // application entry 0x0000_0000: boot ROM trampoline in simulation, UART
  // loader on the board).  Its only interrupt input is the machine timer, and
  // the coherence inputs belong to the experimental shared-L2 build.
  myCPU u_core (
    .cpu_rst            (rst),
    .cpu_clk            (clk),
    .timer_irq          (irq_timer),
    .irom_req_valid     (irom_req_valid),
    .irom_req_addr      (irom_req_addr),
    .irom_req_ready     (irom_req_ready),
    .irom_rsp_valid     (irom_rsp_valid),
    .irom_rsp_data      (irom_rsp_data),
    .irom_rsp_ready     (irom_rsp_ready),
    .irom_flush         (irom_flush),
    .perip_valid        (perip_valid),
    .perip_ready        (perip_ready),
    .perip_rvalid       (perip_rvalid),
    .perip_addr         (perip_addr),
    .perip_wen          (perip_wen),
    .perip_mask         (perip_mask),
    .perip_wdata        (perip_wdata),
    .perip_rdata        (perip_rdata),
    .perip_idle         (perip_idle),
    .coh_inv_valid      (1'b0),
    .coh_inv_addr       (32'd0),
    .coh_epoch          (8'd0),
    .data_offset        (32'd0),
    .retire_valid       (retire_valid),
    .retire_pc          (retire_pc),
    .retire_pc_next     (retire_pc_next),
    .retire_rd_wen      (retire_rd_wen),
    .retire_rd          (retire_rd),
    .retire_wdata       (retire_wdata),
    .retire_is_ebreak   (retire_is_ebreak)
  );

  // ---------------------------------------------------------- instruction
  logic        refill_req_valid, refill_req_ready, refill_rsp_valid, refill_rsp_ready;
  logic [31:0] refill_req_addr, refill_rsp_data;

  pipeline_icache #(
    .ADDR_WIDTH (32),
    .DATA_WIDTH (32),
    .LINE_BYTES (ICACHE_LINE_BYTES),
    .NR_SETS    (ICACHE_SETS),
    .NR_WAYS    (ICACHE_WAYS),
    .BEAT_BYTES (4),
    .PIPE_HITS  (1)
  ) u_icache (
    .clk              (clk),
    .rst              (rst),
    .req_valid        (irom_req_valid),
    .req_addr         (irom_req_addr),
    .req_ready        (irom_req_ready),
    .rsp_valid        (irom_rsp_valid),
    .rsp_data         (irom_rsp_data),
    .rsp_ready        (irom_rsp_ready),
    .flush            (irom_flush),
    .refill_req_valid (refill_req_valid),
    .refill_req_addr  (refill_req_addr),
    .refill_req_ready (refill_req_ready),
    .refill_rsp_valid (refill_rsp_valid),
    .refill_rsp_data  (refill_rsp_data),
    .refill_rsp_ready (refill_rsp_ready),
    .stats_dump       (retire_valid && retire_is_ebreak),
    .hit_count        (),
    .miss_count       (),
    .refill_count     (),
    .request_count    ()
  );

  logic        i_l2_req_valid, i_l2_req_ready, i_l2_rsp_valid, i_l2_rsp_ready;
  logic [31:0] i_l2_req_addr;
  logic [127:0] i_l2_rsp_rdata;

  ares_icache_refill u_icache_refill (
    .clk,
    .rst,
    .refill_req_valid (refill_req_valid),
    .refill_req_addr  (refill_req_addr),
    .refill_req_ready (refill_req_ready),
    .refill_rsp_valid (refill_rsp_valid),
    .refill_rsp_data  (refill_rsp_data),
    .refill_rsp_ready (refill_rsp_ready),
    .l2_req_valid     (i_l2_req_valid),
    .l2_req_ready     (i_l2_req_ready),
    .l2_req_addr      (i_l2_req_addr),
    .l2_rsp_valid     (i_l2_rsp_valid),
    .l2_rsp_ready     (i_l2_rsp_ready),
    .l2_rsp_rdata     (i_l2_rsp_rdata)
  );

  // ------------------------------------------------------------- data path
  // PERIP -> uncached 32-bit data port.  ares_perip_bridge converts the PERIP
  // size mask into byte strobes and turns the variable-latency L2 round trip
  // into the fixed two-cycle response the LSU expects at LS3.
  logic        b_req_valid, b_req_ready, b_req_write, b_rsp_valid, b_rsp_ready;
  logic [31:0] b_req_addr, b_req_wdata, b_rsp_rdata;
  logic [3:0]  b_req_wstrb;

  ares_perip_bridge u_perip (
    .clk,
    .rst,
    .perip_valid  (perip_valid),
    .perip_ready  (perip_ready),
    .perip_wen    (perip_wen),
    .perip_addr   (perip_addr),
    .perip_mask   (perip_mask),
    .perip_wdata  (perip_wdata),
    .perip_rvalid (perip_rvalid),
    .perip_rdata  (perip_rdata),
    .perip_idle   (perip_idle),
    .req_valid    (b_req_valid),
    .req_ready    (b_req_ready),
    .req_write    (b_req_write),
    .req_addr     (b_req_addr),
    .req_wdata    (b_req_wdata),
    .req_wstrb    (b_req_wstrb),
    .rsp_valid    (b_rsp_valid),
    .rsp_ready    (b_rsp_ready),
    .rsp_rdata    (b_rsp_rdata)
  );

  // ----------------------------------------------------------- miniTensor
  logic        mt_l2_req_valid, mt_l2_req_ready, mt_l2_req_write, mt_l2_rsp_valid, mt_l2_rsp_ready;
  logic [31:0] mt_l2_req_addr;
  logic [127:0] mt_l2_req_wdata, mt_l2_rsp_rdata;
  logic [15:0] mt_l2_req_wstrb;

  logic        mt_reg_wr_en;
  logic [2:0]  mt_reg_wr_idx;
  logic [31:0] mt_reg_wr_data;
  logic        mt_status_rd;
  logic [31:0] mt_status, mt_result;
  logic [31:0] mt_perf_dma, mt_perf_mma;

`ifdef ARES_NO_MT
  // Bring-up builds replace the accelerator with a port-compatible stub.
  mt_cluster_stub u_mt (
    .clk, .rst,
    .reg_wr_en(mt_reg_wr_en), .reg_wr_idx(mt_reg_wr_idx), .reg_wr_data(mt_reg_wr_data),
    .status_rd(mt_status_rd), .status(mt_status), .result_data(mt_result),
    .l2_req_valid(mt_l2_req_valid), .l2_req_ready(mt_l2_req_ready),
    .l2_req_write(mt_l2_req_write), .l2_req_addr(mt_l2_req_addr),
    .l2_req_wdata(mt_l2_req_wdata), .l2_req_wstrb(mt_l2_req_wstrb),
    .l2_rsp_valid(mt_l2_rsp_valid), .l2_rsp_ready(mt_l2_rsp_ready), .l2_rsp_rdata(mt_l2_rsp_rdata),
    .mt_irq(mt_irq),
    .perf_dma(mt_perf_dma), .perf_mma(mt_perf_mma)
  );
`else
  mt_cluster u_mt (
    .clk, .rst,
    .reg_wr_en(mt_reg_wr_en), .reg_wr_idx(mt_reg_wr_idx), .reg_wr_data(mt_reg_wr_data),
    .status_rd(mt_status_rd), .status(mt_status), .result_data(mt_result),
    .l2_req_valid(mt_l2_req_valid), .l2_req_ready(mt_l2_req_ready),
    .l2_req_write(mt_l2_req_write), .l2_req_addr(mt_l2_req_addr),
    .l2_req_wdata(mt_l2_req_wdata), .l2_req_wstrb(mt_l2_req_wstrb),
    .l2_rsp_valid(mt_l2_rsp_valid), .l2_rsp_ready(mt_l2_rsp_ready), .l2_rsp_rdata(mt_l2_rsp_rdata),
    .mt_irq(mt_irq),
    .perf_dma(mt_perf_dma), .perf_mma(mt_perf_mma)
  );
`endif

  // --------------------------------------------------- bypass / local MMIO
  typedef enum logic [2:0] {
    B_IDLE, B_MT_RESP, B_L2_REQ, B_L2_WAIT, B_L2_RESP
  } bstate_t;
  bstate_t bstate_q;

  logic [31:0] b_addr_q, b_wdata_q, b_rsp_data_q;
  logic [3:0]  b_wstrb_q;
  logic        b_write_q;
  logic [1:0]  b_lane_q;

  logic        b_l2_req_valid, b_l2_req_ready, b_l2_req_write;
  logic [31:0] b_l2_req_addr;
  logic [127:0] b_l2_req_wdata;
  logic [15:0] b_l2_req_wstrb;
  logic        b_l2_rsp_valid, b_l2_rsp_ready;
  logic [127:0] b_l2_rsp_rdata;

  wire mt_local = (b_req_addr[31:12] == MT_BASE[31:12]);
  wire [2:0] mt_idx = b_req_addr[4:2];

  assign b_req_ready = (bstate_q == B_IDLE);
  assign b_rsp_valid = (bstate_q == B_MT_RESP) || (bstate_q == B_L2_RESP);
  assign b_rsp_rdata = b_rsp_data_q;

  assign mt_reg_wr_en = (bstate_q == B_IDLE) && b_req_valid && b_req_ready &&
                        b_req_write && mt_local;
  assign mt_reg_wr_idx = mt_idx;
  assign mt_reg_wr_data = b_req_wdata;
  assign mt_status_rd = (bstate_q == B_IDLE) && b_req_valid && b_req_ready &&
                        !b_req_write && mt_local && (mt_idx == 3'd4);

  assign b_l2_req_valid = (bstate_q == B_L2_REQ);
  assign b_l2_req_write = b_write_q;

  // 0xD0xx_xxxx is the peripheral space.  It used to be only 0xD000_xxxx (64 KB),
  // which is not enough for the two 320x240 frame windows (300 KB each): loads
  // past 0xD000_FFFF were treated as memory and silently returned zero.
  wire b_is_mmio = ((b_addr_q[31:16] == 16'h0001) ||
                    (b_addr_q[31:24] == 8'hD0));
  assign b_l2_req_addr = b_is_mmio ? {b_addr_q[31:2], 2'b00} : {b_addr_q[31:4], 4'b0};
  assign b_l2_rsp_ready = (bstate_q == B_L2_WAIT);

  always_comb begin
    b_l2_req_wdata = 128'd0;
    b_l2_req_wstrb = 16'd0;
    if (b_is_mmio) begin
      b_l2_req_wdata[31:0] = b_wdata_q;
      b_l2_req_wstrb[3:0] = b_wstrb_q;
    end else begin
      b_l2_req_wdata[b_lane_q*32 +: 32] = b_wdata_q;
      for (int unsigned i = 0; i < 4; i++) begin
        b_l2_req_wstrb[b_lane_q*4 + i] = b_wstrb_q[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bstate_q <= B_IDLE;
      b_addr_q <= 32'd0;
      b_wdata_q <= 32'd0;
      b_wstrb_q <= 4'd0;
      b_write_q <= 1'b0;
      b_lane_q <= 2'd0;
      b_rsp_data_q <= 32'd0;
    end else begin
      case (bstate_q)
        B_IDLE: begin
          if (b_req_valid && b_req_ready) begin
            b_addr_q <= b_req_addr;
            b_wdata_q <= b_req_wdata;
            b_wstrb_q <= b_req_wstrb;
            b_write_q <= b_req_write;
            b_lane_q <= b_req_addr[3:2];
            if (mt_local) begin
              bstate_q <= B_MT_RESP;
              case (mt_idx)
                3'd4: b_rsp_data_q <= mt_status;
                3'd5: b_rsp_data_q <= mt_result;
                3'd6: b_rsp_data_q <= mt_perf_dma;
                3'd7: b_rsp_data_q <= mt_perf_mma;
                default: b_rsp_data_q <= 32'd0;
              endcase
            end else begin
              bstate_q <= B_L2_REQ;
            end
          end
        end
        B_MT_RESP: if (b_rsp_ready) bstate_q <= B_IDLE;
        B_L2_REQ: if (b_l2_req_ready) bstate_q <= B_L2_WAIT;
        B_L2_WAIT: begin
          if (b_l2_rsp_valid) begin
            b_rsp_data_q <= b_l2_rsp_rdata[b_lane_q*32 +: 32];
            bstate_q <= B_L2_RESP;
          end
        end
        B_L2_RESP: if (b_rsp_ready) bstate_q <= B_IDLE;
        default: bstate_q <= B_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------- mem mux
  // Three masters: 0 = instruction refill, 1 = miniTensor DMA, 2 = data/MMIO.
  logic [2:0]        m_req_valid, m_req_ready, m_req_write;
  logic [2:0][31:0]  m_req_addr;
  logic [2:0][127:0] m_req_wdata;
  logic [2:0][15:0]  m_req_wstrb;
  logic [2:0]        m_rsp_valid, m_rsp_ready;
  logic [2:0][127:0] m_rsp_rdata;

  assign m_req_valid[0] = i_l2_req_valid;
  assign m_req_write[0] = 1'b0;
  assign m_req_addr[0]  = i_l2_req_addr;
  assign m_req_wdata[0] = 128'd0;
  assign m_req_wstrb[0] = 16'd0;
  assign i_l2_req_ready = m_req_ready[0];
  assign i_l2_rsp_valid = m_rsp_valid[0];
  assign i_l2_rsp_rdata = m_rsp_rdata[0];
  assign m_rsp_ready[0] = i_l2_rsp_ready;

  assign m_req_valid[1] = mt_l2_req_valid;
  assign m_req_write[1] = mt_l2_req_write;
  assign m_req_addr[1]  = mt_l2_req_addr;
  assign m_req_wdata[1] = mt_l2_req_wdata;
  assign m_req_wstrb[1] = mt_l2_req_wstrb;
  assign mt_l2_req_ready = m_req_ready[1];
  assign mt_l2_rsp_valid = m_rsp_valid[1];
  assign mt_l2_rsp_rdata = m_rsp_rdata[1];
  assign m_rsp_ready[1] = mt_l2_rsp_ready;

  assign m_req_valid[2] = b_l2_req_valid;
  assign m_req_write[2] = b_l2_req_write;
  assign m_req_addr[2]  = b_l2_req_addr;
  assign m_req_wdata[2] = b_l2_req_wdata;
  assign m_req_wstrb[2] = b_l2_req_wstrb;
  assign b_l2_req_ready = m_req_ready[2];
  assign b_l2_rsp_valid = m_rsp_valid[2];
  assign b_l2_rsp_rdata = m_rsp_rdata[2];
  assign m_rsp_ready[2] = b_l2_rsp_ready;

  typedef enum logic [1:0] {A_IDLE, A_WAIT} astate_t;
  astate_t astate_q;
  logic [1:0] owner_q;

  always_comb begin
    m_req_ready = 3'b000;
    if (astate_q == A_IDLE) begin
      if (m_req_valid[1]) m_req_ready[1] = l2_req_ready;
      else if (m_req_valid[2]) m_req_ready[2] = l2_req_ready;
      else if (m_req_valid[0]) m_req_ready[0] = l2_req_ready;
    end
  end

  always_comb begin
    l2_req_valid = 1'b0;
    l2_req_write = 1'b0;
    l2_req_addr  = 32'd0;
    l2_req_wdata = 128'd0;
    l2_req_wstrb = 16'd0;
    if (astate_q == A_IDLE) begin
      if (m_req_valid[1]) begin
        l2_req_valid = m_req_valid[1]; l2_req_write = m_req_write[1];
        l2_req_addr = m_req_addr[1]; l2_req_wdata = m_req_wdata[1]; l2_req_wstrb = m_req_wstrb[1];
      end else if (m_req_valid[2]) begin
        l2_req_valid = m_req_valid[2]; l2_req_write = m_req_write[2];
        l2_req_addr = m_req_addr[2]; l2_req_wdata = m_req_wdata[2]; l2_req_wstrb = m_req_wstrb[2];
      end else if (m_req_valid[0]) begin
        l2_req_valid = m_req_valid[0]; l2_req_write = m_req_write[0];
        l2_req_addr = m_req_addr[0]; l2_req_wdata = m_req_wdata[0]; l2_req_wstrb = m_req_wstrb[0];
      end
    end
  end

  always_comb begin
    m_rsp_valid = 3'b000;
    m_rsp_rdata = '0;
    l2_rsp_ready = 1'b0;
    if (astate_q == A_WAIT) begin
      m_rsp_valid[owner_q] = l2_rsp_valid;
      m_rsp_rdata[owner_q] = l2_rsp_rdata;
      l2_rsp_ready = m_rsp_ready[owner_q];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      astate_q <= A_IDLE;
      owner_q <= 2'd0;
    end else begin
      case (astate_q)
        A_IDLE: begin
          if (l2_req_valid && l2_req_ready) begin
            astate_q <= A_WAIT;
            if (m_req_valid[1]) owner_q <= 2'd1;
            else if (m_req_valid[2]) owner_q <= 2'd2;
            else owner_q <= 2'd0;
          end
        end
        A_WAIT: begin
          if (l2_rsp_valid && l2_rsp_ready) astate_q <= A_IDLE;
        end
        default: astate_q <= A_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------- commit tracing
  assign dbg_pc            = retire_pc;
  assign dbg_commit        = retire_valid;
  assign dbg_halt          = retire_valid && retire_is_ebreak;
  assign dbg_pc_f          = retire_pc_next;
  assign dbg_instr         = 32'd0;
  assign dbg_ifid_valid    = 1'b0;
  assign dbg_idex_valid    = 1'b0;
  assign dbg_exmem_valid   = 1'b0;
  assign dbg_memwb_valid   = 1'b0;
  assign dbg_if_pending    = 1'b0;
endmodule
