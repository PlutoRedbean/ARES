package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class IROM extends Bundle {
  val addr = Output(UInt(32.W))
  val data = Input(UInt(32.W))
}

class RetireBundle extends Bundle {
  val valid     = Bool()
  val pc        = UInt(PC_DATA_WIDTH.W)
  val pc_next   = UInt(PC_DATA_WIDTH.W)
  val rd_wen    = Bool()
  val rd        = UInt(GPR_ADDR_WIDTH.W)
  val wdata     = UInt(REG_DATA_WIDTH.W)
  val is_ebreak = Bool()
}

class PERIP extends Bundle {
  val valid = Output(Bool())
  val ready = Input(Bool())
  val rvalid = Input(Bool())
  val idle  = Input(Bool())
  val addr  = Output(UInt(32.W))
  val wen   = Output(Bool())
  val mask  = Output(UInt(2.W))
  val wdata = Output(UInt(32.W))
  val rdata = Input(UInt(32.W))
}

// Coherence sideband for the write-through L1 D-cache.
//
// The shared L2 uses a write-invalidate protocol: when any hart commits a
// store, every other hart receives a one-cycle invalidate tagged with the
// stored word address.  `epoch` increments on every accepted L2 write.  A refill
// captures the epoch when its load leaves L1; if the epoch changed while the
// refill was in flight, the line is not installed.  This closes the
// read-then-remote-write race without adding a per-line directory or a
// partition of the tag RAM.
class COH extends Bundle {
  val inv_valid = Input(Bool())
  val inv_addr  = Input(UInt(32.W))
  val epoch     = Input(UInt(8.W))
}

// IF → ID Payload
class IF_ID_Payload extends Bundle {
  val pc   = UInt(PC_DATA_WIDTH.W)
  val inst = UInt(32.W)
  val snpc = UInt(PC_DATA_WIDTH.W)
  val predicted_pc    = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
}

// ID → IS Payload
class ID_IS_Payload extends Bundle {
  // comsume
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val alu_ctrl     = UInt(ALU_CTRL_WIDTH.W)
  val bru_ctrl     = UInt(BRU_CTRL_WIDTH.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)
  val csr_ctrl     = UInt(CSR_CMD_WIDTH.W)
  val csr_mask     = UInt(CSR_MASK_WIDTH.W)
  val jump         = Bool()
  val ras_push     = if (AutoConfig.CONFIG_BRANCH_RAS) Some(Bool()) else None
  val ras_pop      = if (AutoConfig.CONFIG_BRANCH_RAS) Some(Bool()) else None
  val snpc         = UInt(PC_DATA_WIDTH.W)
  val ALU_operand1 = UInt(OPR_CTRL_WIDTH.W)
  val ALU_operand2 = UInt(OPR_CTRL_WIDTH.W)
  val imm          = UInt(32.W)
  val rs1_addr     = UInt(GPR_ADDR_WIDTH.W)
  val rs2_addr     = UInt(GPR_ADDR_WIDTH.W)
  val rs1_need     = UInt(NEED_WHEN_WIDTH.W)
  val rs2_need     = UInt(NEED_WHEN_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
  
  // penetrate
  val pc           = UInt(PC_DATA_WIDTH.W)
  val rd_addr      = UInt(GPR_ADDR_WIDTH.W)
  val rd_wen       = Bool()
  val L_sign       = Bool()
  val mem_wen      = Bool()
  val mem_bytes    = UInt(2.W)
  val envir        = UInt(ENVIR_WIDTH.W)
}

// IS → EX Payload
class IS_EX_Payload extends Bundle {
  // comsume
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val alu_ctrl     = UInt(ALU_CTRL_WIDTH.W)
  val bru_ctrl     = UInt(BRU_CTRL_WIDTH.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)
  val csr_ctrl     = UInt(CSR_CMD_WIDTH.W)
  val csr_mask     = UInt(CSR_MASK_WIDTH.W)
  val jump         = Bool()
  val ras_push     = if (AutoConfig.CONFIG_BRANCH_RAS) Some(Bool()) else None
  val ras_pop      = if (AutoConfig.CONFIG_BRANCH_RAS) Some(Bool()) else None
  val snpc         = UInt(PC_DATA_WIDTH.W)
  val imm          = UInt(32.W)
  val alu_din1     = UInt(REG_DATA_WIDTH.W)
  val alu_din2     = UInt(REG_DATA_WIDTH.W)
  val rs1_val      = UInt(REG_DATA_WIDTH.W)
  val rs2_val      = UInt(REG_DATA_WIDTH.W)
  val rs1_where_ex1 = UInt(WHERE_WIDTH.W)
  val rs2_where_ex1 = UInt(WHERE_WIDTH.W)
  val rs1_need     = UInt(NEED_WHEN_WIDTH.W)
  val rs2_need     = UInt(NEED_WHEN_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
  val pc           = UInt(PC_DATA_WIDTH.W)
  val rd_addr      = UInt(GPR_ADDR_WIDTH.W)
  val rd_wen       = Bool()
  val addr         = UInt(MEM_ADDR_WIDTH.W)
  val L_sign       = Bool()
  val mem_wen      = Bool()
  val mem_bytes    = UInt(2.W)
  val envir        = UInt(ENVIR_WIDTH.W)
}

// EX → WB Payload
class EX_WB_Payload extends Bundle {
  // test data
  val pc          = UInt(PC_DATA_WIDTH.W)
  val pc_next     = UInt(PC_DATA_WIDTH.W)
  val addr        = UInt(MEM_ADDR_WIDTH.W)
  val mem_bytes   = UInt(2.W)
  val mem_wen     = Bool()
  val when         = UInt(NEED_WHEN_WIDTH.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
  val bit_ctrl     = UInt(BIT_CTRL_WIDTH.W)

  val rd          = new GPRWriteBackBundle
  val envir        = UInt(ENVIR_WIDTH.W)
}
