package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import MDUParams._
import Func._
import OperandStats._

class GroupWBU extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new EX_WB_Group))

    val mul_out = Input(UInt(MUL_OUT_WIDTH.W))
    val mulbe_out = Input(UInt(REG_DATA_WIDTH.W))
    val side_mul_out = Input(UInt(MUL_OUT_WIDTH.W))
    val side_mulbe_out = Input(UInt(REG_DATA_WIDTH.W))
    val div_out = Input(UInt(REG_DATA_WIDTH.W))
    val div_done = Input(Bool())
    val backend_stall = Input(Bool())

    val valid = Output(Bool())
    val retireMask = Output(UInt(DualIssue.Width.W))
    val gprWriteMask = Output(UInt(DualIssue.Width.W))
    val long_stall = Output(Bool())
    val div_stall = Output(Bool())
    val gpr = Output(Vec(DualIssue.Width, new GPRWriteBackBundle))
    val producer = Output(new ForwardProducerGroup)
    val pc =
      Output(Vec(DualIssue.Width, UInt(PC_DATA_WIDTH.W)))
    val pcNext =
      Output(Vec(DualIssue.Width, UInt(PC_DATA_WIDTH.W)))
    val envir =
      Output(Vec(DualIssue.Width, UInt(ENVIR_WIDTH.W)))
  })

  val lane0 = Module(new WBU)
  lane0.io.in.valid := io.in.valid && io.in.bits.laneValid(0)
  lane0.io.in.bits := io.in.bits.lane(0)
  io.in.ready := lane0.io.in.ready

  lane0.io.mul_out := io.mul_out
  lane0.io.mulbe_out := io.mulbe_out
  lane0.io.div_out := io.div_out
  lane0.io.div_done := io.div_done
  lane0.io.backend_stall := io.backend_stall

  val rawRetireMask =
    Mux(lane0.io.valid, io.in.bits.laneValid, 0.U)
  // Forwarding readiness is a property of the registered WB payload, not of
  // retirement.  A downstream stall must hold architectural side effects,
  // but it must not make an already-computed value disappear from bypass.
  val rawProducerMask =
    Mux(io.in.valid && !lane0.io.long_stall,
      io.in.bits.laneValid, 0.U)
  // System redirects are currently single-issued, but keep the commit rule
  // explicit: an older exception/return can retire while no younger slot-1
  // architectural state is allowed to escape.
  val slot0KillsSlot1 =
    rawRetireMask(0) &&
      io.in.bits.lane(0).envir =/= ENVIR_NORMAL
  val producerSlot0KillsSlot1 =
    rawProducerMask(0) &&
      io.in.bits.lane(0).envir =/= ENVIR_NORMAL
  io.retireMask :=
    rawRetireMask &
      Mux(slot0KillsSlot1, "b01".U, "b11".U)
  io.valid := io.retireMask.orR
  val sameGroupWaw =
    io.retireMask === "b11".U &&
      io.in.bits.lane(0).rd.wen &&
      io.in.bits.lane(1).rd.wen &&
      io.in.bits.lane(0).rd.addr =/= 0.U &&
      io.in.bits.lane(0).rd.addr === io.in.bits.lane(1).rd.addr
  // Resolve an accepted WAW before the physical register file: the younger
  // port commits the final value and the older instruction still retires.
  // Raw per-instruction write metadata remains available for differential
  // testing, which observes the two retirements in program order.
  io.gprWriteMask :=
    io.retireMask &
      Mux(sameGroupWaw, "b10".U, "b11".U)
  val producerMask =
    rawProducerMask &
      Mux(producerSlot0KillsSlot1, "b01".U, "b11".U)
  val producerSameGroupWaw =
    producerMask === "b11".U &&
      io.in.bits.lane(0).rd.wen &&
      io.in.bits.lane(1).rd.wen &&
      io.in.bits.lane(0).rd.addr =/= 0.U &&
      io.in.bits.lane(0).rd.addr === io.in.bits.lane(1).rd.addr
  val producerWriteMask =
    producerMask &
      Mux(producerSameGroupWaw, "b10".U, "b11".U)
  io.long_stall := lane0.io.long_stall
  io.div_stall := lane0.io.div_stall

  io.gpr :=
    0.U.asTypeOf(Vec(DualIssue.Width, new GPRWriteBackBundle))
  io.producer := 0.U.asTypeOf(new ForwardProducerGroup)
  io.producer.laneValid := producerMask

  val sideMduMux =
    io.in.bits.lane(1).mdu_ctrl(MDU_MUX_WIDTH - 1, 0)
  val sideMduPos =
    io.in.bits.lane(1).mdu_ctrl(
      MDU_POS_WIDTH + MDU_MUX_WIDTH - 1, MDU_MUX_WIDTH)
  val sideIsMulBe = if (CONFIG_CUSTOM_MULBE) {
    io.in.bits.lane(1).mdu_ctrl === MDU_MULBE
  } else {
    false.B
  }
  val sideData = Mux(
    sideMduMux === MD_MULT,
    Mux(sideIsMulBe, io.side_mulbe_out,
      Mux(sideMduPos.asBool,
        io.side_mul_out(63, 32), io.side_mul_out(31, 0))),
    io.in.bits.lane(1).rd.data)

  for (lane <- 0 until DualIssue.Width) {
    io.pc(lane) := io.in.bits.lane(lane).pc
    io.pcNext(lane) := io.in.bits.lane(lane).pc_next
    io.envir(lane) := io.in.bits.lane(lane).envir
    if (lane == 0) {
      io.gpr(lane) := lane0.io.gpr
      io.producer.rd(lane) := lane0.io.rd
      io.producer.rd(lane).wen :=
        lane0.io.rd.wen && producerWriteMask(lane)
      io.producer.value(lane) := lane0.io.gpr.data
    } else {
      io.gpr(lane) := io.in.bits.lane(lane).rd
      io.gpr(lane).data := sideData
      io.producer.rd(lane).wen :=
        io.in.bits.lane(lane).rd.wen && producerWriteMask(lane)
      io.producer.rd(lane).addr := io.in.bits.lane(lane).rd.addr
      io.producer.rd(lane).when := io.in.bits.lane(lane).when
      io.producer.rd(lane).producerType := producerType(
        io.in.bits.lane(lane).mem_bytes =/= MEM_NONE &&
          !io.in.bits.lane(lane).mem_wen,
        io.in.bits.lane(lane).mdu_ctrl)
      io.producer.value(lane) := sideData
    }
  }

  assert(!io.in.valid || isDualLanePrefix(io.in.bits.laneValid),
    "writeback group mask must be a contiguous oldest prefix")
  assert(!io.retireMask(1) || io.retireMask(0),
    "slot 1 must never retire without slot 0")
  assert(!io.producer.laneValid(1) || io.producer.laneValid(0),
    "slot 1 must never forward without slot 0")
  assert(!lane0.io.long_stall || !io.producer.laneValid.orR,
    "an unfinished long operation must not forward")
  assert(!slot0KillsSlot1 || !io.retireMask(1),
    "slot 1 must not retire after a slot 0 exception or return")
  assert(!sameGroupWaw ||
    (!io.gprWriteMask(0) && io.gprWriteMask(1)),
    "a same-group WAW must commit only the younger physical write")
  assert(!io.retireMask(1) ||
    io.pc(1) === io.pc(0) + 4.U,
    "dual-retire instruction PCs must remain consecutive")
  when(io.in.valid && io.in.bits.laneValid(1)) {
    assert(sideMduMux === MD_MUX_NONE || sideMduMux === MD_MULT,
      "slot 1 writeback only supports integer multiply")
  }
}
