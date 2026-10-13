package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._
import MDUParams._
import OperandStats._

class WBU extends Module {
  val sim_io = IO(new Bundle {
    val pc_next = Output(UInt(PC_DATA_WIDTH.W))
  })
  val io = IO(new Bundle {
    val valid = Output(Bool())

    val in = Flipped(Decoupled(new EX_WB_Payload))

    val ex4_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))
    val mul_out = Input(UInt(MUL_OUT_WIDTH.W))
    val mulbe_out = Input(UInt(REG_DATA_WIDTH.W))
    val div_out = Input(UInt(32.W))
    val div_done = Input(Bool())
    val backend_stall = Input(Bool())
    val long_stall = Output(Bool())
    val div_stall = Output(Bool())
    val gpr = Output(new GPRWriteBackBundle)
    val rd  = Output(new ProducerBundle)
    val envir = Output(UInt(ENVIR_WIDTH.W))
  })

  val wb_in    = io.in

  io.ex4_reg_val_q := wb_in.bits.rd.data

  wb_in.ready := true.B
  val valid = wb_in.valid

  val mdu_op_mux = wb_in.bits.mdu_ctrl(MDU_MUX_WIDTH - 1, 0)
  val mdu_pos    = wb_in.bits.mdu_ctrl(MDU_POS_WIDTH  + MDU_MUX_WIDTH - 1, MDU_MUX_WIDTH)
  val isMulBe = if (CONFIG_CUSTOM_MULBE) {
    wb_in.bits.mdu_ctrl === MDU_MULBE
  } else {
    false.B
  }
  val mdu_reg_data = MuxLookup(mdu_op_mux, wb_in.bits.rd.data)(Seq(
    MD_MULT -> Mux(isMulBe, io.mulbe_out,
      Mux(mdu_pos.asBool, io.mul_out(63, 32), io.mul_out(31, 0))),
    MD_DIV  -> io.div_out
  ))

  val reg_data = mdu_reg_data
  val div_stall =
    valid && mdu_op_mux === MD_DIV && !io.div_done
  val long_stall = div_stall

  io.valid := valid && !long_stall && !io.backend_stall
  io.gpr.wen  := wb_in.bits.rd.wen
  io.gpr.addr := wb_in.bits.rd.addr
  io.gpr.data := reg_data

  io.rd.wen  := wb_in.bits.rd.wen
  io.rd.addr := wb_in.bits.rd.addr
  io.rd.when := wb_in.bits.when
  io.rd.producerType := producerType(
    wb_in.bits.mem_bytes =/= MEM_NONE && !wb_in.bits.mem_wen,
    wb_in.bits.mdu_ctrl)
  io.envir := wb_in.bits.envir
  io.long_stall := long_stall
  io.div_stall := div_stall

  sim_io.pc_next := wb_in.bits.pc_next

  if (CONFIG_SIMULATION) {
    val DPIC = Module(new WBU_DPIC)
    DPIC.io.clk   := clock
    DPIC.io.read  := io.in.valid && !io.backend_stall &&
                     !io.in.bits.mem_wen && io.in.bits.mem_bytes =/= MEM_NONE
    DPIC.io.write := io.in.valid && !io.backend_stall && io.in.bits.mem_wen
    DPIC.io.addr  := io.in.bits.addr
  }
}

class WBU_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val read = Input(Bool())
    val write = Input(Bool())
    val addr = Input(UInt(MEM_ADDR_WIDTH.W))
  })
}
