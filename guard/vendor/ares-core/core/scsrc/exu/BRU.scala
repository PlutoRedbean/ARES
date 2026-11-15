package npc

import chisel3._
import chisel3.util._
import MundusConfig._
import BRUParams._

class BRU extends Module {
  val io = IO(new Bundle {
    val bru_ctrl  = Input(UInt(BRU_CTRL_WIDTH.W))
    val imm       = Input(UInt(32.W))
    val snpc      = Input(UInt(32.W))
    val pc        = Input(UInt(32.W))
    val rs1_val   = Input(UInt(32.W))
    val rs2_val   = Input(UInt(32.W))
    val redirect  = Output(Bool())
    val target_pc = Output(UInt(32.W))
  })

  val bru_mux  = io.bru_ctrl(BRU_MUX_WIDTH  - 1, 0)
  val bru_inst = io.bru_ctrl(BRU_CTRL_WIDTH - 1, BRU_MUX_WIDTH)
  val imm      = io.imm
  val snpc     = io.snpc
  val pc       = io.pc
  val rs1_val  = io.rs1_val
  val rs2_val  = io.rs2_val

  val branch = Wire(Bool())
  branch := MuxLookup(bru_inst, false.B)(Seq(
    BR_BEQ  ->  (rs1_val        === rs2_val       ),
    BR_BNE  -> !(rs1_val        === rs2_val       ),
    BR_BLT  ->  (rs1_val.asSInt  <  rs2_val.asSInt),
    BR_BGE  -> !(rs1_val.asSInt  <  rs2_val.asSInt),
    BR_BLTU ->  (rs1_val         <  rs2_val       ),
    BR_BGEU -> !(rs1_val         <  rs2_val       )
  ))

  val branch_adder = imm + pc
  val jalr_adder   = (imm + rs1_val) & ~1.U(32.W)

  val target_pc = MuxLookup(bru_mux, snpc)(Seq(
    BR_BRANCH -> branch_adder,
    BR_JAL    -> branch_adder,
    BR_JALR   -> jalr_adder
  ))

  val redirect = MuxLookup(bru_mux, false.B)(Seq(
    BR_BRANCH -> branch,
    BR_JAL    -> true.B,
    BR_JALR   -> true.B
  ))

  io.redirect := redirect
  io.target_pc := target_pc
}
