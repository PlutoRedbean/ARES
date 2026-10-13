package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._
import OperandStats._

class exu_ex4 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX3_EX4_Payload))
    val out  = Decoupled(new EX_WB_Payload)

    val rdata_slow = Input(UInt(REG_DATA_WIDTH.W))
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
  val isLoad = io.in.bits.mem_bytes =/= MEM_NONE && !io.in.bits.mem_wen
  val regData = Mux(
    isLoad && !io.in.bits.cache_hit,
    io.rdata_slow,
    io.in.bits.rd.data)

  io.out.bits.rd        := io.in.bits.rd
  io.out.bits.rd.data   := regData
  io.out.bits.envir     := io.in.bits.envir
  io.out.bits.when      := io.in.bits.when
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl

  // Keep cache-hit classification off the Ex4 forwarding data path.  On a
  // miss, result availability remains delayed to WB and only architectural
  // writeback selects the slow completion above.
  io.reg_val := io.in.bits.rd.data

  io.rd.wen  := io.in.bits.rd.wen
  io.rd.addr := io.in.bits.rd.addr
  io.rd.when := io.in.bits.when
  io.rd.producerType := producerType(
    io.in.bits.mem_bytes =/= MEM_NONE && !io.in.bits.mem_wen,
    io.in.bits.mdu_ctrl)
}
