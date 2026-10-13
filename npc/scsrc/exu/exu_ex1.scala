package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import BRUParams._
import MDUParams._
import CSRParams._
import DPUParams._
import OperandStats._

class exu_ex1 extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IS_EX_Payload))
    val side_valid = Input(Bool())
    val side = Input(new IS_EX_Payload)
    val mul_drain = Input(Bool())
    val out  = Decoupled(new EX1_EX2_Payload)
    val flush = Input(Bool())
    val mul_out = Output(UInt(MUL_OUT_WIDTH.W))
    val mulbe_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_busy = Output(Bool())
    val div_done = Output(Bool())
    val bpu_update_en = Output(Bool())
    val bpu_update_pc = Output(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val branch_resolve = Output(new BranchResolveBundle)
    val frp_event = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(new FrpExecutionEventBundle)) else None
    val side_branch_pc_next = Output(UInt(PC_DATA_WIDTH.W))
    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd = Output(new ProducerBundle)

    val forwardEx2 = Input(new ForwardProducerGroup)
    val forwardEx3 = Input(new ForwardProducerGroup)
    val forwardEx4 = Input(new ForwardProducerGroup)
    val forwardWb = Input(new ForwardProducerGroup)

    val csr_rdata = Input(UInt(REG_DATA_WIDTH.W))
    val csr_mtvec = Input(UInt(PC_DATA_WIDTH.W))
    val csr_mepc = Input(UInt(PC_DATA_WIDTH.W))
  })

  val ex_in = io.in
  val valid = ex_in.valid && !io.flush

  val alu_ctrl     = ex_in.bits.alu_ctrl
  val mdu_ctrl     = ex_in.bits.mdu_ctrl

  private def forwardSource(
      operand: LateOperandBundle): Ex1ForwardSource =
    LateOperandForward.select(
      operand, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, io.forwardWb)

  // Issue never lets a control-flow instruction enter Ex1 with a WB token:
  // an unavailable Ex4 producer is interlocked for one cycle and captured
  // into the Issue/Ex1 payload once it reaches WB.  Keep that invariant
  // structural here as well.  Passing the generic WB group to the branch
  // value mux leaves the WB MDU selector physically connected to BRU/HZU
  // even though the WB arm is unreachable for a valid branch.
  private val noBranchWb =
    0.U.asTypeOf(new ForwardProducerGroup)
  private def branchForwardSource(
      operand: LateOperandBundle): Ex1ForwardSource =
    LateOperandForward.select(
      operand, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, noBranchWb)

  private def forwardedValue(
      base: UInt,
      operand: LateOperandBundle,
      source: Ex1ForwardSource): UInt =
    // Issue already selected the producer stage and lane.  Keep the operand
    // data mux on that static token only; dynamic readiness is an interlock /
    // replay decision and must not sit in front of the Ex1 ALU or BRU.
    Mux(operand.pending, source.value, base)

  val rs1Source = forwardSource(ex_in.bits.rs1_late)
  val rs2Source = forwardSource(ex_in.bits.rs2_late)
  val rs1_val =
    forwardedValue(ex_in.bits.rs1_val, ex_in.bits.rs1_late, rs1Source)
  val rs2_val =
    forwardedValue(ex_in.bits.rs2_val, ex_in.bits.rs2_late, rs2Source)

  val ALU = Module(new ALU)
  ALU.io.alu_ctrl := alu_ctrl
  ALU.io.din1 :=
    forwardedValue(
      ex_in.bits.alu_din1, ex_in.bits.rs1_late, rs1Source)
  ALU.io.din2 :=
    forwardedValue(
      ex_in.bits.alu_din2, ex_in.bits.rs2_late, rs2Source)
  val alu_out = ALU.io.dout

  // A53-style shared branch ownership: decode carries the branch class for
  // both slots and EX1 selects the sole BRU input.  Slot 0 branch/system
  // instructions remain serial, so the two owners cannot conflict.
  val sideBranch =
    io.side_valid &&
      (io.side.bru_ctrl =/= BRU_NONE || io.side.jump) &&
      !(io.side.load_pair_rs1 || io.side.load_pair_rs2)
  val branchIn = Mux(sideBranch, io.side, ex_in.bits)
  val mainBranchRs1Source = branchForwardSource(ex_in.bits.rs1_late)
  val mainBranchRs2Source = branchForwardSource(ex_in.bits.rs2_late)
  val sideRs1Source = branchForwardSource(io.side.rs1_late)
  val sideRs2Source = branchForwardSource(io.side.rs2_late)
  val branchRs1Source =
    Mux(sideBranch, sideRs1Source, mainBranchRs1Source)
  val branchRs2Source =
    Mux(sideBranch, sideRs2Source, mainBranchRs2Source)
  val branchRs1 =
    forwardedValue(
      branchIn.rs1_val, branchIn.rs1_late, branchRs1Source)
  val branchRs2 =
    forwardedValue(
      branchIn.rs2_val, branchIn.rs2_late, branchRs2Source)
  val branchPc = branchIn.pc
  val branchSnpc = branchIn.snpc
  val branchJump = branchIn.jump
  val branchBruCtrl = branchIn.bru_ctrl

  val BRU = Module(new BRU)
  BRU.io.bru_ctrl := branchBruCtrl
  BRU.io.imm      := branchIn.imm
  BRU.io.snpc     := branchSnpc
  BRU.io.pc       := branchPc
  BRU.io.rs1_val  := branchRs1
  BRU.io.rs2_val  := branchRs2
  val bru_redirect = BRU.io.redirect
  val is_branch_inst =
    branchBruCtrl(BRU_MUX_WIDTH - 1, 0) === BR_BRANCH

  val MUL = Module(new MUL)
  MUL.io.mdu_ctrl := mdu_ctrl
  MUL.io.enable   := io.out.ready || io.mul_drain
  MUL.io.din1     := rs1_val
  MUL.io.din2     := rs2_val

  val DIV = Module(new DIV)
  DIV.io.mdu_ctrl := mdu_ctrl
  DIV.io.valid    := valid
  DIV.io.din1     := rs1_val
  DIV.io.din2     := rs2_val

  val exu_stall = DIV.io.stall
  val exu_out_valid = valid && !exu_stall
  
  ex_in.ready := io.out.ready && !exu_stall
  io.out.valid := exu_out_valid
  val exu_fire = exu_out_valid && io.out.ready

  private def ex1SourceUsable(
      operand: LateOperandBundle,
      source: Ex1ForwardSource): Bool =
    source.valueAvailable ||
      (operand.loadSpec && operand.pending &&
        source.stage(WHR_IDX_EX2))

  when(exu_fire &&
      ex_in.bits.rs1_need === NEED_EX1 &&
      ex_in.bits.rs1_late.pending) {
    assert(ex1SourceUsable(ex_in.bits.rs1_late, rs1Source),
      "Ex1 rs1 selected producer is not available")
  }
  when(exu_fire &&
      ex_in.bits.rs2_need === NEED_EX1 &&
      ex_in.bits.rs2_late.pending) {
    assert(ex1SourceUsable(ex_in.bits.rs2_late, rs2Source),
      "Ex1 rs2 selected producer is not available")
  }
  when(exu_fire && sideBranch &&
      branchIn.rs1_need === NEED_EX1 &&
      branchIn.rs1_late.pending) {
    assert(ex1SourceUsable(branchIn.rs1_late, branchRs1Source),
      "side Ex1 branch rs1 selected producer is not available")
  }
  when(exu_fire && sideBranch &&
      branchIn.rs2_need === NEED_EX1 &&
      branchIn.rs2_late.pending) {
    assert(ex1SourceUsable(branchIn.rs2_late, branchRs2Source),
      "side Ex1 branch rs2 selected producer is not available")
  }

  val is_ecall     = ex_in.bits.envir === ENVIR_ECALL
  val is_mret      = ex_in.bits.envir === ENVIR_MRET

  // Select the trap payload from the registered instruction class only.
  // exu_fire gates the resolution event below, so a backend/LSU hold cannot
  // feed back into the branch target data mux.
  val trapSelected   = is_ecall || is_mret
  val trap_target_pc = Fill(32, is_ecall) & io.csr_mtvec |
                       Fill(32, is_mret) & io.csr_mepc

  val actual_taken = bru_redirect || trapSelected
  val actual_pc = Mux(bru_redirect , BRU.io.target_pc,
                  Mux(trapSelected, trap_target_pc  , branchSnpc))

  val dnpc_mispredict = BRU.io.target_pc =/= branchIn.predicted_pc
  val snpc_mispredict = branchSnpc       =/= branchIn.predicted_pc
  val trap_mispredict = trap_target_pc   =/= branchIn.predicted_pc
  val branch_mispredict = Mux(bru_redirect , dnpc_mispredict,
                          Mux(trapSelected, trap_mispredict, snpc_mispredict))

  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    val event = io.frp_event.get
    event.valid := exu_fire
    event.rdWen := ex_in.bits.rd_wen
    event.rdAddr := ex_in.bits.rd_addr
    event.bitTest := ex_in.bits.frp_bit_test.get
    event.bitState := rs1_val
    event.zeroBranch := ex_in.bits.frp_zero_branch.get
    event.branchPc := ex_in.bits.pc
    event.testReg := ex_in.bits.frp_test_reg.get
    event.branchBeqz := ex_in.bits.frp_branch_beqz.get

    io.branch_resolve.frp_owned.get := branchIn.frp_owned.get
    io.branch_resolve.frp_update.get :=
      0.U.asTypeOf(new FastRecurrenceUpdateBundle)
  }

  val is_load = ex_in.bits.mem_bytes =/= MEM_NONE && !ex_in.bits.mem_wen

  io.out.bits.pc      := io.in.bits.pc
  io.out.bits.addr    := io.in.bits.addr
  io.out.bits.mem_wdata := rs2_val
  io.out.bits.mem_wen := ex_in.bits.mem_wen
  io.out.bits.late_data.token := Mux(
    ex_in.bits.csr_ctrl =/= CSR_NONE,
    Mux(ex_in.bits.csr_ctrl(2),
      0.U.asTypeOf(new LateOperandBundle),
      ex_in.bits.rs1_late),
    ex_in.bits.rs2_late)
  // Issue carries only producer identity/age metadata.  Capture the resolved
  // architectural store/CSR value here, after the Ex1 forwarding mux, so a
  // producer value cannot feed back into the next Issue payload register.
  io.out.bits.late_data.value := Mux(
    ex_in.bits.csr_ctrl =/= CSR_NONE,
    Mux(ex_in.bits.csr_ctrl(2), ex_in.bits.imm, rs1_val),
    rs2_val)

  if (CONFIG_SIMULATION) {
    when(exu_fire && sideBranch) {
      assert(!io.side.flat_rs1 && !io.side.flat_rs2,
        "slot1 branch must not use the same-group ALU flat bypass")
    }
    LateOperandForward.assertIdentity(
      ex_in.bits.rs1_late, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, io.forwardWb, ex_in.bits.rs1_assert_addr.get,
      exu_fire && ex_in.bits.rs1_need.orR, "main Ex1 rs1")
    LateOperandForward.assertIdentity(
      ex_in.bits.rs2_late, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, io.forwardWb, ex_in.bits.rs2_assert_addr.get,
      exu_fire && ex_in.bits.rs2_need.orR, "main Ex1 rs2")
    LateOperandForward.assertIdentity(
      branchIn.rs1_late, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, io.forwardWb, branchIn.rs1_assert_addr.get,
      exu_fire && sideBranch && branchIn.rs1_need.orR,
      "slot1 branch rs1")
    LateOperandForward.assertIdentity(
      branchIn.rs2_late, io.forwardEx2, io.forwardEx3,
      io.forwardEx4, io.forwardWb, branchIn.rs2_assert_addr.get,
      exu_fire && sideBranch && branchIn.rs2_need.orR,
      "slot1 branch rs2")
  }

  val reg_val =
    Mux(ex_in.bits.csr_ctrl =/= CSR_NONE, io.csr_rdata, alu_out)

  io.out.bits.reg_data := reg_val
  io.out.bits.mdu_ctrl := mdu_ctrl
  io.out.bits.L_sign := ex_in.bits.L_sign
  io.out.bits.mem_bytes := ex_in.bits.mem_bytes
  io.out.bits.rd_addr := ex_in.bits.rd_addr
  io.out.bits.rd_wen := ex_in.bits.rd_wen
  io.out.bits.is_load := is_load
  io.out.bits.csr_ctrl := ex_in.bits.csr_ctrl
  io.out.bits.csr_mask := ex_in.bits.csr_mask
  io.out.bits.trap_pc := ex_in.bits.pc
  io.out.bits.envir := ex_in.bits.envir
  io.out.bits.when := ex_in.bits.when

  io.bpu_update_en :=
    (is_branch_inst || branchJump) && exu_fire
  io.bpu_update_pc := branchPc
  if (CONFIG_BRANCH_RAS) {
    io.bpu_update_ras_push.get :=
      branchIn.ras_push.get && exu_fire
    io.bpu_update_ras_pop.get :=
      branchIn.ras_pop.get && exu_fire
    io.bpu_update_ras_addr.get := branchSnpc
  }

  io.branch_resolve.predicted_pc := branchIn.predicted_pc
  io.branch_resolve.predicted_taken := branchIn.predicted_taken
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    io.branch_resolve.is_branch.get := is_branch_inst
  }
  if (CONFIG_BP_TAGE) {
    io.branch_resolve.tage_meta.get := branchIn.tage_meta.get
  }
  if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
    io.branch_resolve.loop_meta.get := branchIn.loop_meta.get
  }
  io.branch_resolve.actual_pc    := actual_pc
  io.branch_resolve.actual_taken := actual_taken
  // Resolution is an event, not a level.  A branch held in Ex1 by an older
  // WB/backend stall must not redirect until the whole group advances.
  io.branch_resolve.mispredict   := branch_mispredict && exu_fire

  io.rd.wen  := ex_in.bits.rd_wen
  io.rd.addr := ex_in.bits.rd_addr
  io.rd.when := ex_in.bits.when
  io.rd.producerType := producerType(is_load, mdu_ctrl)
  io.reg_val := reg_val

  io.mul_out := MUL.io.dout
  io.mulbe_out := MUL.io.mulbeDout
  io.div_out := DIV.io.dout
  io.div_busy := DIV.io.busy
  io.div_done := DIV.io.done

  // A slot-1 redirect is the architectural next PC of slot 1, while slot 0
  // still retires to its sequential successor (which is slot 1's own PC).
  io.out.bits.pc_next :=
    Mux(sideBranch, ex_in.bits.snpc, io.branch_resolve.actual_pc)
  io.side_branch_pc_next :=
    Mux(sideBranch, io.branch_resolve.actual_pc, io.side.snpc)
}
