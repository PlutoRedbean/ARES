package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import BitManipParams._
import DPUParams._

class exu_ex2 extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new EX1_EX2_Payload))
    val out = Decoupled(new EX2_EX3_Payload)

    val cache_hit = Input(Bool())
    val rdata_fast = Input(UInt(MEM_DATA_WIDTH.W))
    
    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd    = Output(new ProducerBundle)
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid

  val exu_out = io.in.bits.reg_data

  val base_reg_data = Mux(
    io.in.bits.is_load && io.cache_hit,
    io.rdata_fast,
    exu_out)

  val bitResult = WireDefault(0.U(REG_DATA_WIDTH.W))
  if (CONFIG_RV32_ZBB_CLZ || CONFIG_RV32_ZBB_CTZ || CONFIG_RV32_ZBB_CPOP ||
      CONFIG_RV32_ZBKX_XPERM4 || CONFIG_RV32_ZBB_ROR) {
    val BIT_EX2 = Module(new BitManipEx2)
    BIT_EX2.io.ctrl     := io.in.bits.bit_ctrl
    BIT_EX2.io.bit_data := io.in.bits.bit_data
    BIT_EX2.io.bit_aux  := io.in.bits.bit_aux
    bitResult := BIT_EX2.io.result
  }

  val CRC8_EX2 = Module(new CRC8Ex2)
  CRC8_EX2.io.bit_data := io.in.bits.bit_data
  CRC8_EX2.io.bit_aux  := io.in.bits.bit_aux
  val isCrc8 = io.in.bits.bit_ctrl === BIT_CRC8

  val isTwoStageBitOp = io.in.bits.bit_ctrl === BIT_CLZ ||
                        io.in.bits.bit_ctrl === BIT_CTZ ||
                        io.in.bits.bit_ctrl === BIT_CPOP ||
                        io.in.bits.bit_ctrl === BIT_XPERM4 ||
                        io.in.bits.bit_ctrl === BIT_ROR || isCrc8
  val stage2Result = Mux(isCrc8, CRC8_EX2.io.result, bitResult)
  val reg_data = Mux(isTwoStageBitOp, stage2Result, base_reg_data)

  io.out.bits.pc        := io.in.bits.pc
  io.out.bits.pc_next   := io.in.bits.pc_next
  io.out.bits.addr      := io.in.bits.addr
  io.out.bits.mem_wdata := io.in.bits.mem_wdata
  io.out.bits.mem_wen   := io.in.bits.mem_wen
  io.out.bits.when      := Mux(io.in.bits.is_load,
    Mux(io.cache_hit, WHEN_ABS_EX2, WHEN_ABS_EX3),
    io.in.bits.when)

  io.out.bits.reg_data  := reg_data
  io.out.bits.mdu_ctrl  := io.in.bits.mdu_ctrl
  io.out.bits.bit_ctrl  := io.in.bits.bit_ctrl
  io.out.bits.L_sign    := io.in.bits.L_sign
  io.out.bits.mem_bytes := io.in.bits.mem_bytes
  io.out.bits.rd_addr   := io.in.bits.rd_addr
  io.out.bits.rd_wen    := io.in.bits.rd_wen
  io.out.bits.is_load   := io.in.bits.is_load
  io.out.bits.cache_hit := io.cache_hit
  io.out.bits.envir     := io.in.bits.envir

  io.reg_val := reg_data

  io.rd.wen  := io.in.bits.rd_wen
  io.rd.addr := io.in.bits.rd_addr
  io.rd.when := Mux(io.in.bits.is_load,
    Mux(io.cache_hit, WHEN_ABS_EX2, WHEN_ABS_EX3),
    io.in.bits.when)
}
