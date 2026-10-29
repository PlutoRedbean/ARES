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
import Func._
import DPUParams._

class EXU extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IS_EX_Payload))
    val out  = Decoupled(new EX_WB_Payload)
    val flush = Input(Bool())
    val load_miss_replay = Output(Bool())
    val replay_pc = Output(UInt(PC_DATA_WIDTH.W))
    val backend_stall = Output(Bool())

    val ex1_ex2_stall = Input(Bool())
    val ex2_ex3_stall = Input(Bool())
    val ex3_ex4_stall = Input(Bool())

    val ex1_ex2_bubble = Input(Bool())
    val ex2_ex3_bubble = Input(Bool())
    val ex3_ex4_bubble = Input(Bool())

    val perip = new PERIP()

    val lsu_lookup_valid = Input(Bool())
    val lsu_lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lsu_idle = Output(Bool())

    val rs1_val_iss = Output(UInt(REG_DATA_WIDTH.W))
    val rs2_val_iss = Output(UInt(REG_DATA_WIDTH.W))
    val rs1_where_ex1 = Output(UInt(WHERE_WIDTH.W))
    val rs2_where_ex1 = Output(UInt(WHERE_WIDTH.W))
    val rs1_val_ex1 = Input(UInt(REG_DATA_WIDTH.W))
    val rs2_val_ex1 = Input(UInt(REG_DATA_WIDTH.W))

    val ex1_valid = Output(Bool())
    val ex2_valid = Output(Bool())
    val ex3_valid = Output(Bool())
    val ex4_valid = Output(Bool())
    val ex1_ready = Output(Bool())
    val ex2_ready = Output(Bool())
    val ex3_ready = Output(Bool())
    val ex4_ready = Output(Bool())
    val ex1_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex1_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))

    val bpu_update_en = Output(Bool())
    val bpu_update_pc = Output(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val branch_resolve = Output(new BranchResolveBundle)
    val mul_out = Output(UInt(MUL_OUT_WIDTH.W))
    val div_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_busy = Output(Bool())
    val div_done = Output(Bool())
    val clmul_out = Output(UInt(REG_DATA_WIDTH.W))
    val clmul_busy = Output(Bool())
    val clmul_done = Output(Bool())
    val long_in_flight = Output(Bool())

    val ex1_rd = Output(new ProducerBundle)
    val ex2_rd = Output(new ProducerBundle)
    val ex3_rd = Output(new ProducerBundle)
    val ex4_rd = Output(new ProducerBundle)
  })

  io.rs1_val_iss := io.in.bits.rs1_val
  io.rs2_val_iss := io.in.bits.rs2_val
  io.rs1_where_ex1 := io.in.bits.rs1_where_ex1
  io.rs2_where_ex1 := io.in.bits.rs2_where_ex1

  val ex1_ex2_stall  = io.ex1_ex2_stall
  val ex2_ex3_stall  = io.ex2_ex3_stall
  val ex3_ex4_stall  = io.ex3_ex4_stall

  val ex1_ex2_bubble = io.ex1_ex2_bubble
  val ex2_ex3_bubble = io.ex2_ex3_bubble
  val ex3_ex4_bubble = io.ex3_ex4_bubble

  val exu_ex1 = Module(new exu_ex1)
  val exu_ex2 = Module(new exu_ex2)
  val exu_ex3 = Module(new exu_ex3)
  val exu_ex4 = Module(new exu_ex4)

  val lsu = Module(new LSU)
  lsu.io.in.valid          := exu_ex1.io.out.valid
  lsu.io.in.bits.addr      := exu_ex1.io.out.bits.addr
  lsu.io.in.bits.L_sign    := exu_ex1.io.out.bits.L_sign
  lsu.io.in.bits.mem_wdata := exu_ex1.io.out.bits.mem_wdata
  lsu.io.in.bits.mem_bytes := exu_ex1.io.out.bits.mem_bytes
  lsu.io.in.bits.mem_wen   := exu_ex1.io.out.bits.mem_wen
  lsu.io.lookup_valid      := io.lsu_lookup_valid
  lsu.io.lookup_addr       := io.lsu_lookup_addr
  lsu.io.out.ready         := exu_ex2.io.out.ready
  lsu.io.slow_ready        := exu_ex3.io.out.ready
  lsu.io.flush             := ex1_ex2_bubble
  lsu.io.stall             := ex1_ex2_stall
  lsu.io.perip             <> io.perip
  io.lsu_idle              := lsu.io.idle
  exu_ex2.io.cache_hit     := lsu.io.out.bits.cache_hit
  exu_ex2.io.rdata_fast    := lsu.io.out.bits.rdata_fast
  exu_ex3.io.rdata_slow    := lsu.io.out.bits.rdata_slow

  io.ex1_valid              := exu_ex1.io.out.valid
  io.ex2_valid              := exu_ex2.io.out.valid
  io.ex3_valid              := exu_ex3.io.out.valid
  io.ex4_valid              := exu_ex4.io.out.valid
  io.ex1_ready              := exu_ex1.io.in.ready
  io.ex2_ready              := exu_ex2.io.in.ready
  io.ex3_ready              := exu_ex3.io.in.ready
  io.ex4_ready              := exu_ex4.io.in.ready

  exu_ex1.io.in.bits        := io.in.bits
  exu_ex1.io.in.valid       := io.in.valid
  io.in.ready               := exu_ex1.io.in.ready
  exu_ex1.io.flush          := io.flush
  io.bpu_update_en          := exu_ex1.io.bpu_update_en
  io.bpu_update_pc          := exu_ex1.io.bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    io.bpu_update_ras_push.get := exu_ex1.io.bpu_update_ras_push.get
    io.bpu_update_ras_pop.get := exu_ex1.io.bpu_update_ras_pop.get
    io.bpu_update_ras_addr.get := exu_ex1.io.bpu_update_ras_addr.get
  }
  io.branch_resolve         := exu_ex1.io.branch_resolve
  io.mul_out                := exu_ex1.io.mul_out
  io.div_out                := exu_ex1.io.div_out
  io.div_busy               := exu_ex1.io.div_busy
  io.div_done               := exu_ex1.io.div_done
  io.clmul_out              := exu_ex1.io.clmul_out
  io.clmul_busy             := exu_ex1.io.clmul_busy
  io.clmul_done             := exu_ex1.io.clmul_done
  io.ex1_reg_val            := exu_ex1.io.reg_val
  io.ex1_rd.wen             := exu_ex1.io.rd.wen
  io.ex1_rd.addr            := exu_ex1.io.rd.addr
  // Loads are issued optimistically: a hit is assumed to be available for
  // Ex2 forwarding.  The registered Ex2 hit result corrects this prediction
  // by replaying the (only) younger Ex1 instruction when it consumed the
  // predicted value.  This keeps D-cache tag compare off the issue/GPR CE
  // path and adds no cycle to the hit case.
  io.ex1_rd.when            := exu_ex1.io.rd.when

  val ex2_load_miss = exu_ex2.io.in.valid &&
                      exu_ex2.io.in.bits.is_load &&
                      !lsu.io.out.bits.cache_hit
  val ex1_depends_on_ex2_load = io.in.valid && (
    (io.in.bits.rs1_where_ex1(WHR_IDX_EX2) && io.in.bits.rs1_need.orR) ||
    (io.in.bits.rs2_where_ex1(WHR_IDX_EX2) && io.in.bits.rs2_need.orR))
  io.load_miss_replay := ex2_load_miss && ex1_depends_on_ex2_load
  io.replay_pc := io.in.bits.pc

  // The LSU runs beside the Ex1 -> Ex2 pipeline register. If the peripheral
  // bridge cannot accept a request, hold Ex1 and every younger stage until the
  // same request completes its valid/ready handshake.
  val lsu_backend_stall = lsu.io.perip.valid && !lsu.io.perip.ready
  io.backend_stall := lsu_backend_stall
  pipelineConnect(
    exu_ex1.io.out,
    exu_ex2.io.in,
    ex1_ex2_stall || lsu_backend_stall,
    ex1_ex2_bubble)

  io.ex1_reg_val_q  := exu_ex2.io.in.bits.reg_data
  io.ex2_reg_val    := exu_ex2.io.reg_val
  io.ex2_rd         := exu_ex2.io.rd

  pipelineConnect(
    exu_ex2.io.out,
    exu_ex3.io.in,
    ex2_ex3_stall || lsu_backend_stall,
    ex2_ex3_bubble)

  io.ex2_reg_val_q := exu_ex3.io.in.bits.reg_data
  io.ex3_reg_val   := exu_ex3.io.reg_val
  io.ex3_rd        := exu_ex3.io.rd

  pipelineConnect(
    exu_ex3.io.out,
    exu_ex4.io.in,
    ex3_ex4_stall || lsu_backend_stall,
    ex3_ex4_bubble)

  io.ex3_reg_val_q := exu_ex4.io.in.bits.rd.data
  io.ex4_reg_val   := exu_ex4.io.reg_val
  io.ex4_rd        := exu_ex4.io.rd
  io.out.bits      := exu_ex4.io.out.bits
  io.out.valid     := exu_ex4.io.out.valid
  exu_ex4.io.out.ready := io.out.ready

  private def isLong(mdu_ctrl: UInt, bit_ctrl: UInt): Bool =
    mdu_ctrl(MDU_MUX_WIDTH - 1, 0) === MD_DIV || bit_ctrl === BIT_CLMUL

  val long_in_ex1 = exu_ex1.io.out.valid && isLong(exu_ex1.io.out.bits.mdu_ctrl, exu_ex1.io.out.bits.bit_ctrl)
  val long_in_ex2 = exu_ex2.io.out.valid && isLong(exu_ex2.io.out.bits.mdu_ctrl, exu_ex2.io.out.bits.bit_ctrl)
  val long_in_ex3 = exu_ex3.io.out.valid && isLong(exu_ex3.io.out.bits.mdu_ctrl, exu_ex3.io.out.bits.bit_ctrl)
  val long_in_ex4 = exu_ex4.io.out.valid && isLong(exu_ex4.io.out.bits.mdu_ctrl, exu_ex4.io.out.bits.bit_ctrl)

  io.long_in_flight := (io.div_busy && !io.div_done) ||
                       (io.clmul_busy && !io.clmul_done) ||
                       long_in_ex1 || long_in_ex2 || long_in_ex3 || long_in_ex4
}
