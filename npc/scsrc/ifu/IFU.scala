package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class FetchBufferEntry extends Bundle {
  val pc = UInt(PC_DATA_WIDTH.W)
  val inst = UInt(32.W)
  val predicted_taken = Bool()
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val ftq_idx = if (CONFIG_BP_TAGE)
    Some(UInt(log2Ceil(CONFIG_BRANCH_FTQ_DEPTH).W)) else None
  val ftq_last = if (CONFIG_BP_TAGE) Some(Bool()) else None
  val ftq_finalized = if (CONFIG_BP_TAGE) Some(Bool()) else None
  val loop_meta = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frp_owned = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
}

class FetchTargetQueueEntry extends Bundle {
  val iqStart = UInt(log2Ceil(
    CONFIG_FRONTEND_QUEUE_DEPTH + DualIssue.Width).W)
  val iqCount = UInt(log2Ceil(DualIssue.Width + 1).W)
}

class TageFetchBlockMeta extends Bundle {
  val startPc = UInt(PC_DATA_WIDTH.W)
  val predictedTaken = Bool()
  val predictedPc = UInt(PC_DATA_WIDTH.W)
  val predictedSlot = Bool()
  val predictedHit = Bool()
  val fetchId = UInt(4.W)
  val fetchEpoch = Bool()
  val ftqIdx = UInt(log2Ceil(CONFIG_BRANCH_FTQ_DEPTH).W)
  val loopMeta = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frpOwned = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
}

class IFU extends Module {
  val io = IO(new Bundle {
    val ready = Output(Bool())
    val irom = new IROM()
    val out = Decoupled(new IF_ID_Group)
    val consume_count = Input(UInt(log2Ceil(DualIssue.Width + 1).W))
    val queue_count =
      Output(UInt(log2Ceil(CONFIG_FRONTEND_QUEUE_DEPTH + 1).W))

    val bpu_update_en = Input(Bool())
    val bpu_update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_update_target = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push =
      if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val bpu_update_ras_pop =
      if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val bpu_update_ras_addr =
      if (CONFIG_BRANCH_RAS) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val actual_taken = Input(Bool())
    val redirected = Input(Bool())
    val redirected_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_update_is_branch =
      if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0)
        Some(Input(Bool()))
      else None
    val bpu_update_tage_meta =
      if (CONFIG_BP_TAGE) Some(Input(new TageMetaBundle)) else None
    val bpu_update_frp_owned =
      if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val bpu_update_frp =
      if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(new FastRecurrenceUpdateBundle)) else None
    val frp_update_active = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(Bool())) else None
    val frp_boundary_mismatch = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(Bool())) else None
    val frp_blocked_by_issued = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(Bool())) else None
  })

  private val QueueDepth = CONFIG_FRONTEND_QUEUE_DEPTH
  // Keep one complete synchronous fetch response behind the configured
  // frontend capacity.  The reserve absorbs a response that was launched
  // before downstream backpressure became visible.
  private val QueueReserve = DualIssue.Width
  private val QueueStorageDepth = QueueDepth + QueueReserve
  private val QueuePtrWidth = log2Ceil(QueueStorageDepth)
  private val QueueCountWidth = log2Ceil(QueueStorageDepth + 1)
  private val QueueReportWidth = log2Ceil(QueueDepth + 1)

  require(CONFIG_FRONTEND_QUEUE,
    "64-bit fetch requires the frontend instruction queue")
  require(QueueDepth >= 4,
    "dual-fetch instruction queue must contain at least four entries")

  val queue = Reg(Vec(QueueStorageDepth, new FetchBufferEntry))
  val queueHead = RegInit(0.U(QueuePtrWidth.W))
  val queueTail = RegInit(0.U(QueuePtrWidth.W))
  val queueCount = RegInit(0.U(QueueCountWidth.W))
  // Register the critical dequeue decision before it reaches the queue body.
  // The effective view below applies that decision immediately, while the
  // physical head/count registers catch up on the following edge.
  val pendingDequeueCount = RegInit(0.U(
    log2Ceil(DualIssue.Width + 1).W))
  val effectiveQueueCount = queueCount - pendingDequeueCount
  val reportedQueueCount = Mux(
    effectiveQueueCount > QueueDepth.U,
    QueueDepth.U,
    effectiveQueueCount)
  io.queue_count := reportedQueueCount(QueueReportWidth - 1, 0)
  val tageOverrideEvent = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  val tageOverrideRestart = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  val tageOverrideBlocked = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  val tageFastLoopProvisional = if (CONFIG_BP_TAGE && CONFIG_SIMULATION &&
      CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(WireDefault(false.B)) else None
  val tageOverrideReplacedLoop = if (CONFIG_BP_TAGE && CONFIG_SIMULATION &&
      CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(WireDefault(false.B)) else None
  val statRequestCandidate = WireDefault(false.B)
  val statReservationAvailable = WireDefault(false.B)
  val statRequestFire = WireDefault(false.B)
  val statInflightCount = WireDefault(0.U(32.W))
  val statResponseUsable = WireDefault(false.B)
  val statEnqueueCount = WireDefault(0.U(2.W))
  val statIqReservationAvailable = WireDefault(true.B)
  val statFtqReservationAvailable = WireDefault(true.B)
  val statFtqCount = WireDefault(0.U(32.W))
  val statFtqAllocCount = WireDefault(0.U(2.W))
  val statFtqPopCount = WireDefault(0.U(2.W))
  val statFtqRollbackCount = WireDefault(0.U(32.W))
  val tageFinalizeValid = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  val tageFinalizeFtqIdx = if (CONFIG_BP_TAGE)
    Some(WireDefault(0.U(log2Ceil(CONFIG_BRANCH_FTQ_DEPTH).W))) else None
  val tageFinalizeCfiPc = if (CONFIG_BP_TAGE)
    Some(WireDefault(0.U(PC_DATA_WIDTH.W))) else None
  val tageFinalizeTaken = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  val tageFinalizeNextPc = if (CONFIG_BP_TAGE)
    Some(WireDefault(0.U(PC_DATA_WIDTH.W))) else None
  val tageFinalizeMeta = if (CONFIG_BP_TAGE)
    Some(WireDefault(0.U.asTypeOf(new TageMetaBundle))) else None
  val tageFinalizePathOverride = if (CONFIG_BP_TAGE)
    Some(WireDefault(false.B)) else None
  // TAGE training metadata belongs to the fetch block, not to each
  // instruction in that block.  Keep one copy per FTQ entry so the late,
  // wide TAGE response no longer drives every fetch-queue entry.  The
  // finalization bypass below preserves the existing same-cycle handoff.
  val tageMetaSidecar = if (CONFIG_BP_TAGE)
    Some(Mem(CONFIG_BRANCH_FTQ_DEPTH, new TageMetaBundle)) else None
  val tageCfiSlotSidecar = if (CONFIG_BP_TAGE)
    Some(Mem(CONFIG_BRANCH_FTQ_DEPTH, Bool())) else None

  private def ptrAdd(ptr: UInt, amount: UInt): UInt = {
    val sum = ptr +& amount
    Mux(sum >= QueueStorageDepth.U,
      sum - QueueStorageDepth.U, sum)(QueuePtrWidth - 1, 0)
  }

  val effectiveQueueHead = ptrAdd(queueHead, pendingDequeueCount)
  val availableMask = Mux(effectiveQueueCount >= 2.U, "b11".U,
    Mux(effectiveQueueCount === 1.U, "b01".U, "b00".U))
  val laneReady = Wire(Vec(DualIssue.Width, Bool()))
  val laneKilled = Wire(Vec(DualIssue.Width, Bool()))
  for (lane <- 0 until DualIssue.Width) {
    val entry = queue(ptrAdd(effectiveQueueHead, lane.U))
    laneReady(lane) := true.B
    laneKilled(lane) := false.B
    io.out.bits.lane(lane).pc := entry.pc
    io.out.bits.lane(lane).inst := entry.inst
    io.out.bits.lane(lane).snpc := entry.pc + 4.U
    io.out.bits.lane(lane).predicted_taken := entry.predicted_taken
    io.out.bits.lane(lane).predicted_pc := entry.predicted_pc
    if (CONFIG_BP_TAGE) {
      val finalizingEntry = tageFinalizeValid.get &&
        entry.ftq_idx.get === tageFinalizeFtqIdx.get
      val finalizingCfi = finalizingEntry &&
        entry.pc === tageFinalizeCfiPc.get
      laneReady(lane) := entry.ftq_finalized.get || finalizingEntry
      laneKilled(lane) := tageFinalizePathOverride.get && finalizingEntry &&
        entry.pc > tageFinalizeCfiPc.get
      io.out.bits.lane(lane).predicted_taken :=
        Mux(finalizingCfi, tageFinalizeTaken.get, entry.predicted_taken)
      io.out.bits.lane(lane).predicted_pc :=
        Mux(finalizingCfi, tageFinalizeNextPc.get, entry.predicted_pc)
      val storedCfi = entry.ftq_finalized.get &&
        entry.pc(2) === tageCfiSlotSidecar.get.read(entry.ftq_idx.get)
      val storedMeta = Mux(storedCfi,
        tageMetaSidecar.get.read(entry.ftq_idx.get),
        0.U.asTypeOf(new TageMetaBundle))
      io.out.bits.lane(lane).tage_meta.get := Mux(finalizingCfi,
        tageFinalizeMeta.get, storedMeta)
    }
    if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
      io.out.bits.lane(lane).loop_meta.get := entry.loop_meta.get
    }
    if (CONFIG_BRANCH_FAST_RECURRENCE) {
      io.out.bits.lane(lane).frp_owned.get := entry.frp_owned.get
    }
  }

  val outputLane0 = availableMask(0) && laneReady(0) && !laneKilled(0)
  val outputLane1 = availableMask(1) && outputLane0 &&
    laneReady(1) && !laneKilled(1)
  val outputMask = Cat(outputLane1, outputLane0)
  io.out.valid := outputMask.orR && !io.redirected
  io.out.bits.laneValid := outputMask

  val dequeueCount = Mux(io.out.fire, io.consume_count, 0.U)

  val bpu = Module(new BPU)
  bpu.io.update_en := io.bpu_update_en
  bpu.io.update_pc := io.bpu_update_pc
  bpu.io.actual_taken := io.actual_taken
  bpu.io.actual_target := io.bpu_update_target
  if (CONFIG_BRANCH_RAS) {
    bpu.io.update_ras_push.get := io.bpu_update_ras_push.get
    bpu.io.update_ras_pop.get := io.bpu_update_ras_pop.get
    bpu.io.update_ras_addr.get := io.bpu_update_ras_addr.get
  }
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    bpu.io.update_is_branch.get := io.bpu_update_is_branch.get
  }
  if (CONFIG_BP_TAGE) {
    bpu.io.update_tage_meta.get := io.bpu_update_tage_meta.get
  }
  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    bpu.io.update_frp_owned.get := io.bpu_update_frp_owned.get
    bpu.io.update_frp.get := io.bpu_update_frp.get
    io.frp_update_active.get := bpu.io.frp_update_active.get
    io.frp_boundary_mismatch.get := bpu.io.frp_boundary_mismatch.get
    io.frp_blocked_by_issued.get := bpu.io.frp_blocked_by_issued.get
  }

  val nextRequestValid = RegInit(true.B)
  val nextRequestPc = Module(new Mundus_PC)
  nextRequestPc.io.clk := clock
  nextRequestPc.io.rst := reset

  if (CONFIG_BP_TAGE) {
    require(CONFIG_IROM_READ_LATENCY == 1,
      "FTQ-backed TAGE requires the one-cycle IROM response")
    val FtqDepth = CONFIG_BRANCH_FTQ_DEPTH
    val FtqPtrWidth = log2Ceil(FtqDepth)
    val FtqCountWidth = log2Ceil(FtqDepth + 1)

    def ftqPtrAdd(ptr: UInt, amount: UInt): UInt = {
      val sum = ptr +& amount
      Mux(sum >= FtqDepth.U, sum - FtqDepth.U, sum)(FtqPtrWidth - 1, 0)
    }

    def queuePtrDistance(from: UInt, until: UInt): UInt = {
      Mux(until >= from, until - from,
        QueueStorageDepth.U + until - from)(QueueCountWidth - 1, 0)
    }

    def ftqPtrDistance(from: UInt, until: UInt): UInt = {
      Mux(until >= from, until - from,
        FtqDepth.U + until - from)(FtqCountWidth - 1, 0)
    }

    val ftq = Reg(Vec(FtqDepth, new FetchTargetQueueEntry))
    val ftqHead = RegInit(0.U(FtqPtrWidth.W))
    val ftqTail = RegInit(0.U(FtqPtrWidth.W))
    val ftqCount = RegInit(0.U(FtqCountWidth.W))
    val stage0Valid = RegInit(false.B)
    val stage0StartPc = Reg(UInt(PC_DATA_WIDTH.W))
    val stage0FtqIdx = Reg(UInt(FtqPtrWidth.W))
    val stage1Valid = RegInit(false.B)
    val stage1 = Reg(new TageFetchBlockMeta)
    val stage2Valid = RegInit(false.B)
    val stage2 = Reg(new TageFetchBlockMeta)

    val fastMatchesStage0 = stage0Valid && bpu.io.resp_valid &&
      bpu.io.resp_pc === stage0StartPc
    val fastNextPc = bpu.io.predicted_pc

    val controlPc = (stage2.startPc & "hfffffff8".U) +
      Mux(stage2.predictedSlot, 4.U, 0.U)
    val tageMatchesStage2 = stage2Valid && bpu.io.tage_resp_valid.get &&
      bpu.io.tage_resp_pc.get === controlPc &&
      bpu.io.tage_resp_id.get === stage2.fetchId &&
      bpu.io.tage_resp_epoch.get === stage2.fetchEpoch
    val finalTaken = Mux(tageMatchesStage2,
      bpu.io.tage_predicted_taken.get, stage2.predictedTaken)
    val finalNextPc = Mux(tageMatchesStage2,
      bpu.io.tage_predicted_pc.get, stage2.predictedPc)
    val tageOverride = tageMatchesStage2 &&
      bpu.io.tage_predicted_pc.get =/= stage2.predictedPc
    val internalTageOverride = tageOverride && !io.redirected
    val frontendFlush = io.redirected || tageOverride

    bpu.io.frontend_flush.get := frontendFlush
    bpu.io.external_redirect.get := io.redirected
    bpu.io.restore_committed.get := io.redirected &&
      !(io.bpu_update_en && io.bpu_update_is_branch.get &&
        io.bpu_update_tage_meta.get.valid)
    if (CONFIG_BRANCH_RAS) {
      bpu.io.ras_restore.get := frontendFlush
    }
    if (CONFIG_BRANCH_LOOP_PREDICTOR) {
      // A TAGE S2 correction keeps the corrected branch itself.  Its final
      // direction advances the loop cursor in BPU; only an architectural
      // redirect restores speculative loop state to the committed cursor.
      bpu.io.loop_restore.get := io.redirected
    }

    // IROM and the fast predictor return together after one cycle.  The block
    // enters the instruction queue provisionally; the pipelined TAGE response
    // finalizes it two cycles later before that block can be consumed.
    val fastResponseUsable = fastMatchesStage0 && !frontendFlush
    val fastResponseBlockPc = stage0StartPc & "hfffffff8".U
    val fastResponseStartSlot = stage0StartPc(2)
    val fastResponseEndSlot = Mux(bpu.io.predicted_hit,
      bpu.io.predicted_slot, true.B)
    val enqueueCount = Wire(UInt(2.W))
    enqueueCount := 0.U
    when (fastResponseUsable) {
      enqueueCount := Cat(0.U(1.W), fastResponseEndSlot) -
        Cat(0.U(1.W), fastResponseStartSlot) + 1.U
    }

    val countBeforePendingDequeue = queueCount +& enqueueCount
    val countAfterResponse =
      countBeforePendingDequeue - pendingDequeueCount

    // Retire FTQ entries together with the already-registered dequeue that is
    // being applied to the physical IQ head this cycle.  Using the new
    // downstream consume decision here would create a long feedback path:
    // IQ output/decode -> consume_count -> FTQ occupancy -> fetch request.
    // FTQ capacity is therefore released one cycle later only when full;
    // steady-state fetch throughput is unchanged.
    val appliedFtqLast = Wire(Vec(DualIssue.Width, Bool()))
    for (lane <- 0 until DualIssue.Width) {
      appliedFtqLast(lane) := pendingDequeueCount > lane.U &&
        queue(ptrAdd(queueHead, lane.U)).ftq_last.get
    }
    val ftqPopCount = PopCount(appliedFtqLast)
    val tageFtqEntry = ftq(stage2.ftqIdx)
    val ftqAfterTage = ftqPtrAdd(stage2.ftqIdx, 1.U)
    val youngerFtqCount = ftqPtrDistance(ftqAfterTage, ftqTail)
    val retainedFtqCount = ftqCount - youngerFtqCount
    val tageIqTailAfter = ptrAdd(tageFtqEntry.iqStart,
      tageFtqEntry.iqCount)
    val youngerQueueCount = queuePtrDistance(tageIqTailAfter, queueTail)
    val countAfterOverride =
      queueCount - pendingDequeueCount - youngerQueueCount
    // Do not feed the current downstream dequeue decision back into either
    // reservation path.  IQ has a complete-response reserve, while FTQ waits
    // one cycle when exactly full instead of making request launch depend on
    // the same-cycle pop.
    val iqReservationCount =
      Mux(tageOverride, countAfterOverride, countAfterResponse)
    val iqHasReservation = iqReservationCount <= QueueDepth.U
    val normalFtqHasSpace = ftqCount < FtqDepth.U
    val overrideFtqHasSpace = retainedFtqCount < FtqDepth.U
    val ftqHasReservation = Mux(tageOverride,
      overrideFtqHasSpace, normalFtqHasSpace)
    val requestHasReservation = iqHasReservation && ftqHasReservation

    val requestCandidateValid = frontendFlush || fastMatchesStage0 ||
      nextRequestValid
    val requestCandidatePc = Mux(io.redirected, io.redirected_pc,
      Mux(tageOverride, finalNextPc,
        Mux(fastMatchesStage0, fastNextPc, nextRequestPc.io.dout)))
    // An internal TAGE override may immediately launch the corrected block.
    // That request enters IROM and the fast predictor now; its TAGE lookup
    // starts from the fast response on the following cycle, after the old
    // TAGE token has been flushed. Architectural redirects retain the
    // conservative one-cycle restart behavior.
    val requestFire = requestCandidateValid && requestHasReservation &&
      !io.redirected

    statRequestCandidate := requestCandidateValid
    statReservationAvailable := requestHasReservation
    statRequestFire := requestFire
    statInflightCount := ftqCount
    statResponseUsable := fastResponseUsable
    statEnqueueCount := enqueueCount
    statIqReservationAvailable := iqHasReservation
    statFtqReservationAvailable := ftqHasReservation
    statFtqCount := ftqCount
    statFtqAllocCount := requestFire
    statFtqPopCount := ftqPopCount
    statFtqRollbackCount := Mux(internalTageOverride,
      youngerFtqCount, 0.U)

    tageOverrideEvent.get := internalTageOverride
    tageOverrideRestart.get := internalTageOverride && requestFire
    tageOverrideBlocked.get := internalTageOverride && !requestFire
    if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
      val fastLoopProvisional = tageMatchesStage2 &&
        stage2.loopMeta.get.valid && stage2.loopMeta.get.candidate
      tageFastLoopProvisional.get := fastLoopProvisional
      tageOverrideReplacedLoop.get := internalTageOverride &&
        fastLoopProvisional
    }

    val responseUsable = stage2Valid && tageMatchesStage2 && !io.redirected
    tageFinalizeValid.get := responseUsable
    tageFinalizeFtqIdx.get := stage2.ftqIdx
    tageFinalizeCfiPc.get := controlPc
    tageFinalizeTaken.get := finalTaken
    tageFinalizeNextPc.get := finalNextPc
    tageFinalizeMeta.get := bpu.io.tage_meta.get
    tageFinalizePathOverride.get := internalTageOverride

    io.irom.addr := requestCandidatePc & "hfffffff8".U
    io.ready := requestFire
    bpu.io.req_valid := requestFire
    bpu.io.current_pc := requestCandidatePc

    // The saved value is ignored while nextRequestValid is clear. Capture the
    // candidate unconditionally so the PC-register enable does not depend on
    // same-cycle dequeue/reservation control.
    nextRequestPc.io.wen := requestCandidateValid
    nextRequestPc.io.din := requestCandidatePc

    when (frontendFlush) {
      nextRequestValid := !requestFire
    }.elsewhen(fastMatchesStage0) {
      nextRequestValid := !requestFire
    }.elsewhen(nextRequestValid && requestFire) {
      nextRequestValid := false.B
    }

    val requestFtqIdx = Mux(tageOverride, ftqAfterTage, ftqTail)

    when (io.redirected) {
      stage0Valid := false.B
      stage1Valid := false.B
      stage2Valid := false.B
    }.elsewhen(tageOverride) {
      stage0Valid := requestFire
      stage1Valid := false.B
      stage2Valid := false.B
      when (requestFire) {
        stage0StartPc := requestCandidatePc
        stage0FtqIdx := requestFtqIdx
      }
    }.otherwise {
      stage2Valid := stage1Valid
      when (stage1Valid) {
        stage2 := stage1
      }
      stage1Valid := fastResponseUsable
      when (fastResponseUsable) {
        stage1.startPc := stage0StartPc
        stage1.predictedTaken := bpu.io.predicted_taken
        stage1.predictedPc := bpu.io.predicted_pc
        stage1.predictedSlot := bpu.io.predicted_slot
        stage1.predictedHit := bpu.io.predicted_hit
        stage1.fetchId := bpu.io.resp_id.get
        stage1.fetchEpoch := bpu.io.resp_epoch.get
        stage1.ftqIdx := stage0FtqIdx
        if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
          stage1.loopMeta.get.valid := bpu.io.loop_meta_valid.get
          stage1.loopMeta.get.candidate := bpu.io.loop_candidate.get
          stage1.loopMeta.get.prediction := bpu.io.loop_prediction.get
          stage1.loopMeta.get.basePrediction :=
            bpu.io.loop_base_prediction.get
        }
        if (CONFIG_BRANCH_FAST_RECURRENCE) {
          stage1.frpOwned.get := bpu.io.frp_owned.get
        }
      }
      stage0Valid := requestFire
      when (requestFire) {
        stage0StartPc := requestCandidatePc
        stage0FtqIdx := requestFtqIdx
      }
    }

    when (io.redirected) {
      queueHead := 0.U
      queueTail := 0.U
      queueCount := 0.U
      pendingDequeueCount := 0.U
    }.otherwise {
      for (slot <- 0 until DualIssue.Width) {
        val slotSelected = fastResponseUsable &&
          slot.U >= fastResponseStartSlot &&
          slot.U <= fastResponseEndSlot
        val enqueueOffset = Cat(0.U(1.W), slot.U(1.W)) -
          Cat(0.U(1.W), fastResponseStartSlot)
        val writeIndex = ptrAdd(queueTail, enqueueOffset)
        val slotPc = fastResponseBlockPc + (slot * 4).U
        val slotPredictedTaken = bpu.io.predicted_taken &&
          bpu.io.predicted_slot === slot.U

        when (slotSelected) {
          queue(writeIndex).pc := slotPc
          queue(writeIndex).inst := io.irom.data(32 * slot + 31, 32 * slot)
          queue(writeIndex).predicted_taken := slotPredictedTaken
          queue(writeIndex).predicted_pc :=
            Mux(slotPredictedTaken, fastNextPc, slotPc + 4.U)
          queue(writeIndex).ftq_idx.get := stage0FtqIdx
          queue(writeIndex).ftq_last.get := slot.U === fastResponseEndSlot
          queue(writeIndex).ftq_finalized.get := false.B
          if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
            queue(writeIndex).loop_meta.get :=
              0.U.asTypeOf(new LoopPredictionMetaBundle)
            when (bpu.io.predicted_slot === slot.U) {
              queue(writeIndex).loop_meta.get.valid :=
                bpu.io.loop_meta_valid.get
              queue(writeIndex).loop_meta.get.candidate :=
                bpu.io.loop_candidate.get
              queue(writeIndex).loop_meta.get.prediction :=
                bpu.io.loop_prediction.get
              queue(writeIndex).loop_meta.get.basePrediction :=
                bpu.io.loop_base_prediction.get
            }
          }
          if (CONFIG_BRANCH_FAST_RECURRENCE) {
            queue(writeIndex).frp_owned.get :=
              bpu.io.frp_owned.get && bpu.io.predicted_slot === slot.U
          }
        }
      }

      for (offset <- 0 until DualIssue.Width) {
        val finalizeIndex = ptrAdd(tageFtqEntry.iqStart, offset.U)
        when (responseUsable && offset.U < tageFtqEntry.iqCount) {
          queue(finalizeIndex).ftq_finalized.get := true.B
          when (queue(finalizeIndex).pc === controlPc) {
            queue(finalizeIndex).predicted_taken := finalTaken
            queue(finalizeIndex).predicted_pc := finalNextPc
          }
        }
      }

      when (responseUsable) {
        tageMetaSidecar.get.write(stage2.ftqIdx, bpu.io.tage_meta.get)
        tageCfiSlotSidecar.get.write(stage2.ftqIdx, controlPc(2))
      }

      when (pendingDequeueCount =/= 0.U) {
        queueHead := ptrAdd(queueHead, pendingDequeueCount)
      }
      when (tageOverride) {
        queueTail := tageIqTailAfter
        queueCount := countAfterOverride
      }.otherwise {
        queueCount := countAfterResponse
      }
      when (!tageOverride && enqueueCount =/= 0.U) {
        queueTail := ptrAdd(queueTail, enqueueCount)
      }
      pendingDequeueCount := dequeueCount
    }

    val retainedAfterPop = retainedFtqCount - ftqPopCount
    when (io.redirected) {
      ftqHead := 0.U
      ftqTail := 0.U
      ftqCount := 0.U
    }.elsewhen(tageOverride) {
      ftqHead := ftqPtrAdd(ftqHead, ftqPopCount)
      ftqTail := ftqPtrAdd(ftqAfterTage, requestFire.asUInt)
      ftqCount := retainedAfterPop + requestFire.asUInt
    }.otherwise {
      ftqHead := ftqPtrAdd(ftqHead, ftqPopCount)
      ftqTail := ftqPtrAdd(ftqTail, requestFire.asUInt)
      ftqCount := ftqCount + requestFire.asUInt - ftqPopCount
    }
    when (fastResponseUsable) {
      ftq(stage0FtqIdx).iqStart := queueTail
      ftq(stage0FtqIdx).iqCount := enqueueCount
    }

    assert(!stage0Valid || bpu.io.resp_valid,
      "BPU fast response did not follow a dual-fetch request")
    assert(!stage2Valid || tageMatchesStage2,
      "TAGE response did not align with its FTQ entry")
    assert(ftqCount <= FtqDepth.U,
      "fetch target queue occupancy exceeded its configured depth")
    assert(!tageOverride || youngerFtqCount <= ftqCount,
      "TAGE override did not reference a live FTQ entry")
    assert(!tageOverride || youngerQueueCount <= effectiveQueueCount,
      "TAGE override did not reference live instruction queue entries")
    assert(countAfterResponse <= QueueStorageDepth.U,
      "instruction response exceeded the reserved queue capacity")
    assert(!fastResponseUsable || enqueueCount =/= 0.U,
      "64-bit instruction response produced an empty block")
    assert(!requestFire || requestHasReservation,
      "instruction request launched without IQ and FTQ reservations")
  } else {
    if (CONFIG_BRANCH_RAS) {
      bpu.io.ras_restore.get := io.redirected
    }
    if (CONFIG_BRANCH_LOOP_PREDICTOR) {
      bpu.io.loop_restore.get := io.redirected
    }

    val responseValid = RegInit(false.B)
    val responseStartPc = Reg(UInt(PC_DATA_WIDTH.W))
    val responseUsable = responseValid && bpu.io.resp_valid && !io.redirected

    val responseBlockPc = responseStartPc & "hfffffff8".U
    val responseStartSlot = responseStartPc(2)
    val responseEndSlot = Mux(bpu.io.predicted_hit,
      bpu.io.predicted_slot, true.B)
    val enqueueCount = Wire(UInt(2.W))
    enqueueCount := 0.U
    when (responseUsable) {
      enqueueCount := Cat(0.U(1.W), responseEndSlot) -
        Cat(0.U(1.W), responseStartSlot) + 1.U
    }

    val responseNextPc = bpu.io.predicted_pc
    val requestCandidateValid = responseUsable || nextRequestValid
    val requestCandidatePc = Mux(responseUsable,
      responseNextPc, nextRequestPc.io.dout)
    val countBeforePendingDequeue = queueCount +& enqueueCount
    val countAfterResponse =
      countBeforePendingDequeue - pendingDequeueCount
    val requestHasReservation = countAfterResponse <= QueueDepth.U
    val requestFire = requestCandidateValid && requestHasReservation &&
      !io.redirected

    statRequestCandidate := requestCandidateValid
    statReservationAvailable := requestHasReservation
    statRequestFire := requestFire
    statInflightCount := responseValid
    statResponseUsable := responseUsable
    statEnqueueCount := enqueueCount
    statIqReservationAvailable := requestHasReservation

    io.irom.addr := requestCandidatePc & "hfffffff8".U
    bpu.io.req_valid := requestFire
    bpu.io.current_pc := requestCandidatePc
    io.ready := requestFire

    nextRequestPc.io.wen := io.redirected || responseUsable
    nextRequestPc.io.din :=
      Mux(io.redirected, io.redirected_pc, responseNextPc)

    when (io.redirected) {
      nextRequestValid := true.B
    }.elsewhen(responseUsable) {
      nextRequestValid := !requestFire
    }.elsewhen(nextRequestValid && requestFire) {
      nextRequestValid := false.B
    }

    when (io.redirected) {
      responseValid := false.B
    }.otherwise {
      responseValid := requestFire
      when (requestCandidateValid) {
        responseStartPc := requestCandidatePc
      }
    }

    when (io.redirected) {
      queueHead := 0.U
      queueTail := 0.U
      queueCount := 0.U
      pendingDequeueCount := 0.U
    }.otherwise {
      for (slot <- 0 until DualIssue.Width) {
        val slotSelected = responseUsable &&
          slot.U >= responseStartSlot && slot.U <= responseEndSlot
        val enqueueOffset = Cat(0.U(1.W), slot.U(1.W)) -
          Cat(0.U(1.W), responseStartSlot)
        val writeIndex = ptrAdd(queueTail, enqueueOffset)
        val slotPc = responseBlockPc + (slot * 4).U
        val slotPredictedTaken = bpu.io.predicted_taken &&
          bpu.io.predicted_slot === slot.U

        when (slotSelected) {
          queue(writeIndex).pc := slotPc
          queue(writeIndex).inst := io.irom.data(32 * slot + 31, 32 * slot)
          queue(writeIndex).predicted_taken := slotPredictedTaken
          queue(writeIndex).predicted_pc :=
            Mux(slotPredictedTaken, bpu.io.predicted_pc, slotPc + 4.U)
          if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
            queue(writeIndex).loop_meta.get :=
              0.U.asTypeOf(new LoopPredictionMetaBundle)
            when (bpu.io.predicted_slot === slot.U) {
              queue(writeIndex).loop_meta.get.valid :=
                bpu.io.loop_meta_valid.get
              queue(writeIndex).loop_meta.get.candidate :=
                bpu.io.loop_candidate.get
              queue(writeIndex).loop_meta.get.prediction :=
                bpu.io.loop_prediction.get
              queue(writeIndex).loop_meta.get.basePrediction :=
                bpu.io.loop_base_prediction.get
            }
          }
          if (CONFIG_BRANCH_FAST_RECURRENCE) {
            queue(writeIndex).frp_owned.get :=
              bpu.io.frp_owned.get && bpu.io.predicted_slot === slot.U
          }
        }
      }

      when (pendingDequeueCount =/= 0.U) {
        queueHead := ptrAdd(queueHead, pendingDequeueCount)
      }
      when (enqueueCount =/= 0.U) {
        queueTail := ptrAdd(queueTail, enqueueCount)
      }
      queueCount := countAfterResponse
      pendingDequeueCount := dequeueCount
    }

    assert(!responseUsable || bpu.io.resp_pc === responseStartPc,
      "IROM and block predictor responses lost alignment")
    assert(countAfterResponse <= QueueStorageDepth.U,
      "instruction response exceeded the reserved queue capacity")
    assert(!responseUsable || enqueueCount =/= 0.U,
      "64-bit instruction response produced an empty block")
    assert(!requestFire || requestHasReservation,
      "instruction request launched without two reserved entries")
  }

  assert(queueCount <= QueueStorageDepth.U,
    "instruction queue occupancy exceeded its physical depth")
  assert(pendingDequeueCount <= queueCount,
    "registered instruction dequeue exceeded physical occupancy")
  assert(!io.out.valid || Func.isDualLanePrefix(io.out.bits.laneValid),
    "instruction queue must expose a contiguous oldest prefix")
  assert(!io.out.fire || io.consume_count =/= 0.U,
    "instruction queue handshake consumed no instruction")
  assert(!io.out.fire || io.consume_count <= PopCount(io.out.bits.laneValid),
    "instruction queue consumed beyond the offered prefix")

  if (CONFIG_SIMULATION) {
    val dpic = Module(new IFU_DPIC)
    dpic.io.clk := clock
    dpic.io.valid := io.out.valid
    dpic.io.bpu_resp_valid := bpu.io.resp_valid
    dpic.io.bpu_resp_pc := bpu.io.resp_pc
    dpic.io.bpu_predicted_pc := bpu.io.predicted_pc
    dpic.io.bpu_predicted_taken := bpu.io.predicted_taken
    dpic.io.bpu_predicted_slot := bpu.io.predicted_slot
    dpic.io.bpu_predicted_hit := bpu.io.predicted_hit
    dpic.io.frontend_external_redirect := io.redirected
    dpic.io.frontend_queue_count := queueCount
    dpic.io.frontend_downstream_ready := io.out.ready
    dpic.io.frontend_dequeue_count := dequeueCount
    dpic.io.frontend_request_candidate := statRequestCandidate
    dpic.io.frontend_reservation_available := statReservationAvailable
    dpic.io.frontend_request_fire := statRequestFire
    dpic.io.frontend_inflight_count := statInflightCount
    dpic.io.frontend_response_usable := statResponseUsable
    dpic.io.frontend_enqueue_count := statEnqueueCount
    dpic.io.frontend_iq_reservation_available :=
      statIqReservationAvailable
    dpic.io.frontend_ftq_reservation_available :=
      statFtqReservationAvailable
    dpic.io.frontend_ftq_count := statFtqCount
    dpic.io.frontend_ftq_alloc_count := statFtqAllocCount
    dpic.io.frontend_ftq_pop_count := statFtqPopCount
    dpic.io.frontend_ftq_rollback_count := statFtqRollbackCount
    if (CONFIG_BP_TAGE) {
      dpic.io.tage_resp_valid.get := bpu.io.tage_resp_valid.get
      dpic.io.tage_resp_pc.get := bpu.io.tage_resp_pc.get
      dpic.io.tage_provisional_pc.get := bpu.io.tage_provisional_pc.get
      dpic.io.tage_final_pc.get := bpu.io.tage_predicted_pc.get
      dpic.io.tage_final_taken.get := bpu.io.tage_predicted_taken.get
      dpic.io.tage_override.get := tageOverrideEvent.get
      dpic.io.tage_override_restart.get := tageOverrideRestart.get
      dpic.io.tage_override_blocked.get := tageOverrideBlocked.get
      if (CONFIG_BRANCH_LOOP_PREDICTOR) {
        dpic.io.tage_fast_loop_provisional.get :=
          tageFastLoopProvisional.get
        dpic.io.tage_override_replaced_loop.get :=
          tageOverrideReplacedLoop.get
      }
    }
  }
}

class IFU_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val valid = Input(Bool())
    val bpu_resp_valid = Input(Bool())
    val bpu_resp_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_predicted_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_predicted_taken = Input(Bool())
    val bpu_predicted_slot = Input(Bool())
    val bpu_predicted_hit = Input(Bool())
    val frontend_external_redirect = Input(Bool())
    val frontend_queue_count = Input(UInt(32.W))
    val frontend_downstream_ready = Input(Bool())
    val frontend_dequeue_count = Input(UInt(32.W))
    val frontend_request_candidate = Input(Bool())
    val frontend_reservation_available = Input(Bool())
    val frontend_request_fire = Input(Bool())
    val frontend_inflight_count = Input(UInt(32.W))
    val frontend_response_usable = Input(Bool())
    val frontend_enqueue_count = Input(UInt(32.W))
    val frontend_iq_reservation_available = Input(Bool())
    val frontend_ftq_reservation_available = Input(Bool())
    val frontend_ftq_count = Input(UInt(32.W))
    val frontend_ftq_alloc_count = Input(UInt(32.W))
    val frontend_ftq_pop_count = Input(UInt(32.W))
    val frontend_ftq_rollback_count = Input(UInt(32.W))
    val tage_resp_valid = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val tage_resp_pc = if (CONFIG_BP_TAGE) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val tage_provisional_pc = if (CONFIG_BP_TAGE) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val tage_final_pc = if (CONFIG_BP_TAGE) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val tage_final_taken = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val tage_override = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val tage_override_restart = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val tage_override_blocked = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val tage_fast_loop_provisional = if (CONFIG_BP_TAGE &&
        CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val tage_override_replaced_loop = if (CONFIG_BP_TAGE &&
        CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
  })
}
