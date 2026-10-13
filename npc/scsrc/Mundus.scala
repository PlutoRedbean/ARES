/*****************************************************************
 * Mundus Processor Core
 *
 * To be optimized:
 *   仿真环境参数显示
 *   valid logic for units
 *   div 控制电路优化
 *   mul 的符号位放在 iss 阶段计算
 *   one-hot coding optimization (Mux FSM)
 *   清除掉没用的信号
 *   Multiple same functions repeated
 *   debug process optimization
 *   区分 jal，jalr/branch 的预测错误惩罚
 *   清除掉没用的import
 **/
package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import DeviceParams._
import RISCV_INST._
import Func._
import MDUParams._
import ALUParams._
import DPUParams._
import StoreForward._

class Mundus extends Module {
  val io = IO(new Bundle {
    val irom  = new IROM()
    val perip = new PERIP()
    val interrupt = Input(Bool())
  })

  /*===========================================================================*/
  // 1. Signal Declarations
  /*===========================================================================*/

  val ifu_valid = Wire(Bool())
  val idu_valid = Wire(Bool())
  val iss_valid = Wire(Bool())
  val ex1_valid = Wire(Bool())
  val ex2_valid = Wire(Bool())
  val ex3_valid = Wire(Bool())
  val ex4_valid = Wire(Bool())
  val exu_valid = Wire(Bool())
  val wbu_valid = Wire(Bool())

  val ifu_ready = Wire(Bool())
  val idu_ready = Wire(Bool())
  val iss_ready = Wire(Bool())
  val ex1_ready = Wire(Bool())
  val ex2_ready = Wire(Bool())
  val ex3_ready = Wire(Bool())
  val ex4_ready = Wire(Bool())
  val exu_ready = Wire(Bool())
  val wbu_ready = Wire(Bool())

  val ifu_stall     = Wire(Bool())
  val if_id_stall   = Wire(Bool())
  val id_iss_stall  = Wire(Bool())
  val iss_ex1_stall = Wire(Bool())
  val ex1_ex2_stall = Wire(Bool())
  val ex2_ex3_stall = Wire(Bool())
  val ex3_ex4_stall = Wire(Bool())
  val ex4_wb_stall  = Wire(Bool())

  val if_id_bubble   = Wire(Bool())
  val id_iss_bubble  = Wire(Bool())
  val iss_ex1_bubble = Wire(Bool())
  val ex1_ex2_bubble = Wire(Bool())
  val ex2_ex3_bubble = Wire(Bool())
  val ex3_ex4_bubble = Wire(Bool())
  val ex4_wb_bubble  = Wire(Bool())

  val long_stall_wb  = Wire(Bool())
  val long_in_flight = Wire(Bool())
  val backend_stall  = Wire(Bool())
  val localEx1Hold   = Wire(Bool())

  val data_hazard    = Wire(Bool())
  val control_hazard = Wire(Bool())
  val load_miss_replay = Wire(Bool())
  val frontend_redirect = Wire(Bool())
  val interrupt_take = Wire(Bool())
  val interrupt_hold = Wire(Bool())
  val interrupt_target = Wire(UInt(PC_DATA_WIDTH.W))

  val ex1Producer = Wire(new ForwardProducerGroup)
  val ex2Producer = Wire(new ForwardProducerGroup)
  val ex3Producer = Wire(new ForwardProducerGroup)
  val ex4Producer = Wire(new ForwardProducerGroup)
  val wbProducer = Wire(new ForwardProducerGroup)
  val issueProducer = Wire(new ForwardProducerGroup)

  val gprWb = Wire(Vec(DualIssue.Width, new GPRWriteBackBundle))
  val gprRs1Addr =
    Wire(Vec(DualIssue.Width, UInt(GPR_ADDR_WIDTH.W)))
  val gprRs2Addr =
    Wire(Vec(DualIssue.Width, UInt(GPR_ADDR_WIDTH.W)))
  val gprRs1Value =
    Wire(Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W)))
  val gprRs2Value =
    Wire(Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W)))
  val gprReadEnable = Wire(Bool())

  val ex1_bpu_update_en = Wire(Bool())
  val ex1_bpu_update_pc = Wire(UInt(PC_DATA_WIDTH.W))
  val ex1_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val ex1_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val ex1_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Wire(UInt(PC_DATA_WIDTH.W))) else None
  val ex1_branch_resolve = Wire(new BranchResolveBundle)
  val delayed_branch_resolve = Wire(new BranchResolveBundle)
  val hzu_bpu_update_en = Wire(Bool())
  val hzu_bpu_update_pc = Wire(UInt(PC_DATA_WIDTH.W))
  val hzu_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val hzu_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val hzu_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Wire(UInt(PC_DATA_WIDTH.W))) else None
  val hzu_branch_resolve = Wire(new BranchResolveBundle)

  /*===========================================================================*/
  // 2. Module Instantiations
  /*===========================================================================*/

  val GPR          = Module(new RegisterFile)
  val IFU          = Module(new IFU)
  val IDU          = Module(new GroupIDU)
  val ISU          = Module(new GroupISU)
  val EXU          = Module(new EXU)
  val IntegerLanes = Module(new GroupIntegerLanes)
  val FrpTracker = if (CONFIG_BRANCH_FAST_RECURRENCE)
    Some(Module(new FrpPredicateTracker)) else None
  val WBU          = Module(new GroupWBU)
  val HZU          = Module(new HZU)

  /*===========================================================================*/
  // 3. Datapath & Pipeline Stages
  /*===========================================================================*/

  /*---------------------------------------------------------------------------*/
  // 通用模块静态连接
  /*---------------------------------------------------------------------------*/
  GPR.io.clk    := clock
  GPR.io.ren    := gprReadEnable
  GPR.io.wen0   := gprWb(0).wen && WBU.io.gprWriteMask(0)
  GPR.io.waddr0 := gprWb(0).addr
  GPR.io.wdata0 := gprWb(0).data
  GPR.io.wen1   := gprWb(1).wen && WBU.io.gprWriteMask(1)
  GPR.io.waddr1 := gprWb(1).addr
  GPR.io.wdata1 := gprWb(1).data
  GPR.io.raddr1_0 := gprRs1Addr(0)
  GPR.io.raddr2_0 := gprRs2Addr(0)
  GPR.io.raddr1_1 := gprRs1Addr(1)
  GPR.io.raddr2_1 := gprRs2Addr(1)
  gprRs1Value(0) := GPR.io.rdata1_0
  gprRs2Value(0) := GPR.io.rdata2_0
  gprRs1Value(1) := GPR.io.rdata1_1
  gprRs2Value(1) := GPR.io.rdata2_1

  assert(!(GPR.io.wen0 && GPR.io.wen1 &&
    GPR.io.waddr0 =/= 0.U &&
    GPR.io.waddr0 === GPR.io.waddr1),
    "physical register writes must resolve same-group WAW before the GPR")

  /*---------------------------------------------------------------------------*/
  // IFU: Instruction Fetch Unit
  /*---------------------------------------------------------------------------*/
  IFU.io.irom          <> io.irom
  IFU.io.bpu_update_en := hzu_bpu_update_en
  IFU.io.bpu_update_pc := hzu_bpu_update_pc
  IFU.io.bpu_update_target := hzu_branch_resolve.actual_pc
  if (CONFIG_BRANCH_RAS) {
    IFU.io.bpu_update_ras_push.get := hzu_bpu_update_ras_push.get
    IFU.io.bpu_update_ras_pop.get := hzu_bpu_update_ras_pop.get
    IFU.io.bpu_update_ras_addr.get := hzu_bpu_update_ras_addr.get
  }
  IFU.io.actual_taken  := hzu_branch_resolve.actual_taken
  IFU.io.redirected    := frontend_redirect
  // Load misses recover inside Ex1; interrupts take priority over resolved
  // control flow when redirecting the frontend.
  IFU.io.redirected_pc := Mux(interrupt_take,
    interrupt_target,
    hzu_branch_resolve.actual_pc)
  IFU.io.consume_count := IDU.io.consumeCount
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    IFU.io.bpu_update_is_branch.get := hzu_branch_resolve.is_branch.get
  }
  if (CONFIG_BP_TAGE) {
    IFU.io.bpu_update_tage_meta.get := hzu_branch_resolve.tage_meta.get
  }
  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    IFU.io.bpu_update_frp_owned.get := hzu_branch_resolve.frp_owned.get
    IFU.io.bpu_update_frp.get := hzu_branch_resolve.frp_update.get
  }

  ifu_valid := IFU.io.out.valid
  ifu_ready := IFU.io.ready

  /*---------------------------------------------------------------------------*/
  // The continuous instruction queue remains the IF/ID storage.  Decode tells
  // it whether the selected oldest prefix contains one or two instructions.
  IDU.io.in <> IFU.io.out
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // IDU: Instruction Decode Unit
  /*---------------------------------------------------------------------------*/
  idu_valid     := IDU.io.out.valid
  idu_ready     := IDU.io.in.ready

  /*---------------------------------------------------------------------------*/
  // ID -> IS synchronous-read stage and elastic holding queue.  Decode first
  // launches the GPR read and registers its group.  One cycle later the group
  // and operands enter a small circular queue.  Queue admission depends only
  // on registered occupancy, so a current ISU interlock cannot propagate back
  // through IDU into the fetch queue.
  // Two body entries plus decodeReadBits absorb short issue stalls without
  // building a wide, four-way operand mux in front of ISU.
  private val IssueHoldingDepth = 2
  private val IssueHoldingPtrWidth = log2Ceil(IssueHoldingDepth)
  private val IssueHoldingCountWidth = log2Ceil(IssueHoldingDepth + 1)

  // Map the architectural redirect flush onto the queue-control flops'
  // synchronous reset pins.  Keeping it out of their D-input update muxes
  // prevents the late branch redirect from being factored through the issue
  // ready/dequeue cone while preserving the same edge-visible state.
  val issueHoldingFlushReset = reset.asBool || frontend_redirect
  val decodeReadValid = withReset(issueHoldingFlushReset) {
    RegInit(false.B)
  }
  val decodeReadBits = Reg(new ID_IS_Group)
  val issueHolding = Reg(Vec(IssueHoldingDepth, new ID_IS_HoldingEntry))
  val issueHoldingHead = withReset(issueHoldingFlushReset) {
    RegInit(0.U(IssueHoldingPtrWidth.W))
  }
  val issueHoldingTail = withReset(issueHoldingFlushReset) {
    RegInit(0.U(IssueHoldingPtrWidth.W))
  }
  val issueHoldingCount = withReset(issueHoldingFlushReset) {
    RegInit(0.U(IssueHoldingCountWidth.W))
  }

  private def issueHoldingPtrNext(ptr: UInt): UInt =
    Mux(ptr === (IssueHoldingDepth - 1).U, 0.U, ptr + 1.U)

  val issueHoldingHasSpace =
    issueHoldingCount =/= IssueHoldingDepth.U
  val decodeReadAdvance = decodeReadValid && issueHoldingHasSpace
  val decodeReadReady = !decodeReadValid || issueHoldingHasSpace
  IDU.io.out.ready := decodeReadReady && !frontend_redirect
  val decodeReadFire = IDU.io.out.fire && !frontend_redirect
  gprReadEnable := decodeReadFire

  val issueHoldingHeadEntry = issueHolding(issueHoldingHead)
  ISU.io.in.valid := issueHoldingCount =/= 0.U
  ISU.io.in.bits := issueHoldingHeadEntry.group
  ISU.io.gprRs1 := issueHoldingHeadEntry.gprRs1
  ISU.io.gprRs2 := issueHoldingHeadEntry.gprRs2
  ISU.io.preparedAddr := issueHoldingHeadEntry.preparedAddr

  val issueHoldingEnqueue = decodeReadAdvance
  val issueHoldingDequeue = ISU.io.out.fire

  private def refreshFromWriteback(addr: UInt, base: UInt): UInt = {
    val lane0Hit =
      gprWb(0).wen && WBU.io.gprWriteMask(0) &&
        gprWb(0).addr =/= 0.U && gprWb(0).addr === addr
    val lane1Hit =
      gprWb(1).wen && WBU.io.gprWriteMask(1) &&
        gprWb(1).addr =/= 0.U && gprWb(1).addr === addr
    Mux(lane1Hit, gprWb(1).data,
      Mux(lane0Hit, gprWb(0).data, base))
  }

  when(!frontend_redirect) {
    when(decodeReadFire) {
      decodeReadValid := true.B
      decodeReadBits := IDU.io.out.bits
    }.elsewhen(decodeReadAdvance) {
      decodeReadValid := false.B
    }

    // A queued group can outlive the producer that supplied its original RF
    // snapshot.  Keep every waiting base value coherent with architectural
    // writeback; lane 1 has the same younger-write priority as the GPR.
    for (entry <- 0 until IssueHoldingDepth) {
      for (lane <- 0 until DualIssue.Width) {
        val refreshedRs1 = refreshFromWriteback(
          issueHolding(entry).group.lane(lane).rs1_addr,
          issueHolding(entry).gprRs1(lane))
        issueHolding(entry).gprRs1(lane) := refreshedRs1
        issueHolding(entry).gprRs2(lane) := refreshFromWriteback(
          issueHolding(entry).group.lane(lane).rs2_addr,
          issueHolding(entry).gprRs2(lane))
        issueHolding(entry).preparedAddr(lane) :=
          refreshedRs1 + issueHolding(entry).group.lane(lane).imm
      }
    }

    when(issueHoldingEnqueue) {
      issueHolding(issueHoldingTail).group := decodeReadBits
      for (lane <- 0 until DualIssue.Width) {
        val enqueueRs1 = refreshFromWriteback(
          decodeReadBits.lane(lane).rs1_addr, gprRs1Value(lane))
        issueHolding(issueHoldingTail).gprRs1(lane) := enqueueRs1
        issueHolding(issueHoldingTail).gprRs2(lane) :=
          refreshFromWriteback(
            decodeReadBits.lane(lane).rs2_addr, gprRs2Value(lane))
        issueHolding(issueHoldingTail).preparedAddr(lane) :=
          enqueueRs1 + decodeReadBits.lane(lane).imm
      }
      issueHoldingTail := issueHoldingPtrNext(issueHoldingTail)
    }
    when(issueHoldingDequeue) {
      issueHoldingHead := issueHoldingPtrNext(issueHoldingHead)
    }
    issueHoldingCount :=
      issueHoldingCount + issueHoldingEnqueue - issueHoldingDequeue
  }

  ISU.io.longStallWb := long_stall_wb
  ISU.io.longInFlight := long_in_flight
  ISU.io.flush := frontend_redirect
  ISU.io.loadPortBlocked := EXU.io.load_port_blocked
  ISU.io.storeBufferEmpty := EXU.io.store_buffer_empty
  ISU.io.systemInFlight := EXU.io.system_in_flight

  issueProducer := 0.U.asTypeOf(new ForwardProducerGroup)
  issueProducer.laneValid :=
    Mux(ISU.io.out.valid, ISU.io.out.bits.laneValid, 0.U)
  for (lane <- 0 until DualIssue.Width) {
    issueProducer.rd(lane).wen := ISU.io.out.bits.lane(lane).rd_wen
    issueProducer.rd(lane).addr := ISU.io.out.bits.lane(lane).rd_addr
    issueProducer.rd(lane).when := ISU.io.out.bits.lane(lane).when
  }
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // ISU: Issue/Register Read Unit
  /*---------------------------------------------------------------------------*/
  iss_valid := ISU.io.out.valid
  iss_ready := ISU.io.in.ready

  // The GPR is read synchronously when ID enters decodeReadBits.  Its result is
  // attached to the same group on the following queue-enqueue edge.
  for (lane <- 0 until DualIssue.Width) {
    gprRs1Addr(lane) := IDU.io.out.bits.lane(lane).rs1_addr
    gprRs2Addr(lane) := IDU.io.out.bits.lane(lane).rs2_addr
  }

  assert(issueHoldingCount <= IssueHoldingDepth.U,
    "decode/issue holding queue occupancy exceeded its capacity")
  assert(!decodeReadValid || isDualLanePrefix(decodeReadBits.laneValid),
    "decode/GPR-read group mask must be a contiguous oldest prefix")
  assert(!ISU.io.in.valid || isDualLanePrefix(ISU.io.in.bits.laneValid),
    "decode/issue holding group mask must be a contiguous oldest prefix")

  /*---------------------------------------------------------------------------*/
  // IS -> EX Pipeline Register
  val issEx1Group = Wire(Decoupled(new IS_EX_Group))
  pipelineConnect(
    ISU.io.out, issEx1Group, iss_ex1_stall, iss_ex1_bubble,
    frontend_redirect)
  // Replay needs only the producer stage and lane selected by Issue.  Capture
  // that compact classification beside the Issue -> Ex1 payload instead of
  // rebuilding it from both wide operand tokens on the load-miss edge.
  private def loadReplayDependencyMask(
      group: IS_EX_Group,
      where: Int,
      requireLoadSpec: Boolean): UInt =
    VecInit((0 until DualIssue.Width).map { producerLane =>
      (0 until DualIssue.Width).flatMap { consumerLane =>
        val lane = group.lane(consumerLane)
        Seq(
          (lane.rs1_need, lane.rs1_late),
          (lane.rs2_need, lane.rs2_late)).map { case (need, operand) =>
          group.laneValid(consumerLane) && need.orR && operand.pending &&
            operand.stage(where) && operand.lane === producerLane.U &&
            ((!requireLoadSpec).B || operand.loadSpec)
        }
      }.reduce(_ || _)
    }).asUInt

  val issueReplayDepEx2 = loadReplayDependencyMask(
    ISU.io.out.bits, WHR_IDX_EX2, requireLoadSpec = true)
  val issueReplayDepEx3 = loadReplayDependencyMask(
    ISU.io.out.bits, WHR_IDX_EX3, requireLoadSpec = false)
  val ex1ReplayDepEx2 = RegInit(0.U(DualIssue.Width.W))
  val ex1ReplayDepEx3 = RegInit(0.U(DualIssue.Width.W))
  // The baseline resolves store conflicts beside Issue.  The experimental
  // path elaborates none of this AGU/comparator cone and validates the
  // registered request in Ex2 instead.
  val issueMemoryValid = Wire(Vec(DualIssue.Width, Bool()))
  for (lane <- 0 until DualIssue.Width) {
    issueMemoryValid(lane) :=
      ISU.io.out.bits.laneValid(lane) &&
        ISU.io.out.bits.lane(lane).mem_bytes =/= MEM_NONE
  }
  val issueMemory = Mux(
    issueMemoryValid(1),
    ISU.io.out.bits.lane(1),
    ISU.io.out.bits.lane(0))
  val issueStoreAddressMatch = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    0.U(3.W)
  } else {
    val issueLoadMask = byteEnable(issueMemory.addr, issueMemory.mem_bytes)
    VecInit((0 until 3).map { stage =>
      val store = EXU.io.stores(stage)
      store.valid && store.addrValid &&
        store.addr(MEM_ADDR_WIDTH - 1, 2) ===
          issueMemory.addr(MEM_ADDR_WIDTH - 1, 2) &&
        (store.byteMask & issueLoadMask).orR
    }).asUInt
  }
  val issueOlderStoreValid = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    0.U(3.W)
  } else {
    VecInit((0 until 3).map(EXU.io.stores(_).valid)).asUInt
  }
  val dc1StoreAddressMatch = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    WireDefault(0.U(3.W))
  } else {
    Reg(UInt(3.W))
  }
  val dc1OlderStoreValid = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    WireDefault(0.U(3.W))
  } else {
    Reg(UInt(3.W))
  }
  val heldEx1LateValid = RegInit(false.B)
  val heldEx1Rs1Late =
    Reg(Vec(DualIssue.Width, new LateOperandStateBundle))
  val heldEx1Rs2Late =
    Reg(Vec(DualIssue.Width, new LateOperandStateBundle))
  val heldEx1Rs1Selected =
    Reg(Vec(DualIssue.Width, Bool()))
  val heldEx1Rs2Selected =
    Reg(Vec(DualIssue.Width, Bool()))
  val effectiveEx1Group = WireDefault(issEx1Group.bits)
  when(heldEx1LateValid) {
    for (lane <- 0 until DualIssue.Width) {
      effectiveEx1Group.lane(lane).rs1_late :=
        heldEx1Rs1Late(lane).token
      effectiveEx1Group.lane(lane).rs2_late :=
        heldEx1Rs2Late(lane).token
      when(heldEx1Rs1Selected(lane)) {
        effectiveEx1Group.lane(lane).rs1_val :=
          heldEx1Rs1Late(lane).value
        effectiveEx1Group.lane(lane).alu_din1 :=
          heldEx1Rs1Late(lane).value
      }
      when(heldEx1Rs2Selected(lane)) {
        effectiveEx1Group.lane(lane).rs2_val :=
          heldEx1Rs2Late(lane).value
        effectiveEx1Group.lane(lane).alu_din2 :=
          heldEx1Rs2Late(lane).value
      }
    }
  }
  // Memory bases cannot leave Issue with a late token, so the final AGU result
  // is already resident in the Issue -> Ex1 payload.  In particular, a held
  // operand refresh must not put a mux back in front of address generation.

  private def advanceHeldEx1(
      operand: LateOperandStateBundle): LateOperandStateBundle =
    LateOperandForward.advance(
      operand, ex2Producer, ex3Producer, ex4Producer, wbProducer)

  private def heldOperandState(
      value: UInt,
      token: LateOperandBundle): LateOperandStateBundle = {
    val state = Wire(new LateOperandStateBundle)
    state.value := value
    state.token := token
    state
  }

  // A held Ex1 group advances its late-operand tokens on the same edge as the
  // older producer stages.  Rebuild the two compact replay bits from those
  // *next* tokens so a cache hit that captures an operand also clears the
  // corresponding replay dependency immediately.  Only token metadata reaches
  // these registers; the wide forwarded value is dead and is removed by FIRRTL.
  private def advancedLoadReplayDependencyMask(
      group: IS_EX_Group,
      where: Int,
      requireLoadSpec: Boolean): UInt =
    VecInit((0 until DualIssue.Width).map { producerLane =>
      (0 until DualIssue.Width).flatMap { consumerLane =>
        val lane = group.lane(consumerLane)
        Seq(
          (lane.rs1_need, lane.rs1_late),
          (lane.rs2_need, lane.rs2_late)).map { case (need, operand) =>
          val advanced = advanceHeldEx1(
            heldOperandState(0.U(REG_DATA_WIDTH.W), operand)).token
          group.laneValid(consumerLane) && need.orR && advanced.pending &&
            advanced.stage(where) && advanced.lane === producerLane.U &&
            ((!requireLoadSpec).B || advanced.loadSpec)
        }
      }.reduce(_ || _)
    }).asUInt

  // DC1 receives the registered issue group.  The D-cache lookup launched
  // when this group left Iss is side-effect-free; only the registered DC1
  // request is held when an older store can affect it.  The current Ex1 slot
  // is this load itself, so only Ex2..Ex4 can contain older in-flight stores.
  val dc1MemoryValid = Wire(Vec(DualIssue.Width, Bool()))
  for (lane <- 0 until DualIssue.Width) {
    dc1MemoryValid(lane) :=
      issEx1Group.valid && effectiveEx1Group.laneValid(lane) &&
        effectiveEx1Group.lane(lane).mem_bytes =/= MEM_NONE
  }
  val dc1MemoryOwner1 = dc1MemoryValid(1)
  val dc1Memory = Mux(
    dc1MemoryOwner1,
    effectiveEx1Group.lane(1),
    effectiveEx1Group.lane(0))
  val dc1LoadValid =
    dc1MemoryValid.asUInt.orR && !dc1Memory.mem_wen
  val dc1LoadMask = byteEnable(dc1Memory.addr, dc1Memory.mem_bytes)
  // Every current store producer supplies its final AGU address in Ex1.
  // Consequently DC1 consumes only the registered Issue comparison instead
  // of rebuilding a wide address comparator on the Ex1 hold path.
  val dc1UnknownStoreAddress = false.B
  val dc1StoreOverlap =
    !CONFIG_LSU_EX2_STORE_REPLAY.B && dc1StoreAddressMatch.orR
  val dc1StoreDataUnavailable = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    false.B
  } else {
    (1 until 4).map { stage =>
      dc1StoreAddressMatch(stage - 1) &&
        !EXU.io.stores(stage).dataValid
    }.reduce(_ || _)
  }
  val dc1AnyOlderStore = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    VecInit((1 until 4).map(EXU.io.stores(_).valid)).asUInt.orR ||
      !EXU.io.store_buffer_empty
  } else {
    dc1OlderStoreValid.orR || !EXU.io.store_buffer_empty
  }
  val dc1Cacheable =
    dc1Memory.addr(31, 18) === "b1000_0000_0001_00".U(14.W)
  val dc1StoreHazard =
    !CONFIG_LSU_EX2_STORE_REPLAY.B && dc1LoadValid &&
      (dc1UnknownStoreAddress || dc1StoreOverlap)
  val dc1MmioHazard =
    dc1LoadValid && !dc1Cacheable && dc1AnyOlderStore
  val dc1LoadHazard = dc1StoreHazard || dc1MmioHazard

  val ex2ReplayLoadMask =
    byteEnable(EXU.io.lsu_ex2_addr, EXU.io.lsu_ex2_bytes)
  val ex2StoreAddressMatch = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    VecInit((2 until 4).map { stage =>
      val store = EXU.io.stores(stage)
      store.valid && store.addrValid &&
        store.addr(MEM_ADDR_WIDTH - 1, 2) ===
          EXU.io.lsu_ex2_addr(MEM_ADDR_WIDTH - 1, 2) &&
        (store.byteMask & ex2ReplayLoadMask).orR
    }).asUInt
  } else {
    0.U(2.W)
  }
  val ex2StoreDataUnavailable = if (CONFIG_LSU_EX2_STORE_REPLAY) {
    (2 until 4).map { stage =>
      ex2StoreAddressMatch(stage - 2) &&
        !EXU.io.stores(stage).dataValid
    }.reduce(_ || _)
  } else {
    false.B
  }
  val ex2StoreReplayConflict =
    CONFIG_LSU_EX2_STORE_REPLAY.B && EXU.io.lsu_ex2_load_valid &&
      ex2StoreAddressMatch.orR
  EXU.io.store_replay_conflict := ex2StoreReplayConflict

  // A group retained in front of Ex1 advances its late-operand token with
  // the older producer stages.  If a branch token reaches WB while the group
  // is held, keep it for one final cycle so heldEx1Rs*Late captures the WB
  // value into a register and clears the token.  Releasing it immediately
  // would either require the removed WB/MDU -> BRU combinational path or use
  // an invalid zero WB arm in Ex1.
  val heldBranchWbPending = heldEx1LateValid &&
    VecInit((0 until DualIssue.Width).map { lane =>
      val issued = issEx1Group.bits.lane(lane)
      val isControl = issued.bru_ctrl.orR || issued.jump
      issEx1Group.bits.laneValid(lane) && isControl &&
        ((heldEx1Rs1Late(lane).token.pending &&
          heldEx1Rs1Late(lane).token.stage(WHR_IDX_WB)) ||
         (heldEx1Rs2Late(lane).token.pending &&
          heldEx1Rs2Late(lane).token.stage(WHR_IDX_WB)))
    }).asUInt.orR

  localEx1Hold :=
    IntegerLanes.io.holdEx1 || EXU.io.load_miss_hold ||
      EXU.io.store_replay_hold || dc1LoadHazard || heldBranchWbPending
  val heldStagesAdvance = !(long_stall_wb || backend_stall)
  if (!CONFIG_LSU_EX2_STORE_REPLAY) {
    when(localEx1Hold && issEx1Group.valid) {
      // The retained load stays in DC1 while older stores drain.  Move both
      // tokens with those stores so each bit retains its stage identity.
      when(heldStagesAdvance) {
        dc1StoreAddressMatch := (dc1StoreAddressMatch << 1)(2, 0)
        dc1OlderStoreValid := (dc1OlderStoreValid << 1)(2, 0)
      }
    }.elsewhen(ISU.io.out.ready) {
      dc1StoreAddressMatch := issueStoreAddressMatch
      dc1OlderStoreValid := issueOlderStoreValid
    }
  }
  when(frontend_redirect) {
    ex1ReplayDepEx2 := 0.U
    ex1ReplayDepEx3 := 0.U
  }.elsewhen(localEx1Hold && issEx1Group.valid) {
    when(heldStagesAdvance) {
      ex1ReplayDepEx2 := advancedLoadReplayDependencyMask(
        effectiveEx1Group, WHR_IDX_EX2, requireLoadSpec = true)
      ex1ReplayDepEx3 := advancedLoadReplayDependencyMask(
        effectiveEx1Group, WHR_IDX_EX3, requireLoadSpec = false)
    }
  }.elsewhen(ISU.io.out.ready) {
    ex1ReplayDepEx2 := issueReplayDepEx2
    ex1ReplayDepEx3 := issueReplayDepEx3
  }
  when(frontend_redirect) {
    heldEx1LateValid := false.B
  }.elsewhen(localEx1Hold && issEx1Group.valid && !heldEx1LateValid) {
    heldEx1LateValid := true.B
    for (lane <- 0 until DualIssue.Width) {
      val rs1State = heldOperandState(
        issEx1Group.bits.lane(lane).rs1_val,
        issEx1Group.bits.lane(lane).rs1_late)
      val rs2State = heldOperandState(
        issEx1Group.bits.lane(lane).rs2_val,
        issEx1Group.bits.lane(lane).rs2_late)
      heldEx1Rs1Late(lane) := Mux(
        heldStagesAdvance,
        advanceHeldEx1(rs1State), rs1State)
      heldEx1Rs2Late(lane) := Mux(
        heldStagesAdvance,
        advanceHeldEx1(rs2State), rs2State)
      heldEx1Rs1Selected(lane) :=
        issEx1Group.bits.lane(lane).rs1_late.pending
      heldEx1Rs2Selected(lane) :=
        issEx1Group.bits.lane(lane).rs2_late.pending
    }
  }.elsewhen(heldEx1LateValid) {
    // A local miss can resolve while scalar Ex1 remains unready.  Older side
    // stages still drain in that interval, so keep their operand tokens in
    // lockstep until the retained group actually enters Ex1.
    when(issEx1Group.fire) {
      heldEx1LateValid := false.B
    }.elsewhen(heldStagesAdvance) {
      for (lane <- 0 until DualIssue.Width) {
        heldEx1Rs1Late(lane) := advanceHeldEx1(heldEx1Rs1Late(lane))
        heldEx1Rs2Late(lane) := advanceHeldEx1(heldEx1Rs2Late(lane))
      }
    }
  }
  assert(!heldEx1LateValid || issEx1Group.valid,
    "held Ex1 operands require a valid pipeline group")
  if (CONFIG_SIMULATION) {
    if (!CONFIG_LSU_EX2_STORE_REPLAY) {
      val referenceDc1StoreAddressMatch =
        VecInit((1 until 4).map { stage =>
          val store = EXU.io.stores(stage)
          store.valid && store.addrValid &&
            store.addr(MEM_ADDR_WIDTH - 1, 2) ===
              dc1Memory.addr(MEM_ADDR_WIDTH - 1, 2) &&
            (store.byteMask & dc1LoadMask).orR
        }).asUInt
      val referenceDc1AnyOlderStore =
        VecInit((1 until 4).map(EXU.io.stores(_).valid)).asUInt.orR
      when(dc1LoadValid && !frontend_redirect) {
        assert(dc1StoreAddressMatch === referenceDc1StoreAddressMatch,
          "registered DC1 store conflict must match live pipeline state")
        assert(dc1OlderStoreValid.orR === referenceDc1AnyOlderStore,
          "registered DC1 store occupancy must match live pipeline state")
      }
    }
    if (CONFIG_LSU_EX2_STORE_REPLAY) {
      val replayAddress = RegEnable(
        EXU.io.lsu_ex2_addr, EXU.io.store_replay_start)
      when(EXU.io.store_replay_hold && !EXU.io.store_replay_start) {
        assert(EXU.io.lsu_ex2_load_valid,
          "Ex2 store replay must retain a cacheable load")
        assert(EXU.io.lsu_ex2_addr === replayAddress,
          "Ex2 store replay must retain the original load address")
      }
      when(EXU.io.store_replay_start) {
        assert(ex2StoreReplayConflict,
          "store replay must start from a registered Ex2 conflict")
      }
    }
    for (stage <- 0 until 4) {
      assert(!EXU.io.stores(stage).valid || EXU.io.stores(stage).addrValid,
        s"store stage $stage must carry its final address")
    }
    for (lane <- 0 until DualIssue.Width) {
      val ex1MemoryValid =
        issEx1Group.valid && effectiveEx1Group.laneValid(lane) &&
          effectiveEx1Group.lane(lane).mem_bytes =/= MEM_NONE &&
          !frontend_redirect
      val previousHeldMemory = RegNext(
        ex1MemoryValid && iss_ex1_stall, false.B)
      val previousHeldAddress = RegNext(
        effectiveEx1Group.lane(lane).addr)
      when(ex1MemoryValid) {
        assert(!effectiveEx1Group.lane(lane).rs1_late.pending,
          s"Ex1 lane $lane memory base must have been captured in Issue")
        assert(effectiveEx1Group.lane(lane).addr ===
          issEx1Group.bits.lane(lane).addr,
          s"Ex1 lane $lane must use the registered Issue address")
      }
      when(previousHeldMemory && ex1MemoryValid) {
        assert(effectiveEx1Group.lane(lane).addr === previousHeldAddress,
          s"held Ex1 lane $lane memory address must remain stable")
      }
      def assertMissAdvance(
          value: UInt,
          token: LateOperandBundle,
          missValid: Bool,
          missLane: UInt,
          where: Int,
          message: String): Unit = {
        val state = heldOperandState(value, token)
        val advanced = advanceHeldEx1(state)
        when(missValid && heldStagesAdvance && token.pending &&
            token.stage(where) && token.lane === missLane) {
          assert(advanced.token.pending,
            s"$message must remain pending on a load miss")
          assert(advanced.value === state.value,
            s"$message must not capture invalid fast load data")
          assert(advanced.token.stage === (token.stage >> 1),
            s"$message must advance toward the slow WB result")
        }
      }
      val ex3LoadMiss =
        EXU.io.lsu_load_valid && !EXU.io.lsu_cache_hit
      assertMissAdvance(
        effectiveEx1Group.lane(lane).rs1_val,
        effectiveEx1Group.lane(lane).rs1_late,
        ex3LoadMiss, EXU.io.lsu_fast_lane, WHR_IDX_EX3,
        s"held Ex1 lane $lane rs1")
      assertMissAdvance(
        effectiveEx1Group.lane(lane).rs2_val,
        effectiveEx1Group.lane(lane).rs2_late,
        ex3LoadMiss, EXU.io.lsu_fast_lane, WHR_IDX_EX3,
        s"held Ex1 lane $lane rs2")
      assertMissAdvance(
        effectiveEx1Group.lane(lane).rs1_val,
        effectiveEx1Group.lane(lane).rs1_late,
        EXU.io.lsu_slow_valid, EXU.io.lsu_slow_lane, WHR_IDX_EX4,
        s"held Ex1 lane $lane rs1 slow completion")
      assertMissAdvance(
        effectiveEx1Group.lane(lane).rs2_val,
        effectiveEx1Group.lane(lane).rs2_late,
        EXU.io.lsu_slow_valid, EXU.io.lsu_slow_lane, WHR_IDX_EX4,
        s"held Ex1 lane $lane rs2 slow completion")
      LateOperandForward.assertIdentity(
        effectiveEx1Group.lane(lane).rs1_late,
        ex2Producer, ex3Producer, ex4Producer, wbProducer,
        effectiveEx1Group.lane(lane).rs1_assert_addr.get,
        issEx1Group.valid && effectiveEx1Group.laneValid(lane) &&
          !frontend_redirect && heldStagesAdvance,
        s"held Ex1 lane $lane rs1")
      LateOperandForward.assertIdentity(
        effectiveEx1Group.lane(lane).rs2_late,
        ex2Producer, ex3Producer, ex4Producer, wbProducer,
        effectiveEx1Group.lane(lane).rs2_assert_addr.get,
        issEx1Group.valid && effectiveEx1Group.laneValid(lane) &&
          !frontend_redirect && heldStagesAdvance,
        s"held Ex1 lane $lane rs2")
    }
  }
  EXU.io.in.valid := issEx1Group.valid && effectiveEx1Group.laneValid(0)
  EXU.io.in.bits := effectiveEx1Group.lane(0)
  EXU.io.side_valid :=
    issEx1Group.valid && effectiveEx1Group.laneValid(1)
  EXU.io.side := effectiveEx1Group.lane(1)
  issEx1Group.ready := EXU.io.in.ready
  val lookupMemoryValid = issueMemoryValid
  val lookupMemory = issueMemory
  val probeMemoryValid = Wire(Vec(DualIssue.Width, Bool()))
  for (lane <- 0 until DualIssue.Width) {
    probeMemoryValid(lane) :=
      ISU.io.in.valid && ISU.io.in.bits.laneValid(lane) &&
        ISU.io.in.bits.lane(lane).mem_bytes =/= MEM_NONE
  }
  val probeMemoryOwner1 = probeMemoryValid(1)
  val probeAddress = Mux(
    probeMemoryOwner1,
    issueHoldingHeadEntry.preparedAddr(1),
    issueHoldingHeadEntry.preparedAddr(0))
  EXU.io.lsu_probe_valid :=
    probeMemoryValid.asUInt.orR &&
      probeAddress(31, 18) === "b1000_0000_0001_00".U(14.W)
  EXU.io.lsu_probe_addr := probeAddress
  EXU.io.lsu_lookup_valid :=
    ISU.io.out.fire && !frontend_redirect &&
      lookupMemoryValid.asUInt.orR
  // AG0 inside the LSU captures this address before it reaches either cache
  // BRAM.  No forwarding, hazard, or issue-ready signal crosses that boundary.
  EXU.io.lsu_lookup_addr := lookupMemory.addr
  EXU.io.lsu_lookup_match := lookupMemory.cache_probe_match
  EXU.io.flush := frontend_redirect
  EXU.io.hold_ex1 := localEx1Hold
  EXU.io.replay_dep_ex2 := ex1ReplayDepEx2
  EXU.io.replay_dep_ex3 := ex1ReplayDepEx3
  EXU.io.rs1_val_ex1 := issEx1Group.bits.lane(0).rs1_val
  EXU.io.rs2_val_ex1 := issEx1Group.bits.lane(0).rs2_val
  // Pass only the pre-existing long-operation stall into the LSU request
  // qualifier. EXU adds bridge backpressure locally to all execution stages.
  EXU.io.ex1_ex2_stall := long_stall_wb
  EXU.io.ex2_ex3_stall := long_stall_wb
  EXU.io.ex3_ex4_stall := long_stall_wb
  EXU.io.ex1_ex2_bubble := ex1_ex2_bubble
  EXU.io.ex2_ex3_bubble := ex2_ex3_bubble
  EXU.io.ex3_ex4_bubble := ex3_ex4_bubble
  EXU.io.perip <> io.perip
  EXU.io.timer_interrupt := io.interrupt
  EXU.io.side_ex2 := IntegerLanes.io.ex2
  EXU.io.side_ex3 := IntegerLanes.io.ex3
  EXU.io.side_ex4 := IntegerLanes.io.ex4
  EXU.io.side_stores := IntegerLanes.io.stores
  EXU.io.side_store_valid := IntegerLanes.io.storeValid
  EXU.io.side_store := IntegerLanes.io.store
  EXU.io.wb := wbProducer
  // A DIV/REM may hold the scalar Ex1 internally without asserting the
  // group-wide WB stall.  Inject slot 1 only when slot 0 actually produces
  // this group, while older side stages continue to drain.
  // Keep pre-quash occupancy in the bypass scoreboard.  Each lane applies
  // frontend_redirect to its execution-valid bit locally.
  IntegerLanes.io.inValid := EXU.io.ex1_valid
  IntegerLanes.io.in := effectiveEx1Group
  IntegerLanes.io.lane0Value := EXU.io.ex1_reg_val
  IntegerLanes.io.branchPcNext := EXU.io.side_branch_pc_next
  IntegerLanes.io.lsuEx2Lane := EXU.io.lsu_ex2_lane
  IntegerLanes.io.lsuEx2Valid := EXU.io.lsu_ex2_valid
  IntegerLanes.io.lsuEx2CacheHit := EXU.io.lsu_ex2_cache_hit
  IntegerLanes.io.lsuEx2Rdata := EXU.io.lsu_ex2_rdata
  IntegerLanes.io.lsuEx2StoreCacheHit :=
    EXU.io.lsu_ex2_store_cache_hit
  IntegerLanes.io.lsuEx2StoreCacheData :=
    EXU.io.lsu_ex2_store_cache_data
  IntegerLanes.io.lsuFastLane := EXU.io.lsu_fast_lane
  IntegerLanes.io.lsuLoadValid := EXU.io.lsu_load_valid
  IntegerLanes.io.lsuFastValid := EXU.io.lsu_fast_valid
  IntegerLanes.io.lsuFastRd := EXU.io.lsu_fast_rd
  IntegerLanes.io.lsuFastAddr := EXU.io.lsu_fast_addr
  IntegerLanes.io.lsuFastBytes := EXU.io.lsu_fast_bytes
  IntegerLanes.io.lsuFastSign := EXU.io.lsu_fast_sign
  IntegerLanes.io.lsuSlowLane := EXU.io.lsu_slow_lane
  IntegerLanes.io.lsuSlowValid := EXU.io.lsu_slow_valid
  IntegerLanes.io.lsuSlowRd := EXU.io.lsu_slow_rd
  IntegerLanes.io.lsuSlowAddr := EXU.io.lsu_slow_addr
  IntegerLanes.io.lsuSlowBytes := EXU.io.lsu_slow_bytes
  IntegerLanes.io.lsuSlowSign := EXU.io.lsu_slow_sign
  IntegerLanes.io.lsuCacheHit := EXU.io.lsu_cache_hit
  IntegerLanes.io.lsuRdataFast := EXU.io.lsu_rdata_fast
  IntegerLanes.io.lsuRdataSlow := EXU.io.lsu_rdata_slow
  IntegerLanes.io.lsuStoreCacheHit := EXU.io.lsu_store_cache_hit
  IntegerLanes.io.lsuStoreCacheData := EXU.io.lsu_store_cache_data
  IntegerLanes.io.mainEx2Valid := EXU.io.ex2_valid
  IntegerLanes.io.mainEx2Rd := EXU.io.ex2_rd
  IntegerLanes.io.mainEx2Value := EXU.io.ex2_reg_val
  IntegerLanes.io.mainEx3Valid := EXU.io.ex3_valid
  IntegerLanes.io.mainEx3Rd := EXU.io.ex3_rd
  IntegerLanes.io.mainEx3Value := EXU.io.ex3_reg_val
  IntegerLanes.io.mainEx4Valid := EXU.io.ex4_valid
  IntegerLanes.io.mainEx4Rd := EXU.io.ex4_rd
  IntegerLanes.io.mainEx4Value := EXU.io.ex4_reg_val
  IntegerLanes.io.wb := wbProducer
  IntegerLanes.io.flush := frontend_redirect
  IntegerLanes.io.stall := long_stall_wb || backend_stall
  IntegerLanes.io.holdEx2 := EXU.io.store_replay_hold

  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    // The delayed load-pair event is older than the current Ex1 group.  The
    // tracker then applies lane 0 and lane 1 in architectural program order.
    FrpTracker.get.io.event(0) := IntegerLanes.io.frpDelayedEvent.get
    FrpTracker.get.io.event(1) := EXU.io.frp_event.get
    FrpTracker.get.io.event(2) := IntegerLanes.io.frpEvent.get
  }

  /*---------------------------------------------------------------------------*/
  // EXU: Execution Unit
  /*---------------------------------------------------------------------------*/
  ex1_valid   := EXU.io.ex1_valid
  ex2_valid   := EXU.io.ex2_valid
  ex3_valid   := EXU.io.ex3_valid
  ex4_valid   := EXU.io.ex4_valid
  ex1_ready   := EXU.io.ex1_ready
  ex2_ready   := EXU.io.ex2_ready
  ex3_ready   := EXU.io.ex3_ready
  ex4_ready   := EXU.io.ex4_ready
  exu_valid    := EXU.io.out.valid
  exu_ready    := EXU.io.in.ready
  long_in_flight := EXU.io.long_in_flight
  backend_stall := EXU.io.backend_stall

  ex1Producer := IntegerLanes.io.ex1
  ex2Producer := IntegerLanes.io.ex2
  ex3Producer := IntegerLanes.io.ex3
  ex4Producer := IntegerLanes.io.ex4
  ex1Producer.laneValid :=
    IntegerLanes.io.ex1.laneValid |
      Mux(EXU.io.ex1_present, "b01".U, 0.U)
  ex2Producer.laneValid :=
    IntegerLanes.io.ex2.laneValid | Mux(ex2_valid, "b01".U, 0.U)
  ex3Producer.laneValid :=
    IntegerLanes.io.ex3.laneValid | Mux(ex3_valid, "b01".U, 0.U)
  ex4Producer.laneValid :=
    IntegerLanes.io.ex4.laneValid | Mux(ex4_valid, "b01".U, 0.U)
  ex1Producer.rd(0) := EXU.io.ex1_rd
  ex2Producer.rd(0) := EXU.io.ex2_rd
  ex3Producer.rd(0) := EXU.io.ex3_rd
  ex4Producer.rd(0) := EXU.io.ex4_rd
  ex1Producer.value(0) := EXU.io.ex1_reg_val
  ex2Producer.value(0) := EXU.io.ex2_reg_val
  ex3Producer.value(0) := EXU.io.ex3_reg_val
  ex4Producer.value(0) := EXU.io.ex4_reg_val

  ex1_bpu_update_en  := EXU.io.bpu_update_en
  ex1_bpu_update_pc  := EXU.io.bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    ex1_bpu_update_ras_push.get := EXU.io.bpu_update_ras_push.get
    ex1_bpu_update_ras_pop.get := EXU.io.bpu_update_ras_pop.get
    ex1_bpu_update_ras_addr.get := EXU.io.bpu_update_ras_addr.get
  }
  ex1_branch_resolve := EXU.io.branch_resolve
  delayed_branch_resolve := IntegerLanes.io.delayedBranchResolve
  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    val lane1BranchSelected = EXU.io.bpu_update_en &&
      IntegerLanes.io.frpEvent.get.zeroBranch &&
      EXU.io.bpu_update_pc === IntegerLanes.io.frpEvent.get.branchPc
    ex1_branch_resolve.frp_update.get := Mux(
      lane1BranchSelected,
      FrpTracker.get.io.update(2),
      FrpTracker.get.io.update(1))
    delayed_branch_resolve.frp_update.get :=
      FrpTracker.get.io.update(0)
  }

  /*---------------------------------------------------------------------------*/
  // EX -> WB Pipeline Register
  val exGroupOut = Wire(Decoupled(new EX_WB_Group))
  exGroupOut.valid := EXU.io.out.valid
  exGroupOut.bits := IntegerLanes.io.ex4Payload
  exGroupOut.bits.laneValid :=
    IntegerLanes.io.ex4Payload.laneValid |
      Mux(EXU.io.out.valid, "b01".U, 0.U)
  exGroupOut.bits.lane(0) := EXU.io.out.bits
  EXU.io.out.ready := exGroupOut.ready
  assert(!IntegerLanes.io.ex4Payload.laneValid.orR || EXU.io.out.valid,
    "slot 1 must remain aligned with slot 0 at Ex4")

  val ex4WbGroup = Wire(Decoupled(new EX_WB_Group))
  pipelineConnect(
    exGroupOut, ex4WbGroup, ex4_wb_stall, ex4_wb_bubble)
  WBU.io.in <> ex4WbGroup

  assert(!issEx1Group.valid || isDualLanePrefix(issEx1Group.bits.laneValid),
    "ISS/EX1 group mask must be a contiguous oldest prefix")
  assert(!ISU.io.out.valid || PopCount(lookupMemoryValid) <= 1.U,
    "current shared LSU lookup accepts at most one lane candidate")
  assert(!ex4WbGroup.valid || isDualLanePrefix(ex4WbGroup.bits.laneValid),
    "EX4/WB group mask must be a contiguous oldest prefix")
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // WBU: Write-Back Unit
  /*---------------------------------------------------------------------------*/
  WBU.io.mul_out  := EXU.io.mul_out
  WBU.io.mulbe_out := EXU.io.mulbe_out
  WBU.io.side_mul_out := IntegerLanes.io.mulOut
  WBU.io.side_mulbe_out := IntegerLanes.io.mulbeOut
  WBU.io.div_out  := EXU.io.div_out
  WBU.io.div_done := EXU.io.div_done
  WBU.io.backend_stall := backend_stall

  wbu_valid := WBU.io.valid
  wbu_ready := WBU.io.in.ready

  gprWb := WBU.io.gpr
  wbProducer := WBU.io.producer

  long_stall_wb := WBU.io.long_stall

  /*
   * Take an interrupt only after all already-issued instructions have
   * retired. The front end is held while Ex1..WB drain, so interrupt_pc is
   * the exact architectural successor and no younger store can escape.
   */
  val retireNextPc = Mux(WBU.io.retireMask(1),
    WBU.io.pcNext(1), WBU.io.pcNext(0))
  val architecturalNextPc = RegInit("h80000000".U(PC_DATA_WIDTH.W))
  when(WBU.io.valid) {
    architecturalNextPc := retireNextPc
  }

  val interruptDraining = RegInit(false.B)
  val interruptBackendEmpty =
    !issEx1Group.valid && !EXU.io.ex2_valid && !EXU.io.ex3_valid &&
      !EXU.io.ex4_valid && !ex4WbGroup.valid

  interrupt_hold := interruptDraining || EXU.io.interrupt_pending
  interrupt_take := interruptDraining && interruptBackendEmpty
  interrupt_target := EXU.io.interrupt_target
  EXU.io.interrupt_take := interrupt_take
  EXU.io.interrupt_pc := architecturalNextPc

  when(EXU.io.interrupt_pending) {
    interruptDraining := true.B
  }
  when(interrupt_take) {
    interruptDraining := false.B
  }

  /*===========================================================================*/
  // 5. ISU Bypass Network
  /*===========================================================================*/
  ISU.io.ex1 := ex1Producer
  ISU.io.ex2 := ex2Producer
  ISU.io.ex3 := ex3Producer
  ISU.io.ex4 := ex4Producer
  ISU.io.wb := wbProducer

  // Pairing latency estimates are advisory; the live ISU dependency network
  // remains the correctness authority.  Register this compact producer view
  // so a current LSU/ISU interlock cannot feed decode pairing and the IFU
  // dequeue decision in the same cycle.
  val pairingIssueProducer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  val pairingEx1Producer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  val pairingEx2Producer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  val pairingEx3Producer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  val pairingEx4Producer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  val pairingWbProducer =
    RegInit(0.U.asTypeOf(new ForwardProducerGroup))
  pairingIssueProducer := issueProducer
  pairingEx1Producer := ex1Producer
  pairingEx2Producer := ex2Producer
  pairingEx3Producer := ex3Producer
  pairingEx4Producer := ex4Producer
  pairingWbProducer := wbProducer

  IDU.io.issue := pairingIssueProducer
  IDU.io.ex1 := pairingEx1Producer
  IDU.io.ex2 := pairingEx2Producer
  IDU.io.ex3 := pairingEx3Producer
  IDU.io.ex4 := pairingEx4Producer
  IDU.io.wb := pairingWbProducer

  /*===========================================================================*/
  // 6. Hazard Detect Unit
  /*===========================================================================*/

  HZU.io.ex1_valid          := ex1_valid

  HZU.io.ex1_bpu_update_en  := ex1_bpu_update_en
  HZU.io.ex1_bpu_update_pc  := ex1_bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    HZU.io.ex1_bpu_update_ras_push.get := ex1_bpu_update_ras_push.get
    HZU.io.ex1_bpu_update_ras_pop.get := ex1_bpu_update_ras_pop.get
    HZU.io.ex1_bpu_update_ras_addr.get := ex1_bpu_update_ras_addr.get
  }
  HZU.io.ex1_branch_resolve := ex1_branch_resolve

  hzu_bpu_update_en :=
    IntegerLanes.io.delayedBranchUpdate ||
      HZU.io.hzu_bpu_update_en
  hzu_bpu_update_pc := Mux(
    IntegerLanes.io.delayedBranchUpdate,
    IntegerLanes.io.delayedBranchUpdatePc,
    HZU.io.hzu_bpu_update_pc)
  if (CONFIG_BRANCH_RAS) {
    hzu_bpu_update_ras_push.get := Mux(
      IntegerLanes.io.delayedBranchUpdate,
      false.B, HZU.io.hzu_bpu_update_ras_push.get)
    hzu_bpu_update_ras_pop.get := Mux(
      IntegerLanes.io.delayedBranchUpdate,
      false.B, HZU.io.hzu_bpu_update_ras_pop.get)
    hzu_bpu_update_ras_addr.get := Mux(
      IntegerLanes.io.delayedBranchUpdate,
      0.U, HZU.io.hzu_bpu_update_ras_addr.get)
  }
  hzu_branch_resolve := Mux(
    IntegerLanes.io.delayedBranchUpdate,
    delayed_branch_resolve,
    HZU.io.hzu_branch_resolve)

  data_hazard    := ISU.io.interlock || dc1LoadHazard
  control_hazard :=
    delayed_branch_resolve.mispredict ||
      HZU.io.hzu_hazard
  load_miss_replay :=
    EXU.io.load_miss_replay || EXU.io.store_replay_start
  // Load misses retain only the affected execution group.  The frontend is
  // redirected only by resolved control flow or an accepted interrupt.
  frontend_redirect := control_hazard || interrupt_take

  val issue_hazard = !control_hazard && data_hazard

  // A DIV/REM waits in Iss while an older long operation is in flight. Iss is held
  // by stalling its upstream register and a bubble is sent to Ex1, allowing
  // older instructions to keep advancing.  A long operation waiting in Wr still has
  // to freeze the in-order pipeline until its result is available.
  ifu_stall     := long_stall_wb || backend_stall || issue_hazard || interrupt_hold
  if_id_stall   := long_stall_wb || backend_stall || issue_hazard || interrupt_hold
  id_iss_stall  := long_stall_wb || backend_stall || issue_hazard || interrupt_hold
  iss_ex1_stall := long_stall_wb || backend_stall || localEx1Hold
  ex1_ex2_stall := long_stall_wb || backend_stall
  ex2_ex3_stall := long_stall_wb || backend_stall
  ex3_ex4_stall := long_stall_wb || backend_stall
  ex4_wb_stall  := long_stall_wb || backend_stall

  if_id_bubble   := frontend_redirect
  id_iss_bubble  := frontend_redirect
  iss_ex1_bubble := frontend_redirect || issue_hazard || interrupt_hold
  ex1_ex2_bubble := interrupt_take
  ex2_ex3_bubble := interrupt_take
  ex3_ex4_bubble := interrupt_take
  ex4_wb_bubble  := interrupt_take

  /*===========================================================================*/
  // 6. Simulation
  /*===========================================================================*/

  if (CONFIG_SIMULATION) {

    dontTouch(ifu_valid)
    dontTouch(idu_valid)
    dontTouch(iss_valid)
    dontTouch(ex1_valid)
    dontTouch(ex2_valid)
    dontTouch(ex3_valid)
    dontTouch(ex4_valid)
    dontTouch(exu_valid)
    dontTouch(wbu_valid)
    dontTouch(ifu_ready)
    dontTouch(idu_ready)
    dontTouch(iss_ready)
    dontTouch(ex1_ready)
    dontTouch(ex2_ready)
    dontTouch(ex3_ready)
    dontTouch(ex4_ready)
    dontTouch(exu_ready)
    dontTouch(wbu_ready)
    dontTouch(ifu_stall)
    dontTouch(if_id_stall)
    dontTouch(id_iss_stall)
    dontTouch(iss_ex1_stall)
    dontTouch(ex1_ex2_stall)
    dontTouch(ex2_ex3_stall)
    dontTouch(ex3_ex4_stall)
    dontTouch(ex4_wb_stall)
    dontTouch(if_id_bubble)
    dontTouch(id_iss_bubble)
    dontTouch(iss_ex1_bubble)
    dontTouch(ex1_ex2_bubble)
    dontTouch(ex2_ex3_bubble)
    dontTouch(ex3_ex4_bubble)
    dontTouch(ex4_wb_bubble)

    val DPIC = Module(new Mundus_DPIC)
    DPIC.io.clk        := clock
    DPIC.io.rst        := reset
    DPIC.io.pc_next_in := retireNextPc
    DPIC.io.cycle_done := wbu_valid
    DPIC.io.interrupt_take := interrupt_take
    DPIC.io.interrupt_target := interrupt_target
    DPIC.io.retire_mask := WBU.io.retireMask
    DPIC.io.pc0 := WBU.io.pc(0)
    DPIC.io.pc1 := WBU.io.pc(1)
    DPIC.io.pc_next0 := WBU.io.pcNext(0)
    DPIC.io.pc_next1 := WBU.io.pcNext(1)
    DPIC.io.rd_wen0 := gprWb(0).wen
    DPIC.io.rd_addr0 := gprWb(0).addr
    DPIC.io.rd_data0 := gprWb(0).data
    DPIC.io.rd_wen1 := gprWb(1).wen
    DPIC.io.rd_addr1 := gprWb(1).addr
    DPIC.io.rd_data1 := gprWb(1).data
    DPIC.io.bpu_update_en := hzu_bpu_update_en
    DPIC.io.bpu_update_pc := hzu_bpu_update_pc
    DPIC.io.predicted_pc := hzu_branch_resolve.predicted_pc
    DPIC.io.predicted_taken := hzu_branch_resolve.predicted_taken
    DPIC.io.actual_pc := hzu_branch_resolve.actual_pc
    DPIC.io.actual_taken := hzu_branch_resolve.actual_taken
    if (CONFIG_BRANCH_FAST_RECURRENCE) {
      DPIC.io.frp_owned.get := hzu_branch_resolve.frp_owned.get
      DPIC.io.frp_candidate.get := hzu_branch_resolve.frp_update.get.valid
      DPIC.io.frp_active.get := IFU.io.frp_update_active.get
      DPIC.io.frp_boundary.get := IFU.io.frp_boundary_mismatch.get
      DPIC.io.frp_token_created.get := FrpTracker.get.io.tokenCreated
      DPIC.io.frp_token_consumed.get := FrpTracker.get.io.tokenConsumed
      DPIC.io.frp_blocked_by_issued.get := IFU.io.frp_blocked_by_issued.get
    }
    if (CONFIG_BRANCH_LOOP_PREDICTOR) {
      DPIC.io.loop_meta_valid.get := hzu_branch_resolve.loop_meta.get.valid
      DPIC.io.loop_candidate.get := hzu_branch_resolve.loop_meta.get.candidate
      DPIC.io.loop_prediction.get := hzu_branch_resolve.loop_meta.get.prediction
      DPIC.io.loop_base_prediction.get :=
        hzu_branch_resolve.loop_meta.get.basePrediction
    }
    if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR) {
      val loopMetaBase = 64 + 4 * CONFIG_BRANCH_TAGE_INDEX_BITS +
        4 * CONFIG_BRANCH_TAGE_TAG_BITS + 6
      DPIC.io.tage_meta_valid.get := hzu_branch_resolve.tage_meta.get.valid
      DPIC.io.tage_prediction.get :=
        hzu_branch_resolve.tage_meta.get.bits(loopMetaBase + 2)
    }
    DPIC.io.environment0 := WBU.io.envir(0)
    DPIC.io.environment1 := WBU.io.envir(1)

    val pipelineStats = Module(new PipelineStats_DPIC)
    pipelineStats.io.clk := clock
    pipelineStats.io.rst := reset
    pipelineStats.io.retire_count := PopCount(WBU.io.retireMask)
    pipelineStats.io.issue_count :=
      Mux(ISU.io.out.fire && !frontend_redirect,
        PopCount(ISU.io.out.bits.laneValid), 0.U)
    pipelineStats.io.iq_count := IFU.io.queue_count
    pipelineStats.io.pair_opportunity :=
      IDU.io.pairOpportunity && !frontend_redirect
    pipelineStats.io.pair_success :=
      IDU.io.pairSuccess && !frontend_redirect
    pipelineStats.io.reject_slot0_serial :=
      IDU.io.rejectSlot0Serial && !frontend_redirect
    pipelineStats.io.reject_slot1_unsupported :=
      IDU.io.rejectSlot1Unsupported && !frontend_redirect
    pipelineStats.io.reject_shared_resource :=
      IDU.io.rejectSharedResource && !frontend_redirect
    pipelineStats.io.reject_waw :=
      IDU.io.rejectWaw && !frontend_redirect
    pipelineStats.io.reject_raw :=
      IDU.io.rejectRaw && !frontend_redirect
    pipelineStats.io.reject_slot1_late :=
      IDU.io.rejectSlot1Late && !frontend_redirect
    pipelineStats.io.waw_only :=
      IDU.io.wawOnly && !frontend_redirect
    pipelineStats.io.waw_flat_raw :=
      IDU.io.wawFlatRaw && !frontend_redirect
    pipelineStats.io.waw_load_raw :=
      IDU.io.wawLoadRaw && !frontend_redirect
    pipelineStats.io.waw_mul_raw :=
      IDU.io.wawMulRaw && !frontend_redirect
    pipelineStats.io.flat_bypass :=
      issEx1Group.fire && issEx1Group.bits.laneValid(1) &&
        (issEx1Group.bits.lane(1).flat_rs1 ||
          issEx1Group.bits.lane(1).flat_rs2)
    pipelineStats.io.load_pair_hit := false.B
    pipelineStats.io.load_pair_replay := false.B
    pipelineStats.io.pipeline_active :=
      ifu_valid || idu_valid || iss_valid || ex1_valid || ex2_valid ||
      ex3_valid || ex4_valid || exu_valid || wbu_valid
    pipelineStats.io.backend_stall := backend_stall
    pipelineStats.io.long_stall := long_stall_wb
    pipelineStats.io.issue_hazard := issue_hazard

    // Primary attribution follows the oldest blocking stage: WB long
    // operation, Ex4/LSU backend, then Iss.  The raw mask remains
    // overlapping so secondary pressure is not hidden by that priority.
    val stallRaw = Wire(Vec(9, Bool()))
    stallRaw(0) := WBU.io.div_stall
    stallRaw(1) := EXU.io.backend_store_stall
    stallRaw(2) := EXU.io.backend_load_stall
    stallRaw(3) := issue_hazard && ISU.io.stallSystem
    stallRaw(4) := issue_hazard && ISU.io.stallLong
    stallRaw(5) := issue_hazard &&
      (ISU.io.stallStoreOverlap || dc1StoreHazard)
    stallRaw(6) := issue_hazard &&
      (ISU.io.stallMmioOrder || dc1MmioHazard)
    stallRaw(7) := issue_hazard &&
      (ISU.io.stallLoadPort || ISU.io.stallLoadPrepare)
    stallRaw(8) := issue_hazard && ISU.io.stallOperand
    val pipelineFreeze =
      long_stall_wb || backend_stall || issue_hazard
    val stallPrimary = MuxCase(0.U(4.W), Seq(
      stallRaw(0) -> 1.U(4.W),
      stallRaw(1) -> 2.U(4.W),
      stallRaw(2) -> 3.U(4.W),
      stallRaw(3) -> 4.U(4.W),
      stallRaw(4) -> 5.U(4.W),
      stallRaw(5) -> 6.U(4.W),
      stallRaw(6) -> 7.U(4.W),
      stallRaw(7) -> 8.U(4.W),
      stallRaw(8) -> 9.U(4.W)
    ))
    pipelineStats.io.stall_primary := stallPrimary
    pipelineStats.io.stall_raw := stallRaw.asUInt
    pipelineStats.io.issue_operand_stall := stallRaw(8)
    pipelineStats.io.operand_stall_mask := ISU.io.operandStallMask
    pipelineStats.io.operand_producer_stage :=
      ISU.io.operandProducerStage.asUInt
    pipelineStats.io.operand_producer_type :=
      ISU.io.operandProducerType.asUInt
    pipelineStats.io.operand_consumer_type :=
      ISU.io.operandConsumerType.asUInt
    pipelineStats.io.operand_pc := ISU.io.operandPc
    pipelineStats.io.control_redirect := control_hazard
    pipelineStats.io.load_replay := load_miss_replay
    pipelineStats.io.store_overlap_ex1 := false.B
    pipelineStats.io.store_overlap_ex2 := Mux(
      CONFIG_LSU_EX2_STORE_REPLAY.B,
      ex2StoreReplayConflict,
      dc1LoadValid && dc1StoreAddressMatch(0))
    pipelineStats.io.store_overlap_ready := Mux(
      CONFIG_LSU_EX2_STORE_REPLAY.B,
      ex2StoreReplayConflict && !ex2StoreDataUnavailable,
      dc1LoadValid && dc1StoreOverlap && !dc1StoreDataUnavailable)
    pipelineStats.io.store_overlap_not_ready := Mux(
      CONFIG_LSU_EX2_STORE_REPLAY.B,
      ex2StoreReplayConflict && ex2StoreDataUnavailable,
      dc1LoadValid && dc1StoreDataUnavailable)
    pipelineStats.io.transient_forward := ISU.io.transientForward
    pipelineStats.io.transient_forward_bytes :=
      ISU.io.transientForwardBytes
    pipelineStats.io.transient_unknown_addr_stall :=
      dc1LoadValid && dc1UnknownStoreAddress
    pipelineStats.io.transient_data_stall :=
      dc1LoadValid && dc1StoreDataUnavailable
    pipelineStats.io.transient_multi_store :=
      ISU.io.transientMultiStore
    pipelineStats.io.transient_shadowed_not_ready :=
      ISU.io.transientShadowedNotReady

    assert(pipelineFreeze === stallRaw.asUInt.orR,
      "raw stall causes must exactly cover every frozen pipeline cycle")
    assert(pipelineFreeze === stallPrimary.orR,
      "every frozen pipeline cycle must have one primary cause")
  }
}

import java.io.File
import java.io.PrintWriter

object Elaborate extends App {
  println("Starting Elaboration...")
  val sv = _root_.circt.stage.ChiselStage.emitSystemVerilog(
    gen = new Mundus,
    firtoolOpts = Array(
      "--lowering-options=disallowLocalVariables",
      "-disable-all-randomization",
      "-strip-debug-info"
    )
  )
  println(s"SV Length: ${sv.length}")
  val targetDir = if (args.contains("--target-dir")) args(args.indexOf("--target-dir") + 1) else "."
  println(s"Target Dir: $targetDir")
  val dir = new File(targetDir)
  if (!dir.exists()) dir.mkdirs()
  val pw = new PrintWriter(new File(dir, "Mundus.sv"))
  pw.write(sv)
  pw.close()
  println("Successfully generated!")
}
