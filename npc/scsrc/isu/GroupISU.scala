package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import MDUParams._
import BRUParams._
import CSRParams._
import DPUParams._
import Func._
import OperandStats._

// Two-lane synchronous register read and conservative producer-group bypass.
// Connections considered later have priority: the closest stage wins, then
// the younger lane within that stage.
class GroupISU extends Module {
  // Timing policy: keep the generic WB/MDU select cone out of branch Ex1.
  // This is local to Issue and does not require software scheduling changes.
  private val BlockEx4BranchBypass = true

  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new ID_IS_Group))
    val out = Decoupled(new IS_EX_Group)

    val gprRs1 = Input(Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W)))
    val gprRs2 = Input(Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W)))
    val preparedAddr =
      Input(Vec(DualIssue.Width, UInt(MEM_ADDR_WIDTH.W)))

    val ex1 = Input(new ForwardProducerGroup)
    val ex2 = Input(new ForwardProducerGroup)
    val ex3 = Input(new ForwardProducerGroup)
    val ex4 = Input(new ForwardProducerGroup)
    val wb = Input(new ForwardProducerGroup)

    val longStallWb = Input(Bool())
    val longInFlight = Input(Bool())
    val flush = Input(Bool())
    val loadPortBlocked = Input(Bool())
    val storeBufferEmpty = Input(Bool())
    val systemInFlight = Input(Bool())
    val interlock = Output(Bool())
    val stallOperand = Output(Bool())
    val stallStoreOverlap = Output(Bool())
    val stallMmioOrder = Output(Bool())
    val stallLoadPort = Output(Bool())
    val stallLoadPrepare = Output(Bool())
    val stallSystem = Output(Bool())
    val stallLong = Output(Bool())
    val storeOverlapEx1 = Output(Bool())
    val storeOverlapEx2 = Output(Bool())
    val storeOverlapReady = Output(Bool())
    val storeOverlapNotReady = Output(Bool())
    val transientForward = Output(Bool())
    val transientForwardBytes = Output(UInt(3.W))
    val transientUnknownAddrStall = Output(Bool())
    val transientDataStall = Output(Bool())
    val transientMultiStore = Output(Bool())
    val transientShadowedNotReady = Output(Bool())
    val operandStallMask =
      Output(UInt((DualIssue.Width * 2).W))
    val operandProducerStage = Output(Vec(
      DualIssue.Width * 2, UInt(PRODUCER_STAGE_WIDTH.W)))
    val operandProducerType = Output(Vec(
      DualIssue.Width * 2, UInt(PRODUCER_TYPE_WIDTH.W)))
    val operandConsumerType = Output(Vec(
      DualIssue.Width * 2, UInt(CONSUMER_TYPE_WIDTH.W)))
    val operandPc =
      Output(Vec(DualIssue.Width, UInt(PC_DATA_WIDTH.W)))
  })

  private def resolve(
      consumer: ConsumerBundle,
      rfValue: UInt,
      allowLoadHitBypass: Bool,
      blockEx4BranchBypass: Bool): (
        UInt, Bool, Bool, LateOperandBundle, UInt, UInt) = {
    val matched = WireDefault(false.B)
    val interlock = WireDefault(false.B)
    val forwarded = WireDefault(false.B)
    val producerStage = WireDefault(PRODUCER_EX1)
    val producerType = WireDefault(PRODUCER_ALU)
    val value = WireDefault(rfValue)
    val late = WireDefault(0.U.asTypeOf(new LateOperandBundle))

    def relativeWhen(when: UInt, stage: Int): UInt = stage match {
      case WHN_IDX_EX1 =>
        Cat(when(WHN_IDX_EX4), when(WHN_IDX_EX3), when(WHN_IDX_EX2),
          when(WHN_IDX_EX1), true.B)
      case WHN_IDX_EX2 =>
        Cat(false.B, when(WHN_IDX_EX4), when(WHN_IDX_EX3),
          when(WHN_IDX_EX2), when(WHN_IDX_EX1))
      case WHN_IDX_EX3 =>
        Cat(false.B, false.B, when(WHN_IDX_EX4),
          when(WHN_IDX_EX3), when(WHN_IDX_EX2))
      case WHN_IDX_EX4 =>
        Cat(false.B, false.B, false.B,
          when(WHN_IDX_EX4), when(WHN_IDX_EX3))
      case WHN_IDX_WB => 0.U(NEED_WHEN_WIDTH.W)
    }

    def consider(
        group: ForwardProducerGroup,
        stage: Int,
        alwaysReady: Boolean,
        nextWhere: Int = -1,
        reachesEx2Next: Boolean = false,
        blockReadyCapture: Boolean = false): Unit = {
      for (producerLane <- 0 until DualIssue.Width) {
        val producer = group.rd(producerLane)
        val hit =
          group.laneValid(producerLane) &&
          consumer.ren &&
          producer.wen &&
          producer.addr =/= 0.U &&
          producer.addr === consumer.addr
        when (hit) {
          val ready =
            if (alwaysReady) true.B else !producer.when(stage)
          val loadHitBypass =
            reachesEx2Next.B &&
              producer.producerType === PRODUCER_LOAD &&
              producer.when === WHEN_ABS_EX2 &&
              allowLoadHitBypass
          val blockedOptimisticLoad =
            reachesEx2Next.B &&
              producer.producerType === PRODUCER_LOAD &&
              producer.when === WHEN_ABS_EX2 &&
              !allowLoadHitBypass
          val deferToEx1 =
            consumer.need === NEED_EX1
          // A53 permits the same-cycle ALU0 -> ALU1 path inside one issue
          // group, but all later consumers select registered Ex2/WB sources.
          // Likewise, never put a current Ex1 result back onto an Issue data
          // input.  Consumers carry a token into Ex1; address generation is
          // the exception and is interlocked below while its base is pending.
          // A ready Ex4 result can be captured into the Issue -> Ex1 payload
          // register without exposing the branch comparator to WB.  An
          // unavailable Ex4 result must instead wait until WB; never carry a
          // WB late token into a branch, because the generic WB value mux is
          // controlled by mdu_ctrl and recreates the critical BRU/HZU path.
          val captureReadyEx4Branch =
            if (stage == WHN_IDX_EX4) {
              blockEx4BranchBypass && ready
            } else {
              false.B
            }
          val deferReadyValue =
            (deferToEx1 || blockReadyCapture.B) &&
              !captureReadyEx4Branch
          val trackProducer =
            (!ready || deferReadyValue || loadHitBypass) &&
              (nextWhere >= 0).B
          val blockedEx4Branch =
            if (stage == WHN_IDX_EX4) {
              blockEx4BranchBypass && trackProducer
            } else {
              false.B
            }
          val captureNow =
            ready && (!deferReadyValue || (nextWhere < 0).B)
          matched := true.B
          interlock :=
            blockedEx4Branch ||
              ((consumer.need & relativeWhen(producer.when, stage)).orR &&
                !loadHitBypass) || blockedOptimisticLoad
          forwarded := ready && !blockedEx4Branch
          producerStage := stage.U
          producerType := Mux(
            producer.producerType === PRODUCER_ALU &&
              producer.when === WHEN_ABS_EX3,
            PRODUCER_LOAD_PAIR_ALU,
            producer.producerType)
          // Replay is checked one cycle later, when this consumer is in Ex1.
          // Either producer lane may own the shared load pipe in Ex2.
          when(captureNow) {
            value := group.value(producerLane)
          }
          // The ordinary operand register already captures an immediately
          // available value.  Keep the late path metadata-only until Ex1 (or
          // a held Ex1 group) captures the selected producer stage.
          late.pending := trackProducer
          if (nextWhere >= 0) {
            late.stage := Mux(trackProducer,
              (1 << nextWhere).U(WHERE_WIDTH.W), 0.U)
          } else {
            late.stage := 0.U
          }
          late.lane := producerLane.U
          late.loadSpec := loadHitBypass
        }
      }
    }

    consider(io.wb, WHN_IDX_WB, alwaysReady = true)
    consider(io.ex4, WHN_IDX_EX4, alwaysReady = false,
      nextWhere = WHR_IDX_WB)
    consider(io.ex3, WHN_IDX_EX3, alwaysReady = false,
      nextWhere = WHR_IDX_EX4)
    consider(io.ex2, WHN_IDX_EX2, alwaysReady = false,
      nextWhere = WHR_IDX_EX3)
    consider(io.ex1, WHN_IDX_EX1, alwaysReady = false,
      nextWhere = WHR_IDX_EX2,
      reachesEx2Next = true,
      blockReadyCapture = true)

    (value, matched && interlock, matched && forwarded, late,
      producerStage, producerType)
  }

  val sourceUnavailable = Wire(Vec(DualIssue.Width * 2, Bool()))
  val sourceForwarded = Wire(Vec(DualIssue.Width * 2, Bool()))
  val sourceProducerStage =
    Wire(Vec(DualIssue.Width * 2, UInt(PRODUCER_STAGE_WIDTH.W)))
  val sourceProducerType =
    Wire(Vec(DualIssue.Width * 2, UInt(PRODUCER_TYPE_WIDTH.W)))
  val sourceConsumerType =
    Wire(Vec(DualIssue.Width * 2, UInt(CONSUMER_TYPE_WIDTH.W)))
  val cacheProbeMatches = Wire(Vec(DualIssue.Width, Bool()))

  io.out.bits := 0.U.asTypeOf(new IS_EX_Group)
  io.out.bits.laneValid := io.in.bits.laneValid
  for (lane <- 0 until DualIssue.Width) {
    val decoded = io.in.bits.lane(lane)
    val isMemory = decoded.mem_bytes =/= MEM_NONE
    val isControl = decoded.bru_ctrl =/= BRU_NONE || decoded.jump

    val rs1 = Wire(new ConsumerBundle)
    rs1.ren := decoded.ALU_operand1 === OPR_RS1
    rs1.addr := decoded.rs1_addr
    rs1.need := decoded.rs1_need

    val rs2 = Wire(new ConsumerBundle)
    rs2.ren := decoded.ALU_operand2 === OPR_RS2
    rs2.addr := decoded.rs2_addr
    rs2.need := decoded.rs2_need

    // Only ordinary integer ALU consumers may follow an optimistic EX2 load.
    // Keep branches, AGU/memory, MDU, CSR, and system operations away from the
    // fast path so neither the BRU nor another cache request enters its cone.
    val allowLoadHitBypass =
      decoded.mem_bytes === MEM_NONE &&
        !isControl &&
        decoded.mdu_ctrl === MDU_NONE &&
        decoded.csr_ctrl === CSR_NONE &&
        decoded.envir === ENVIR_NORMAL

    val (rs1Value, rs1Unavailable, rs1Forwarded, rs1Late,
      rs1ProducerStage, rs1ProducerType) =
        resolve(rs1, io.gprRs1(lane), allowLoadHitBypass,
          BlockEx4BranchBypass.B && isControl)
    val (rs2Value, rs2Unavailable, rs2Forwarded, rs2Late,
      rs2ProducerStage, rs2ProducerType) =
        resolve(rs2, io.gprRs2(lane), allowLoadHitBypass,
          BlockEx4BranchBypass.B && isControl)

    // A same-group slot-0 ALU producer is younger than every pipeline
    // producer found above.  Its flat path therefore suppresses both the
    // older interlock and any speculative load metadata on that source.
    val flatRs1 =
      if (lane == 1) decoded.flat_rs1 else false.B
    val flatRs2 =
      if (lane == 1) decoded.flat_rs2 else false.B
    val loadPairRs1 =
      if (lane == 1) decoded.load_pair_rs1 else false.B
    val loadPairRs2 =
      if (lane == 1) decoded.load_pair_rs2 else false.B
    val sameGroupRs1 = flatRs1 || loadPairRs1
    val sameGroupRs2 = flatRs2 || loadPairRs2
    val sideAluSkew =
      if (lane == 1) {
        (flatRs1 || flatRs2) &&
          decoded.mem_bytes === MEM_NONE &&
          decoded.mdu_ctrl === MDU_NONE &&
          decoded.bru_ctrl === BRU_NONE &&
          !decoded.jump &&
          decoded.csr_ctrl === CSR_NONE &&
          decoded.envir === ENVIR_NORMAL
      } else {
        false.B
      }
    sourceUnavailable(lane * 2) :=
      rs1Unavailable && !sameGroupRs1
    sourceUnavailable(lane * 2 + 1) :=
      rs2Unavailable && !sameGroupRs2
    sourceForwarded(lane * 2) :=
      rs1Forwarded && !sameGroupRs1
    sourceForwarded(lane * 2 + 1) :=
      rs2Forwarded && !sameGroupRs2
    sourceProducerStage(lane * 2) := rs1ProducerStage
    sourceProducerStage(lane * 2 + 1) := rs2ProducerStage
    sourceProducerType(lane * 2) := rs1ProducerType
    sourceProducerType(lane * 2 + 1) := rs2ProducerType

    // The holding address remains exact while its base is read from the saved
    // RF snapshot.  Any same-group or in-flight producer selects the EX3
    // fallback instead.  This validity test keeps the forwarded AGU adder out
    // of the early D-cache probe timing cone.
    val cacheProbeMatch =
      isMemory && io.preparedAddr(lane)(31, 18) ===
          "b1000_0000_0001_00".U(14.W) &&
        io.storeBufferEmpty &&
        !sameGroupRs1 && !rs1Forwarded
    cacheProbeMatches(lane) := cacheProbeMatch
    sourceConsumerType(lane * 2) := MuxCase(CONSUMER_ALU, Seq(
      isControl -> CONSUMER_BRANCH,
      isMemory -> CONSUMER_AGU
    ))
    sourceConsumerType(lane * 2 + 1) := MuxCase(CONSUMER_ALU, Seq(
      isControl -> CONSUMER_BRANCH,
      (isMemory && decoded.mem_wen) -> CONSUMER_STORE_DATA
    ))
    io.operandPc(lane) := decoded.pc

    val aluDin1 =
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand1(OPR_IDX_IMM)) & decoded.imm) |
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand1(OPR_IDX_SNPC)) & decoded.snpc) |
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand1(OPR_IDX_RS1)) & rs1Value)
    val aluDin2 =
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand2(OPR_IDX_IMM)) & decoded.imm) |
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand2(OPR_IDX_SNPC)) & decoded.snpc) |
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand2(OPR_IDX_PC)) & decoded.pc) |
      (Fill(REG_DATA_WIDTH, decoded.ALU_operand2(OPR_IDX_RS2)) & rs2Value)

    val issued = io.out.bits.lane(lane)
    issued.predicted_pc := decoded.predicted_pc
    issued.predicted_taken := decoded.predicted_taken
    if (CONFIG_BP_TAGE) {
      issued.tage_meta.get := decoded.tage_meta.get
    }
    if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
      issued.loop_meta.get := decoded.loop_meta.get
    }
    if (CONFIG_BRANCH_FAST_RECURRENCE) {
      issued.frp_owned.get := decoded.frp_owned.get
      issued.frp_bit_test.get := decoded.frp_bit_test.get
      issued.frp_zero_branch.get := decoded.frp_zero_branch.get
      issued.frp_branch_beqz.get := decoded.frp_branch_beqz.get
      issued.frp_test_reg.get := decoded.frp_test_reg.get
    }
    issued.alu_ctrl := decoded.alu_ctrl
    issued.bru_ctrl := decoded.bru_ctrl
    issued.mdu_ctrl := decoded.mdu_ctrl
    issued.csr_ctrl := decoded.csr_ctrl
    issued.csr_mask := decoded.csr_mask
    issued.jump := decoded.jump
    if (CONFIG_BRANCH_RAS) {
      issued.ras_push.get := decoded.ras_push.get
      issued.ras_pop.get := decoded.ras_pop.get
    }
    issued.snpc := decoded.snpc
    issued.imm := decoded.imm
    issued.alu_din1 := aluDin1
    issued.alu_din2 := aluDin2
    issued.rs1_val := rs1Value
    issued.rs2_val := rs2Value
    issued.rs1_late :=
      Mux(sameGroupRs1,
        0.U.asTypeOf(new LateOperandBundle), rs1Late)
    issued.rs2_late :=
      Mux(sameGroupRs2,
        0.U.asTypeOf(new LateOperandBundle), rs2Late)
    if (CONFIG_SIMULATION) {
      issued.rs1_assert_addr.get := decoded.rs1_addr
      issued.rs2_assert_addr.get := decoded.rs2_addr
    }
    issued.flat_rs1 := decoded.flat_rs1
    issued.flat_rs2 := decoded.flat_rs2
    issued.load_pair_rs1 := decoded.load_pair_rs1
    issued.load_pair_rs2 := decoded.load_pair_rs2
    issued.rs1_need := decoded.rs1_need
    issued.rs2_need := decoded.rs2_need
    // A validated holding-queue probe advertises the registered EX2 fast
    // candidate.  Address mismatches and non-cacheable loads retain the
    // conservative EX3 result; a real cache miss replays its ALU consumer.
    val issuedLoad = isMemory && !decoded.mem_wen
    issued.when := Mux(
      issuedLoad,
      Mux(cacheProbeMatch, WHEN_ABS_EX2, WHEN_ABS_EX3),
      Mux(sideAluSkew || loadPairRs1 || loadPairRs2,
        WHEN_ABS_EX3,
        decoded.when))
    issued.cache_probe_match := cacheProbeMatch
    issued.pc := decoded.pc
    issued.rd_addr := decoded.rd_addr
    issued.rd_wen := decoded.rd_wen
    // A memory base may leave Issue only after its ordinary forwarding value
    // is final.  Capture the resolved AGU result at the Issue -> Ex1 boundary
    // so held-operand selection never precedes address generation in Ex1.
    // The holding-queue address remains an independent, speculative D-cache
    // probe input and is never used as the architectural request address.
    issued.addr := Mux(isMemory, rs1Value + decoded.imm, 0.U)
    issued.L_sign := decoded.L_sign
    issued.mem_wen := decoded.mem_wen
    issued.mem_bytes := decoded.mem_bytes
    issued.transient_fwd_mask := 0.U
    issued.transient_fwd_data := 0.U
    issued.transient_fwd_sources := 0.U
    issued.envir := decoded.envir
  }

  io.out.bits.laneValid := io.in.bits.laneValid

  val operandInterlock = (0 until DualIssue.Width).map { lane =>
    val issued = io.out.bits.lane(lane)
    val aguPending =
      issued.mem_bytes =/= MEM_NONE && issued.rs1_late.pending
    io.in.bits.laneValid(lane) &&
      (sourceUnavailable(lane * 2) || sourceUnavailable(lane * 2 + 1) ||
        aguPending)
  }.reduce(_ || _)

  val memoryValid = Wire(Vec(DualIssue.Width, Bool()))
  for (lane <- 0 until DualIssue.Width) {
    memoryValid(lane) :=
      io.in.bits.laneValid(lane) &&
        io.out.bits.lane(lane).mem_bytes =/= MEM_NONE
  }
  // AG0 is an elastic LSU sidecar.  Issue never retains a load merely to
  // register its address; only genuine port backpressure may interlock it.
  val sharedMemory = memoryValid.asUInt.orR
  val memoryInterlock = sharedMemory && io.loadPortBlocked

  val lane0Issued = io.out.bits.lane(0)
  val lane0System = io.in.bits.laneValid(0) &&
    (lane0Issued.csr_ctrl =/= CSR_NONE ||
      lane0Issued.envir =/= ENVIR_NORMAL)
  val systemInterlock = lane0System && io.systemInFlight

  val lane0 = io.in.bits.lane(0)
  val rawLong =
    io.in.valid &&
    io.in.bits.laneValid(0) &&
    lane0.mdu_ctrl(MDU_MUX_WIDTH - 1, 0) === MD_DIV
  val longInterlock = rawLong && (io.longInFlight || io.longStallWb)

  io.stallOperand := operandInterlock
  io.stallStoreOverlap := false.B
  io.stallMmioOrder := false.B
  io.stallLoadPort := sharedMemory && io.loadPortBlocked
  io.stallLoadPrepare := false.B
  io.stallSystem := systemInterlock
  io.stallLong := longInterlock
  io.storeOverlapEx1 := false.B
  io.storeOverlapEx2 := false.B
  io.storeOverlapReady := false.B
  io.storeOverlapNotReady := false.B
  io.transientForward := false.B
  io.transientForwardBytes := 0.U
  io.transientUnknownAddrStall := false.B
  io.transientDataStall := false.B
  io.transientMultiStore := false.B
  io.transientShadowedNotReady := false.B
  val operandLaneValidMask = Cat(
    Fill(2, io.in.bits.laneValid(1)),
    Fill(2, io.in.bits.laneValid(0))
  )
  io.operandStallMask := sourceUnavailable.asUInt &
    operandLaneValidMask &
    Fill(DualIssue.Width * 2, io.in.valid)
  io.operandProducerStage := sourceProducerStage
  io.operandProducerType := sourceProducerType
  io.operandConsumerType := sourceConsumerType
  io.interlock :=
    operandInterlock || memoryInterlock || systemInterlock || longInterlock
  io.in.ready := io.out.ready && !io.interlock
  io.out.valid := io.in.valid && !io.interlock

  assert(!io.in.valid || isDualLanePrefix(io.in.bits.laneValid),
    "group issue input must be a contiguous oldest prefix")
  assert(!io.out.valid || isDualLanePrefix(io.out.bits.laneValid),
    "group issue output must be a contiguous oldest prefix")
  assert(!io.in.valid || PopCount(memoryValid) <= 1.U,
    "group issue accepts at most one memory candidate")

  if (CONFIG_SIMULATION) {
    for (lane <- 0 until DualIssue.Width) {
      val decoded = io.in.bits.lane(lane)
      val issued = io.out.bits.lane(lane)
      val memoryIssue =
        io.out.fire && io.out.bits.laneValid(lane) &&
          issued.mem_bytes =/= MEM_NONE
      when(memoryIssue) {
        assert(!issued.rs1_late.pending,
          s"lane $lane memory address must be resolved before Issue")
        assert(!issued.flat_rs1 && !issued.load_pair_rs1,
          s"lane $lane memory base must not use a same-group bypass")
        assert(issued.addr === issued.rs1_val + decoded.imm,
          s"lane $lane issued memory address must match captured base plus immediate")
      }
      when(io.out.fire && io.out.bits.laneValid(lane) &&
          (issued.bru_ctrl =/= BRU_NONE || issued.jump)) {
        assert(!(issued.rs1_late.pending &&
          issued.rs1_late.stage(WHR_IDX_WB)),
          s"lane $lane branch must capture an Ex4 producer before Ex1")
        assert(!(issued.rs2_late.pending &&
          issued.rs2_late.stage(WHR_IDX_WB)),
          s"lane $lane branch must capture an Ex4 producer before Ex1")
      }
    }
    dontTouch(sourceForwarded)
  }
}
