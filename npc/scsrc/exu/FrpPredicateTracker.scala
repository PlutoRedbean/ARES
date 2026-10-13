package npc

import chisel3._
import chisel3.util._
import MundusConfig._

class FrpPredicateToken extends Bundle {
  val valid = Bool()
  val state = UInt(REG_DATA_WIDTH.W)
}

// Events are ordered oldest to youngest.  Slot 0/slot 1 and delayed load-pair
// execution all use the same register-indexed token semantics.
class FrpPredicateTracker extends Module {
  private val EventCount = 3

  val io = IO(new Bundle {
    val event = Input(Vec(EventCount, new FrpExecutionEventBundle))
    val update = Output(Vec(EventCount, new FastRecurrenceUpdateBundle))
    val tokenCreated = Output(UInt(2.W))
    val tokenConsumed = Output(UInt(2.W))
  })

  // Keep the validity state packed.  A Vec of dynamically written registers
  // is lowered into one register and one priority chain per architectural
  // register, which needlessly expands the generated SystemVerilog.
  val tokenValid = RegInit(0.U(32.W))
  val tokenState = Reg(Vec(32, UInt(REG_DATA_WIDTH.W)))

  val candidate = Wire(Vec(EventCount, Bool()))

  for (eventIndex <- 0 until EventCount) {
    val event = io.event(eventIndex)
    var lookupValid: Bool = tokenValid(event.testReg)
    var lookupState: UInt = tokenState(event.testReg)

    // Forward older token actions within the same cycle.  This is what lets a
    // delayed load-pair ANDI feed the following group's branch without a
    // dedicated PC-adjacency state machine.
    for (olderIndex <- 0 until eventIndex) {
      val older = io.event(olderIndex)
      val olderCreates = older.valid && older.rdWen && older.bitTest &&
        older.rdAddr =/= 0.U && older.rdAddr === event.testReg
      val olderClears = older.valid && older.rdWen && !older.bitTest &&
        older.rdAddr =/= 0.U && older.rdAddr === event.testReg
      val olderConsumes = candidate(olderIndex) &&
        older.testReg === event.testReg
      lookupState = Mux(olderCreates, older.bitState, lookupState)
      lookupValid = Mux(olderCreates, true.B,
        Mux(olderClears || olderConsumes, false.B, lookupValid))
    }

    candidate(eventIndex) := event.valid && event.zeroBranch &&
      event.testReg =/= 0.U && lookupValid
    io.update(eventIndex).valid := candidate(eventIndex)
    io.update(eventIndex).state := lookupState
    io.update(eventIndex).beqz := event.branchBeqz
  }

  // Apply both actions from each event before moving to the next one.  A
  // same-event destination write wins over a consume, and later events win
  // on aliases, matching the original Vec last-connect priority.
  var tokenValidNext = tokenValid
  for (eventIndex <- 0 until EventCount) {
    val event = io.event(eventIndex)
    val afterConsume = Mux(candidate(eventIndex),
      tokenValidNext.bitSet(event.testReg, false.B), tokenValidNext)
    val writeValid = event.valid && event.rdWen && event.rdAddr =/= 0.U
    tokenValidNext = Mux(writeValid,
      afterConsume.bitSet(event.rdAddr, event.bitTest), afterConsume)

    when(writeValid && event.bitTest) {
      tokenState(event.rdAddr) := event.bitState
    }
  }
  tokenValid := tokenValidNext

  io.tokenCreated := PopCount(io.event.map { event =>
    event.valid && event.rdWen && event.rdAddr =/= 0.U && event.bitTest
  })
  io.tokenConsumed := PopCount(candidate)
}
