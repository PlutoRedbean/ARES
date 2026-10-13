package npc

import chisel3._
import chisel3.util._
import MundusConfig._
import ALUParams._

object SideSkewALUCtrl {
  val Width = 3

  val Add  = "b000".U(Width.W)
  val Sub  = "b001".U(Width.W)
  val Slt  = "b010".U(Width.W)
  val Sltu = "b011".U(Width.W)
  val Xor  = "b100".U(Width.W)
  val Or   = "b101".U(Width.W)
  val And  = "b110".U(Width.W)

  def encode(aluCtrl: UInt): UInt =
    MuxCase(Add, Seq(
      aluCtrl(ALU_IDX_SUB)  -> Sub,
      aluCtrl(ALU_IDX_XOR)  -> Xor,
      aluCtrl(ALU_IDX_OR)   -> Or,
      aluCtrl(ALU_IDX_AND)  -> And,
      aluCtrl(ALU_IDX_SLT)  -> Slt,
      aluCtrl(ALU_IDX_SLTU) -> Sltu
    ))

  def legal(aluCtrl: UInt): Bool = {
    val ordinary = Cat(
      aluCtrl(ALU_IDX_SLTU),
      aluCtrl(ALU_IDX_SLT),
      aluCtrl(ALU_IDX_AND),
      aluCtrl(ALU_IDX_OR),
      aluCtrl(ALU_IDX_XOR),
      aluCtrl(ALU_IDX_SUB),
      aluCtrl(ALU_IDX_ADD))
    PopCount(ordinary) === 1.U
  }
}

class SideSkewALU extends Module {
  val io = IO(new Bundle {
    // Give every result bit a registered opcode copy.  A single opcode FF
    // became a 65-load, multi-column route when the legacy side multiplier
    // remained in this lane.  Valid/fallback selection happens only after
    // this result has reached its side-local EX3 register.
    val op = Input(Vec(REG_DATA_WIDTH,
      UInt(SideSkewALUCtrl.Width.W)))
    val din1 = Input(UInt(REG_DATA_WIDTH.W))
    val din2 = Input(UInt(REG_DATA_WIDTH.W))
    val dout = Output(UInt(REG_DATA_WIDTH.W))
  })

  import SideSkewALUCtrl._

  val arithmeticKind = io.op(0)(1, 0)
  val addSub = Mux(arithmeticKind(0), io.din1 - io.din2,
    io.din1 + io.din2)
  val compare = Mux(arithmeticKind(0),
    io.din1 < io.din2,
    io.din1.asSInt < io.din2.asSInt)

  val resultBits = Wire(Vec(REG_DATA_WIDTH, Bool()))
  for (bit <- 0 until REG_DATA_WIDTH) {
    val kind = io.op(bit)(1, 0)
    val logic = MuxLookup(kind,
      io.din1(bit) ^ io.din2(bit))(Seq(
        1.U -> (io.din1(bit) | io.din2(bit)),
        2.U -> (io.din1(bit) & io.din2(bit))))
    val arithmetic = Mux(
      io.op(bit)(1), if (bit == 0) compare else false.B, addSub(bit))
    resultBits(bit) := Mux(io.op(bit)(2), logic, arithmetic)
  }
  io.dout := resultBits.asUInt
}
