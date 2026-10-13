package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MDUParams._

class MUL extends Module {
  val io = IO(new Bundle {
    val mdu_ctrl  = Input(UInt(MDU_CTRL_WIDTH.W))
    val enable    = Input(Bool())
    val din1      = Input(UInt(32.W))
    val din2      = Input(UInt(32.W))
    val dout      = Output(UInt(MUL_OUT_WIDTH.W))
    val mulbeDout = Output(UInt(REG_DATA_WIDTH.W))
  })

  val mdu_sign   = io.mdu_ctrl(MDU_CTRL_WIDTH - 1, MDU_POS_WIDTH  + MDU_MUX_WIDTH)

  val Mult = Module(new Multiplier)
  val mul_a_sign = Mux(mdu_sign(1), io.din1(31), 0.U)
  val mul_b_sign = Mux(mdu_sign(0), io.din2(31), 0.U)
  val mul_a = Cat(mul_a_sign, io.din1)
  val mul_b = Cat(mul_b_sign, io.din2)

  // Keep an explicit local boundary between the late Ex1 bypass and the DSP
  // input registers.  The capture primitive has one cycle and the IP has one
  // fewer internal stage, so total latency and throughput remain unchanged.
  val capture = Module(new MultiplierInputCapture)
  capture.io.CLK := clock
  capture.io.reset := reset.asBool
  capture.io.CE := io.enable
  capture.io.A := mul_a
  capture.io.B := mul_b

  require(MUL_LATENCY == 4,
    "captured multiplier requires a four-cycle total latency")

  Mult.io.CLK := clock
  Mult.io.CE  := io.enable
  Mult.io.A   := capture.io.A_CAPTURE
  Mult.io.B   := capture.io.B_CAPTURE

  val mul_out = Mult.io.P

  io.dout := mul_out

  // MULBE only depends on product bits [11:2].  Register its narrow operands
  // before either multiply to isolate the issue/forwarding muxes from the DSP
  // inputs.  Keep the result aligned with the regular multiplier latency:
  //   S1 operands -> S2 low product -> S3 post-product -> S4 result.
  io.mulbeDout := (if (CONFIG_CUSTOM_MULBE) {
    require(MUL_LATENCY >= 4,
      "MULBE input-register pipeline requires at least four stages")

    val mulbeDin1S1 = RegEnable(io.din1(11, 0), io.enable)
    val mulbeDin2S1 = RegEnable(io.din2(11, 0), io.enable)
    val lowProduct = mulbeDin1S1 * mulbeDin2S1
    val lowProductS2 = RegEnable(lowProduct(11, 0), io.enable)
    val mulbeProduct = lowProductS2(5, 2) * lowProductS2(11, 5)
    val mulbeResultS3 = RegEnable(mulbeProduct, io.enable)
    val mulbeResult = ShiftRegister(
      mulbeResultS3, MUL_LATENCY - 3, io.enable)
    mulbeResult.pad(REG_DATA_WIDTH)
  } else {
    0.U(REG_DATA_WIDTH.W)
  })
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

class MultiplierInputCapture extends BlackBox {
  val io = IO(new Bundle {
    val CLK       = Input(Clock())
    val reset     = Input(Bool())
    val CE        = Input(Bool())
    val A         = Input(UInt(33.W))
    val B         = Input(UInt(33.W))
    val A_CAPTURE = Output(UInt(33.W))
    val B_CAPTURE = Output(UInt(33.W))
  })
}
