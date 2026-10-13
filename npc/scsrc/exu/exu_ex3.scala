package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._
import DPUParams._
import OperandStats._

class exu_ex3 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX2_EX3_Payload))
    val out = Decoupled(new EX3_EX4_Payload)

    val cache_hit = Input(Bool())
    val rdata_fast = Input(UInt(REG_DATA_WIDTH.W))
    val store_cache_hit = Input(Bool())
    val store_cache_data = Input(UInt(MEM_DATA_WIDTH.W))

    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd    = Output(new ProducerBundle)
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid

  val isLoad = io.in.bits.is_load
  val fallbackHit =
    isLoad && !io.in.bits.cache_hit && io.cache_hit
  val resolvedHit = io.in.bits.cache_hit || fallbackHit
  // rdata_fast is registered at the D-cache response boundary.  A load
  // always presents that candidate to the forwarding network; hit/miss only
  // controls replay and the advertised availability below.
  val reg_data = Mux(isLoad, io.rdata_fast, io.in.bits.reg_data)
  val resultWhen = Mux(
    isLoad,
    Mux(resolvedHit, WHEN_ABS_EX3, WHEN_ABS_WB_EARLY),
    io.in.bits.when)

  io.out.bits.rd.data := reg_data
  io.out.bits.rd.addr := io.in.bits.rd_addr
  io.out.bits.rd.wen  := io.in.bits.rd_wen
  io.out.bits.envir   := io.in.bits.envir
  io.out.bits.pc      := io.in.bits.pc
  io.out.bits.pc_next := io.in.bits.pc_next
  io.out.bits.addr      := io.in.bits.addr
  io.out.bits.mem_bytes := io.in.bits.mem_bytes
  io.out.bits.mem_wen   := io.in.bits.mem_wen
  io.out.bits.cache_hit := resolvedHit
  io.out.bits.late_data := io.in.bits.late_data
  io.out.bits.store_cache_hit := io.store_cache_hit
  io.out.bits.store_cache_data := io.store_cache_data
  io.out.bits.csr_ctrl   := io.in.bits.csr_ctrl
  io.out.bits.csr_mask   := io.in.bits.csr_mask
  io.out.bits.trap_pc    := io.in.bits.trap_pc
  io.out.bits.when      := resultWhen
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl

  io.reg_val := reg_data

  io.rd.wen  := io.in.bits.rd_wen
  io.rd.addr := io.in.bits.rd_addr
  io.rd.when := resultWhen
  io.rd.producerType :=
    producerType(io.in.bits.is_load, io.in.bits.mdu_ctrl)
}
