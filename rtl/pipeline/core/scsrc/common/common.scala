package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class GPRWriteBackBundle extends Bundle {
  val wen  = Bool()
  val addr = UInt(GPR_ADDR_WIDTH.W)
  val data = UInt(REG_DATA_WIDTH.W)
}

class BranchResolveBundle extends Bundle {
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Bool()) else None
  val actual_pc    = UInt(PC_DATA_WIDTH.W)
  val actual_taken = Bool()
  val mispredict   = Bool()
}

class ConsumerBundle extends Bundle {
  val ren  = Bool()
  val addr = UInt(GPR_ADDR_WIDTH.W)
  val need = UInt(NEED_WHEN_WIDTH.W)
}

class ProducerBundle extends Bundle {
  val wen  = Bool()
  val addr = UInt(GPR_ADDR_WIDTH.W)
  val when = UInt(NEED_WHEN_WIDTH.W)
}

class CannotFwdBundle extends Bundle {
  val ex1 = UInt(NEED_WHEN_WIDTH.W)
  val ex2 = UInt(NEED_WHEN_WIDTH.W)
  val ex3 = UInt(NEED_WHEN_WIDTH.W)
  val ex4 = UInt(NEED_WHEN_WIDTH.W)
  val wb  = UInt(NEED_WHEN_WIDTH.W)
}

object Func {
  def str2UInt(s: String, maxLength: Int): UInt = {
    val paddedStr = s.padTo(maxLength, ' ').substring(0, maxLength)
    val asciiBits = paddedStr.map(c => c.toInt.U(8.W))
    Cat(asciiBits) 
  }

  def pipelineConnect[T1 <: Data](prevOut: DecoupledIO[T1], thisIn: DecoupledIO[T1],
                                  stall: Bool, bubble: Bool, kill: Bool = false.B) = {
    prevOut.ready := thisIn.ready && !stall
    thisIn.bits := RegEnable(prevOut.bits, prevOut.valid && thisIn.ready && !stall)
    val valid = Reg(Bool())
    when(kill) {
      // A redirect invalidates younger work even while an older long-latency
      // instruction is holding every pipeline register.
      valid := false.B
    }.elsewhen(!stall) {
      valid := prevOut.valid && !bubble
    }
    thisIn.valid := valid
  }

  def dataHazard(consumer: ConsumerBundle, producer: ProducerBundle): Bool = {
    consumer.ren && producer.wen && (producer.addr =/= 0.U) &&
      (producer.addr === consumer.addr)
  }

  def dataHazard(consumerValid: Bool, consumer: ConsumerBundle,
                 producerValid: Bool, producer: ProducerBundle): Bool = {
    consumerValid && producerValid && dataHazard(consumer, producer)
  }
}
