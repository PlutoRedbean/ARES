package npc

import chisel3._
import chisel3.util._
import MundusConfig._

// EX1 → EX2 Payload
class EX1_EX2_Payload extends Bundle {
  // test data
  val pc          = UInt(PC_DATA_WIDTH.W)
  val pc_next     = UInt(PC_DATA_WIDTH.W)
  val addr        = UInt(MEM_ADDR_WIDTH.W)
  val mem_wdata   = UInt(REG_DATA_WIDTH.W)
  val mem_wen     = Bool()

  // penetrate
  val reg_data     = UInt(32.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)
  val bit_data     = UInt(REG_DATA_WIDTH.W)
  val bit_aux      = UInt(REG_DATA_WIDTH.W)
  val L_sign      = Bool()
  val mem_bytes   = UInt(2.W)
  val rd_addr     = UInt(GPR_ADDR_WIDTH.W)
  val rd_wen      = Bool()
  val is_load     = Bool()
  val envir       = UInt(ENVIR_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
}

// EX2 → EX3 Payload
class EX2_EX3_Payload extends Bundle {
  // test data
  val pc          = UInt(PC_DATA_WIDTH.W)
  val pc_next     = UInt(PC_DATA_WIDTH.W)
  val addr        = UInt(MEM_ADDR_WIDTH.W)
  val mem_wdata   = UInt(REG_DATA_WIDTH.W)
  val mem_wen     = Bool()
  
  // penetrate
  val reg_data     = UInt(32.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)
  val L_sign      = Bool()
  val mem_bytes   = UInt(2.W)
  val rd_addr     = UInt(GPR_ADDR_WIDTH.W)
  val rd_wen      = Bool()
  val is_load     = Bool()
  val cache_hit   = Bool()
  val envir       = UInt(ENVIR_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
}

// EX3 → EX4 Payload
class EX3_EX4_Payload extends Bundle {
  // test data
  val pc          = UInt(PC_DATA_WIDTH.W)
  val pc_next     = UInt(PC_DATA_WIDTH.W)
  val addr        = UInt(MEM_ADDR_WIDTH.W)
  val mem_bytes   = UInt(2.W)
  val mem_wen     = Bool()

  // penetrate
  val rd          = new GPRWriteBackBundle
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)
  val envir        = UInt(ENVIR_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
}
