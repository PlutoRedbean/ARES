package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import DPUParams._
import MDUParams._
import BitManipParams._

// ISS: register read happens here (synchronous GPR data aligned to this stage).
// The AGU forms the load/store address through its dedicated early-compare
// bypass, while the general operand network continues to feed the EX1 units.
class ISU extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new ID_IS_Payload))
    val out = Decoupled(new IS_EX_Payload)

    val gpr_rs1_val = Input(UInt(REG_DATA_WIDTH.W))
    val gpr_rs2_val = Input(UInt(REG_DATA_WIDTH.W))

    val idu_valid = Input(Bool())
    val idu_rs1   = Input(new ConsumerBundle)
    val idu_rs2   = Input(new ConsumerBundle)

    val rs1_val_iss = Input(UInt(REG_DATA_WIDTH.W))
    val rs2_val_iss = Input(UInt(REG_DATA_WIDTH.W))
    val rs1_where_ex1 = Input(UInt(WHERE_WIDTH.W))
    val rs2_where_ex1 = Input(UInt(WHERE_WIDTH.W))

    val ex1_valid = Input(Bool())
    val ex2_valid = Input(Bool())
    val ex3_valid = Input(Bool())
    val ex4_valid = Input(Bool())
    val wb_valid  = Input(Bool())

    val ex1_rd = Input(new ProducerBundle)
    val ex2_rd = Input(new ProducerBundle)
    val ex3_rd = Input(new ProducerBundle)
    val ex4_rd = Input(new ProducerBundle)
    val wb_rd  = Input(new ProducerBundle)

    val ex1_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val wb_reg_val  = Input(UInt(REG_DATA_WIDTH.W))

    val ex1_reg_val_q = Input(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val_q = Input(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val_q = Input(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val_q = Input(UInt(REG_DATA_WIDTH.W))

    val rs1_val_ex1 = Output(UInt(REG_DATA_WIDTH.W))
    val rs2_val_ex1 = Output(UInt(REG_DATA_WIDTH.W))

    val long_stall_wb  = Input(Bool())
    val backend_stall  = Input(Bool())
    val long_in_flight = Input(Bool())
    val interlock   = Output(Bool())

    // Per-hart private-data relocation.  The offset is applied to the AGU
    // address before the L1 lookup, so tag/index and the later L2 access see
    // the same private physical address.  MMIO and IROM addresses are not
    // offset.
    val data_offset = Input(UInt(MEM_ADDR_WIDTH.W))
  })

  io.in.ready  := io.out.ready
  io.out.valid := io.in.valid & !io.interlock

  val alu_op1 = io.in.bits.ALU_operand1
  val alu_op2 = io.in.bits.ALU_operand2

  val imm  = io.in.bits.imm
  val snpc = io.in.bits.snpc
  val pc   = io.in.bits.pc

  val isu_ctrl = Module(new isu_ctrl)
  val isu_rf   = Module(new isu_rf)
  val isu_ex1  = Module(new isu_ex1)
  val isu_agu      = Module(new isu_agu)

  val agu_valid_iss = io.in.valid && io.in.bits.mem_bytes =/= MEM_NONE

  val iss_rs1 = Wire(new ConsumerBundle)
  val iss_rs2 = Wire(new ConsumerBundle)
  iss_rs1.ren  := alu_op1 === OPR_RS1
  iss_rs1.addr := io.in.bits.rs1_addr
  // An address is consumed early in Iss.  Unlike the general operand path,
  // the AGU has no Ex1 forwarding input, so an immediate predecessor stalls
  // for one cycle and is then selected from Ex2 by the early-compare network.
  iss_rs1.need := Mux(agu_valid_iss, NEED_ISS_EARLY, io.in.bits.rs1_need)
  iss_rs2.ren  := alu_op2 === OPR_RS2
  iss_rs2.addr := io.in.bits.rs2_addr
  iss_rs2.need := io.in.bits.rs2_need

  val raw_long_valid_iss = io.in.valid && (
    io.in.bits.mdu_ctrl(MDU_MUX_WIDTH - 1, 0) === MD_DIV ||
    io.in.bits.bit_ctrl === BIT_CLMUL)

  isu_ctrl.io.raw_long_valid_iss := raw_long_valid_iss
  isu_ctrl.io.long_stall_wb      := io.long_stall_wb
  isu_ctrl.io.backend_stall      := io.backend_stall
  isu_ctrl.io.long_in_flight     := io.long_in_flight
  isu_ctrl.io.ex1_valid := io.ex1_valid
  isu_ctrl.io.ex2_valid := io.ex2_valid
  isu_ctrl.io.ex3_valid := io.ex3_valid
  isu_ctrl.io.ex4_valid := io.ex4_valid
  isu_ctrl.io.wb_valid  := io.wb_valid
  isu_ctrl.io.iss_rs1   := iss_rs1
  isu_ctrl.io.iss_rs2   := iss_rs2
  isu_ctrl.io.idu_valid := io.idu_valid
  isu_ctrl.io.idu_rs1   := io.idu_rs1
  isu_ctrl.io.idu_rs2   := io.idu_rs2
  isu_ctrl.io.ex1_rd    := io.ex1_rd
  isu_ctrl.io.ex2_rd    := io.ex2_rd
  isu_ctrl.io.ex3_rd    := io.ex3_rd
  isu_ctrl.io.ex4_rd    := io.ex4_rd
  isu_ctrl.io.wb_rd     := io.wb_rd

  isu_rf.io.gpr_rs1_val := io.gpr_rs1_val
  isu_rf.io.gpr_rs2_val := io.gpr_rs2_val
  isu_rf.io.ex1_reg_val := io.ex1_reg_val
  isu_rf.io.ex2_reg_val := io.ex2_reg_val
  isu_rf.io.ex3_reg_val := io.ex3_reg_val
  isu_rf.io.ex4_reg_val := io.ex4_reg_val
  isu_rf.io.wb_reg_val  := io.wb_reg_val
  isu_rf.io.rs1_fwd_sel_iss := isu_ctrl.io.rs1_fwd_sel_iss
  isu_rf.io.rs2_fwd_sel_iss := isu_ctrl.io.rs2_fwd_sel_iss

  isu_ctrl.io.rs1_where_ex1 := io.rs1_where_ex1
  isu_ctrl.io.rs2_where_ex1 := io.rs2_where_ex1

  isu_ex1.io.rs1_where_ex1 := io.rs1_where_ex1
  isu_ex1.io.rs2_where_ex1 := io.rs2_where_ex1
  isu_ex1.io.rs1_val_iss := io.rs1_val_iss
  isu_ex1.io.rs2_val_iss := io.rs2_val_iss
  isu_ex1.io.ex1_reg_val := 0.U
  isu_ex1.io.ex2_reg_val := io.ex2_reg_val
  isu_ex1.io.ex3_reg_val := io.ex3_reg_val
  isu_ex1.io.ex4_reg_val := io.ex4_reg_val
  isu_ex1.io.wb_reg_val  := io.wb_reg_val
  isu_ex1.io.rs1_fwd_sel_ex1 := isu_ctrl.io.rs1_fwd_sel_ex1
  isu_ex1.io.rs2_fwd_sel_ex1 := isu_ctrl.io.rs2_fwd_sel_ex1

  io.rs1_val_ex1 := isu_ex1.io.rs1_val_ex1
  io.rs2_val_ex1 := isu_ex1.io.rs2_val_ex1

  val rs1_val_iss = isu_rf.io.rs1_val
  val rs2_val_iss = isu_rf.io.rs2_val

  val alu_din1 = (Fill(32, alu_op1(OPR_IDX_IMM )) & imm        ) |
                 (Fill(32, alu_op1(OPR_IDX_SNPC)) & snpc       ) |
                 (Fill(32, alu_op1(OPR_IDX_RS1 )) & rs1_val_iss)
  val alu_din2 = (Fill(32, alu_op2(OPR_IDX_IMM )) & imm        ) |
                 (Fill(32, alu_op2(OPR_IDX_SNPC)) & snpc       ) |
                 (Fill(32, alu_op2(OPR_IDX_PC  )) & pc         ) |
                 (Fill(32, alu_op2(OPR_IDX_RS2 )) & rs2_val_iss)

  isu_agu.io.agu_fwd_sel_iss := isu_ctrl.io.agu_fwd_sel_iss
  isu_agu.io.gpr_rs1_val   := io.gpr_rs1_val
  isu_agu.io.ex1_reg_val_q := io.ex1_reg_val_q
  isu_agu.io.ex2_reg_val_q := io.ex2_reg_val_q
  isu_agu.io.ex3_reg_val_q := io.ex3_reg_val_q
  isu_agu.io.ex4_reg_val_q := io.ex4_reg_val_q

  val agu_base = isu_agu.io.base

  val addr = agu_base + imm
  private def cacheable(addr: UInt): Bool =
    addr(31, 18) === "b1000_0000_0001_00".U(14.W)
  val addr_eff = Mux(cacheable(addr), addr + io.data_offset, addr)

  io.interlock   := isu_ctrl.io.interlock

  io.out.bits.predicted_pc    := io.in.bits.predicted_pc
  io.out.bits.predicted_taken := io.in.bits.predicted_taken
  io.out.bits.alu_ctrl        := io.in.bits.alu_ctrl
  io.out.bits.bru_ctrl        := io.in.bits.bru_ctrl
  io.out.bits.mdu_ctrl        := io.in.bits.mdu_ctrl
  io.out.bits.bit_ctrl        := io.in.bits.bit_ctrl
  io.out.bits.csr_ctrl        := io.in.bits.csr_ctrl
  io.out.bits.csr_mask        := io.in.bits.csr_mask
  io.out.bits.jump            := io.in.bits.jump
  if (CONFIG_BRANCH_RAS) {
    io.out.bits.ras_push.get := io.in.bits.ras_push.get
    io.out.bits.ras_pop.get := io.in.bits.ras_pop.get
  }
  io.out.bits.snpc            := snpc
  io.out.bits.imm             := imm
  io.out.bits.alu_din1        := alu_din1
  io.out.bits.alu_din2        := alu_din2
  io.out.bits.rs1_val         := rs1_val_iss
  io.out.bits.rs2_val         := rs2_val_iss
  io.out.bits.rs1_where_ex1   := isu_ctrl.io.nxt_rs1_where_ex1
  io.out.bits.rs2_where_ex1   := isu_ctrl.io.nxt_rs2_where_ex1
  io.out.bits.rs1_need        := io.in.bits.rs1_need
  io.out.bits.rs2_need        := io.in.bits.rs2_need
  io.out.bits.when            := io.in.bits.when
  io.out.bits.pc              := pc
  io.out.bits.rd_addr         := io.in.bits.rd_addr
  io.out.bits.rd_wen          := io.in.bits.rd_wen
  io.out.bits.addr            := addr_eff
  io.out.bits.L_sign          := io.in.bits.L_sign
  io.out.bits.mem_wen         := io.in.bits.mem_wen
  io.out.bits.mem_bytes       := io.in.bits.mem_bytes
  io.out.bits.envir           := io.in.bits.envir
}
