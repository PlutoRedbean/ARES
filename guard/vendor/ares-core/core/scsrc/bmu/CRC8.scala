package npc

import chisel3._
import chisel3.util._
import MundusConfig._

/** Two-stage CRC8 datapath for the ARES custom-0 CoreMark instruction.
  *
  * The reference crcu8() recurrence is eight serial bit steps.  Implementing
  * all eight steps in one EX1 cycle would add a long carry-like path in front
  * of the register file writeback.  Instead EX1 performs the low nibble and
  * EX2 performs the high nibble, so each stage is four bit steps.  The
  * instruction therefore has a 2-cycle result latency (WHEN_ABS_EX2), which
  * is already a supported pipeline timing class for two-stage bit ops.
  */
object CRC8Ops {
  def step4(data: UInt, crc_in: UInt): UInt = {
    var c = crc_in(15, 0)
    var d = data(3, 0)
    for (_ <- 0 until 4) {
      val x16 = d(0) ^ c(0)
      val cx  = Mux(x16, c ^ "h4002".U(16.W), c)
      c = Cat(x16, cx(15, 1))
      d = Cat(0.U(1.W), d(3, 1))
    }
    c
  }
}

/** EX1 half of the split CRC8 operation. */
class CRC8Ex1 extends Module {
  val io = IO(new Bundle {
    val rs1      = Input(UInt(REG_DATA_WIDTH.W))
    val rs2      = Input(UInt(REG_DATA_WIDTH.W))
    val bit_data = Output(UInt(REG_DATA_WIDTH.W))
    val bit_aux  = Output(UInt(REG_DATA_WIDTH.W))
  })

  // EX2 needs the remaining high nibble and the partial CRC state.
  io.bit_data := io.rs1
  io.bit_aux  := Cat(0.U(16.W), CRC8Ops.step4(io.rs1(3, 0), io.rs2(15, 0)))
}

/** EX2 half of the split CRC8 operation. */
class CRC8Ex2 extends Module {
  val io = IO(new Bundle {
    val bit_data = Input(UInt(REG_DATA_WIDTH.W))
    val bit_aux  = Input(UInt(REG_DATA_WIDTH.W))
    val result   = Output(UInt(REG_DATA_WIDTH.W))
  })

  val crc = CRC8Ops.step4(io.bit_data(7, 4), io.bit_aux(15, 0))
  io.result := Cat(0.U(16.W), crc)
}
