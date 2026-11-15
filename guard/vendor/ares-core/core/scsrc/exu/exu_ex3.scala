package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

class exu_ex3 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX2_EX3_Payload))
    val out = Decoupled(new EX3_EX4_Payload)

    val rdata_slow = Input(UInt(REG_DATA_WIDTH.W))

    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd    = Output(new ProducerBundle)
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid

  val load_data = Mux(io.in.bits.cache_hit,
    io.in.bits.reg_data,
    io.rdata_slow)
  val reg_data = Mux(io.in.bits.is_load, load_data, io.in.bits.reg_data)

  io.out.bits.rd.data := reg_data
  io.out.bits.rd.addr := io.in.bits.rd_addr
  io.out.bits.rd.wen  := io.in.bits.rd_wen
  io.out.bits.envir   := io.in.bits.envir
  io.out.bits.pc      := io.in.bits.pc
  io.out.bits.pc_next := io.in.bits.pc_next
  io.out.bits.addr      := io.in.bits.addr
  io.out.bits.mem_bytes := io.in.bits.mem_bytes
  io.out.bits.mem_wen   := io.in.bits.mem_wen
  io.out.bits.when      := io.in.bits.when
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl
  io.out.bits.bit_ctrl  := io.in.bits.bit_ctrl

  io.reg_val := reg_data

  io.rd.wen  := io.in.bits.rd_wen
  io.rd.addr := io.in.bits.rd_addr
  io.rd.when := io.in.bits.when
}
