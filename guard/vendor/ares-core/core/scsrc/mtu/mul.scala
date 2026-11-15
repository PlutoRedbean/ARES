package npc

import chisel3._
import chisel3.util._
import MundusConfig._
import MDUParams._

class MUL extends Module {
  val io = IO(new Bundle {
    val mdu_ctrl  = Input(UInt(MDU_CTRL_WIDTH.W))
    val enable    = Input(Bool())
    val din1      = Input(UInt(32.W))
    val din2      = Input(UInt(32.W))
    val dout      = Output(UInt(MUL_OUT_WIDTH.W))
  })

  val din1 = io.din1
  val din2 = io.din2

  val mdu_sign   = io.mdu_ctrl(MDU_CTRL_WIDTH - 1, MDU_POS_WIDTH  + MDU_MUX_WIDTH)

  val Mult = Module(new Multiplier)
  val mul_a_sign = Mux(mdu_sign(1), din1(31), 0.U)
  val mul_b_sign = Mux(mdu_sign(0), din2(31), 0.U)

  Mult.io.CLK := clock
  Mult.io.CE  := io.enable
  Mult.io.A   := Cat(mul_a_sign, din1)
  Mult.io.B   := Cat(mul_b_sign, din2)

  val mul_out = Mult.io.P

  io.dout := mul_out
}

class Multiplier extends BlackBox {
  val io = IO(new Bundle {
    val CLK = Input(Clock())
    val CE  = Input(Bool())
    val A   = Input(UInt(33.W))
    val B   = Input(UInt(33.W))
    val P   = Output(UInt(64.W))
  })
}
