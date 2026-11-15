package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._

class BPU extends Module {
  val io = IO(new Bundle {
    val req_valid       = Input(Bool())
    val current_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid      = Output(Bool())
    val resp_pc         = Output(UInt(PC_DATA_WIDTH.W))
    val predicted_taken = Output(Bool())
    val predicted_pc    = Output(UInt(PC_DATA_WIDTH.W))

    val update_en      = Input(Bool())
    val update_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val update_ras_push = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val actual_taken   = Input(Bool())
    val actual_target  = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Input(Bool())) else None
  })

  val BranchPredict = Module(if (CONFIG_BRANCH_PREDICT == BP_BIMODAL) {
    if (CONFIG_BRANCH_RAS) new BimodalRasWrapper else new BimodalWrapper
  } else {
    new AlwaysNotTaken
  })

  BranchPredict.io.current_pc    := io.current_pc
  BranchPredict.io.req_valid     := io.req_valid
  BranchPredict.io.update_en     := io.update_en
  BranchPredict.io.update_pc     := io.update_pc
  BranchPredict.io.actual_taken  := io.actual_taken
  BranchPredict.io.actual_target := io.actual_target
  io.resp_valid      := BranchPredict.io.resp_valid
  io.resp_pc         := BranchPredict.io.resp_pc

  var selectedTaken = BranchPredict.io.predicted_taken
  var selectedTarget = BranchPredict.io.predicted_pc

  if (CONFIG_BRANCH_RAS) {
    BranchPredict.io.update_is_return.get := io.update_ras_pop.get
    val ras = Module(new ReturnAddressStack)
    ras.io.clk := clock
    ras.io.rst := reset
    ras.io.update_push := io.update_en && io.update_ras_push.get
    ras.io.update_pop := io.update_en && io.update_ras_pop.get
    ras.io.update_addr := io.update_ras_addr.get

    val returnHit = BranchPredict.io.predicted_is_return.get && ras.io.top_valid
    selectedTaken = returnHit || selectedTaken
    selectedTarget = Mux(returnHit, ras.io.top_addr, selectedTarget)
  }

  io.predicted_taken := selectedTaken
  io.predicted_pc    := selectedTarget

  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    BranchPredict.io.update_is_branch.get := io.update_is_branch.get
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
    val predicted_is_return = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None

    val update_en      = Input(Bool())
    val update_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_return = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val actual_taken   = Input(Bool())
    val actual_target  = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Input(Bool())) else None
  })
}

class AlwaysNotTaken extends BranchPredictor {
  val validPipe = RegNext(io.req_valid, false.B)
  val pcPipe = RegNext(io.current_pc)
  io.resp_valid := validPipe
  io.resp_pc := pcPipe
  io.predicted_taken := false.B
  io.predicted_pc    := pcPipe + 4.U
  if (CONFIG_BRANCH_RAS) {
    io.predicted_is_return.get := false.B
  }
}

class BimodalWrapper extends BranchPredictor {
  val Bimodal = Module(new Bimodal)
  Bimodal.io.clk := clock
  Bimodal.io.rst := reset
  
  io.resp_valid      := Bimodal.io.resp_valid
  io.resp_pc         := Bimodal.io.resp_pc
  io.predicted_taken := Bimodal.io.pred_taken && Bimodal.io.btb_hit
  io.predicted_pc    := Bimodal.io.pred_target_pc

  Bimodal.io.req_valid     := io.req_valid
  Bimodal.io.fetch_pc      := io.current_pc 
  Bimodal.io.update_en     := io.update_en
  Bimodal.io.update_pc     := io.update_pc
  Bimodal.io.update_target := io.actual_target
  Bimodal.io.actual_taken  := io.actual_taken
  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    Bimodal.io.update_is_branch.get := io.update_is_branch.get
  }
}

class BimodalRasWrapper extends BranchPredictor {
  val BimodalRas = Module(new BimodalRas)
  BimodalRas.io.clk := clock
  BimodalRas.io.rst := reset

  io.resp_valid := BimodalRas.io.resp_valid
  io.resp_pc := BimodalRas.io.resp_pc
  io.predicted_taken := BimodalRas.io.pred_taken && BimodalRas.io.btb_hit
  io.predicted_pc := BimodalRas.io.pred_target_pc
  io.predicted_is_return.get := BimodalRas.io.pred_is_return

  BimodalRas.io.req_valid := io.req_valid
  BimodalRas.io.fetch_pc := io.current_pc
  BimodalRas.io.update_en := io.update_en
  BimodalRas.io.update_pc := io.update_pc
  BimodalRas.io.update_is_return := io.update_is_return.get
  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    BimodalRas.io.update_is_branch.get := io.update_is_branch.get
  }
  BimodalRas.io.update_target := io.actual_target
  BimodalRas.io.actual_taken := io.actual_taken
}

class Bimodal extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "BTB_WIDTH" -> CONFIG_BRANCH_BTB_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk            = Input(Clock())
    val rst            = Input(Bool())
    val req_valid      = Input(Bool())
    val fetch_pc       = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid     = Output(Bool())
    val resp_pc        = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken     = Output(Bool())
    val pred_target_pc = Output(UInt(PC_DATA_WIDTH.W))
    val btb_hit        = Output(Bool())
    val update_en      = Input(Bool())
    val update_pc      = Input(UInt(PC_DATA_WIDTH.W))
    val update_target  = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken   = Input(Bool())
    val update_is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Input(Bool())) else None
  })
}

class BimodalRas extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "BTB_WIDTH" -> CONFIG_BRANCH_BTB_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk              = Input(Clock())
    val rst              = Input(Bool())
    val req_valid        = Input(Bool())
    val fetch_pc         = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid       = Output(Bool())
    val resp_pc          = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken       = Output(Bool())
    val pred_target_pc   = Output(UInt(PC_DATA_WIDTH.W))
    val btb_hit          = Output(Bool())
    val pred_is_return   = Output(Bool())
    val update_en        = Input(Bool())
    val update_pc        = Input(UInt(PC_DATA_WIDTH.W))
    val update_is_return = Input(Bool())
    val update_is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Input(Bool())) else None
    val update_target    = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken     = Input(Bool())
  })
}

class ReturnAddressStack extends BlackBox(Map(
  "ADDR_WIDTH" -> PC_DATA_WIDTH,
  "RAS_WIDTH" -> CONFIG_BRANCH_RAS_WIDTH)) {
  val io = IO(new Bundle {
    val clk         = Input(Clock())
    val rst         = Input(Bool())
    val update_push = Input(Bool())
    val update_pop  = Input(Bool())
    val update_addr = Input(UInt(PC_DATA_WIDTH.W))
    val top_valid   = Output(Bool())
    val top_addr    = Output(UInt(PC_DATA_WIDTH.W))
  })
}
