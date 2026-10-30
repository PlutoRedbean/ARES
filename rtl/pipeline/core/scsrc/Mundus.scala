/*****************************************************************
 * Mundus Processor Core
 *
 * To be optimized:
 *   仿真环境参数显示
 *   valid logic for units
 *   div 控制电路优化
 *   mul 的符号位放在 iss 阶段计算
 *   one-hot coding optimization (Mux FSM)
 *   清除掉没用的信号
 *   Multiple same functions repeated
 *   debug process optimization
 *   区分 jal，jalr/branch 的预测错误惩罚
 *   清除掉没用的import
 **/
package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import DeviceParams._
import RISCV_INST._
import Func._
import MDUParams._
import ALUParams._

class Mundus extends Module {
  val io = IO(new Bundle {
    val irom  = new IROM()
    val perip = new PERIP()
    val coh   = new COH()
    val retire = Output(new RetireBundle)
  })

  /*===========================================================================*/
  // 1. Signal Declarations
  /*===========================================================================*/

  val ifu_valid = Wire(Bool())
  val idu_valid = Wire(Bool())
  val iss_valid = Wire(Bool())
  val ex1_valid = Wire(Bool())
  val ex2_valid = Wire(Bool())
  val ex3_valid = Wire(Bool())
  val ex4_valid = Wire(Bool())
  val exu_valid = Wire(Bool())
  val wbu_valid = Wire(Bool())

  val ifu_ready = Wire(Bool())
  val idu_ready = Wire(Bool())
  val iss_ready = Wire(Bool())
  val ex1_ready = Wire(Bool())
  val ex2_ready = Wire(Bool())
  val ex3_ready = Wire(Bool())
  val ex4_ready = Wire(Bool())
  val exu_ready = Wire(Bool())
  val wbu_ready = Wire(Bool())

  val ifu_stall     = Wire(Bool())
  val if_id_stall   = Wire(Bool())
  val id_iss_stall  = Wire(Bool())
  val iss_ex1_stall = Wire(Bool())
  val ex1_ex2_stall = Wire(Bool())
  val ex2_ex3_stall = Wire(Bool())
  val ex3_ex4_stall = Wire(Bool())
  val ex4_wb_stall  = Wire(Bool())

  val if_id_bubble   = Wire(Bool())
  val id_iss_bubble  = Wire(Bool())
  val iss_ex1_bubble = Wire(Bool())
  val ex1_ex2_bubble = Wire(Bool())
  val ex2_ex3_bubble = Wire(Bool())
  val ex3_ex4_bubble = Wire(Bool())
  val ex4_wb_bubble  = Wire(Bool())

  val long_stall_wb  = Wire(Bool())
  val long_in_flight = Wire(Bool())
  val backend_stall  = Wire(Bool())

  val data_hazard    = Wire(Bool())
  val control_hazard = Wire(Bool())
  val load_miss_replay = Wire(Bool())
  val frontend_redirect = Wire(Bool())

  val ex1_rd  = Wire(new ProducerBundle)
  val ex2_rd  = Wire(new ProducerBundle)
  val ex3_rd  = Wire(new ProducerBundle)
  val ex4_rd  = Wire(new ProducerBundle)
  val wb_rd   = Wire(new ProducerBundle)
  val ex1_reg_val = Wire(UInt(REG_DATA_WIDTH.W))
  val ex2_reg_val = Wire(UInt(REG_DATA_WIDTH.W))
  val ex3_reg_val = Wire(UInt(REG_DATA_WIDTH.W))
  val ex4_reg_val = Wire(UInt(REG_DATA_WIDTH.W))
  val ex1_reg_val_q = Wire(UInt(REG_DATA_WIDTH.W))
  val ex2_reg_val_q = Wire(UInt(REG_DATA_WIDTH.W))
  val ex3_reg_val_q = Wire(UInt(REG_DATA_WIDTH.W))
  val ex4_reg_val_q = Wire(UInt(REG_DATA_WIDTH.W))
  val wb_reg_val  = Wire(UInt(REG_DATA_WIDTH.W))

  val gpr_wb = Wire(new GPRWriteBackBundle)
  val gpr_rs1_addr = Wire(UInt(GPR_ADDR_WIDTH.W))
  val gpr_rs2_addr = Wire(UInt(GPR_ADDR_WIDTH.W))
  val gpr_rs1_val  = Wire(UInt(REG_DATA_WIDTH.W))
  val gpr_rs2_val  = Wire(UInt(REG_DATA_WIDTH.W))

  val ex1_bpu_update_en = Wire(Bool())
  val ex1_bpu_update_pc = Wire(UInt(PC_DATA_WIDTH.W))
  val ex1_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val ex1_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val ex1_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Wire(UInt(PC_DATA_WIDTH.W))) else None
  val ex1_branch_resolve = Wire(new BranchResolveBundle)
  val hzu_bpu_update_en = Wire(Bool())
  val hzu_bpu_update_pc = Wire(UInt(PC_DATA_WIDTH.W))
  val hzu_bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val hzu_bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Wire(Bool())) else None
  val hzu_bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Wire(UInt(PC_DATA_WIDTH.W))) else None
  val hzu_branch_resolve = Wire(new BranchResolveBundle)

  /*===========================================================================*/
  // 2. Module Instantiations
  /*===========================================================================*/

  val GPR          = Module(new RegisterFile)
  val IFU          = Module(new IFU)
  val IDU          = Module(new IDU)
  val ISU          = Module(new ISU)
  val EXU          = Module(new EXU)
  val WBU          = Module(new WBU)
  val HZU          = Module(new HZU)

  /*===========================================================================*/
  // 3. Datapath & Pipeline Stages
  /*===========================================================================*/

  /*---------------------------------------------------------------------------*/
  // 通用模块静态连接
  /*---------------------------------------------------------------------------*/
  GPR.io.clk    := clock
  GPR.io.wen    := gpr_wb.wen && wbu_valid
  GPR.io.waddr  := gpr_wb.addr
  GPR.io.wdata  := gpr_wb.data
  GPR.io.ren    := !(long_stall_wb || backend_stall || data_hazard)
  GPR.io.raddr1 := gpr_rs1_addr
  GPR.io.raddr2 := gpr_rs2_addr
  gpr_rs1_val   := GPR.io.rdata1
  gpr_rs2_val   := GPR.io.rdata2

  /*---------------------------------------------------------------------------*/
  // IFU: Instruction Fetch Unit
  /*---------------------------------------------------------------------------*/
  IFU.io.irom          <> io.irom
  IFU.io.bpu_update_en := hzu_bpu_update_en
  IFU.io.bpu_update_pc := hzu_bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    IFU.io.bpu_update_ras_push.get := hzu_bpu_update_ras_push.get
    IFU.io.bpu_update_ras_pop.get := hzu_bpu_update_ras_pop.get
    IFU.io.bpu_update_ras_addr.get := hzu_bpu_update_ras_addr.get
  }
  IFU.io.actual_taken  := hzu_branch_resolve.actual_taken
  IFU.io.redirected    := frontend_redirect
  // An older resolved branch has priority over a speculative load replay.
  IFU.io.redirected_pc := Mux(control_hazard,
    hzu_branch_resolve.actual_pc, EXU.io.replay_pc)
  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    IFU.io.bpu_update_is_branch.get := hzu_branch_resolve.is_branch.get
  }

  ifu_valid := IFU.io.out.valid
  ifu_ready := IFU.io.ready

  /*---------------------------------------------------------------------------*/
  // IF -> ID Pipeline Register
  pipelineConnect(IFU.io.out, IDU.io.in, if_id_stall, if_id_bubble, frontend_redirect)
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // IDU: Instruction Decode Unit
  /*---------------------------------------------------------------------------*/
  idu_valid     := IDU.io.out.valid
  idu_ready     := IDU.io.in.ready

  /*---------------------------------------------------------------------------*/
  // ID -> IS Pipeline Register
  pipelineConnect(IDU.io.out, ISU.io.in, id_iss_stall, id_iss_bubble, frontend_redirect)
  ISU.io.gpr_rs1_val := gpr_rs1_val
  ISU.io.gpr_rs2_val := gpr_rs2_val
  ISU.io.idu_valid   := idu_valid
  ISU.io.idu_rs1     := IDU.io.rs1
  ISU.io.idu_rs2     := IDU.io.rs2
  ISU.io.rs1_val_iss := EXU.io.rs1_val_iss
  ISU.io.rs2_val_iss := EXU.io.rs2_val_iss
  ISU.io.rs1_where_ex1 := EXU.io.rs1_where_ex1
  ISU.io.rs2_where_ex1 := EXU.io.rs2_where_ex1
  ISU.io.long_stall_wb  := long_stall_wb
  ISU.io.backend_stall  := backend_stall
  ISU.io.long_in_flight := long_in_flight
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // ISU: Issue/Register Read Unit
  /*---------------------------------------------------------------------------*/
  iss_valid := ISU.io.out.valid
  iss_ready := ISU.io.in.ready

  // The GPR is read synchronously: ID supplies the next address so its data
  // arrives together with ID -> ISS.  GPR.ren holds the registered read data
  // during an ISS stall.  Keeping the stall/interlock network off the RAM
  // address path avoids a control -> address mux -> RAM -> read-data path.
  gpr_rs1_addr := IDU.io.out.bits.rs1_addr
  gpr_rs2_addr := IDU.io.out.bits.rs2_addr

  /*---------------------------------------------------------------------------*/
  // IS -> EX Pipeline Register
  pipelineConnect(ISU.io.out, EXU.io.in, iss_ex1_stall, iss_ex1_bubble, frontend_redirect)
  EXU.io.lsu_lookup_valid := ISU.io.out.fire && !frontend_redirect &&
                             ISU.io.out.bits.mem_bytes =/= MEM_NONE
  EXU.io.lsu_lookup_addr := ISU.io.out.bits.addr
  EXU.io.flush := frontend_redirect
  EXU.io.rs1_val_ex1 := ISU.io.rs1_val_ex1
  EXU.io.rs2_val_ex1 := ISU.io.rs2_val_ex1
  // Pass only the pre-existing long-operation stall into the LSU request
  // qualifier. EXU adds bridge backpressure locally to all execution stages.
  EXU.io.ex1_ex2_stall := long_stall_wb
  EXU.io.ex2_ex3_stall := long_stall_wb
  EXU.io.ex3_ex4_stall := long_stall_wb
  EXU.io.ex1_ex2_bubble := ex1_ex2_bubble
  EXU.io.ex2_ex3_bubble := ex2_ex3_bubble
  EXU.io.ex3_ex4_bubble := ex3_ex4_bubble
  EXU.io.perip <> io.perip
  EXU.io.coh   := io.coh

  /*---------------------------------------------------------------------------*/
  // EXU: Execution Unit
  /*---------------------------------------------------------------------------*/
  ex1_valid   := EXU.io.ex1_valid
  ex2_valid   := EXU.io.ex2_valid
  ex3_valid   := EXU.io.ex3_valid
  ex4_valid   := EXU.io.ex4_valid
  ex1_ready   := EXU.io.ex1_ready
  ex2_ready   := EXU.io.ex2_ready
  ex3_ready   := EXU.io.ex3_ready
  ex4_ready   := EXU.io.ex4_ready
  exu_valid    := EXU.io.out.valid
  exu_ready    := EXU.io.in.ready
  long_in_flight := EXU.io.long_in_flight
  backend_stall := EXU.io.backend_stall

  ex1_reg_val := EXU.io.ex1_reg_val
  ex2_reg_val := EXU.io.ex2_reg_val
  ex3_reg_val := EXU.io.ex3_reg_val
  ex4_reg_val := EXU.io.ex4_reg_val
  ex1_reg_val_q := EXU.io.ex1_reg_val_q
  ex2_reg_val_q := EXU.io.ex2_reg_val_q
  ex3_reg_val_q := EXU.io.ex3_reg_val_q
  ex4_reg_val_q := WBU.io.ex4_reg_val_q
  ex1_rd <> EXU.io.ex1_rd
  ex2_rd <> EXU.io.ex2_rd
  ex3_rd <> EXU.io.ex3_rd
  ex4_rd <> EXU.io.ex4_rd

  ex1_bpu_update_en  := EXU.io.bpu_update_en
  ex1_bpu_update_pc  := EXU.io.bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    ex1_bpu_update_ras_push.get := EXU.io.bpu_update_ras_push.get
    ex1_bpu_update_ras_pop.get := EXU.io.bpu_update_ras_pop.get
    ex1_bpu_update_ras_addr.get := EXU.io.bpu_update_ras_addr.get
  }
  ex1_branch_resolve := EXU.io.branch_resolve

  /*---------------------------------------------------------------------------*/
  // EX -> WB Pipeline Register
  pipelineConnect(EXU.io.out, WBU.io.in, ex4_wb_stall, ex4_wb_bubble)
  /*---------------------------------------------------------------------------*/

  /*---------------------------------------------------------------------------*/
  // WBU: Write-Back Unit
  /*---------------------------------------------------------------------------*/
  wb_reg_val  := gpr_wb.data

  WBU.io.mul_out  := EXU.io.mul_out
  WBU.io.div_out  := EXU.io.div_out
  WBU.io.div_done := EXU.io.div_done
  WBU.io.clmul_out  := EXU.io.clmul_out
  WBU.io.clmul_done := EXU.io.clmul_done
  WBU.io.backend_stall := backend_stall

  wbu_valid := WBU.io.valid
  wbu_ready := WBU.io.in.ready

  gpr_wb <> WBU.io.gpr
  wb_rd <> WBU.io.rd

  io.retire := WBU.io.retire

  // EBREAK is a commit-visible halt for the standalone pipeline core.  Set a
  // sticky halt bit when it retires and freeze all stages; the testbench uses
  // retire_is_ebreak to terminate, while the core no longer fetches younger
  // instructions.
  val halted = RegInit(false.B)
  when (wbu_valid && WBU.io.retire.is_ebreak) {
    halted := true.B
  }

  long_stall_wb := WBU.io.long_stall

  /*===========================================================================*/
  // 5. ISU Bypass Network
  /*===========================================================================*/
  ISU.io.ex1_valid := ex1_valid
  ISU.io.ex2_valid := ex2_valid
  ISU.io.ex3_valid := ex3_valid
  ISU.io.ex4_valid := ex4_valid
  ISU.io.wb_valid  := wbu_valid
  ISU.io.ex1_rd    := ex1_rd
  ISU.io.ex2_rd    := ex2_rd
  ISU.io.ex3_rd    := ex3_rd
  ISU.io.ex4_rd    := ex4_rd
  ISU.io.wb_rd     := wb_rd
  ISU.io.ex1_reg_val := ex1_reg_val
  ISU.io.ex2_reg_val := ex2_reg_val
  ISU.io.ex3_reg_val := ex3_reg_val
  ISU.io.ex4_reg_val := ex4_reg_val
  ISU.io.ex1_reg_val_q := ex1_reg_val_q
  ISU.io.ex2_reg_val_q := ex2_reg_val_q
  ISU.io.ex3_reg_val_q := ex3_reg_val_q
  ISU.io.ex4_reg_val_q := ex4_reg_val_q
  ISU.io.wb_reg_val  := wb_reg_val

  /*===========================================================================*/
  // 6. Hazard Detect Unit
  /*===========================================================================*/

  HZU.io.ex1_valid          := ex1_valid

  HZU.io.ex1_bpu_update_en  := ex1_bpu_update_en
  HZU.io.ex1_bpu_update_pc  := ex1_bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    HZU.io.ex1_bpu_update_ras_push.get := ex1_bpu_update_ras_push.get
    HZU.io.ex1_bpu_update_ras_pop.get := ex1_bpu_update_ras_pop.get
    HZU.io.ex1_bpu_update_ras_addr.get := ex1_bpu_update_ras_addr.get
  }
  HZU.io.ex1_branch_resolve := ex1_branch_resolve

  hzu_bpu_update_en  := HZU.io.hzu_bpu_update_en
  hzu_bpu_update_pc  := HZU.io.hzu_bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    hzu_bpu_update_ras_push.get := HZU.io.hzu_bpu_update_ras_push.get
    hzu_bpu_update_ras_pop.get := HZU.io.hzu_bpu_update_ras_pop.get
    hzu_bpu_update_ras_addr.get := HZU.io.hzu_bpu_update_ras_addr.get
  }
  hzu_branch_resolve := HZU.io.hzu_branch_resolve

  data_hazard    := ISU.io.interlock
  control_hazard := HZU.io.hzu_hazard
  load_miss_replay := EXU.io.load_miss_replay
  frontend_redirect := control_hazard || load_miss_replay

  val issue_hazard = !control_hazard && data_hazard

  // FENCE/FENCE.I barrier: hold the fence in Decode until all older memory
  // operations have left the LSU and the SoC peripheral bridge is idle.  The
  // fence then issues as a no-register-write NOP; younger instructions cannot
  // pass it because the in-order ID stage is held.
  val fence_wait = IDU.io.out.valid &&
                   IDU.io.out.bits.envir === ENVIR_FENCE &&
                   !(EXU.io.lsu_idle && io.perip.idle)

  // A DIV/REM or CLMUL waits in Iss while an older long operation is in flight.  Iss is held
  // by stalling its upstream register and a bubble is sent to Ex1, allowing
  // older instructions to keep advancing.  A long operation waiting in Wr still has
  // to freeze the in-order pipeline until its result is available.
  ifu_stall     := long_stall_wb || backend_stall || issue_hazard || fence_wait || halted
  if_id_stall   := long_stall_wb || backend_stall || issue_hazard || fence_wait || halted
  id_iss_stall  := long_stall_wb || backend_stall || issue_hazard || fence_wait || halted
  iss_ex1_stall := long_stall_wb || backend_stall || halted
  ex1_ex2_stall := long_stall_wb || backend_stall || halted
  ex2_ex3_stall := long_stall_wb || backend_stall || halted
  ex3_ex4_stall := long_stall_wb || backend_stall || halted
  ex4_wb_stall  := long_stall_wb || backend_stall || halted

  if_id_bubble   := frontend_redirect
  id_iss_bubble  := frontend_redirect
  iss_ex1_bubble := frontend_redirect || issue_hazard
  ex1_ex2_bubble := false.B
  ex2_ex3_bubble := false.B
  ex3_ex4_bubble := false.B
  ex4_wb_bubble  := false.B

  /*===========================================================================*/
  // 6. Simulation
  /*===========================================================================*/

  if (CONFIG_SIMULATION) {

    dontTouch(ifu_valid)
    dontTouch(idu_valid)
    dontTouch(iss_valid)
    dontTouch(ex1_valid)
    dontTouch(ex2_valid)
    dontTouch(ex3_valid)
    dontTouch(ex4_valid)
    dontTouch(exu_valid)
    dontTouch(wbu_valid)
    dontTouch(ifu_ready)
    dontTouch(idu_ready)
    dontTouch(iss_ready)
    dontTouch(ex1_ready)
    dontTouch(ex2_ready)
    dontTouch(ex3_ready)
    dontTouch(ex4_ready)
    dontTouch(exu_ready)
    dontTouch(wbu_ready)
    dontTouch(ifu_stall)
    dontTouch(if_id_stall)
    dontTouch(id_iss_stall)
    dontTouch(iss_ex1_stall)
    dontTouch(ex1_ex2_stall)
    dontTouch(ex2_ex3_stall)
    dontTouch(ex3_ex4_stall)
    dontTouch(ex4_wb_stall)
    dontTouch(if_id_bubble)
    dontTouch(id_iss_bubble)
    dontTouch(iss_ex1_bubble)
    dontTouch(ex1_ex2_bubble)
    dontTouch(ex2_ex3_bubble)
    dontTouch(ex3_ex4_bubble)
    dontTouch(ex4_wb_bubble)

    val DPIC = Module(new Mundus_DPIC)

    DPIC.io.clk        := clock
    DPIC.io.rst        := reset
    DPIC.io.pc_next_in := WBU.sim_io.pc_next
    DPIC.io.cycle_done := wbu_valid
    DPIC.io.bpu_update_en := hzu_bpu_update_en
    DPIC.io.bpu_update_pc := hzu_bpu_update_pc
    DPIC.io.predicted_pc := hzu_branch_resolve.predicted_pc
    DPIC.io.predicted_taken := hzu_branch_resolve.predicted_taken
    DPIC.io.actual_pc := hzu_branch_resolve.actual_pc
    DPIC.io.actual_taken := hzu_branch_resolve.actual_taken
    DPIC.io.environment := WBU.io.envir

    val pipelineStats = Module(new PipelineStats_DPIC)
    pipelineStats.io.clk := clock
    pipelineStats.io.rst := reset
    pipelineStats.io.retire := wbu_valid
    pipelineStats.io.pipeline_active :=
      ifu_valid || idu_valid || iss_valid || ex1_valid || ex2_valid ||
      ex3_valid || ex4_valid || exu_valid || wbu_valid
    pipelineStats.io.backend_stall := backend_stall
    pipelineStats.io.long_stall := long_stall_wb
    pipelineStats.io.issue_hazard := issue_hazard
    pipelineStats.io.control_redirect := control_hazard
    pipelineStats.io.load_replay := load_miss_replay
  }
}

import java.io.File
import java.io.PrintWriter

object Elaborate extends App {
  println("Starting Elaboration...")
  val sv = _root_.circt.stage.ChiselStage.emitSystemVerilog(
    gen = new Mundus,
    firtoolOpts = Array(
      "--lowering-options=disallowLocalVariables",
      "-disable-all-randomization",
      "-strip-debug-info"
    )
  )
  println(s"SV Length: ${sv.length}")
  val targetDir = if (args.contains("--target-dir")) args(args.indexOf("--target-dir") + 1) else "."
  println(s"Target Dir: $targetDir")
  val dir = new File(targetDir)
  if (!dir.exists()) dir.mkdirs()
  val pw = new PrintWriter(new File(dir, "Mundus.sv"))
  pw.write(sv)
  pw.close()
  println("Successfully generated!")
}
