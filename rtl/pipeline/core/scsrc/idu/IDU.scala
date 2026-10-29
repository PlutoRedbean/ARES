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
import DPUParams._
import RISCV_INST._

class IDU extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IF_ID_Payload))
    val out = Decoupled(new ID_IS_Payload)

    val rs1 = Output(new ConsumerBundle)
    val rs2 = Output(new ConsumerBundle)
  })

  val id_in = io.in
  val inst = id_in.bits.inst

  val valid = id_in.valid

  id_in.ready  := io.out.ready
  io.out.valid := valid

  val opcode   = inst( 6,  0)
  val rd_addr  = inst(11,  7)
  val rs1_addr = inst(19, 15)
  val rs2_addr = inst(24, 20)

  val csr_addr = inst(31, 20)

  val imm_i = inst(31, 20)
  val imm_i_sext = Cat(Fill(20, imm_i(11)), imm_i)

  val imm_s = Cat(inst(31, 25), inst(11, 7))
  val imm_s_sext = Cat(Fill(20, imm_s(11)), imm_s)

  val imm_b = Cat(inst(31), inst(7), inst(30, 25), inst(11, 8))
  val imm_b_sext = Cat(Fill(19, imm_b(11)), imm_b, 0.U(1.W))

  val imm_j = Cat(inst(31), inst(19, 12), inst(20), inst(30, 21))
  val imm_j_sext = Cat(Fill(11, imm_j(19)), imm_j, 0.U(1.W))

  val imm_u = inst(31, 12)
  val imm_u_shifted = Cat(imm_u, Fill(12, 0.U))

  val imm_csr = inst(19, 15)
  val imm_csr_uext = Cat(Fill(27, 0.U), imm_csr)

  val jump = opcode === JAL_OPCODE || opcode === JALR_OPCODE
  val branch = opcode === BRANCH_OPCODE

  val List(base_inst_type, base_alu_operand1, base_alu_ctrl, base_alu_operand2,
           base_bru_ctrl, base_mdu_ctrl, base_rd_wen, base_mem_wen,
           base_mem_bytes, base_l_sign, base_rs1_need, base_rs2_need,
           base_when) = ListLookup(
    inst,
    List(R, OPR_NONE, ALU_DIN1, OPR_NONE, BRU_NONE, MDU_NONE, REG_READ, MEM_READ, MEM_NONE, UNSIGNED, NEED_EX4, NEED_EX4, WHEN_ABS_EX1),
    Array(
      ADD    -> List(R  , OPR_RS1 , ALU_ADD , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SUB    -> List(R  , OPR_RS1 , ALU_SUB , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      AND    -> List(R  , OPR_RS1 , ALU_AND , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      OR     -> List(R  , OPR_RS1 , ALU_OR  , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      XOR    -> List(R  , OPR_RS1 , ALU_XOR , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),

      MUL    -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_MUL   , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_EARLY),
      MULH   -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_MULH  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_EARLY),
      MULHSU -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_MULHSU, REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_EARLY),
      MULHU  -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_MULHU , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_EARLY),
      DIV    -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_DIV   , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_LATE ),
      DIVU   -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_DIVU  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_LATE ),
      REM    -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_REM   , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_LATE ),
      REMU   -> List(R  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_NONE, MDU_REMU  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_WB_LATE ),

      ADDI   -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      ANDI   -> List(I  , OPR_RS1 , ALU_AND , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      ORI    -> List(I  , OPR_RS1 , ALU_OR  , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      XORI   -> List(I  , OPR_RS1 , ALU_XOR , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),

      BEQ    -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BEQ , MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      BNE    -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BNE , MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      BLT    -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BLT , MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      BGE    -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BGE , MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      BLTU   -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BLTU, MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      BGEU   -> List(B  , OPR_RS1 , ALU_DIN1, OPR_RS2  , BRU_BGEU, MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),

      JALR   -> List(I  , OPR_RS1 , ALU_DIN2, OPR_SNPC , BRU_JALR, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      JAL    -> List(J  , OPR_SNPC, ALU_DIN1, OPR_NONE , BRU_JAL , MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),

      LB     -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_BYTE,   SIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX2     ),
      LH     -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_HALF,   SIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX2     ),
      LW     -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_WORD, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX2     ),
      LBU    -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_BYTE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX2     ),
      LHU    -> List(I  , OPR_RS1 , ALU_ADD , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_HALF, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX2     ),
      SB     -> List(S  , OPR_RS1 , ALU_ADD , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_READ , MEM_WRITE, MEM_BYTE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SH     -> List(S  , OPR_RS1 , ALU_ADD , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_READ , MEM_WRITE, MEM_HALF, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SW     -> List(S  , OPR_RS1 , ALU_ADD , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_READ , MEM_WRITE, MEM_WORD, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),

      SLL    -> List(R  , OPR_RS1 , ALU_SLL , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SRL    -> List(R  , OPR_RS1 , ALU_SRL , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SRA    -> List(R  , OPR_RS1 , ALU_SRA , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SLLI   -> List(I  , OPR_RS1 , ALU_SLL , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      SRLI   -> List(I  , OPR_RS1 , ALU_SRL , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      SRAI   -> List(I  , OPR_RS1 , ALU_SRA , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),

      SLT    -> List(R  , OPR_RS1 , ALU_SLT , OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SLTU   -> List(R  , OPR_RS1 , ALU_SLTU, OPR_RS2  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_ISS_LATE , WHEN_ABS_EX1     ),
      SLTI   -> List(I  , OPR_RS1 , ALU_SLT , OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      SLTIU  -> List(I  , OPR_RS1 , ALU_SLTU, OPR_IMM  , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),

      CSRRW  -> List(CSR, OPR_RS1 , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      CSRRS  -> List(CSR, OPR_RS1 , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      CSRRC  -> List(CSR, OPR_RS1 , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_ISS_LATE , NEED_EX4      , WHEN_ABS_EX1     ),
      CSRRWI -> List(CSR, OPR_IMM , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),
      CSRRSI -> List(CSR, OPR_IMM , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),
      CSRRCI -> List(CSR, OPR_IMM , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),

      ECALL  -> List(R  , OPR_NONE, ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),
      MRET   -> List(R  , OPR_NONE, ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_READ , MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),

      AUIPC  -> List(U  , OPR_IMM , ALU_ADD , OPR_PC   , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     ),
      LUI    -> List(U  , OPR_IMM , ALU_DIN1, OPR_NONE , BRU_NONE, MDU_NONE  , REG_WRITE, MEM_READ , MEM_NONE, UNSIGNED, NEED_EX4      , NEED_EX4      , WHEN_ABS_EX1     )
    ),
  )

  var bitCtrlCases = Seq.empty[(Bool, UInt)]
  if (CONFIG_RV32_ZBB_CLZ)     bitCtrlCases :+= ((inst === CLZ)    -> BIT_CLZ)
  if (CONFIG_RV32_ZBB_CTZ)     bitCtrlCases :+= ((inst === CTZ)    -> BIT_CTZ)
  if (CONFIG_RV32_ZBB_CPOP)    bitCtrlCases :+= ((inst === CPOP)   -> BIT_CPOP)
  if (CONFIG_RV32_ZBB_ORC_B)   bitCtrlCases :+= ((inst === ORC_B)  -> BIT_ORC_B)
  if (CONFIG_RV32_ZBKX_XPERM4) bitCtrlCases :+= ((inst === XPERM4) -> BIT_XPERM4)
  if (CONFIG_RV32_ZBB_ROR)     bitCtrlCases :+= ((inst === ROR)    -> BIT_ROR)
  if (CONFIG_RV32_ZBC_CLMUL)   bitCtrlCases :+= ((inst === CLMUL)  -> BIT_CLMUL)
  if (CONFIG_RV32_ZBB_ZEXT_H)  bitCtrlCases :+= ((inst === ZEXT_H) -> BIT_ZEXT_H)

  val bit_ctrl = MuxCase(BIT_NONE, bitCtrlCases)
  val is_bit_inst = bit_ctrl =/= BIT_NONE
  val is_bit_binary = bit_ctrl === BIT_XPERM4 || bit_ctrl === BIT_ROR || bit_ctrl === BIT_CLMUL

  val inst_type    = Mux(is_bit_inst, R,             base_inst_type)
  val alu_operand1 = Mux(is_bit_inst, OPR_RS1,       base_alu_operand1)
  val alu_ctrl     = Mux(is_bit_inst, ALU_DIN1,      base_alu_ctrl)
  val alu_operand2 = Mux(is_bit_inst,
                         Mux(is_bit_binary, OPR_RS2, OPR_NONE), base_alu_operand2)
  val bru_ctrl     = Mux(is_bit_inst, BRU_NONE,       base_bru_ctrl)
  val mdu_ctrl     = Mux(is_bit_inst, MDU_NONE,       base_mdu_ctrl)
  val rd_wen       = Mux(is_bit_inst, REG_WRITE,      base_rd_wen)
  val mem_wen      = Mux(is_bit_inst, MEM_READ,       base_mem_wen)
  val mem_bytes    = Mux(is_bit_inst, MEM_NONE,       base_mem_bytes)
  val l_sign       = Mux(is_bit_inst, UNSIGNED,       base_l_sign)
  val rs1_need     = Mux(is_bit_inst, NEED_ISS_LATE,  base_rs1_need)
  val rs2_need     = Mux(is_bit_inst,
                         Mux(is_bit_binary, NEED_ISS_LATE, NEED_EX4), base_rs2_need)
  val bit_when = Mux(bit_ctrl === BIT_ORC_B || bit_ctrl === BIT_ZEXT_H, WHEN_ABS_EX1,
                   Mux(bit_ctrl === BIT_CLMUL, WHEN_ABS_WB_LATE, WHEN_ABS_EX2))
  val when = Mux(is_bit_inst, bit_when, base_when)

  val imm = MuxLookup(inst_type, 0.U(32.W))(Seq(
    I   -> imm_i_sext,
    S   -> imm_s_sext,
    B   -> imm_b_sext,
    U   -> imm_u_shifted,
    J   -> imm_j_sext,
    CSR -> imm_csr_uext
  ))

  val csr_ctrl = Mux(inst_type =/= CSR, CSR_NONE, inst(14, 12))

  val csr_mask = MuxLookup(csr_addr, CSR_MASK_NONE)(CSR_DECODE_TABLE)

  val is_ecall = inst === ECALL
  val is_ebreak = inst === EBREAK
  val is_mret = inst === MRET
  // FENCE/FENCE.I are decoded as a pipeline barrier.  They do not write a
  // register or access memory; Mundus stalls them until the LSU/peripheral
  // side is idle before allowing them to issue.
  val is_fence = (opcode === "b0001111".U) &&
                 (inst(14, 12) === 0.U || inst(14, 12) === 1.U)
  val is_envir = is_ecall || is_ebreak || is_mret
  val envir = MuxCase(ENVIR_NORMAL, Seq(
    is_ecall   -> ENVIR_ECALL,
    is_ebreak  -> ENVIR_EBREAK,
    is_mret    -> ENVIR_MRET,
    is_fence   -> ENVIR_FENCE
  ))

  io.rs1.ren  := alu_operand1 === OPR_RS1
  io.rs1.addr := rs1_addr
  io.rs1.need := rs1_need
  io.rs2.ren  := alu_operand2 === OPR_RS2
  io.rs2.addr := rs2_addr
  io.rs2.need := rs2_need

  io.out.bits.predicted_pc    := id_in.bits.predicted_pc
  io.out.bits.predicted_taken := id_in.bits.predicted_taken
  io.out.bits.jump         := jump
  if (CONFIG_BRANCH_RAS) {
    // RISC-V RAS hints (x1=ra, x5=alternate link register).  A coroutine
    // JALR with different link registers performs pop then push.
    val isJal = opcode === JAL_OPCODE
    val isJalr = opcode === JALR_OPCODE
    val rdIsLink = rd_addr === 1.U || rd_addr === 5.U
    val rs1IsLink = rs1_addr === 1.U || rs1_addr === 5.U
    io.out.bits.ras_push.get := (isJal || isJalr) && rdIsLink
    io.out.bits.ras_pop.get :=
      isJalr && rs1IsLink && (!rdIsLink || rd_addr =/= rs1_addr)
  }
  io.out.bits.snpc         := id_in.bits.snpc
  io.out.bits.ALU_operand1 := alu_operand1
  io.out.bits.ALU_operand2 := alu_operand2
  io.out.bits.imm          := imm
  io.out.bits.rs1_addr     := rs1_addr
  io.out.bits.rs2_addr     := rs2_addr
  io.out.bits.rs1_need     := rs1_need
  io.out.bits.rs2_need     := rs2_need
  io.out.bits.when         := when

  io.out.bits.pc           := id_in.bits.pc
  io.out.bits.rd_addr      := rd_addr
  io.out.bits.rd_wen       := rd_wen
  io.out.bits.alu_ctrl     := alu_ctrl
  io.out.bits.bru_ctrl     := bru_ctrl
  io.out.bits.mdu_ctrl     := mdu_ctrl
  io.out.bits.bit_ctrl     := bit_ctrl
  io.out.bits.csr_ctrl     := csr_ctrl
  io.out.bits.csr_mask     := csr_mask
  io.out.bits.L_sign       := l_sign
  io.out.bits.mem_wen      := mem_wen
  io.out.bits.mem_bytes    := mem_bytes
  io.out.bits.envir        := envir
}
