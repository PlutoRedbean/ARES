package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import DPUParams._
import OperandStats._

class exu_ex2 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX1_EX2_Payload))
    val out = Decoupled(new EX2_EX3_Payload)

    val cache_hit = Input(Bool())
    val rdata_fast = Input(UInt(MEM_DATA_WIDTH.W))
    val store_cache_hit = Input(Bool())
    val store_cache_data = Input(UInt(MEM_DATA_WIDTH.W))

    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd    = Output(new ProducerBundle)
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid

  val optimisticLoad =
    io.in.bits.is_load && io.in.bits.when === WHEN_ABS_EX2
  // The fast candidate is already formatted and registered at the D-cache
  // response boundary.  Select it using registered Issue metadata only:
  // cache_hit is deliberately absent from this data path.  A miss suppresses
  // and replays the dependent Ex1 group through the separate control path.
  val reg_data = Mux(
    optimisticLoad, io.rdata_fast, io.in.bits.reg_data)
  // Readiness is control-only.  On a miss the producer is downgraded to EX3
  // before the held consumer advances its late token, so invalid FastData is
  // never captured; this signal does not select the ALU operand value.
  val resultWhen = Mux(
    optimisticLoad,
    Mux(io.cache_hit, WHEN_ABS_EX2, WHEN_ABS_EX3),
    io.in.bits.when)

  io.out.bits.pc        := io.in.bits.pc
  io.out.bits.pc_next   := io.in.bits.pc_next
  io.out.bits.addr      := io.in.bits.addr
  io.out.bits.mem_wdata := io.in.bits.mem_wdata
  io.out.bits.mem_wen   := io.in.bits.mem_wen
  io.out.bits.late_data := io.in.bits.late_data
  io.out.bits.when      := resultWhen

  io.out.bits.reg_data  := reg_data
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl
  io.out.bits.L_sign    := io.in.bits.L_sign
  io.out.bits.mem_bytes := io.in.bits.mem_bytes
  io.out.bits.rd_addr   := io.in.bits.rd_addr
  io.out.bits.rd_wen    := io.in.bits.rd_wen
  io.out.bits.is_load   := io.in.bits.is_load
  io.out.bits.cache_hit := optimisticLoad && io.cache_hit
  io.out.bits.store_cache_hit := io.store_cache_hit
  io.out.bits.store_cache_data := io.store_cache_data
  io.out.bits.csr_ctrl    := io.in.bits.csr_ctrl
  io.out.bits.csr_mask    := io.in.bits.csr_mask
  io.out.bits.trap_pc     := io.in.bits.trap_pc
  io.out.bits.envir     := io.in.bits.envir

  io.reg_val := reg_data

  io.rd.wen  := io.in.bits.rd_wen
  io.rd.addr := io.in.bits.rd_addr
  io.rd.when := resultWhen
  io.rd.producerType :=
    producerType(io.in.bits.is_load, io.in.bits.mdu_ctrl)
}
