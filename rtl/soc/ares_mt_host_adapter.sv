//=============================================================================
// ARES SoC - miniTensor CV-X-IF host adapter (S09 / SPEC-M6, control path)
//-----------------------------------------------------------------------------
// Bridges the ARES/JYD 32-bit MMIO control window (perip_bridge mt_* seam) to
// the CV-X-IF slave port of mini_tensor_top.  This is the ARES host-side
// adapter required before the FE/BE owners land the full in-core XIF path
// (SPEC-M6): the core programs the command registers through ordinary MMIO and
// this FSM synthesises the CV-X-IF issue -> register -> commit -> result
// transaction for each queued command.
//
// Register map (byte offsets from the JYD miniTensor base 0x8020_1000; the
// perip_bridge already decodes the window and supplies reg_wr_idx=addr[4:2]):
//   0x00  MT_INSTR   W   32-bit custom-0 instruction word
//   0x04  MT_RS1     W   value delivered as CV-X-IF register.rs[0]
//   0x08  MT_RS2     W   value delivered as CV-X-IF register.rs[1]
//   0x0C  MT_KICK    W   write 1 to queue the current INSTR/RS1/RS2 tuple
//   0x10  MT_STATUS  R   bit0 busy, bit1 done, bit2 err, bit3 accept_err,
//                        bit4 kick_err; a read while not busy clears the flags
//   0x14  MT_RESULT  R   result.data (miniTensor returns 0 today)
//
// Why a queue: an MMIO write retires as soon as it is accepted by the bridge,
// but an MMIO read costs a full round trip, so a per-command status poll costs
// more than the command itself.  The depth-8 command queue lets software push
// commands back-to-back and drain/check once per batch.
//
// Two mini_tensor_top properties drive the sequencer:
//   * issue_ready is only high in S_IDLE, so exactly one command is in flight;
//   * commit is sampled only in S_WAIT_COMMIT and the accelerator advances only
//     when register_seen and committed are both set.  A one-cycle commit pulse
//     that lands before the register beat would be dropped and the command
//     would hang (miniTensor has no timeout), so commit_valid is held from
//     REGISTER_TO_COMMIT until the result arrives.
//
// Provenance: this is the ARES-owned adaptation of the retained legacy adapter
// miniTensor/integration/npc/mt_cvxif_shim.sv (same MMIO/CV-X-IF contract and
// sequencer); it is re-targeted to the ARES SoC seam and tracked here so the
// ARES integration does not depend on the retired NPC tree.
//
// Scope: this adapter provides the MMIO control path only.  The in-core
// decode/issue/commit path and the CPU<->miniTensor shared-memory ordering rules
// remain SPEC-M6; the accelerator DMA port is exported by ares_soc_top as the
// future Fabric boundary (SPEC-M7/M20/M21).
//=============================================================================
module ares_mt_host_adapter #(
    parameter int unsigned ISSUE_TO_REGISTER  = 2,
    parameter int unsigned REGISTER_TO_COMMIT = 3,
    parameter int unsigned FIFO_DEPTH         = 8
) (
    input  logic        clk,
    input  logic        rst,           // synchronous, active high

    // MMIO register port (driven by the JYD perip_bridge mt_* seam)
    input  logic        reg_wr_en,
    input  logic [2:0]  reg_wr_idx,    // perip_addr[4:2]
    input  logic [31:0] reg_wr_data,
    input  logic        status_rd,     // CPU is reading MT_STATUS this cycle
    output logic [31:0] status,
    output logic [31:0] result_data,

    // CV-X-IF master
    core_v_xif xif
);

  localparam logic [2:0] IDX_INSTR = 3'd0;
  localparam logic [2:0] IDX_RS1   = 3'd1;
  localparam logic [2:0] IDX_RS2   = 3'd2;
  localparam logic [2:0] IDX_KICK  = 3'd3;
  // 3'd4 = MT_STATUS and 3'd5 = MT_RESULT are read-only.

  typedef enum logic [2:0] {
    S_IDLE,
    S_ISSUE,
    S_REG_WAIT,
    S_REGISTER,
    S_COMMIT_WAIT,
    S_WAIT_RESULT
  } state_t;

  state_t      state_q;
  // Execution registers, latched from the queue at pop time and driven onto the
  // CV-X-IF channels.
  logic [31:0] instr_q, rs1_q, rs2_q;
  // Software staging registers.  These MUST be separate from the execution
  // registers: software writes a new command while the queue is still draining,
  // so a pop in the same cycle as a staging write would otherwise clobber it.
  logic [31:0] stg_instr_q, stg_rs1_q, stg_rs2_q;
  logic [3:0]  id_q;
  logic [7:0]  wait_q;

  logic [31:0] result_data_q;
  logic        done_q, err_q, accept_err_q, kick_err_q;

  // ---------------------------------------------------------------------------
  // Command queue
  // ---------------------------------------------------------------------------
  localparam int unsigned PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
  localparam int unsigned CNT_W = $clog2(FIFO_DEPTH + 1);

  logic [31:0] fifo_instr [0:FIFO_DEPTH-1];
  logic [31:0] fifo_rs1   [0:FIFO_DEPTH-1];
  logic [31:0] fifo_rs2   [0:FIFO_DEPTH-1];
  logic [PTR_W-1:0] fifo_head_q, fifo_tail_q;
  logic [CNT_W-1:0] fifo_count_q;

  wire kick       = reg_wr_en && (reg_wr_idx == IDX_KICK) && reg_wr_data[0];
  wire fifo_full  = (fifo_count_q == CNT_W'(FIFO_DEPTH));
  wire fifo_push  = kick && !fifo_full;
  wire fifo_pop   = (state_q == S_IDLE) && (fifo_count_q != CNT_W'(0));

  wire busy = (fifo_count_q != CNT_W'(0)) || (state_q != S_IDLE);

  assign status      = {27'd0, kick_err_q, accept_err_q, err_q, done_q, busy};
  assign result_data = result_data_q;

  // ---------------------------------------------------------------------------
  // CV-X-IF master drive
  // ---------------------------------------------------------------------------
  always_comb begin
    xif.issue_valid      = (state_q == S_ISSUE);
    xif.issue_req        = '0;
    xif.issue_req.instr  = instr_q;
    xif.issue_req.mode   = 2'b00;
    xif.issue_req.hartid = '0;
    xif.issue_req.id     = id_q;

    xif.register_valid    = (state_q == S_REGISTER);
    xif.register          = '0;
    xif.register.hartid   = '0;
    xif.register.id       = id_q;
    xif.register.rs[0]    = rs1_q;
    xif.register.rs[1]    = rs2_q;
    xif.register.rs_valid = 2'b11;

    // Held, not pulsed -- see the header comment.
    xif.commit_valid       = (state_q == S_COMMIT_WAIT) || (state_q == S_WAIT_RESULT);
    xif.commit             = '0;
    xif.commit.hartid      = '0;
    xif.commit.id          = id_q;
    xif.commit.commit_kill = 1'b0;

    xif.result_ready = (state_q == S_WAIT_RESULT);

    // Unused CV-X-IF channels; mini_tensor_top ties the memory channel off.
    xif.compressed_valid = 1'b0;
    xif.compressed_req   = '0;
    xif.mem_ready        = 1'b1;
    xif.mem_resp         = '0;
    xif.mem_result_valid = 1'b0;
    xif.mem_result       = '0;
  end

  // ---------------------------------------------------------------------------
  // Register file and control FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state_q       <= S_IDLE;
      instr_q       <= 32'd0;
      rs1_q         <= 32'd0;
      rs2_q         <= 32'd0;
      stg_instr_q   <= 32'd0;
      stg_rs1_q     <= 32'd0;
      stg_rs2_q     <= 32'd0;
      id_q          <= 4'd0;
      wait_q        <= 8'd0;
      result_data_q <= 32'd0;
      done_q        <= 1'b0;
      err_q         <= 1'b0;
      accept_err_q  <= 1'b0;
      kick_err_q    <= 1'b0;
      fifo_head_q   <= '0;
      fifo_tail_q   <= '0;
      fifo_count_q  <= '0;
    end else begin
      if (reg_wr_en) begin
        case (reg_wr_idx)
          IDX_INSTR: stg_instr_q <= reg_wr_data;
          IDX_RS1:   stg_rs1_q   <= reg_wr_data;
          IDX_RS2:   stg_rs2_q   <= reg_wr_data;
          default:   ;  // KICK is consumed below
        endcase
      end

      // Enqueue the staged operands.  A full queue drops the kick and flags it
      // rather than stalling the peripheral bus; the push reads the staging
      // registers' current values on the same edge a KICK is accepted.
      if (fifo_push) begin
        fifo_instr[fifo_tail_q] <= stg_instr_q;
        fifo_rs1[fifo_tail_q]   <= stg_rs1_q;
        fifo_rs2[fifo_tail_q]   <= stg_rs2_q;
        fifo_tail_q             <= fifo_tail_q + PTR_W'(1);
      end else if (kick && fifo_full) begin
        kick_err_q <= 1'b1;
      end

      case ({fifo_push, fifo_pop})
        2'b10:   fifo_count_q <= fifo_count_q + CNT_W'(1);
        2'b01:   fifo_count_q <= fifo_count_q - CNT_W'(1);
        default: ;
      endcase

      // A status read only consumes the flags once the queue has drained, so a
      // mid-batch poll cannot lose an error reported by an earlier command.
      if (status_rd && !busy) begin
        done_q       <= 1'b0;
        err_q        <= 1'b0;
        accept_err_q <= 1'b0;
        kick_err_q   <= 1'b0;
      end

      case (state_q)
        S_IDLE: begin
          if (fifo_count_q != CNT_W'(0)) begin
            instr_q     <= fifo_instr[fifo_head_q];
            rs1_q       <= fifo_rs1[fifo_head_q];
            rs2_q       <= fifo_rs2[fifo_head_q];
            fifo_head_q <= fifo_head_q + PTR_W'(1);
            id_q        <= id_q + 4'd1;
            state_q     <= S_ISSUE;
          end
        end

        S_ISSUE: begin
          if (xif.issue_valid && xif.issue_ready) begin
            if (xif.issue_resp.accept) begin
              wait_q  <= ISSUE_TO_REGISTER[7:0];
              state_q <= S_REG_WAIT;
            end else begin
              // Unsupported funct7/funct3: miniTensor never enters its FSM and
              // will never raise result_valid, so report and move on.
              accept_err_q <= 1'b1;
              state_q      <= S_IDLE;
            end
          end
        end

        S_REG_WAIT: begin
          if (wait_q == 8'd0) state_q <= S_REGISTER;
          else                wait_q <= wait_q - 8'd1;
        end

        S_REGISTER: begin
          if (xif.register_valid && xif.register_ready) begin
            wait_q  <= REGISTER_TO_COMMIT[7:0];
            state_q <= S_COMMIT_WAIT;
          end
        end

        S_COMMIT_WAIT: begin
          if (wait_q == 8'd0) state_q <= S_WAIT_RESULT;
          else                wait_q <= wait_q - 8'd1;
        end

        S_WAIT_RESULT: begin
          if (xif.result_valid && xif.result_ready) begin
            err_q         <= err_q | xif.result.err;
            result_data_q <= xif.result.data;
            // Only the final command of a drained queue raises DONE.
            if (fifo_count_q == CNT_W'(0)) done_q <= 1'b1;
            state_q       <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
