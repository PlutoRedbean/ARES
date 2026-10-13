package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

class ALU extends Module {
  val io = IO(new Bundle {
    val alu_ctrl  = Input(UInt(ALU_CTRL_WIDTH.W))
    val din1      = Input(UInt(32.W))
    val din2      = Input(UInt(32.W))
    val dout      = Output(UInt(32.W))
  })

  val alu_ctrl = io.alu_ctrl
  val din1     = io.din1
  val din2     = io.din2

  // The CoreMark CRC update is linear over GF(2).  Each constant is the
  // dependency mask for one output bit over {old_crc, new_value}.  Expressing
  // it as parity trees avoids a 16-step conditional LFSR chain on the ALU
  // critical path while remaining bit-for-bit equivalent to crcu16().
  val crcResult = if (CONFIG_CUSTOM_CRC16) {
    val crcInput = Cat(din2(15, 0), din1(15, 0))
    val crcMasks = Seq(
      "hfffbfffb".U(32.W), "h000c000c".U(32.W),
      "h00180018".U(32.W), "h00300030".U(32.W),
      "h00600060".U(32.W), "h00c000c0".U(32.W),
      "h01800180".U(32.W), "h03000300".U(32.W),
      "h06000600".U(32.W), "h0c000c00".U(32.W),
      "h18001800".U(32.W), "h30003000".U(32.W),
      "h60016001".U(32.W), "hc002c002".U(32.W),
      "h7ffe7ffe".U(32.W), "hfffdfffd".U(32.W)
    )
    val crc16 = Cat(crcMasks.reverse.map(mask => (crcInput & mask).xorR))
    Cat(0.U(16.W), crc16)
  } else {
    0.U(32.W)
  }

  val dout = 
    (Fill(32, alu_ctrl(ALU_IDX_DIN1)) & ( din1                              )) |
    (Fill(32, alu_ctrl(ALU_IDX_DIN2)) & (                din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_ADD )) & ( din1        +  din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_SUB )) & ( din1        -  din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_XOR )) & ( din1        ^  din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_OR  )) & ( din1        |  din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_AND )) & ( din1        &  din2               )) |
    (Fill(32, alu_ctrl(ALU_IDX_SLL )) & ((din1        << din2(4, 0))(31, 0) )) |
    (Fill(32, alu_ctrl(ALU_IDX_SRL )) & ((din1        >> din2(4, 0) ).asUInt)) |
    (Fill(32, alu_ctrl(ALU_IDX_SRA )) & ((din1.asSInt >> din2(4, 0) ).asUInt)) |
    (Fill(32, alu_ctrl(ALU_IDX_SLT )) & ((din1.asSInt <  din2.asSInt).asUInt)) |
    (Fill(32, alu_ctrl(ALU_IDX_SLTU)) & ((din1        <  din2       ).asUInt)) |
    (Fill(32, alu_ctrl(ALU_IDX_CRC16)) & ( crcResult                    ))

  io.dout := dout
}
