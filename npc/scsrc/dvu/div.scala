package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MDUParams._

class DIV extends Module {
  val io = IO(new Bundle {
    val mdu_ctrl  = Input(UInt(MDU_CTRL_WIDTH.W))
    val valid     = Input(Bool())
    val din1      = Input(UInt(32.W))
    val din2      = Input(UInt(32.W))
    val dout      = Output(UInt(32.W))
    val stall     = Output(Bool())
    val busy      = Output(Bool())
    val done      = Output(Bool())
  })

  val mdu_op_mux = io.mdu_ctrl(MDU_MUX_WIDTH  - 1, 0)
  val mdu_pos    = io.mdu_ctrl(MDU_POS_WIDTH  + MDU_MUX_WIDTH - 1, MDU_MUX_WIDTH)
  val mdu_sign   = io.mdu_ctrl(MDU_CTRL_WIDTH - 1, MDU_POS_WIDTH  + MDU_MUX_WIDTH)

  val is_div_op = mdu_op_mux === MD_DIV

  def neg32(x: UInt): UInt = (0.U(32.W) - x)(31, 0)

  val Div = Module(new Divider)
  val div_signed = mdu_sign === MD_S
  val div_din1_neg = div_signed && io.din1(31)
  val div_din2_neg = div_signed && io.din2(31)
  val div_din1 = Mux(div_din1_neg, neg32(io.din1), io.din1)
  val div_din2 = Mux(div_din2_neg, neg32(io.din2), io.din2)
  val div_by_zero = io.din2 === 0.U

  private val FixedDivLatency = CONFIG_DIV_LATENCY
  require(DIV_LATENCY == FixedDivLatency,
    s"divider controller requires a $FixedDivLatency-cycle Divider IP")

  // Counter encoding: 0 = idle, 1..34 = running, 35 = IP result valid.
  // Keep the registered completion asserted until this request leaves Ex1.
  // A one-cycle done pulse can otherwise be lost when an unrelated LSU
  // backend stall delays the completed DIV on its way to writeback.
  val div_counter = RegInit(0.U(log2Ceil(FixedDivLatency + 1).W))
  val div_idle = div_counter === 0.U
  val div_terminal = div_counter === FixedDivLatency.U
  val div_done_reg = RegInit(false.B)
  val div_busy = !div_idle
  val div_running = div_busy && !div_terminal

  val div_pos_reg = Reg(Bool())
  val div_by_zero_reg = Reg(Bool())
  val div_dividend_reg = Reg(UInt(32.W))
  val div_quotient_neg_reg = Reg(Bool())
  val div_remainder_neg_reg = Reg(Bool())
  val div_result_reg = Reg(UInt(32.W))

  val div_request = io.valid && is_div_op
  val div_request_q = RegNext(div_request, false.B)
  val div_new_request = div_request && !div_request_q
  val div_start = div_request && div_idle &&
    (!div_done_reg || div_new_request)

  Div.io.aclk := clock
  Div.io.s_axis_dividend_tdata := div_din1
  Div.io.s_axis_dividend_tvalid := div_start && !div_by_zero
  Div.io.s_axis_divisor_tdata := div_din2
  Div.io.s_axis_divisor_tvalid := div_start && !div_by_zero

  when(div_start) {
    div_counter := 1.U
    div_pos_reg := mdu_pos.asBool
    div_by_zero_reg := div_by_zero
    div_dividend_reg := io.din1
    div_quotient_neg_reg := div_signed && (io.din1(31) ^ io.din2(31)) && !div_by_zero
    div_remainder_neg_reg := div_signed && io.din1(31)
  } .elsewhen(div_running) {
    div_counter := div_counter + 1.U
  } .elsewhen(div_terminal) {
    div_counter := 0.U
  }

  when(div_start) {
    div_done_reg := false.B
  }.elsewhen(div_terminal) {
    div_done_reg := true.B
  }

  val div_quotient = Div.io.m_axis_dout_tdata(63, 32)
  val div_remainder = Div.io.m_axis_dout_tdata(31, 0)
  val div_quotient_out = Mux(div_quotient_neg_reg, neg32(div_quotient), div_quotient)
  val div_remainder_out = Mux(div_remainder_neg_reg, neg32(div_remainder), div_remainder)
  val div_normal_out = Mux(div_pos_reg, div_quotient_out, div_remainder_out)
  val div_by_zero_out = Mux(div_pos_reg, Fill(32, 1.U(1.W)), div_dividend_reg)
  val div_out = Mux(div_by_zero_reg, div_by_zero_out, div_normal_out)

  when(div_terminal) {
    div_result_reg := div_out
  }

  io.dout := div_result_reg
  io.stall := div_request && div_running
  io.busy := div_busy
  io.done := div_done_reg

  if (CONFIG_SIMULATION) {
    when(div_start && !div_by_zero) {
      assert(Div.io.s_axis_dividend_tready && Div.io.s_axis_divisor_tready,
        "fixed-latency divider must accept both operands in its idle cycle")
    }
    when(div_terminal && !div_by_zero_reg) {
      assert(Div.io.m_axis_dout_tvalid,
        "Divider IP output latency does not match the 35-cycle controller")
    }
  }
}

class Divider extends BlackBox {
  val io = IO(new Bundle {
    val aclk = Input(Clock())
    val s_axis_dividend_tdata = Input(UInt(32.W))
    val s_axis_dividend_tready = Output(Bool())
    val s_axis_dividend_tvalid = Input(Bool())
    val s_axis_divisor_tdata = Input(UInt(32.W))
    val s_axis_divisor_tready = Output(Bool())
    val s_axis_divisor_tvalid = Input(Bool())
    val m_axis_dout_tdata = Output(UInt(64.W))
    val m_axis_dout_tvalid = Output(Bool())
  })
}
