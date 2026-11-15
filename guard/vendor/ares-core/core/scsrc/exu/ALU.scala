package npc

import chisel3._
import chisel3.util._
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
    (Fill(32, alu_ctrl(ALU_IDX_SLTU)) & ((din1        <  din2       ).asUInt))

  io.dout := dout
}

