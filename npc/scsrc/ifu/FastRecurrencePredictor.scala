package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

// A small update-trained predictor for reflected, bit-serial CRC recurrences.
// Fetch performs only an indexed read, a tag comparison and direction select.
class FastRecurrencePredictor extends Module {
  private val IndexBits = CONFIG_BRANCH_FAST_RECURRENCE_INDEX_BITS
  private val Entries = 1 << IndexBits
  private val ActiveThreshold = 2.U(2.W)
  private val ConfidenceWidth = Entries * 2

  private def setConfidence(
      packed: UInt, index: UInt, value: UInt): UInt = {
    val shift = Cat(index, 0.U(1.W))
    val mask = (3.U(ConfidenceWidth.W) << shift)(ConfidenceWidth - 1, 0)
    (packed & ~mask) |
      ((value << shift)(ConfidenceWidth - 1, 0) & mask)
  }

  val io = IO(new Bundle {
    val req_valid = Input(Bool())
    val req_pc = Input(UInt(PC_DATA_WIDTH.W))
    val resp_valid = Output(Bool())
    val resp_pc = Output(UInt(PC_DATA_WIDTH.W))
    val pred_valid = Output(Bool())
    val pred_branch_pc = Output(UInt(PC_DATA_WIDTH.W))
    val pred_taken = Output(Bool())
    val blocked_by_issued = Output(Bool())

    val resolve_valid = Input(Bool())
    val resolve_pc = Input(UInt(PC_DATA_WIDTH.W))
    val update_valid = Input(Bool())
    val update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val update_state = Input(UInt(REG_DATA_WIDTH.W))
    val update_beqz = Input(Bool())
    val update_active = Output(Bool())
    val boundary_mismatch = Output(Bool())
  })

  // Keep narrow per-entry state packed.  Dynamic writes to a register Vec are
  // otherwise lowered into a separate priority chain for every entry.
  val valid = RegInit(0.U(Entries.W))
  val polynomialValid = RegInit(0.U(Entries.W))
  val active = RegInit(0.U(Entries.W))
  val nextValid = RegInit(0.U(Entries.W))
  val issued = RegInit(0.U(Entries.W))
  val confidence = RegInit(0.U(ConfidenceWidth.W))

  // Data arrays do not need reset.  Their validity is carried separately.
  val tag = Reg(Vec(Entries, UInt(PC_DATA_WIDTH.W)))
  val lastState = Reg(Vec(Entries, UInt(REG_DATA_WIDTH.W)))
  val polynomial = Reg(Vec(Entries, UInt(REG_DATA_WIDTH.W)))
  val candidatePolynomial = Reg(Vec(Entries, UInt(REG_DATA_WIDTH.W)))
  val nextDirection = Reg(UInt(Entries.W))

  val requestValid = RegNext(io.req_valid, false.B)
  val requestPc = RegEnable(io.req_pc, io.req_valid)
  val requestIndex = requestPc(IndexBits + 2, 3)
  val requestBlock = requestPc & "hfffffff8".U
  val requestHit = valid(requestIndex) &&
    (tag(requestIndex) & "hfffffff8".U) === requestBlock
  val requestReady = requestValid && requestHit &&
    active(requestIndex) && nextValid(requestIndex)

  io.resp_valid := requestValid
  io.resp_pc := requestPc
  io.pred_valid := requestReady && !issued(requestIndex)
  io.pred_branch_pc := tag(requestIndex)
  io.pred_taken := nextDirection(requestIndex)
  io.blocked_by_issued := requestReady && issued(requestIndex)

  val resolveIndex = io.resolve_pc(IndexBits + 2, 3)
  val resolveHit = valid(resolveIndex) && tag(resolveIndex) === io.resolve_pc

  val updateIndex = io.update_pc(IndexBits + 2, 3)
  val updateHit = valid(updateIndex) && tag(updateIndex) === io.update_pc
  val updateConfidence =
    (confidence >> Cat(updateIndex, 0.U(1.W)))(1, 0)
  val shiftedState = lastState(updateIndex) >> 1
  val residual = io.update_state ^ shiftedState
  val expectedState = shiftedState ^
    Mux(lastState(updateIndex)(0), polynomial(updateIndex), 0.U)
  val transitionMatches = io.update_state === expectedState

  io.update_active := io.update_valid && updateHit && active(updateIndex)
  io.boundary_mismatch := io.update_valid && updateHit &&
    polynomialValid(updateIndex) && !transitionMatches

  // Preserve the original last-connect ordering while updating every
  // non-aliasing index: update clear > resolve clear > prediction set.
  val issuedAfterPrediction = Mux(io.pred_valid,
    issued.bitSet(requestIndex, true.B), issued)
  val issuedAfterResolve = Mux(io.resolve_valid && resolveHit,
    issuedAfterPrediction.bitSet(resolveIndex, false.B),
    issuedAfterPrediction)
  issued := Mux(io.update_valid,
    issuedAfterResolve.bitSet(updateIndex, false.B), issuedAfterResolve)

  when(io.update_valid) {
    when(!updateHit) {
      valid := valid.bitSet(updateIndex, true.B)
      polynomialValid := polynomialValid.bitSet(updateIndex, false.B)
      active := active.bitSet(updateIndex, false.B)
      nextValid := nextValid.bitSet(updateIndex, false.B)
      confidence := setConfidence(confidence, updateIndex, 0.U)
      tag(updateIndex) := io.update_pc
      lastState(updateIndex) := io.update_state
    }.otherwise {
      val learnedPolynomial = WireDefault(polynomial(updateIndex))
      val learnedPolynomialValid = WireDefault(polynomialValid(updateIndex))
      val learnedConfidence = WireDefault(updateConfidence)
      val learnedActive = WireDefault(active(updateIndex))

      when(!polynomialValid(updateIndex)) {
        when(updateConfidence === 0.U) {
          when(lastState(updateIndex)(0)) {
            candidatePolynomial(updateIndex) := residual
            learnedConfidence := 1.U
          }
        }.otherwise {
          val candidateMatches = Mux(lastState(updateIndex)(0),
            candidatePolynomial(updateIndex) === residual,
            residual === 0.U)
          when(candidateMatches) {
            val incremented = Mux(updateConfidence === 3.U,
              updateConfidence, updateConfidence + 1.U)
            learnedConfidence := incremented
            when(incremented === 3.U) {
              learnedPolynomial := candidatePolynomial(updateIndex)
              learnedPolynomialValid := true.B
              learnedActive := true.B
            }
          }.otherwise {
            when(updateConfidence === 1.U && lastState(updateIndex)(0)) {
              candidatePolynomial(updateIndex) := residual
              learnedConfidence := 1.U
            }.otherwise {
              learnedConfidence := updateConfidence - 1.U
            }
          }
        }
      }.otherwise {
        val adjustedConfidence = Mux(transitionMatches,
          Mux(updateConfidence === 3.U,
            updateConfidence, updateConfidence + 1.U),
          Mux(updateConfidence === 0.U,
            updateConfidence, updateConfidence - 1.U))
        learnedConfidence := adjustedConfidence
        learnedActive := adjustedConfidence >= ActiveThreshold
      }

      val nextState = (io.update_state >> 1) ^
        Mux(io.update_state(0), learnedPolynomial, 0.U)
      val modelActive = learnedPolynomialValid && learnedActive

      tag(updateIndex) := io.update_pc
      lastState(updateIndex) := io.update_state
      polynomial(updateIndex) := learnedPolynomial
      polynomialValid := polynomialValid.bitSet(
        updateIndex, learnedPolynomialValid)
      confidence := setConfidence(confidence, updateIndex, learnedConfidence)
      active := active.bitSet(updateIndex, learnedActive)
      nextDirection := nextDirection.bitSet(updateIndex,
        Mux(io.update_beqz, !nextState(0), nextState(0)))
      nextValid := nextValid.bitSet(updateIndex, modelActive)
    }
  }
}
