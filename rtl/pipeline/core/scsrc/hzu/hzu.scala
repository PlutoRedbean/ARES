package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class HZU extends Module {
  val io = IO(new Bundle {
    val ex1_valid           = Input(Bool())

    val ex1_bpu_update_en   = Input(Bool())
    val ex1_bpu_update_pc   = Input(UInt(PC_DATA_WIDTH.W))
    val ex1_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val ex1_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val ex1_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val ex1_branch_resolve  = Input(new BranchResolveBundle)

    val hzu_bpu_update_en   = Output(Bool())
    val hzu_bpu_update_pc   = Output(UInt(PC_DATA_WIDTH.W))
    val hzu_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val hzu_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val hzu_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val hzu_branch_resolve  = Output(new BranchResolveBundle)
    val hzu_hazard          = Output(Bool())
  })

  val ex1_valid          = io.ex1_valid
  val hzu_bpu_update_en  = RegNext(io.ex1_bpu_update_en )
  val hzu_bpu_update_pc  = RegNext(io.ex1_bpu_update_pc )
  val hzu_branch_resolve = RegNext(io.ex1_branch_resolve)

  val branch_mispredict = io.ex1_branch_resolve.mispredict && ex1_valid

  io.hzu_bpu_update_en  := hzu_bpu_update_en
  io.hzu_bpu_update_pc  := hzu_bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    io.hzu_bpu_update_ras_push.get := RegNext(io.ex1_bpu_update_ras_push.get, false.B)
    io.hzu_bpu_update_ras_pop.get := RegNext(io.ex1_bpu_update_ras_pop.get, false.B)
    io.hzu_bpu_update_ras_addr.get := RegNext(io.ex1_bpu_update_ras_addr.get)
  }
  io.hzu_branch_resolve := hzu_branch_resolve
  io.hzu_hazard := RegNext(branch_mispredict)
}
