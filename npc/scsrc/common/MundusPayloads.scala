package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import TageParams._

class TageMetaBundle extends Bundle {
  val valid = Bool()
  val bits = UInt(MetaWidth.W)
}

// Simulation-only metadata used to measure whether the loop predictor is
// helping the final direction decision.  It is absent from synthesis builds.
class LoopPredictionMetaBundle extends Bundle {
  val valid = Bool()
  val candidate = Bool()
  val prediction = Bool()
  val basePrediction = Bool()
}

class FastRecurrenceUpdateBundle extends Bundle {
  val valid = Bool()
  val state = UInt(MundusConfig.REG_DATA_WIDTH.W)
  val beqz = Bool()
}

class FrpExecutionEventBundle extends Bundle {
  val valid = Bool()
  val rdWen = Bool()
  val rdAddr = UInt(MundusConfig.GPR_ADDR_WIDTH.W)
  val bitTest = Bool()
  val bitState = UInt(MundusConfig.REG_DATA_WIDTH.W)
  val zeroBranch = Bool()
  val branchPc = UInt(MundusConfig.PC_DATA_WIDTH.W)
  val testReg = UInt(MundusConfig.GPR_ADDR_WIDTH.W)
  val branchBeqz = Bool()
}

object DualIssue {
  val Width = 2
}

class IROM extends Bundle {
  val addr = Output(UInt(32.W))
  val data = Input(UInt(64.W))
}

class PERIP extends Bundle {
  val valid = Output(Bool())
  val ready = Input(Bool())
  val rvalid = Input(Bool())
  val addr  = Output(UInt(32.W))
  val wen   = Output(Bool())
  val mask  = Output(UInt(2.W))
  val wdata = Output(UInt(32.W))
  val rdata = Input(UInt(32.W))
}

// IF → ID Payload
class IF_ID_Payload extends Bundle {
  val pc   = UInt(PC_DATA_WIDTH.W)
  val inst = UInt(32.W)
  val snpc = UInt(PC_DATA_WIDTH.W)
  val predicted_pc    = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val tage_meta = if (AutoConfig.CONFIG_BP_TAGE) Some(new TageMetaBundle) else None
  val loop_meta = if (AutoConfig.CONFIG_SIMULATION &&
      AutoConfig.CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frp_owned = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
}

// ID → IS Payload
class ID_IS_Payload extends Bundle {
  // comsume
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val tage_meta = if (AutoConfig.CONFIG_BP_TAGE) Some(new TageMetaBundle) else None
  val loop_meta = if (AutoConfig.CONFIG_SIMULATION &&
      AutoConfig.CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frp_owned = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_bit_test = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_zero_branch = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_branch_beqz = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_test_reg = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE)
    Some(UInt(GPR_ADDR_WIDTH.W)) else None
  val alu_ctrl     = UInt(ALU_CTRL_WIDTH.W)
  val bru_ctrl     = UInt(BRU_CTRL_WIDTH.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
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
  val flat_rs1     = Bool()
  val flat_rs2     = Bool()
  val load_pair_rs1 = Bool()
  val load_pair_rs2 = Bool()
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
  val tage_meta = if (AutoConfig.CONFIG_BP_TAGE) Some(new TageMetaBundle) else None
  val loop_meta = if (AutoConfig.CONFIG_SIMULATION &&
      AutoConfig.CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frp_owned = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_bit_test = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_zero_branch = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_branch_beqz = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_test_reg = if (AutoConfig.CONFIG_BRANCH_FAST_RECURRENCE)
    Some(UInt(GPR_ADDR_WIDTH.W)) else None
  val alu_ctrl     = UInt(ALU_CTRL_WIDTH.W)
  val bru_ctrl     = UInt(BRU_CTRL_WIDTH.W)
  val mdu_ctrl     = UInt(MDU_CTRL_WIDTH.W)
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
  val rs1_late     = new LateOperandBundle
  val rs2_late     = new LateOperandBundle
  val rs1_assert_addr = if (AutoConfig.CONFIG_SIMULATION)
    Some(UInt(GPR_ADDR_WIDTH.W)) else None
  val rs2_assert_addr = if (AutoConfig.CONFIG_SIMULATION)
    Some(UInt(GPR_ADDR_WIDTH.W)) else None
  val flat_rs1     = Bool()
  val flat_rs2     = Bool()
  val load_pair_rs1 = Bool()
  val load_pair_rs2 = Bool()
  val rs1_need     = UInt(NEED_WHEN_WIDTH.W)
  val rs2_need     = UInt(NEED_WHEN_WIDTH.W)
  val when         = UInt(NEED_WHEN_WIDTH.W)
  val pc           = UInt(PC_DATA_WIDTH.W)
  val rd_addr      = UInt(GPR_ADDR_WIDTH.W)
  val rd_wen       = Bool()
  val addr         = UInt(MEM_ADDR_WIDTH.W)
  val cache_probe_match = Bool()
  val L_sign       = Bool()
  val mem_wen      = Bool()
  val mem_bytes    = UInt(2.W)
  val transient_fwd_mask = UInt(4.W)
  val transient_fwd_data = UInt(MEM_DATA_WIDTH.W)
  val transient_fwd_sources = UInt(3.W)
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

  val rd          = new GPRWriteBackBundle
  val envir        = UInt(ENVIR_WIDTH.W)
}

// A group always represents the oldest contiguous instruction prefix.  The
// only non-empty masks allowed by the in-order two-wide pipeline are 01 and
// 11; lane 1 is never allowed to live without lane 0.
class IF_ID_Group extends Bundle {
  val laneValid = UInt(DualIssue.Width.W)
  val lane = Vec(DualIssue.Width, new IF_ID_Payload)
}

class ID_IS_Group extends Bundle {
  val laneValid = UInt(DualIssue.Width.W)
  val lane = Vec(DualIssue.Width, new ID_IS_Payload)
}

// Decoded issue groups carry their synchronous register-file snapshot while
// waiting behind an older interlocked group.  Writeback refreshes these base
// values in the holding queue; the normal ISU bypass network still selects
// younger in-flight producers at issue time.
class ID_IS_HoldingEntry extends Bundle {
  val group = new ID_IS_Group
  val gprRs1 = Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W))
  val gprRs2 = Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W))
  // Speculative addresses are formed from the registered RF snapshot while
  // a group waits. LSU validates the direct-mapped index against the final
  // AGU result, while DCache validates the remaining word-address tag.
  val preparedAddr = Vec(DualIssue.Width, UInt(MEM_ADDR_WIDTH.W))
}

class IS_EX_Group extends Bundle {
  val laneValid = UInt(DualIssue.Width.W)
  val lane = Vec(DualIssue.Width, new IS_EX_Payload)
}

class EX_WB_Group extends Bundle {
  val laneValid = UInt(DualIssue.Width.W)
  val lane = Vec(DualIssue.Width, new EX_WB_Payload)
}
