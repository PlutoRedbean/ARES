package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class exu_ex4 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX3_EX4_Payload))
    val out  = Decoupled(new EX_WB_Payload)

    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd    = Output(new ProducerBundle)
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid

  io.out.bits.pc        := io.in.bits.pc
  io.out.bits.pc_next   := io.in.bits.pc_next
  io.out.bits.addr      := io.in.bits.addr
  io.out.bits.mem_bytes := io.in.bits.mem_bytes
  io.out.bits.mem_wen   := io.in.bits.mem_wen
  io.out.bits.rd        := io.in.bits.rd
  io.out.bits.envir     := io.in.bits.envir
  io.out.bits.when      := io.in.bits.when
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl
  io.out.bits.bit_ctrl  := io.in.bits.bit_ctrl

  io.reg_val := io.in.bits.rd.data

  io.rd.wen  := io.in.bits.rd.wen
  io.rd.addr := io.in.bits.rd.addr
  io.rd.when := io.in.bits.when
}
