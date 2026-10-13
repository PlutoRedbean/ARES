package npc
import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

// Configuration object containing constants from .vh files
object MundusConfig {
  val ALU_CTRL_WIDTH = 13
  val OPR_CTRL_WIDTH = 6
  val BRU_INST_WIDTH = 6
  val BRU_MUX_WIDTH  = 3
  val BRU_CTRL_WIDTH = BRU_INST_WIDTH + BRU_MUX_WIDTH
  val MDU_MUX_WIDTH  = 2
  val MDU_POS_WIDTH  = 1
  val MDU_SIGN_WIDTH = 2
  val MDU_CTRL_WIDTH = MDU_SIGN_WIDTH + MDU_POS_WIDTH + MDU_MUX_WIDTH
  val ISU_FWD_SEL_WIDTH = 6
  val AGU_FWD_SEL_WIDTH = 5

  val NEED_WHEN_WIDTH = 5
  val WHERE_WIDTH     = 6
  val ADDR_CMP_WIDTH = WHERE_WIDTH - 2  // 除去 ISS 和 WB
  
  val CSR_CTRL_WIDTH = 2
  val CSR_IMM_WIDTH  = 1
  val CSR_CMD_WIDTH  = CSR_CTRL_WIDTH + CSR_IMM_WIDTH
  val CSR_ADDR_WIDTH = 12
  val CSR_MASK_WIDTH = 10

  val GPR_ADDR_WIDTH = if (CONFIG_RVE) 4 else 5
  val REG_DATA_WIDTH  = 32
  val MEM_ADDR_WIDTH  = 32
  val MEM_DATA_WIDTH  = 32
  val PC_DATA_WIDTH   = 32
  val ISA_SHAMT_WIDTH =  5
  val ENVIR_WIDTH     =  3
}

object MundusParams {
  val OPR_NONE  = "b000001".U(OPR_CTRL_WIDTH.W)
  val OPR_IMM   = "b000010".U(OPR_CTRL_WIDTH.W)
  val OPR_RS1   = "b000100".U(OPR_CTRL_WIDTH.W)
  val OPR_RS2   = "b001000".U(OPR_CTRL_WIDTH.W)
  val OPR_PC    = "b010000".U(OPR_CTRL_WIDTH.W)
  val OPR_SNPC  = "b100000".U(OPR_CTRL_WIDTH.W)

  val OPR_IDX_NONE  = 0
  val OPR_IDX_IMM   = 1
  val OPR_IDX_RS1   = 2
  val OPR_IDX_RS2   = 3
  val OPR_IDX_PC    = 4
  val OPR_IDX_SNPC  = 5
  
  val ISU_FWD_NONE      = "b000001".U(ISU_FWD_SEL_WIDTH.W)
  val ISU_FWD_EX1       = "b000010".U(ISU_FWD_SEL_WIDTH.W)
  val ISU_FWD_EX2       = "b000100".U(ISU_FWD_SEL_WIDTH.W)
  val ISU_FWD_EX3       = "b001000".U(ISU_FWD_SEL_WIDTH.W)
  val ISU_FWD_EX4       = "b010000".U(ISU_FWD_SEL_WIDTH.W)
  val ISU_FWD_WB        = "b100000".U(ISU_FWD_SEL_WIDTH.W)
  
  val ISU_FWD_IDX_NONE  = 0
  val ISU_FWD_IDX_EX1   = 1
  val ISU_FWD_IDX_EX2   = 2
  val ISU_FWD_IDX_EX3   = 3
  val ISU_FWD_IDX_EX4   = 4
  val ISU_FWD_IDX_WB    = 5

  // AGU base forwarding is one-hot and ordered from youngest to oldest.
  val AGU_FWD_EX1_Q = "b10000".U(AGU_FWD_SEL_WIDTH.W)
  val AGU_FWD_EX2_Q = "b01000".U(AGU_FWD_SEL_WIDTH.W)
  val AGU_FWD_EX3_Q = "b00100".U(AGU_FWD_SEL_WIDTH.W)
  val AGU_FWD_EX4_Q = "b00010".U(AGU_FWD_SEL_WIDTH.W)
  val AGU_FWD_NONE  = "b00001".U(AGU_FWD_SEL_WIDTH.W)

  val ENVIR_NORMAL : UInt = 0.U(ENVIR_WIDTH.W)
  val ENVIR_ECALL  : UInt = 1.U(ENVIR_WIDTH.W)
  val ENVIR_EBREAK : UInt = 2.U(ENVIR_WIDTH.W)
  val ENVIR_MRET   : UInt = 3.U(ENVIR_WIDTH.W)
  val ENVIR_FENCE_I: UInt = 4.U(ENVIR_WIDTH.W)

  val BP_ALWAYS_NOT_TAKEN = 0
  val BP_BIMODAL          = 1
  val BP_TAGE             = 2
}

object TageParams {
  val HistoryBits = 64
  val ProviderBits = 3
  val LoopMetaBits = if (AutoConfig.CONFIG_BRANCH_LOOP_PREDICTOR) 3 else 0
  val MetaWidth = HistoryBits +
    4 * AutoConfig.CONFIG_BRANCH_TAGE_INDEX_BITS +
    4 * AutoConfig.CONFIG_BRANCH_TAGE_TAG_BITS +
    ProviderBits + 3 + LoopMetaBits
}

object DPUParams {
  val NEED_ISS_EARLY      = "b11111".U(NEED_WHEN_WIDTH.W);
  val NEED_ISS_LATE       = "b11110".U(NEED_WHEN_WIDTH.W);
  val NEED_EX1            = "b11100".U(NEED_WHEN_WIDTH.W);
  val NEED_EX2            = "b11000".U(NEED_WHEN_WIDTH.W);
  val NEED_EX3            = "b10000".U(NEED_WHEN_WIDTH.W);
  val NEED_EX4            = "b00000".U(NEED_WHEN_WIDTH.W); // store inst

  // rx_when_iss          =>  00000 Available now (early)
  //                          00001 Available now (late)
  //                          00011 Available when I'm in Ex1
  //                          00111 Available when I'm in Ex2
  //                          01111 Available when I'm in Ex3
  //                          11111 Available when I'm in Ex4
  val WHEN_REL_ISS_EARLY  = "b00000".U(NEED_WHEN_WIDTH.W);
  val WHEN_REL_ISS_LATE   = "b00001".U(NEED_WHEN_WIDTH.W);
  val WHEN_REL_EX1        = "b00011".U(NEED_WHEN_WIDTH.W);
  val WHEN_REL_EX2        = "b00111".U(NEED_WHEN_WIDTH.W);
  val WHEN_REL_EX3        = "b01111".U(NEED_WHEN_WIDTH.W);
  val WHEN_REL_EX4        = "b11111".U(NEED_WHEN_WIDTH.W);

  val WHEN_ABS_EX1        = "b00000".U(NEED_WHEN_WIDTH.W);
  val WHEN_ABS_EX2        = "b00001".U(NEED_WHEN_WIDTH.W);
  val WHEN_ABS_EX3        = "b00011".U(NEED_WHEN_WIDTH.W);
  val WHEN_ABS_EX4        = "b00111".U(NEED_WHEN_WIDTH.W);
  val WHEN_ABS_WB_EARLY   = "b01111".U(NEED_WHEN_WIDTH.W);
  val WHEN_ABS_WB_LATE    = "b11111".U(NEED_WHEN_WIDTH.W);  // div inst

  // where_iss = [iss, ex1, ex2, ex3, ex4, wb]
  val WHR_IDX_ISS   = 5
  val WHR_IDX_EX1   = 4
  val WHR_IDX_EX2   = 3
  val WHR_IDX_EX3   = 2
  val WHR_IDX_EX4   = 1
  val WHR_IDX_WB    = 0

  // WHN_IDX_XXX representing whether data is NOT ready by XXX
  val WHN_IDX_EX1    = 0
  val WHN_IDX_EX2    = 1
  val WHN_IDX_EX3    = 2
  val WHN_IDX_EX4    = 3
  val WHN_IDX_WB     = 4
}

object MDUParams {
  // for MDU
  val MUL_OUT_WIDTH = 64;
  
  val MD_MUX_NONE = "b00".U(MDU_MUX_WIDTH.W)
  val MD_MULT     = "b01".U(MDU_MUX_WIDTH.W)
  val MD_DIV      = "b10".U(MDU_MUX_WIDTH.W)

  val MD_LOW  = "b0".U(MDU_POS_WIDTH.W)
  val MD_HIGH = "b1".U(MDU_POS_WIDTH.W)

  val MD_S  = "b11".U(MDU_SIGN_WIDTH.W)
  val MD_SU = "b10".U(MDU_SIGN_WIDTH.W)
  // The remaining sign encoding tags the CoreMark matrix bit-extract mode.
  // MULBE still uses the regular low multiply datapath; WB post-processes
  // product bits [11:2], so signedness cannot affect its result.
  val MD_BE = "b01".U(MDU_SIGN_WIDTH.W)
  val MD_U  = "b00".U(MDU_SIGN_WIDTH.W)

  val MUL_LATENCY = CONFIG_MUL_LATENCY
  val DIV_LATENCY = CONFIG_DIV_LATENCY

  // for IDU
  def MDU_NONE   = Cat(MD_U , MD_LOW , MD_MUX_NONE)
  def MDU_MUL    = Cat(MD_U , MD_LOW , MD_MULT    )
  def MDU_MULH   = Cat(MD_S , MD_HIGH, MD_MULT    )
  def MDU_MULHSU = Cat(MD_SU, MD_HIGH, MD_MULT    )
  def MDU_MULHU  = Cat(MD_U , MD_HIGH, MD_MULT    )
  def MDU_MULBE  = Cat(MD_BE, MD_LOW , MD_MULT    )
  def MDU_DIV    = Cat(MD_S , MD_HIGH, MD_DIV     )
  def MDU_DIVU   = Cat(MD_U , MD_HIGH, MD_DIV     )
  def MDU_REM    = Cat(MD_S , MD_LOW , MD_DIV     )
  def MDU_REMU   = Cat(MD_U , MD_LOW , MD_DIV     )
}

object BRUParams {
  // for BRU
  val BR_MUX_NONE = "b000".U(BRU_MUX_WIDTH.W)
  val BR_BRANCH   = "b001".U(BRU_MUX_WIDTH.W)
  val BR_JAL      = "b010".U(BRU_MUX_WIDTH.W)
  val BR_JALR     = "b100".U(BRU_MUX_WIDTH.W)

  val BR_INST_NONE = "b000000".U(BRU_INST_WIDTH.W)
  val BR_BEQ       = "b000001".U(BRU_INST_WIDTH.W)
  val BR_BNE       = "b000010".U(BRU_INST_WIDTH.W)
  val BR_BLT       = "b000100".U(BRU_INST_WIDTH.W)
  val BR_BLTU      = "b001000".U(BRU_INST_WIDTH.W)
  val BR_BGE       = "b010000".U(BRU_INST_WIDTH.W)
  val BR_BGEU      = "b100000".U(BRU_INST_WIDTH.W)

  // for IDU
  def BRU_NONE  = Cat(BR_INST_NONE, BR_MUX_NONE)
  def BRU_BEQ   = Cat(BR_BEQ      , BR_BRANCH  )
  def BRU_BNE   = Cat(BR_BNE      , BR_BRANCH  )
  def BRU_BLT   = Cat(BR_BLT      , BR_BRANCH  )
  def BRU_BLTU  = Cat(BR_BLTU     , BR_BRANCH  )
  def BRU_BGE   = Cat(BR_BGE      , BR_BRANCH  )
  def BRU_BGEU  = Cat(BR_BGEU     , BR_BRANCH  )
  def BRU_JAL   = Cat(BR_INST_NONE, BR_JAL     )
  def BRU_JALR  = Cat(BR_INST_NONE, BR_JALR    )
}

object ALUParams {
  val REG_READ  = 0.U(1.W)
  val REG_WRITE = 1.U(1.W)

  val MEM_READ  = 0.U(1.W)
  val MEM_WRITE = 1.U(1.W)
  
  val MEM_NONE = "b11".U(2.W)
  val MEM_BYTE = "b00".U(2.W)
  val MEM_HALF = "b01".U(2.W)
  val MEM_WORD = "b10".U(2.W)

  val UNSIGNED = 0.U(1.W)
  val   SIGNED = 1.U(1.W)
  
  val ALU_DIN1 =  "b000000000001".U(ALU_CTRL_WIDTH.W)
  val ALU_DIN2 =  "b000000000010".U(ALU_CTRL_WIDTH.W)
  val ALU_ADD  =  "b000000000100".U(ALU_CTRL_WIDTH.W)
  val ALU_SUB  =  "b000000001000".U(ALU_CTRL_WIDTH.W)
  val ALU_XOR  =  "b000000010000".U(ALU_CTRL_WIDTH.W)
  val ALU_OR   =  "b000000100000".U(ALU_CTRL_WIDTH.W)
  val ALU_AND  =  "b000001000000".U(ALU_CTRL_WIDTH.W)
  val ALU_SLL  =  "b000010000000".U(ALU_CTRL_WIDTH.W)
  val ALU_SRL  =  "b000100000000".U(ALU_CTRL_WIDTH.W)
  val ALU_SRA  =  "b001000000000".U(ALU_CTRL_WIDTH.W)
  val ALU_SLT  =  "b010000000000".U(ALU_CTRL_WIDTH.W)
  val ALU_SLTU =  "b100000000000".U(ALU_CTRL_WIDTH.W)
  val ALU_CRC16 = "b1000000000000".U(ALU_CTRL_WIDTH.W)

  val ALU_IDX_DIN1 =  0
  val ALU_IDX_DIN2 =  1
  val ALU_IDX_ADD  =  2
  val ALU_IDX_SUB  =  3
  val ALU_IDX_XOR  =  4
  val ALU_IDX_OR   =  5
  val ALU_IDX_AND  =  6
  val ALU_IDX_SLL  =  7
  val ALU_IDX_SRL  =  8
  val ALU_IDX_SRA  =  9
  val ALU_IDX_SLT  =  10
  val ALU_IDX_SLTU =  11
  val ALU_IDX_CRC16 = 12
}

object DeviceParams {
  val MASTER_NUM: Int = 2
  val SLAVE_NUM : Int = 1

  val M_IFU  : Int = 0
  val M_LSU  : Int = 1
  val S_CLINT: Int = 0

  val CLINT_ADDR       = CONFIG_CLINT_BASE
  val CLINT_LOWER_ADDR = CONFIG_CLINT_BASE + 0x0
  val CLINT_UPPER_ADDR = CONFIG_CLINT_BASE + 0x4
  val CLINT_SIZE       = CONFIG_CLINT_SIZE
}

object AxiParams {
  val AXI_DATA_WIDTH: Int = MEM_DATA_WIDTH
  val AXI_ADDR_WIDTH: Int = MEM_ADDR_WIDTH
  val AXI_STRB_WIDTH: Int = 4
  val AXI_RESP_WIDTH: Int = 2

  val AXI_OKAY  : UInt = "b00".U(2.W)
  val AXI_EXOKAY: UInt = "b01".U(2.W)
  val AXI_SLVERR: UInt = "b10".U(2.W)
  val AXI_DECERR: UInt = "b11".U(2.W)

  val AXI_FIXED   : UInt = "b00".U(2.W)
  val AXI_INCR    : UInt = "b01".U(2.W)
  val AXI_WRAP    : UInt = "b10".U(2.W)
  val AXI_RESERVED: UInt = "b11".U(2.W)
}

object RISCV_INST {
  
  val INSTS_NUM = 45

// inst types define
  val R  : UInt = 0.U(3.W)
  val I  : UInt = 1.U(3.W)
  val S  : UInt = 2.U(3.W)
  val B  : UInt = 3.U(3.W)
  val U  : UInt = 4.U(3.W)
  val J  : UInt = 5.U(3.W)
  val CSR: UInt = 6.U(3.W)

  val JAL_OPCODE    = "b1101111".U(7.W)
  val JALR_OPCODE   = "b1100111".U(7.W)
  val BRANCH_OPCODE = "b1100011".U(7.W)

// instructions define
  val ADD    = BitPat("b0000000_?????_?????_000_?????_0110011")
  val SUB    = BitPat("b0100000_?????_?????_000_?????_0110011")
  val AND    = BitPat("b0000000_?????_?????_111_?????_0110011")
  val OR     = BitPat("b0000000_?????_?????_110_?????_0110011")
  val XOR    = BitPat("b0000000_?????_?????_100_?????_0110011")
  // Mundus custom-0 instruction: rd = CoreMark CRC16(rs1[15:0], rs2[15:0]).
  val CRC16  = BitPat("b0000000_?????_?????_000_?????_0001011")
  // rd = (((rs1 * rs2) >> 2) & 0xf) *
  //      (((rs1 * rs2) >> 5) & 0x7f), using product low bits.
  val MULBE  = BitPat("b0000001_?????_?????_000_?????_0001011")

  val MUL    = BitPat("b0000001_?????_?????_000_?????_0110011")
  val MULH   = BitPat("b0000001_?????_?????_001_?????_0110011")
  val MULHU  = BitPat("b0000001_?????_?????_011_?????_0110011")
  val MULHSU = BitPat("b0000001_?????_?????_010_?????_0110011")
  val DIV    = BitPat("b0000001_?????_?????_100_?????_0110011")
  val DIVU   = BitPat("b0000001_?????_?????_101_?????_0110011")
  val REM    = BitPat("b0000001_?????_?????_110_?????_0110011")
  val REMU   = BitPat("b0000001_?????_?????_111_?????_0110011")

  val ADDI   = BitPat("b???????_?????_?????_000_?????_0010011")
  val ANDI   = BitPat("b???????_?????_?????_111_?????_0010011")
  val ORI    = BitPat("b???????_?????_?????_110_?????_0010011")
  val XORI   = BitPat("b???????_?????_?????_100_?????_0010011")

  val BEQ    = BitPat("b???????_?????_?????_000_?????_1100011")
  val BNE    = BitPat("b???????_?????_?????_001_?????_1100011")
  val BLT    = BitPat("b???????_?????_?????_100_?????_1100011")
  val BGE    = BitPat("b???????_?????_?????_101_?????_1100011")
  val BLTU   = BitPat("b???????_?????_?????_110_?????_1100011")
  val BGEU   = BitPat("b???????_?????_?????_111_?????_1100011")

  val JAL    = BitPat("b???????_?????_?????_???_?????_1101111")
  val JALR   = BitPat("b???????_?????_?????_000_?????_1100111")

  val LB     = BitPat("b???????_?????_?????_000_?????_0000011")
  val LH     = BitPat("b???????_?????_?????_001_?????_0000011")
  val LW     = BitPat("b???????_?????_?????_010_?????_0000011")
  val LBU    = BitPat("b???????_?????_?????_100_?????_0000011")
  val LHU    = BitPat("b???????_?????_?????_101_?????_0000011")
  val SB     = BitPat("b???????_?????_?????_000_?????_0100011")
  val SH     = BitPat("b???????_?????_?????_001_?????_0100011")
  val SW     = BitPat("b???????_?????_?????_010_?????_0100011")

  val SLL    = BitPat("b0000000_?????_?????_001_?????_0110011")
  val SRL    = BitPat("b0000000_?????_?????_101_?????_0110011")
  val SRA    = BitPat("b0100000_?????_?????_101_?????_0110011")
  val SLLI   = BitPat("b0000000_?????_?????_001_?????_0010011")
  val SRLI   = BitPat("b0000000_?????_?????_101_?????_0010011")
  val SRAI   = BitPat("b0100000_?????_?????_101_?????_0010011")

  val SLT    = BitPat("b0000000_?????_?????_010_?????_0110011")
  val SLTU   = BitPat("b0000000_?????_?????_011_?????_0110011")
  val SLTI   = BitPat("b???????_?????_?????_010_?????_0010011")
  val SLTIU  = BitPat("b???????_?????_?????_011_?????_0010011")

  val AUIPC  = BitPat("b???????_?????_?????_???_?????_0010111")
  val LUI    = BitPat("b???????_?????_?????_???_?????_0110111")

  val CSRRW  = BitPat("b???????_?????_?????_001_?????_1110011")
  val CSRRS  = BitPat("b???????_?????_?????_010_?????_1110011")
  val CSRRC  = BitPat("b???????_?????_?????_011_?????_1110011")
  val CSRRWI = BitPat("b???????_?????_?????_101_?????_1110011")
  val CSRRSI = BitPat("b???????_?????_?????_110_?????_1110011")
  val CSRRCI = BitPat("b???????_?????_?????_111_?????_1110011")
  val MRET   = BitPat("b0011000_00010_00000_000_00000_1110011")
  val ECALL  = BitPat("b0000000_00000_00000_000_00000_1110011")

// environment instructions define
  val NOP    : UInt = "b00000000000000000000000000010011".U(32.W)
  val EBREAK : UInt = "b00000000000100000000000001110011".U(32.W)
  val FENCE_I: UInt = "b00000000000000000001000000001111".U(32.W)

// CSR_addr define
  val MEPC_ADDR     : UInt = 0x341.U(12.W)
  val MTVEC_ADDR    : UInt = 0x305.U(12.W)
  val MCAUSE_ADDR   : UInt = 0x342.U(12.W)
  val MSTATUS_ADDR  : UInt = 0x300.U(12.W)
  val MIE_ADDR      : UInt = 0x304.U(12.W)
  val MIP_ADDR      : UInt = 0x344.U(12.W)
  val MSCRATCH_ADDR : UInt = 0x340.U(12.W)
  val MISA_ADDR     : UInt = 0x301.U(12.W)
  val MCYCLE_ADDR   : UInt = 0xb00.U(12.W)
  val MCYCLEH_ADDR  : UInt = 0xb80.U(12.W)
  val MVENDORID_ADDR: UInt = 0xf11.U(12.W)
  val MARCHID_ADDR  : UInt = 0xf12.U(12.W)
}

object CSRParams {
  case class CsrSpec(name: String, addr: UInt, mask: UInt, init: BigInt, enabled: Boolean = true)

  val CSR_NAME_MSTATUS  = "mstatus"
  val CSR_NAME_MIE      = "mie"
  val CSR_NAME_MIP      = "mip"
  val CSR_NAME_MEPC     = "mepc"
  val CSR_NAME_MTVEC    = "mtvec"
  val CSR_NAME_MCAUSE   = "mcause"
  val CSR_NAME_MSCRATCH = "mscratch"
  val CSR_NAME_MISA     = "misa"
  val CSR_NAME_MCYCLE   = "mcycle"
  val CSR_NAME_MCYCLEH  = "mcycleh"

  val CSR_NONE = 0.U(CSR_CMD_WIDTH.W)
  val CSR_RW   = 1.U(CSR_CTRL_WIDTH.W)
  val CSR_RS   = 2.U(CSR_CTRL_WIDTH.W)
  val CSR_RC   = 3.U(CSR_CTRL_WIDTH.W)

  val CSR_MASK_NONE     = "b0000000000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MSTATUS  = "b0000000001".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MEPC     = "b0000000010".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MTVEC    = "b0000000100".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MCAUSE   = "b0000001000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MSCRATCH = "b0000010000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MISA     = "b0000100000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MIE      = "b0001000000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MIP      = "b0010000000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MCYCLE   = "b0100000000".U(CSR_MASK_WIDTH.W)
  val CSR_MASK_MCYCLEH  = "b1000000000".U(CSR_MASK_WIDTH.W)

  val CSR_SPECS: Seq[CsrSpec] = Seq(
    CsrSpec(CSR_NAME_MSTATUS,  RISCV_INST.MSTATUS_ADDR,  CSR_MASK_MSTATUS,  BigInt(0x00001800)),
    CsrSpec(CSR_NAME_MIE,      RISCV_INST.MIE_ADDR,      CSR_MASK_MIE,      BigInt(0), enabled = CONFIG_HAS_CSR_MIE),
    CsrSpec(CSR_NAME_MIP,      RISCV_INST.MIP_ADDR,      CSR_MASK_MIP,      BigInt(0), enabled = CONFIG_HAS_CSR_MIP),
    CsrSpec(CSR_NAME_MEPC,     RISCV_INST.MEPC_ADDR,     CSR_MASK_MEPC,     BigInt(0)),
    CsrSpec(CSR_NAME_MTVEC,    RISCV_INST.MTVEC_ADDR,    CSR_MASK_MTVEC,    BigInt(0)),
    CsrSpec(CSR_NAME_MCAUSE,   RISCV_INST.MCAUSE_ADDR,   CSR_MASK_MCAUSE,   BigInt(0)),
    CsrSpec(CSR_NAME_MSCRATCH, RISCV_INST.MSCRATCH_ADDR, CSR_MASK_MSCRATCH, BigInt(0), enabled = CONFIG_HAS_CSR_MSCRATCH),
    CsrSpec(CSR_NAME_MISA,     RISCV_INST.MISA_ADDR,     CSR_MASK_MISA,     BigInt(0x40001100), enabled = CONFIG_HAS_CSR_MISA),
    CsrSpec(CSR_NAME_MCYCLE,   RISCV_INST.MCYCLE_ADDR,   CSR_MASK_MCYCLE,   BigInt(0), enabled = CONFIG_HAS_CSR_MCYCLE),
    CsrSpec(CSR_NAME_MCYCLEH,  RISCV_INST.MCYCLEH_ADDR,  CSR_MASK_MCYCLEH,  BigInt(0), enabled = CONFIG_HAS_CSR_MCYCLE)
  )

  val CSR_ENABLED_SPECS: Seq[CsrSpec] = CSR_SPECS.filter(_.enabled)
  val CSR_DECODE_TABLE: Seq[(UInt, UInt)] = CSR_ENABLED_SPECS.map(spec => spec.addr -> spec.mask)
}
