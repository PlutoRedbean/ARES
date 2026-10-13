package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import DPUParams._
import ALUParams._
import Func._

// Central two-wide pairing policy.  Only the oldest contiguous IQ prefix is
// selected: slot 0 is always present and slot 1 is added only when every
// ordered rejection check passes.
class GroupIDU extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IF_ID_Group))
    val out = Decoupled(new ID_IS_Group)
    val consumeCount =
      Output(UInt(log2Ceil(DualIssue.Width + 1).W))

    val rs1 = Output(Vec(DualIssue.Width, new ConsumerBundle))
    val rs2 = Output(Vec(DualIssue.Width, new ConsumerBundle))

    val issue = Input(new ForwardProducerGroup)
    val ex1 = Input(new ForwardProducerGroup)
    val ex2 = Input(new ForwardProducerGroup)
    val ex3 = Input(new ForwardProducerGroup)
    val ex4 = Input(new ForwardProducerGroup)
    val wb = Input(new ForwardProducerGroup)

    val pairOpportunity = Output(Bool())
    val pairSuccess = Output(Bool())
    val rejectSlot0Serial = Output(Bool())
    val rejectSlot1Unsupported = Output(Bool())
    val rejectSharedResource = Output(Bool())
    val rejectWaw = Output(Bool())
    val rejectRaw = Output(Bool())
    val rejectSlot1Late = Output(Bool())
    val wawOnly = Output(Bool())
    val wawFlatRaw = Output(Bool())
    val wawLoadRaw = Output(Bool())
    val wawMulRaw = Output(Bool())
  })

  val decoder = Seq.fill(DualIssue.Width)(Module(new IDU))
  for (lane <- 0 until DualIssue.Width) {
    decoder(lane).io.in.valid := io.in.valid && io.in.bits.laneValid(lane)
    decoder(lane).io.in.bits := io.in.bits.lane(lane)
    decoder(lane).io.out.ready := io.out.ready
    io.rs1(lane) := decoder(lane).io.rs1
    io.rs2(lane) := decoder(lane).io.rs2
    io.out.bits.lane(lane) := decoder(lane).io.out.bits
  }

  val hasLane0 = io.in.valid && io.in.bits.laneValid(0)
  val hasPair = io.in.valid && io.in.bits.laneValid === "b11".U
  val lane0 = decoder(0).io.out.bits
  val lane1 = decoder(1).io.out.bits

  val waw =
    lane0.rd_wen && lane1.rd_wen &&
    lane0.rd_addr =/= 0.U &&
    lane0.rd_addr === lane1.rd_addr

  val rawRs1 =
    lane0.rd_wen && lane0.rd_addr =/= 0.U &&
    decoder(1).io.rs1.ren &&
    lane0.rd_addr === decoder(1).io.rs1.addr
  val rawRs2 =
    lane0.rd_wen && lane0.rd_addr =/= 0.U &&
    decoder(1).io.rs2.ren &&
    lane0.rd_addr === decoder(1).io.rs2.addr
  val sameGroupRaw = rawRs1 || rawRs2
  // Keep the ALU0 flat result local to data-producing slot-1 operations.
  // A dependent control-flow instruction is replayed as the next group so
  // the branch comparator never sits behind the slot-0 ALU path.
  // A dependent slot-1 ALU operation is delayed through SideSkewALU.  Keep
  // the decode admission rule identical to that unit's implemented opcode
  // set.  Checking only shifts used to admit pass-through operations and the
  // custom CRC16 opcode, which then tripped the execution-side legality
  // assertion when CoreMark formed such a same-group RAW pair.
  val slot1SkewAluSupported =
    SideSkewALUCtrl.legal(lane1.alu_ctrl)
  val slot1FlatConsumer =
    (decoder(1).io.ordinaryAlu && slot1SkewAluSupported) ||
      decoder(1).io.multiply
  val slot1StoreData =
    decoder(1).io.memory && lane1.mem_wen
  val flatRs1Allowed = slot1FlatConsumer
  val flatRs2Allowed = slot1FlatConsumer || slot1StoreData
  val flatProducer = decoder(0).io.ordinaryAlu
  val loadProducer =
    decoder(0).io.memory && !lane0.mem_wen
  val rawRs1Supported =
    !rawRs1 ||
      (flatProducer && flatRs1Allowed)
  val rawRs2Supported =
    !rawRs2 ||
      (flatProducer && flatRs2Allowed)
  val unforwardableRaw =
    !rawRs1Supported || !rawRs2Supported
  // As in the A53 integer pipeline, a same-group WAW is harmless when the
  // younger write is guaranteed to supersede the older one.  If slot 1 also
  // consumes slot 0, only the explicit ALU0 flat path makes that WAW safe.
  // Keep this classification parallel to the other pairing predicates so it
  // does not extend the ordered statistics chain below.
  val wawSafe =
    waw && (!sameGroupRaw || !unforwardableRaw)
  val wawBlocked = waw && !wawSafe
  val rawBlocked = sameGroupRaw && unforwardableRaw

  // Estimate how many cycles each instruction would wait in Iss for the
  // youngest matching older producer.  The stage argument is where that
  // producer will be when this decode result reaches Iss next cycle.
  private def sourceDelay(consumer: ConsumerBundle): UInt = {
    val delay = WireDefault(0.U(3.W))

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

    def remaining(when: UInt, firstStage: Int): UInt = {
      val candidates = (0 to WHN_IDX_WB - firstStage).map { cycles =>
        val stage = firstStage + cycles
        !(consumer.need & relativeWhen(when, stage)).orR ->
          cycles.U(3.W)
      }
      MuxCase((WHN_IDX_WB - firstStage + 1).U(3.W), candidates)
    }

    def consider(
        group: ForwardProducerGroup,
        firstStage: Int): Unit = {
      for (producerLane <- 0 until DualIssue.Width) {
        val producer = group.rd(producerLane)
        val hit =
          group.laneValid(producerLane) &&
          consumer.ren &&
          producer.wen &&
          producer.addr =/= 0.U &&
          producer.addr === consumer.addr
        when(hit) {
          delay := remaining(producer.when, firstStage)
        }
      }
    }

    // Later calls override earlier matches: nearest stage first, then the
    // younger producer lane within a stage.
    // Decode observes the registered producer snapshot from the preceding
    // cycle, then crosses the synchronous GPR-read stage.  Advance that view
    // by two stages when estimating where it will be at ISU.  A stalled
    // producer can make this optimistic, but live ISU interlock still checks
    // availability and preserves correctness.
    consider(io.wb, WHN_IDX_WB)
    consider(io.ex4, WHN_IDX_WB)
    consider(io.ex3, WHN_IDX_WB)
    consider(io.ex2, WHN_IDX_WB)
    consider(io.ex1, WHN_IDX_EX4)
    consider(io.issue, WHN_IDX_EX3)
    delay
  }

  val lane0Delay = Seq(
    sourceDelay(decoder(0).io.rs1),
    sourceDelay(decoder(0).io.rs2)
  ).reduce((left, right) => Mux(left > right, left, right))
  val lane1Rs1Delay =
    Mux(rawRs1 && rawRs1Supported, 0.U,
      sourceDelay(decoder(1).io.rs1))
  val lane1Rs2Delay =
    Mux(rawRs2 && rawRs2Supported, 0.U,
      sourceDelay(decoder(1).io.rs2))
  val lane1Delay =
    Mux(lane1Rs1Delay > lane1Rs2Delay, lane1Rs1Delay, lane1Rs2Delay)
  val slot1Later = lane1Delay > lane0Delay

  // Rejections are mutually exclusive and ordered so statistics account for
  // every actual pairing decision exactly once.
  val rejectSlot0Serial = hasPair && !decoder(0).io.slot0Pairable
  val rejectSlot1Unsupported =
    hasPair && !rejectSlot0Serial && !decoder(1).io.slot1Supported
  val sharedMemoryConflict =
    decoder(0).io.memory && decoder(1).io.memory
  // A replay drains older multiply results while holding the memory group at
  // Ex2.  Keep that retained group free of a multiply token because the DSP
  // pipeline exposes one clock enable for all of its internal stages.
  val replayMemoryMulConflict =
    CONFIG_LSU_EX2_STORE_REPLAY.B &&
      ((decoder(0).io.memory && decoder(1).io.multiply) ||
        (decoder(0).io.multiply && decoder(1).io.memory))
  val rejectSharedResource =
    hasPair && !rejectSlot0Serial && !rejectSlot1Unsupported &&
      (sharedMemoryConflict || replayMemoryMulConflict)
  val rejectWaw =
    hasPair && !rejectSlot0Serial && !rejectSlot1Unsupported &&
      !rejectSharedResource && wawBlocked
  val rejectRaw =
    hasPair && !rejectSlot0Serial && !rejectSlot1Unsupported &&
      !rejectSharedResource && !rejectWaw && rawBlocked
  val rejectSlot1Late =
    hasPair && !rejectSlot0Serial && !rejectSlot1Unsupported &&
      !rejectSharedResource && !rejectWaw && !rejectRaw && slot1Later
  val pair = hasPair &&
    decoder(0).io.slot0Pairable &&
    decoder(1).io.slot1Supported &&
    !sharedMemoryConflict && !replayMemoryMulConflict &&
    !wawBlocked &&
    !rawBlocked &&
    !slot1Later

  val selectedMask =
    Mux(hasLane0, Mux(pair, "b11".U, "b01".U), "b00".U)

  io.out.bits.lane(1).flat_rs1 :=
    pair && rawRs1 && flatProducer && flatRs1Allowed
  io.out.bits.lane(1).flat_rs2 :=
    pair && rawRs2 && flatProducer && flatRs2Allowed
  io.out.bits.lane(1).load_pair_rs1 :=
    false.B
  io.out.bits.lane(1).load_pair_rs2 :=
    false.B

  io.in.ready := io.out.ready
  io.out.valid := selectedMask.orR
  io.out.bits.laneValid := selectedMask
  io.consumeCount := PopCount(selectedMask)

  val pairDecision = io.out.fire && hasPair
  io.pairOpportunity := pairDecision
  io.pairSuccess := pairDecision && pair
  io.rejectSlot0Serial := pairDecision && rejectSlot0Serial
  io.rejectSlot1Unsupported := pairDecision && rejectSlot1Unsupported
  io.rejectSharedResource := pairDecision && rejectSharedResource
  io.rejectWaw := pairDecision && rejectWaw
  io.rejectRaw := pairDecision && rejectRaw
  io.rejectSlot1Late := pairDecision && rejectSlot1Late

  // Preserve an unprioritized view of the WAW candidates that reached the
  // dependency policy.  This separates safe opportunities from the remaining
  // WAW reject count without moving classification logic onto the pair path.
  val wawOpportunity =
    hasPair &&
      decoder(0).io.slot0Pairable &&
      decoder(1).io.slot1Supported &&
      !sharedMemoryConflict &&
      waw
  val wawOnly = wawOpportunity && !sameGroupRaw
  val flatRawSupported =
    flatProducer &&
      (!rawRs1 || flatRs1Allowed) &&
      (!rawRs2 || flatRs2Allowed)
  val wawFlatRaw =
    wawOpportunity && sameGroupRaw && flatRawSupported
  val wawLoadRaw =
    wawOpportunity && sameGroupRaw && loadProducer
  val wawMulRaw =
    wawOpportunity && sameGroupRaw &&
      decoder(0).io.multiply
  io.wawOnly := pairDecision && wawOnly
  io.wawFlatRaw := pairDecision && wawFlatRaw
  io.wawLoadRaw := pairDecision && wawLoadRaw
  io.wawMulRaw := pairDecision && wawMulRaw

  assert(!io.in.valid || isDualLanePrefix(io.in.bits.laneValid),
    "decode input mask must be a contiguous oldest prefix")
  assert(!io.out.valid || isDualLanePrefix(io.out.bits.laneValid),
    "decode output mask must be a contiguous oldest prefix")
  when(pairDecision) {
    assert(PopCount(Cat(
      io.pairSuccess,
      io.rejectSlot0Serial,
      io.rejectSlot1Unsupported,
      io.rejectSharedResource,
      io.rejectWaw,
      io.rejectRaw,
      io.rejectSlot1Late)) === 1.U,
      "each pair opportunity must have exactly one outcome")
    assert(PopCount(Cat(
      io.wawOnly,
      io.wawFlatRaw,
      io.wawLoadRaw,
      io.wawMulRaw)) <= 1.U,
      "WAW detail classes must not overlap")
  }
  when(pairDecision &&
      decoder(0).io.slot0Pairable &&
      decoder(1).io.slot1Supported &&
      flatProducer && decoder(1).io.controlFlow && sameGroupRaw) {
    assert(!pair && selectedMask === "b01".U,
      "an ALU0-dependent slot-1 branch must serialize")
  }
  when(io.out.fire && io.out.bits.laneValid(1)) {
    assert(decoder(1).io.slot1Supported,
      "slot 1 received an unsupported instruction class")
    assert(!waw || wawSafe,
      "same-group WAW must be commit-safe")
    assert(!sameGroupRaw || !unforwardableRaw,
      "same-group RAW must have an explicit flat path")
    when(decoder(1).io.controlFlow) {
      assert(!io.out.bits.lane(1).flat_rs1 &&
        !io.out.bits.lane(1).flat_rs2,
        "slot-1 control flow must not use the ALU0 flat path")
    }
    assert(!sharedMemoryConflict,
      "a group may receive at most one shared memory grant")
    assert(!replayMemoryMulConflict,
      "a replayable memory group must not carry a multiply token")
  }
}
