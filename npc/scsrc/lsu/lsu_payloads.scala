package npc

import chisel3._
import chisel3.util._
import MundusConfig._

// LS1 → LS2 Payload
class LS_INPUT_Payload extends Bundle {
  val lane      = Input(UInt(log2Ceil(DualIssue.Width).W))
  val rd        = Input(UInt(GPR_ADDR_WIDTH.W))
  val addr      = Input(UInt(32.W))
  val cache_probe_match = Input(Bool())
  val L_sign    = Input(Bool())
  val mem_wen   = Input(Bool())
  val mem_bytes = Input(UInt(2.W))
  val mem_wdata = Input(UInt(32.W))
  val transient_fwd_mask = Input(UInt(4.W))
  val transient_fwd_data = Input(UInt(MEM_DATA_WIDTH.W))
  val transient_fwd_sources = Input(UInt(3.W))
}

class LS_OUTPUT_Payload extends Bundle {
  val lane = Output(UInt(log2Ceil(DualIssue.Width).W))
  val rd = Output(UInt(GPR_ADDR_WIDTH.W))
  val addr = Output(UInt(MEM_ADDR_WIDTH.W))
  val bytes = Output(UInt(2.W))
  val sign = Output(Bool())
  val slow_lane = Output(UInt(log2Ceil(DualIssue.Width).W))
  val slow_rd = Output(UInt(GPR_ADDR_WIDTH.W))
  val slow_valid = Output(Bool())
  val slow_addr = Output(UInt(MEM_ADDR_WIDTH.W))
  val slow_bytes = Output(UInt(2.W))
  val slow_sign = Output(Bool())
  val is_load = Output(Bool())
  val cache_hit = Output(Bool())
  val rdata_fast = Output(UInt(32.W))
  val rdata_slow = Output(UInt(32.W))
  val store_cache_hit = Output(Bool())
  val store_cache_data = Output(UInt(32.W))
}

class StoreCommitPayload extends Bundle {
  val addr = UInt(MEM_ADDR_WIDTH.W)
  val data = UInt(MEM_DATA_WIDTH.W)
  val bytes = UInt(2.W)
  val cache_hit = Bool()
  val cache_data = UInt(MEM_DATA_WIDTH.W)
}
