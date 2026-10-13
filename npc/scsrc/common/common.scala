package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._
import MDUParams._
import DPUParams._

class GPRWriteBackBundle extends Bundle {
  val wen  = Bool()
  val addr = UInt(GPR_ADDR_WIDTH.W)
  val data = UInt(REG_DATA_WIDTH.W)
}

class BranchResolveBundle extends Bundle {
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val is_branch = if (CONFIG_BRANCH_DIRECTION_METADATA_ENABLE != 0) Some(Bool()) else None
  val tage_meta = if (CONFIG_BP_TAGE) Some(new TageMetaBundle) else None
  val loop_meta = if (CONFIG_SIMULATION && CONFIG_BRANCH_LOOP_PREDICTOR)
    Some(new LoopPredictionMetaBundle) else None
  val frp_owned = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(Bool()) else None
  val frp_update = if (CONFIG_BRANCH_FAST_RECURRENCE) Some(new FastRecurrenceUpdateBundle) else None
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
  val producerType = UInt(OperandStats.PRODUCER_TYPE_WIDTH.W)
}

class ForwardProducerGroup extends Bundle {
  val laneValid = UInt(DualIssue.Width.W)
  val rd = Vec(DualIssue.Width, new ProducerBundle)
  val value = Vec(DualIssue.Width, UInt(REG_DATA_WIDTH.W))
}

// ISS records the youngest matching producer once.  The synthesizable token
// contains only its moving stage/lane identity plus the speculative-load bit;
// downstream stages trust that decision instead of rebuilding the scoreboard
// on the operand data path.  Simulation assertions use the consumer address
// already present in the instruction payload rather than widening this token.
class LateOperandBundle extends Bundle {
  val pending = Bool()
  val stage = UInt(WHERE_WIDTH.W)
  val lane = UInt(log2Ceil(DualIssue.Width).W)
  val loadSpec = Bool()
}

// Stores and CSR operations may consume their source after Ex1.  Once Ex1 has
// created the architectural payload, carry its value beside the small token;
// the wide value never feeds back into the Issue pipeline register.
class LateOperandStateBundle extends Bundle {
  val value = UInt(REG_DATA_WIDTH.W)
  val token = new LateOperandBundle
}

class Ex1ForwardSource extends Bundle {
  val value = UInt(REG_DATA_WIDTH.W)
  val valueAvailable = Bool()
  val stage = UInt(WHERE_WIDTH.W)
  val lane = UInt(log2Ceil(DualIssue.Width).W)
}

object LateOperandForward {
  def select(
      operand: LateOperandBundle,
      ex2: ForwardProducerGroup,
      ex3: ForwardProducerGroup,
      ex4: ForwardProducerGroup,
      wb: ForwardProducerGroup): Ex1ForwardSource = {
    val lane = operand.lane
    val selectedRd =
      WireDefault(0.U.asTypeOf(new ProducerBundle))
    val selectedValue = WireDefault(0.U(REG_DATA_WIDTH.W))
    val selectedAvailable = WireDefault(false.B)

    when(operand.stage(WHR_IDX_EX2)) {
      selectedRd := ex2.rd(lane)
      selectedValue := ex2.value(lane)
      selectedAvailable := !ex2.rd(lane).when(WHN_IDX_EX2)
    }.elsewhen(operand.stage(WHR_IDX_EX3)) {
      selectedRd := ex3.rd(lane)
      selectedValue := ex3.value(lane)
      selectedAvailable := !ex3.rd(lane).when(WHN_IDX_EX3)
    }.elsewhen(operand.stage(WHR_IDX_EX4)) {
      selectedRd := ex4.rd(lane)
      selectedValue := ex4.value(lane)
      selectedAvailable := !ex4.rd(lane).when(WHN_IDX_EX4)
    }.elsewhen(operand.stage(WHR_IDX_WB)) {
      selectedRd := wb.rd(lane)
      selectedValue := wb.value(lane)
      selectedAvailable := true.B
    }

    val source = WireDefault(0.U.asTypeOf(new Ex1ForwardSource))
    source.value := selectedValue
    source.valueAvailable :=
      operand.pending && selectedAvailable
    source.stage := operand.stage
    source.lane := operand.lane
    source
  }

  def advance(
      operand: LateOperandStateBundle,
      ex2: ForwardProducerGroup,
      ex3: ForwardProducerGroup,
      ex4: ForwardProducerGroup,
      wb: ForwardProducerGroup): LateOperandStateBundle = {
    val source = select(operand.token, ex2, ex3, ex4, wb)
    val capture =
      operand.token.pending && source.valueAvailable
    val result = WireDefault(operand)
    result.value := Mux(capture, source.value, operand.value)
    result.token.pending := operand.token.pending && !capture
    result.token.stage :=
      Mux(result.token.pending, operand.token.stage >> 1, 0.U)
    result
  }

  // Check the Issue decision without putting identity qualification back on
  // the synthesized value mux.  Callers gate this with the pipeline-valid
  // event associated with the token being consumed or advanced.
  def assertIdentity(
      operand: LateOperandBundle,
      ex2: ForwardProducerGroup,
      ex3: ForwardProducerGroup,
      ex4: ForwardProducerGroup,
      wb: ForwardProducerGroup,
      expectedAddr: UInt,
      enable: Bool,
      message: String): Unit = if (AutoConfig.CONFIG_SIMULATION) {
    val lane = operand.lane
    val selectedValid = WireDefault(false.B)
    val selectedRd = WireDefault(0.U.asTypeOf(new ProducerBundle))

    when(operand.stage(WHR_IDX_EX2)) {
      selectedValid := ex2.laneValid(lane)
      selectedRd := ex2.rd(lane)
    }.elsewhen(operand.stage(WHR_IDX_EX3)) {
      selectedValid := ex3.laneValid(lane)
      selectedRd := ex3.rd(lane)
    }.elsewhen(operand.stage(WHR_IDX_EX4)) {
      selectedValid := ex4.laneValid(lane)
      selectedRd := ex4.rd(lane)
    }.elsewhen(operand.stage(WHR_IDX_WB)) {
      selectedValid := wb.laneValid(lane)
      selectedRd := wb.rd(lane)
    }

    when(enable && operand.pending) {
      when(!(selectedValid && selectedRd.wen &&
          selectedRd.addr =/= 0.U && selectedRd.addr === expectedAddr)) {
        printf(p"late-token mismatch: stage=0x${Hexadecimal(operand.stage)} " +
          p"lane=${operand.lane} expected=${expectedAddr} " +
          p"valid=${selectedValid} wen=${selectedRd.wen} " +
          p"actual=${selectedRd.addr}\n")
      }
      assert(PopCount(operand.stage) === 1.U,
        s"$message token stage must be one-hot")
      assert(selectedValid && selectedRd.wen && selectedRd.addr =/= 0.U,
        s"$message token selected an invalid producer")
      assert(selectedRd.addr === expectedAddr,
        s"$message token producer address changed")
    }
  }
}

class StoreAddressBundle extends Bundle {
  val valid = Bool()
  val addrValid = Bool()
  val addr = UInt(MEM_ADDR_WIDTH.W)
  val bytes = UInt(2.W)
  val byteMask = UInt(4.W)
  val data = UInt(MEM_DATA_WIDTH.W)
  val dataValid = Bool()
  val stage = UInt(2.W)
  val lane = UInt(log2Ceil(DualIssue.Width).W)
}

object StoreForward {
  def byteEnable(addr: UInt, bytes: UInt): UInt =
    MuxLookup(bytes, 0.U(4.W))(Seq(
      MEM_BYTE -> UIntToOH(addr(1, 0), 4),
      MEM_HALF -> Mux(addr(1), "b1100".U, "b0011".U),
      MEM_WORD -> "b1111".U
    ))

  def wordData(data: UInt, bytes: UInt): UInt =
    MuxLookup(bytes, 0.U(MEM_DATA_WIDTH.W))(Seq(
      MEM_BYTE -> Fill(4, data(7, 0)),
      MEM_HALF -> Fill(2, data(15, 0)),
      MEM_WORD -> data
    ))
}

class CannotFwdBundle extends Bundle {
  val ex1 = UInt(NEED_WHEN_WIDTH.W)
  val ex2 = UInt(NEED_WHEN_WIDTH.W)
  val ex3 = UInt(NEED_WHEN_WIDTH.W)
  val ex4 = UInt(NEED_WHEN_WIDTH.W)
  val wb  = UInt(NEED_WHEN_WIDTH.W)
}

object Func {
  def isDualLanePrefix(mask: UInt): Bool =
    mask === "b00".U || mask === "b01".U || mask === "b11".U

  def str2UInt(s: String, maxLength: Int): UInt = {
    val paddedStr = s.padTo(maxLength, ' ').substring(0, maxLength)
    val asciiBits = paddedStr.map(c => c.toInt.U(8.W))
    Cat(asciiBits) 
  }

  def pipelineConnect[T1 <: Data](prevOut: DecoupledIO[T1], thisIn: DecoupledIO[T1],
                                  stall: Bool, bubble: Bool, kill: Bool = false.B) = {
    prevOut.ready := thisIn.ready && !stall
    // Keep payload clock enables independent of the upstream valid cone.  An
    // invalid payload is architecturally ignored, so refreshing it whenever
    // the stage can advance preserves behavior while avoiding a high-fanout
    // hazard/ready path to every payload register CE pin.
    thisIn.bits := RegEnable(prevOut.bits, thisIn.ready && !stall)
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

object OperandStats {
  val PRODUCER_TYPE_WIDTH = 2
  val PRODUCER_ALU  = 0.U(PRODUCER_TYPE_WIDTH.W)
  val PRODUCER_LOAD = 1.U(PRODUCER_TYPE_WIDTH.W)
  val PRODUCER_MUL  = 2.U(PRODUCER_TYPE_WIDTH.W)
  val PRODUCER_LOAD_PAIR_ALU = 3.U(PRODUCER_TYPE_WIDTH.W)

  val CONSUMER_TYPE_WIDTH = 2
  val CONSUMER_ALU        = 0.U(CONSUMER_TYPE_WIDTH.W)
  val CONSUMER_BRANCH     = 1.U(CONSUMER_TYPE_WIDTH.W)
  val CONSUMER_AGU        = 2.U(CONSUMER_TYPE_WIDTH.W)
  val CONSUMER_STORE_DATA = 3.U(CONSUMER_TYPE_WIDTH.W)

  val PRODUCER_STAGE_WIDTH = 3
  val PRODUCER_EX1 = 0.U(PRODUCER_STAGE_WIDTH.W)
  val PRODUCER_EX2 = 1.U(PRODUCER_STAGE_WIDTH.W)
  val PRODUCER_EX3 = 2.U(PRODUCER_STAGE_WIDTH.W)
  val PRODUCER_EX4 = 3.U(PRODUCER_STAGE_WIDTH.W)
  val PRODUCER_WB  = 4.U(PRODUCER_STAGE_WIDTH.W)

  def producerType(isLoad: Bool, mduCtrl: UInt): UInt =
    MuxCase(PRODUCER_ALU, Seq(
      isLoad -> PRODUCER_LOAD,
      (mduCtrl =/= MDU_NONE) -> PRODUCER_MUL
    ))
}
