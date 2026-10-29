package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import BRUParams._
import MDUParams._
import BitManipParams._
import CSRParams._

class exu_ex1 extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IS_EX_Payload))
    val out  = Decoupled(new EX1_EX2_Payload)
    val flush = Input(Bool())
    val mul_out = Output(UInt(MUL_OUT_WIDTH.W))
    val div_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_busy = Output(Bool())
    val div_done = Output(Bool())
    val clmul_out = Output(UInt(REG_DATA_WIDTH.W))
    val clmul_busy = Output(Bool())
    val clmul_done = Output(Bool())
    val bpu_update_en = Output(Bool())
    val bpu_update_pc = Output(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val branch_resolve = Output(new BranchResolveBundle)
    val reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val rd = Output(new ProducerBundle)
  })

  val ex_in = io.in
  val valid = ex_in.valid && !io.flush

  val this_pc      = ex_in.bits.pc
  val jump         = ex_in.bits.jump
  val alu_ctrl     = ex_in.bits.alu_ctrl
  val bru_ctrl     = ex_in.bits.bru_ctrl
  val mdu_ctrl     = ex_in.bits.mdu_ctrl
  val bit_ctrl     = ex_in.bits.bit_ctrl
  val snpc         = ex_in.bits.snpc
  val imm          = ex_in.bits.imm
  val rs1_val      = ex_in.bits.rs1_val
  val rs2_val      = ex_in.bits.rs2_val

  val ALU = Module(new ALU)
  ALU.io.alu_ctrl := alu_ctrl
  ALU.io.din1     := ex_in.bits.alu_din1
  ALU.io.din2     := ex_in.bits.alu_din2
  val alu_out = ALU.io.dout

  val BRU = Module(new BRU)
  BRU.io.bru_ctrl := bru_ctrl
  BRU.io.imm      := imm
  BRU.io.snpc     := snpc
  BRU.io.pc       := this_pc
  BRU.io.rs1_val  := rs1_val
  BRU.io.rs2_val  := rs2_val
  val bru_redirect = BRU.io.redirect
  val is_branch_inst = bru_ctrl(BRU_MUX_WIDTH - 1, 0) === BR_BRANCH

  val MUL = Module(new MUL)
  MUL.io.mdu_ctrl := mdu_ctrl
  MUL.io.enable   := io.out.ready
  MUL.io.din1     := rs1_val
  MUL.io.din2     := rs2_val

  val DIV = Module(new DIV)
  DIV.io.mdu_ctrl := mdu_ctrl
  DIV.io.valid    := valid
  DIV.io.din1     := rs1_val
  DIV.io.din2     := rs2_val

  val bitData     = WireDefault(0.U(REG_DATA_WIDTH.W))
  val bitAux      = WireDefault(0.U(REG_DATA_WIDTH.W))
  val bitEx1Result = WireDefault(0.U(REG_DATA_WIDTH.W))
  if (CONFIG_RV32_ZBB_CLZ || CONFIG_RV32_ZBB_CTZ || CONFIG_RV32_ZBB_CPOP ||
      CONFIG_RV32_ZBB_ORC_B || CONFIG_RV32_ZBB_ZEXT_H ||
      CONFIG_RV32_ZBKX_XPERM4 || CONFIG_RV32_ZBB_ROR) {
    val BIT_EX1 = Module(new BitManipEx1)
    BIT_EX1.io.ctrl := bit_ctrl
    BIT_EX1.io.rs1  := rs1_val
    BIT_EX1.io.rs2  := rs2_val
    bitData      := BIT_EX1.io.bit_data
    bitAux       := BIT_EX1.io.bit_aux
    bitEx1Result := BIT_EX1.io.ex1_result
  }

  val clmulOut   = WireDefault(0.U(REG_DATA_WIDTH.W))
  val clmulStall = WireDefault(false.B)
  val clmulBusy  = WireDefault(false.B)
  val clmulDone  = WireDefault(false.B)
  if (CONFIG_RV32_ZBC_CLMUL) {
    val CLMUL_UNIT = Module(new CarryLessMul)
    CLMUL_UNIT.io.valid := valid && bit_ctrl === BIT_CLMUL && io.out.ready
    CLMUL_UNIT.io.din1  := rs1_val
    CLMUL_UNIT.io.din2  := rs2_val
    clmulOut   := CLMUL_UNIT.io.dout
    clmulStall := CLMUL_UNIT.io.stall
    clmulBusy  := CLMUL_UNIT.io.busy
    clmulDone  := CLMUL_UNIT.io.done
  }

  val exu_stall = DIV.io.stall || clmulStall
  val exu_out_valid = valid && !exu_stall
  
  ex_in.ready := io.out.ready && !exu_stall
  io.out.valid := exu_out_valid
  val exu_fire = exu_out_valid && io.out.ready

  val is_ecall     = ex_in.bits.envir === ENVIR_ECALL
  val is_mret      = ex_in.bits.envir === ENVIR_MRET

  val CSR = Module(new CSR)
  CSR.io.valid      := exu_fire
  CSR.io.ctrl       := ex_in.bits.csr_ctrl(1, 0)
  CSR.io.wdata      := Mux(ex_in.bits.csr_ctrl(2), ex_in.bits.imm, rs1_val)
  CSR.io.mask       := ex_in.bits.csr_mask
  CSR.io.ecall      := exu_fire && is_ecall
  CSR.io.mret       := exu_fire && is_mret
  CSR.io.trap_pc    := this_pc
  
  val trap_redirect  = exu_fire && (is_ecall || is_mret)
  val trap_target_pc = Fill(32, is_ecall) & CSR.io.mtvec |
                       Fill(32, is_mret) & CSR.io.mepc

  val actual_taken = bru_redirect || trap_redirect
  val actual_pc = Mux(bru_redirect , BRU.io.target_pc,
                  Mux(trap_redirect, trap_target_pc  , snpc))

  val dnpc_mispredict = BRU.io.target_pc =/= ex_in.bits.predicted_pc
  val snpc_mispredict = snpc             =/= ex_in.bits.predicted_pc
  val trap_mispredict = trap_target_pc   =/= ex_in.bits.predicted_pc
  val branch_mispredict = Mux(bru_redirect , dnpc_mispredict,
                          Mux(trap_redirect, trap_mispredict, snpc_mispredict))

  val is_load = ex_in.bits.mem_bytes =/= MEM_NONE && !ex_in.bits.mem_wen

  io.out.bits.pc      := this_pc
  io.out.bits.addr    := io.in.bits.addr
  io.out.bits.mem_wdata := rs2_val
  io.out.bits.mem_wen := ex_in.bits.mem_wen

  val base_reg_val = Mux(ex_in.bits.csr_ctrl =/= CSR_NONE, CSR.io.rdata, alu_out)
  val isEx1BitOp = bit_ctrl === BIT_ORC_B || bit_ctrl === BIT_ZEXT_H
  val reg_val = Mux(isEx1BitOp, bitEx1Result, base_reg_val)

  io.out.bits.reg_data := reg_val
  io.out.bits.mdu_ctrl := mdu_ctrl
  io.out.bits.bit_ctrl := bit_ctrl
  io.out.bits.bit_data := bitData
  io.out.bits.bit_aux := bitAux
  io.out.bits.L_sign := ex_in.bits.L_sign
  io.out.bits.mem_bytes := ex_in.bits.mem_bytes
  io.out.bits.rd_addr := ex_in.bits.rd_addr
  io.out.bits.rd_wen := ex_in.bits.rd_wen
  io.out.bits.is_load := is_load
  io.out.bits.envir := ex_in.bits.envir
  io.out.bits.when := ex_in.bits.when

  io.bpu_update_en := (is_branch_inst || jump) && exu_fire
  io.bpu_update_pc := this_pc
  if (CONFIG_BRANCH_RAS) {
    io.bpu_update_ras_push.get := ex_in.bits.ras_push.get && exu_fire
    io.bpu_update_ras_pop.get := ex_in.bits.ras_pop.get && exu_fire
    io.bpu_update_ras_addr.get := snpc
  }

  io.branch_resolve.predicted_pc := ex_in.bits.predicted_pc
  io.branch_resolve.predicted_taken := ex_in.bits.predicted_taken
  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    io.branch_resolve.is_branch.get := is_branch_inst
  }
  io.branch_resolve.actual_pc    := actual_pc
  io.branch_resolve.actual_taken := actual_taken
  io.branch_resolve.mispredict   := branch_mispredict

  io.rd.wen  := ex_in.bits.rd_wen
  io.rd.addr := ex_in.bits.rd_addr
  io.rd.when := ex_in.bits.when
  io.reg_val := reg_val

  io.mul_out := MUL.io.dout
  io.div_out := DIV.io.dout
  io.div_busy := DIV.io.busy
  io.div_done := DIV.io.done
  io.clmul_out := clmulOut
  io.clmul_busy := clmulBusy
  io.clmul_done := clmulDone

  io.out.bits.pc_next := io.branch_resolve.actual_pc
}
