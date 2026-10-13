package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import TageParams._

class BPU extends Module {
  val io = IO(new Bundle {
    val req_valid       = Input(Bool())
    val current_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid      = Output(Bool())
    val resp_pc         = Output(UInt(PC_DATA_WIDTH.W))
    val predicted_taken = Output(Bool())
    val predicted_pc    = Output(UInt(PC_DATA_WIDTH.W))
    val predicted_slot  = Output(Bool())
    val predicted_hit   = Output(Bool())
    val loop_meta_valid = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Output(Bool())) else None
    val loop_candidate = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Output(Bool())) else None
    val loop_prediction = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Output(Bool())) else None
    val loop_base_prediction = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Output(Bool())) else None
    val frp_owned       = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Output(Bool())) else None
    val frp_update_active = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Output(Bool())) else None
    val frp_boundary_mismatch = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Output(Bool())) else None
    val frp_blocked_by_issued = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Output(Bool())) else None
    val resp_id         = if (CONFIG_BP_TAGE) Some(Output(UInt(4.W))) else None
    val resp_epoch      = if (CONFIG_BP_TAGE) Some(Output(Bool())) else None

    val tage_resp_valid      = if (CONFIG_BP_TAGE) Some(Output(Bool())) else None
    val tage_resp_pc         = if (CONFIG_BP_TAGE) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val tage_resp_id         = if (CONFIG_BP_TAGE) Some(Output(UInt(4.W))) else None
    val tage_resp_epoch      = if (CONFIG_BP_TAGE) Some(Output(Bool())) else None
    val tage_predicted_taken = if (CONFIG_BP_TAGE) Some(Output(Bool())) else None
    val tage_predicted_pc    = if (CONFIG_BP_TAGE) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val tage_provisional_pc  = if (CONFIG_BP_TAGE) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val tage_meta            = if (CONFIG_BP_TAGE) Some(Output(new TageMetaBundle)) else None

    val frontend_flush   = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val external_redirect = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val restore_committed = if (CONFIG_BP_TAGE) Some(Input(Bool())) else None
    val ras_restore = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val loop_restore = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None

    val update_en       = Input(Bool())
    val update_pc       = Input(UInt(PC_DATA_WIDTH.W))
    val update_ras_push = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val update_ras_pop  = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val actual_taken    = Input(Bool())
    val actual_target   = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Input(Bool())) else None
    val update_tage_meta = if (CONFIG_BP_TAGE) Some(Input(new TageMetaBundle)) else None
    val update_frp_owned = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val update_frp = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(new FastRecurrenceUpdateBundle)) else None
  })

  val branchPredict = Module(if (
    CONFIG_BRANCH_PREDICT == BP_BIMODAL || CONFIG_BRANCH_PREDICT == BP_TAGE) {
    if (CONFIG_BRANCH_RAS) new BimodalRasWrapper else new BimodalWrapper
  } else {
    new AlwaysNotTaken
  })

  branchPredict.io.current_pc    := io.current_pc
  branchPredict.io.req_valid     := io.req_valid
  branchPredict.io.update_en     := io.update_en
  branchPredict.io.update_pc     := io.update_pc
  branchPredict.io.actual_taken  := io.actual_taken
  branchPredict.io.actual_target := io.actual_target
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    branchPredict.io.update_is_branch.get := io.update_is_branch.get
  }
  if (CONFIG_BRANCH_LOOP_PREDICTOR) {
    branchPredict.io.loop_restore.get := io.loop_restore.get
  }

  val predictedInRange = branchPredict.io.predicted_hit &&
    (!branchPredict.io.resp_pc(2) || branchPredict.io.predicted_slot)
  val fastControlPc = (branchPredict.io.resp_pc & "hfffffff8".U) +
    Mux(branchPredict.io.predicted_slot, 4.U, 0.U)

  var fastTaken = branchPredict.io.predicted_taken && predictedInRange
  var fastTarget = branchPredict.io.predicted_pc

  if (CONFIG_BP_TAGE) {
    fastTaken = predictedInRange && Mux(
      branchPredict.io.predicted_is_branch.get,
      branchPredict.io.predicted_taken,
      true.B)
  }

  if (CONFIG_BRANCH_RAS) {
    branchPredict.io.update_is_return.get := io.update_ras_pop.get
    branchPredict.io.update_is_call.get := io.update_ras_push.get
    val ras = Module(new ReturnAddressStack)
    ras.io.clk := clock
    ras.io.rst := reset
    ras.io.commit_push := io.update_en && io.update_ras_push.get
    ras.io.commit_pop := io.update_en && io.update_ras_pop.get
    ras.io.commit_addr := io.update_ras_addr.get
    ras.io.restore := io.ras_restore.get

    var rasResponseValid = branchPredict.io.resp_valid && !io.ras_restore.get
    if (CONFIG_BP_TAGE) {
      rasResponseValid = rasResponseValid && !io.frontend_flush.get
    }
    ras.io.spec_push := rasResponseValid && predictedInRange &&
      branchPredict.io.predicted_is_call.get
    ras.io.spec_pop := rasResponseValid && predictedInRange &&
      branchPredict.io.predicted_is_return.get
    ras.io.spec_addr := (branchPredict.io.resp_pc & "hfffffff8".U) +
      Mux(branchPredict.io.predicted_slot, 8.U, 4.U)

    val returnHit = predictedInRange &&
      branchPredict.io.predicted_is_return.get && ras.io.top_valid
    fastTaken = returnHit || fastTaken
    fastTarget = Mux(returnHit, ras.io.top_addr, fastTarget)
  }

  var frpOwned = false.B
  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    val frp = Module(new FastRecurrencePredictor)
    frp.io.req_valid := io.req_valid
    frp.io.req_pc := io.current_pc
    frp.io.resolve_valid := io.update_en && io.update_is_branch.get
    frp.io.resolve_pc := io.update_pc
    frp.io.update_valid := io.update_en && io.update_is_branch.get &&
      io.update_frp.get.valid
    frp.io.update_pc := io.update_pc
    frp.io.update_state := io.update_frp.get.state
    frp.io.update_beqz := io.update_frp.get.beqz

    frpOwned = frp.io.resp_valid && frp.io.pred_valid &&
      branchPredict.io.resp_valid && predictedInRange &&
      branchPredict.io.predicted_is_branch.get &&
      frp.io.resp_pc === branchPredict.io.resp_pc &&
      frp.io.pred_branch_pc === fastControlPc
    fastTaken = Mux(frpOwned, frp.io.pred_taken, fastTaken)
    io.frp_owned.get := frpOwned
    io.frp_update_active.get := frp.io.update_active
    io.frp_boundary_mismatch.get := frp.io.boundary_mismatch
    io.frp_blocked_by_issued.get := frp.io.blocked_by_issued

    when(branchPredict.io.resp_valid) {
      assert(frp.io.resp_valid && frp.io.resp_pc === branchPredict.io.resp_pc,
        "fast recurrence and Bimodal responses lost alignment")
    }
  }

  io.resp_valid      := branchPredict.io.resp_valid
  io.resp_pc         := branchPredict.io.resp_pc
  io.predicted_taken := fastTaken
  val fastFallThrough = Mux(predictedInRange,
    fastControlPc + 4.U,
    (branchPredict.io.resp_pc & "hfffffff8".U) + 8.U)
  io.predicted_pc :=
    Mux(fastTaken, fastTarget, fastFallThrough)
  io.predicted_slot := branchPredict.io.predicted_slot
  io.predicted_hit := predictedInRange
  if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR) {
    io.loop_meta_valid.get := branchPredict.io.resp_valid &&
      predictedInRange && branchPredict.io.predicted_is_branch.get
    io.loop_candidate.get := branchPredict.io.predicted_loop_override.get
    io.loop_prediction.get := branchPredict.io.predicted_loop_taken.get
    io.loop_base_prediction.get := branchPredict.io.predicted_base_taken.get
  }

  if (CONFIG_BP_TAGE) {
    val requestId = RegInit(0.U(4.W))
    val requestEpoch = RegInit(false.B)
    val allocatedEpoch = Mux(io.frontend_flush.get, !requestEpoch, requestEpoch)
    val fastResponseId = RegEnable(requestId, io.req_valid)
    val fastResponseEpoch = RegEnable(allocatedEpoch, io.req_valid)
    when (io.req_valid) {
      requestId := requestId + 1.U
    }
    when (io.frontend_flush.get) {
      requestEpoch := !requestEpoch
    }
    io.resp_id.get := fastResponseId
    io.resp_epoch.get := fastResponseEpoch

    val tage = Module(new TageDirection)
    tage.io.clk := clock
    tage.io.rst := reset
    val fastBranchValid = branchPredict.io.resp_valid && predictedInRange &&
      branchPredict.io.predicted_is_branch.get &&
      !io.frontend_flush.get
    tage.io.req_valid := fastBranchValid
    tage.io.req_pc := fastControlPc
    tage.io.fast_base_taken := branchPredict.io.predicted_base_taken.get
    tage.io.fast_loop_override := branchPredict.io.predicted_loop_override.get
    tage.io.fast_loop_taken := branchPredict.io.predicted_loop_taken.get
    tage.io.fast_direction_override := frpOwned
    tage.io.fast_override_taken := fastTaken
    // A pipelined response reaches IFU one cycle after TAGE has already made
    // its direction decision.  Kill the following speculative lookup at that
    // earlier point when the direction changes, otherwise the soon-to-be
    // discarded younger branch would still advance TAGE global history.
    val earlyTageCorrectionFlush = WireDefault(false.B)
    tage.io.pipeline_flush := io.frontend_flush.get ||
      earlyTageCorrectionFlush
    val tageUpdateValid = io.update_en && io.update_is_branch.get &&
      io.update_tage_meta.get.valid
    val tageUpdateFiltered = if (CONFIG_BRANCH_FAST_RECURRENCE)
      tageUpdateValid && io.update_frp_owned.get else false.B
    tage.io.update_en := tageUpdateValid && !tageUpdateFiltered
    tage.io.update_skip_history := tageUpdateFiltered
    if (CONFIG_BRANCH_LOOP_PREDICTOR) {
      tage.io.update_pc.get := io.update_pc
    }
    tage.io.update_actual_taken := io.actual_taken
    tage.io.update_meta := io.update_tage_meta.get.bits
    tage.io.recover_en := io.external_redirect.get && io.update_en &&
      io.update_is_branch.get && io.update_tage_meta.get.valid
    tage.io.recover_actual_taken := io.actual_taken
    tage.io.recover_meta := io.update_tage_meta.get.bits
    tage.io.restore_committed := io.restore_committed.get

    val fastValidS2 = RegNext(branchPredict.io.resp_valid &&
      !io.frontend_flush.get && !earlyTageCorrectionFlush, false.B)
    val fastPcS2 = RegNext(branchPredict.io.resp_pc)
    val fastIdS2 = RegNext(fastResponseId)
    val fastEpochS2 = RegNext(fastResponseEpoch)
    val fastTakenS2 = RegNext(fastTaken)
    val fastTargetS2 = RegNext(fastTarget)
    val fastSlotS2 = RegNext(branchPredict.io.predicted_slot)
    val fastHitS2 = RegNext(predictedInRange)
    val fastIsBranchS2 = RegNext(
      branchPredict.io.predicted_is_branch.get && predictedInRange)
    val fastLoopOverrideS2 = if (CONFIG_BRANCH_LOOP_PREDICTOR)
      RegNext(branchPredict.io.predicted_loop_override.get, false.B)
    else false.B
    val fastFrpOwnedS2 = if (CONFIG_BRANCH_FAST_RECURRENCE)
      RegNext(frpOwned, false.B) else false.B
    val blockFallThroughS2 = (fastPcS2 & "hfffffff8".U) + 8.U
    val controlPcS2 = (fastPcS2 & "hfffffff8".U) +
      Mux(fastSlotS2, 4.U, 0.U)
    val cfiFallThroughS2 = controlPcS2 + 4.U
    val provisionalPcS2 = Mux(fastTakenS2, fastTargetS2,
      Mux(fastHitS2, cfiFallThroughS2,
        blockFallThroughS2))
    val finalTaken = Mux(fastIsBranchS2 && !fastFrpOwnedS2 && tage.io.resp_valid,
      tage.io.pred_taken, fastTakenS2)
    val finalPc = Mux(finalTaken, fastTargetS2,
      Mux(fastHitS2, cfiFallThroughS2, blockFallThroughS2))
    earlyTageCorrectionFlush := fastValidS2 && fastIsBranchS2 &&
      !fastFrpOwnedS2 && tage.io.resp_valid &&
      finalTaken =/= fastTakenS2

    if (CONFIG_BRANCH_LOOP_PREDICTOR) {
      // The loop cursor follows the direction that S2 actually releases to
      // the frontend.  Advancing it in S1 would require undo/repair whenever
      // TAGE selects a different direction.
      branchPredict.io.loop_spec_update_en.get :=
        fastValidS2 && fastIsBranchS2 && fastLoopOverrideS2 &&
          tage.io.resp_valid && !io.external_redirect.get
      branchPredict.io.loop_spec_update_pc.get := controlPcS2
      branchPredict.io.loop_spec_update_taken.get := finalTaken
    }

    // Isolate the TAGE table/provider path from the IFU rollback and queue
    // control.  Register the complete response as one aligned transaction;
    // IFU carries the matching FTQ block through an additional wait stage.
    val tageRespValidS3 = RegNext(fastValidS2 &&
      (!fastIsBranchS2 || fastFrpOwnedS2 || tage.io.resp_valid), false.B)
    val tageRespPcS3 = RegNext(controlPcS2)
    val tageRespIdS3 = RegNext(fastIdS2)
    val tageRespEpochS3 = RegNext(fastEpochS2)
    val tagePredictedTakenS3 = RegNext(finalTaken)
    val tagePredictedPcS3 = RegNext(finalPc)
    val tageProvisionalPcS3 = RegNext(provisionalPcS2)
    val tageMetaBitsS3 = RegNext(tage.io.resp_meta)
    val tageMetaValidS3 = RegNext(fastIsBranchS2 && tage.io.resp_valid,
      false.B)

    io.tage_resp_valid.get := tageRespValidS3
    io.tage_resp_pc.get := tageRespPcS3
    io.tage_resp_id.get := tageRespIdS3
    io.tage_resp_epoch.get := tageRespEpochS3
    io.tage_predicted_taken.get := tagePredictedTakenS3
    io.tage_predicted_pc.get := tagePredictedPcS3
    io.tage_provisional_pc.get := tageProvisionalPcS3
    io.tage_meta.get.bits := tageMetaBitsS3
    io.tage_meta.get.valid := tageMetaValidS3

    when (fastValidS2 && fastIsBranchS2) {
      assert(tage.io.resp_valid && tage.io.resp_pc === controlPcS2,
        "TAGE response did not match the selected CFI PC")
    }
  }
}

abstract class BranchPredictor extends Module {
  val io = IO(new Bundle {
    val req_valid       = Input(Bool())
    val current_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid      = Output(Bool())
    val resp_pc         = Output(UInt(PC_DATA_WIDTH.W))
    val predicted_taken = Output(Bool())
    val predicted_pc    = Output(UInt(PC_DATA_WIDTH.W))
    val predicted_slot  = Output(Bool())
    val predicted_hit   = Output(Bool())
    val predicted_is_return = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val predicted_is_call = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val btb_hit = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val predicted_base_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val predicted_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val predicted_loop_override = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val predicted_loop_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None

    val update_en        = Input(Bool())
    val update_pc        = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_return = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val update_is_call = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val loop_restore = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val actual_taken     = Input(Bool())
    val actual_target    = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Input(Bool())) else None
    val loop_spec_update_en = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
    val loop_spec_update_pc = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val loop_spec_update_taken = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
  })
}

class AlwaysNotTaken extends BranchPredictor {
  val validPipe = RegNext(io.req_valid, false.B)
  val pcPipe = RegNext(io.current_pc)
  io.resp_valid := validPipe
  io.resp_pc := pcPipe
  io.predicted_taken := false.B
  io.predicted_pc := pcPipe + 4.U
  io.predicted_slot  := false.B
  io.predicted_hit   := false.B
  if (CONFIG_BRANCH_RAS) {
    io.predicted_is_return.get := false.B
    io.predicted_is_call.get := false.B
  }
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    io.btb_hit.get := false.B
    io.predicted_base_taken.get := false.B
    io.predicted_is_branch.get := false.B
    io.predicted_loop_override.get := false.B
    io.predicted_loop_taken.get := false.B
  }
}

class BimodalWrapper extends BranchPredictor {
  val bimodal = Module(new Bimodal)
  bimodal.io.clk := clock
  bimodal.io.rst := reset

  io.resp_valid := bimodal.io.resp_valid
  io.resp_pc := bimodal.io.resp_pc
  io.predicted_taken := bimodal.io.pred_taken && bimodal.io.btb_hit
  io.predicted_pc := bimodal.io.pred_target_pc
  io.predicted_slot := bimodal.io.pred_slot
  io.predicted_hit := bimodal.io.btb_hit

  bimodal.io.req_valid := io.req_valid
  bimodal.io.fetch_pc := io.current_pc
  bimodal.io.update_en := io.update_en
  bimodal.io.update_pc := io.update_pc
  bimodal.io.update_target := io.actual_target
  bimodal.io.actual_taken := io.actual_taken
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    bimodal.io.update_is_branch.get := io.update_is_branch.get
    io.btb_hit.get := bimodal.io.btb_hit
    io.predicted_base_taken.get := bimodal.io.pred_base_taken.get
    io.predicted_is_branch.get := bimodal.io.pred_is_branch.get
    io.predicted_loop_override.get := bimodal.io.pred_loop_override.get
    io.predicted_loop_taken.get := bimodal.io.pred_loop_taken.get
  }
  if (CONFIG_BRANCH_LOOP_PREDICTOR) {
    bimodal.io.loop_restore.get := io.loop_restore.get
  }
  if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR) {
    bimodal.io.loop_spec_update_en.get := io.loop_spec_update_en.get
    bimodal.io.loop_spec_update_pc.get := io.loop_spec_update_pc.get
    bimodal.io.loop_spec_update_taken.get := io.loop_spec_update_taken.get
  }
}

class BimodalRasWrapper extends BranchPredictor {
  val bimodal = Module(new BimodalRas)
  bimodal.io.clk := clock
  bimodal.io.rst := reset

  io.resp_valid := bimodal.io.resp_valid
  io.resp_pc := bimodal.io.resp_pc
  io.predicted_taken := bimodal.io.pred_taken && bimodal.io.btb_hit
  io.predicted_pc := bimodal.io.pred_target_pc
  io.predicted_slot := bimodal.io.pred_slot
  io.predicted_hit := bimodal.io.btb_hit
  io.predicted_is_return.get := bimodal.io.pred_is_return
  io.predicted_is_call.get := bimodal.io.pred_is_call

  bimodal.io.req_valid := io.req_valid
  bimodal.io.fetch_pc := io.current_pc
  bimodal.io.update_en := io.update_en
  bimodal.io.update_pc := io.update_pc
  bimodal.io.update_is_return := io.update_is_return.get
  bimodal.io.update_is_call := io.update_is_call.get
  bimodal.io.update_target := io.actual_target
  bimodal.io.actual_taken := io.actual_taken
  if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) {
    bimodal.io.update_is_branch.get := io.update_is_branch.get
    io.btb_hit.get := bimodal.io.btb_hit
    io.predicted_base_taken.get := bimodal.io.pred_base_taken.get
    io.predicted_is_branch.get := bimodal.io.pred_is_branch.get
    io.predicted_loop_override.get := bimodal.io.pred_loop_override.get
    io.predicted_loop_taken.get := bimodal.io.pred_loop_taken.get
  }
  if (CONFIG_BRANCH_LOOP_PREDICTOR) {
    bimodal.io.loop_restore.get := io.loop_restore.get
  }
  if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR) {
    bimodal.io.loop_spec_update_en.get := io.loop_spec_update_en.get
    bimodal.io.loop_spec_update_pc.get := io.loop_spec_update_pc.get
    bimodal.io.loop_spec_update_taken.get := io.loop_spec_update_taken.get
  }
}

class Bimodal extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "BTB_WIDTH" -> CONFIG_BRANCH_BTB_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val req_valid = Input(Bool())
    val fetch_pc = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid = Output(Bool())
    val resp_pc = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken = Output(Bool())
    val pred_target_pc = Output(UInt(PC_DATA_WIDTH.W))
    val btb_hit = Output(Bool())
    val pred_slot = Output(Bool())
    val pred_base_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_loop_override = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_loop_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val loop_restore = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val loop_spec_update_en = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
    val loop_spec_update_pc = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val loop_spec_update_taken = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
    val update_en = Input(Bool())
    val update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val update_target = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken = Input(Bool())
    val update_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Input(Bool())) else None
  })
}

class BimodalRas extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "BTB_WIDTH" -> CONFIG_BRANCH_BTB_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val req_valid = Input(Bool())
    val fetch_pc = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid = Output(Bool())
    val resp_pc = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken = Output(Bool())
    val pred_target_pc = Output(UInt(PC_DATA_WIDTH.W))
    val btb_hit = Output(Bool())
    val pred_slot = Output(Bool())
    val pred_is_return = Output(Bool())
    val pred_is_call = Output(Bool())
    val pred_base_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_loop_override = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val pred_loop_taken = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Output(Bool())) else None
    val loop_restore = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val loop_spec_update_en = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
    val loop_spec_update_pc = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val loop_spec_update_taken = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR)
      Some(Input(Bool())) else None
    val update_en = Input(Bool())
    val update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_return = Input(Bool())
    val update_is_call = Input(Bool())
    val update_is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Input(Bool())) else None
    val update_target = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken = Input(Bool())
  })
}

class TageDirection extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "INDEX_WIDTH" -> CONFIG_BRANCH_TAGE_INDEX_BITS,
  "TAG_WIDTH" -> CONFIG_BRANCH_TAGE_TAG_BITS,
  "HIST0" -> CONFIG_BRANCH_TAGE_HIST_0,
  "HIST1" -> CONFIG_BRANCH_TAGE_HIST_1,
  "HIST2" -> CONFIG_BRANCH_TAGE_HIST_2,
  "HIST3" -> CONFIG_BRANCH_TAGE_HIST_3,
  "META_WIDTH" -> MetaWidth)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val req_valid = Input(Bool())
    val req_pc = Input(UInt(PC_DATA_WIDTH.W))
    val fast_base_taken = Input(Bool())
    val fast_loop_override = Input(Bool())
    val fast_loop_taken = Input(Bool())
    val fast_direction_override = Input(Bool())
    val fast_override_taken = Input(Bool())
    val pipeline_flush = Input(Bool())
    val resp_valid = Output(Bool())
    val resp_pc = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken = Output(Bool())
    val resp_meta = Output(UInt(MetaWidth.W))
    val update_en = Input(Bool())
    val update_pc = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val update_actual_taken = Input(Bool())
    val update_meta = Input(UInt(MetaWidth.W))
    val recover_en = Input(Bool())
    val recover_actual_taken = Input(Bool())
    val recover_meta = Input(UInt(MetaWidth.W))
    val update_skip_history = Input(Bool())
    val restore_committed = Input(Bool())
  })
}

class ReturnAddressStack extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "RAS_WIDTH" -> CONFIG_BRANCH_RAS_WIDTH)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val spec_push = Input(Bool())
    val spec_pop = Input(Bool())
    val spec_addr = Input(UInt(PC_DATA_WIDTH.W))
    val commit_push = Input(Bool())
    val commit_pop = Input(Bool())
    val commit_addr = Input(UInt(PC_DATA_WIDTH.W))
    val restore = Input(Bool())
    val top_valid = Output(Bool())
    val top_addr = Output(UInt(PC_DATA_WIDTH.W))
  })
}
