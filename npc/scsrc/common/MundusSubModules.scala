package npc
import chisel3._
import chisel3.util._
import chisel3.experimental.ExtModule
import MundusConfig._
import AutoConfig._

// BlackBox for DPIC and Simulation Functions
class Mundus_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val pc_next_in = Input(UInt(PC_DATA_WIDTH.W))
    val cycle_done = Input(Bool())
    val interrupt_take = Input(Bool())
    val interrupt_target = Input(UInt(PC_DATA_WIDTH.W))
    val retire_mask = Input(UInt(DualIssue.Width.W))
    val pc0 = Input(UInt(PC_DATA_WIDTH.W))
    val pc1 = Input(UInt(PC_DATA_WIDTH.W))
    val pc_next0 = Input(UInt(PC_DATA_WIDTH.W))
    val pc_next1 = Input(UInt(PC_DATA_WIDTH.W))
    val rd_wen0 = Input(Bool())
    val rd_addr0 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rd_data0 = Input(UInt(REG_DATA_WIDTH.W))
    val rd_wen1 = Input(Bool())
    val rd_addr1 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rd_data1 = Input(UInt(REG_DATA_WIDTH.W))
    val bpu_update_en = Input(Bool())
    val bpu_update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val predicted_pc = Input(UInt(PC_DATA_WIDTH.W))
    val predicted_taken = Input(Bool())
    val actual_pc = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken = Input(Bool())
    val frp_owned = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val frp_candidate = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val frp_active = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val frp_boundary = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val frp_token_created = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(UInt(2.W))) else None
    val frp_token_consumed = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(UInt(2.W))) else None
    val frp_blocked_by_issued = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Input(Bool())) else None
    val loop_meta_valid = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val loop_candidate = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val loop_prediction = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val loop_base_prediction = if (CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val tage_meta_valid = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val tage_prediction = if (CONFIG_BP_TAGE && CONFIG_BRANCH_LOOP_PREDICTOR) Some(Input(Bool())) else None
    val environment0 = Input(UInt(ENVIR_WIDTH.W))
    val environment1 = Input(UInt(ENVIR_WIDTH.W))
  })
}

class PipelineStats_DPIC extends BlackBox(Map(
  "IQ_COUNT_WIDTH" ->
    log2Ceil(AutoConfig.CONFIG_FRONTEND_QUEUE_DEPTH + 1))) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val retire_count =
      Input(UInt(log2Ceil(DualIssue.Width + 1).W))
    val issue_count =
      Input(UInt(log2Ceil(DualIssue.Width + 1).W))
    val iq_count =
      Input(UInt(log2Ceil(AutoConfig.CONFIG_FRONTEND_QUEUE_DEPTH + 1).W))
    val pair_opportunity = Input(Bool())
    val pair_success = Input(Bool())
    val reject_slot0_serial = Input(Bool())
    val reject_slot1_unsupported = Input(Bool())
    val reject_shared_resource = Input(Bool())
    val reject_waw = Input(Bool())
    val reject_raw = Input(Bool())
    val reject_slot1_late = Input(Bool())
    val waw_only = Input(Bool())
    val waw_flat_raw = Input(Bool())
    val waw_load_raw = Input(Bool())
    val waw_mul_raw = Input(Bool())
    val flat_bypass = Input(Bool())
    val load_pair_hit = Input(Bool())
    val load_pair_replay = Input(Bool())
    val pipeline_active = Input(Bool())
    val backend_stall = Input(Bool())
    val long_stall = Input(Bool())
    val issue_hazard = Input(Bool())
    val stall_primary = Input(UInt(4.W))
    val stall_raw = Input(UInt(9.W))
    val issue_operand_stall = Input(Bool())
    val operand_stall_mask = Input(UInt((DualIssue.Width * 2).W))
    val operand_producer_stage = Input(UInt(
      (DualIssue.Width * 2 * OperandStats.PRODUCER_STAGE_WIDTH).W))
    val operand_producer_type = Input(UInt(
      (DualIssue.Width * 2 * OperandStats.PRODUCER_TYPE_WIDTH).W))
    val operand_consumer_type = Input(UInt(
      (DualIssue.Width * 2 * OperandStats.CONSUMER_TYPE_WIDTH).W))
    val operand_pc =
      Input(Vec(DualIssue.Width, UInt(PC_DATA_WIDTH.W)))
    val control_redirect = Input(Bool())
    val load_replay = Input(Bool())
    val store_overlap_ex1 = Input(Bool())
    val store_overlap_ex2 = Input(Bool())
    val store_overlap_ready = Input(Bool())
    val store_overlap_not_ready = Input(Bool())
    val transient_forward = Input(Bool())
    val transient_forward_bytes = Input(UInt(3.W))
    val transient_unknown_addr_stall = Input(Bool())
    val transient_data_stall = Input(Bool())
    val transient_multi_store = Input(Bool())
    val transient_shadowed_not_ready = Input(Bool())
  })
}

class Mundus_PC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val din = Input(UInt(PC_DATA_WIDTH.W))
    val dout = Output(UInt(PC_DATA_WIDTH.W))
    val wen = Input(Bool())
  })
}

class RegisterFile extends BlackBox(Map(
  "ADDR_WIDTH" -> GPR_ADDR_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val wen0 = Input(Bool())
    val waddr0 = Input(UInt(GPR_ADDR_WIDTH.W))
    val wdata0 = Input(UInt(REG_DATA_WIDTH.W))
    val wen1 = Input(Bool())
    val waddr1 = Input(UInt(GPR_ADDR_WIDTH.W))
    val wdata1 = Input(UInt(REG_DATA_WIDTH.W))
    val ren = Input(Bool())
    val raddr1_0 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata1_0 = Output(UInt(REG_DATA_WIDTH.W))
    val raddr2_0 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata2_0 = Output(UInt(REG_DATA_WIDTH.W))
    val raddr1_1 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata1_1 = Output(UInt(REG_DATA_WIDTH.W))
    val raddr2_1 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata2_1 = Output(UInt(REG_DATA_WIDTH.W))
  })
}
