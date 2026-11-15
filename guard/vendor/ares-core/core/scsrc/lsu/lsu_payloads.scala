package npc

import chisel3._
import chisel3.util._
import MundusConfig._

// LS1 → LS2 Payload
class LS_INPUT_Payload extends Bundle {
  val addr      = Input(UInt(32.W))
  val L_sign    = Input(Bool())
  val mem_wen   = Input(Bool())
  val mem_bytes = Input(UInt(2.W))
  val mem_wdata = Input(UInt(32.W))
}

class LS_OUTPUT_Payload extends Bundle {
  val cache_hit = Output(Bool())
  val rdata_fast = Output(UInt(32.W))
  val rdata_slow = Output(UInt(32.W))
}
