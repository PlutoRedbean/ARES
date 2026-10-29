package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import BitManipParams._

class BitManipEx1 extends Module {
  val io = IO(new Bundle {
    val ctrl       = Input(UInt(BIT_CTRL_WIDTH.W))
    val rs1        = Input(UInt(REG_DATA_WIDTH.W))
    val rs2        = Input(UInt(REG_DATA_WIDTH.W))
    val bit_data   = Output(UInt(REG_DATA_WIDTH.W))
    val bit_aux    = Output(UInt(REG_DATA_WIDTH.W))
    val ex1_result = Output(UInt(REG_DATA_WIDTH.W))
  })

  private def leadingZeros8(x: UInt): UInt = MuxCase(8.U(4.W), Seq(
    x(7) -> 0.U(4.W), x(6) -> 1.U(4.W), x(5) -> 2.U(4.W), x(4) -> 3.U(4.W),
    x(3) -> 4.U(4.W), x(2) -> 5.U(4.W), x(1) -> 6.U(4.W), x(0) -> 7.U(4.W)
  ))

  private def trailingZeros8(x: UInt): UInt = MuxCase(8.U(4.W), Seq(
    x(0) -> 0.U(4.W), x(1) -> 1.U(4.W), x(2) -> 2.U(4.W), x(3) -> 3.U(4.W),
    x(4) -> 4.U(4.W), x(5) -> 5.U(4.W), x(6) -> 6.U(4.W), x(7) -> 7.U(4.W)
  ))

  private def rotateRightFixed(x: UInt, amount: Int): UInt =
    Cat(x(amount - 1, 0), x(31, amount))

  private def selectNibble(source: UInt, index: UInt): UInt = {
    val nibbles = VecInit((0 until 8).map(i => source(4 * i + 3, 4 * i)))
    Mux(index(3), 0.U(4.W), nibbles(index(2, 0)))
  }

  val clzStage1 = if (CONFIG_RV32_ZBB_CLZ) {
    Cat((0 until 4).reverse.map(i => leadingZeros8(io.rs1(8 * i + 7, 8 * i))))
  } else 0.U(16.W)

  val ctzStage1 = if (CONFIG_RV32_ZBB_CTZ) {
    Cat((0 until 4).reverse.map(i => trailingZeros8(io.rs1(8 * i + 7, 8 * i))))
  } else 0.U(16.W)

  val cpopStage1 = if (CONFIG_RV32_ZBB_CPOP) {
    Cat((0 until 4).reverse.map(i => PopCount(io.rs1(8 * i + 7, 8 * i))))
  } else 0.U(16.W)

  val orcResult = if (CONFIG_RV32_ZBB_ORC_B) {
    Cat((0 until 4).reverse.map(i => Fill(8, io.rs1(8 * i + 7, 8 * i).orR)))
  } else 0.U(32.W)

  val zextHResult = if (CONFIG_RV32_ZBB_ZEXT_H) {
    Cat(0.U(16.W), io.rs1(15, 0))
  } else 0.U(32.W)

  val xpermLow = if (CONFIG_RV32_ZBKX_XPERM4) {
    Cat((0 until 4).reverse.map(i => selectNibble(io.rs1, io.rs2(4 * i + 3, 4 * i))))
  } else 0.U(16.W)
  val xpermStage1Data = io.rs1
  val xpermStage1Aux  = Cat(io.rs2(31, 16), xpermLow)

  val rorStage1 = if (CONFIG_RV32_ZBB_ROR) {
    val by1 = Mux(io.rs2(0), rotateRightFixed(io.rs1, 1), io.rs1)
    val by2 = Mux(io.rs2(1), rotateRightFixed(by1, 2), by1)
    Mux(io.rs2(2), rotateRightFixed(by2, 4), by2)
  } else 0.U(32.W)

  var dataCases = Seq.empty[(Bool, UInt)]
  if (CONFIG_RV32_ZBB_CLZ)     dataCases :+= ((io.ctrl === BIT_CLZ)    -> clzStage1)
  if (CONFIG_RV32_ZBB_CTZ)     dataCases :+= ((io.ctrl === BIT_CTZ)    -> ctzStage1)
  if (CONFIG_RV32_ZBB_CPOP)    dataCases :+= ((io.ctrl === BIT_CPOP)   -> cpopStage1)
  if (CONFIG_RV32_ZBKX_XPERM4) dataCases :+= ((io.ctrl === BIT_XPERM4) -> xpermStage1Data)
  if (CONFIG_RV32_ZBB_ROR)     dataCases :+= ((io.ctrl === BIT_ROR)    -> rorStage1)

  var auxCases = Seq.empty[(Bool, UInt)]
  if (CONFIG_RV32_ZBKX_XPERM4) auxCases :+= ((io.ctrl === BIT_XPERM4) -> xpermStage1Aux)
  if (CONFIG_RV32_ZBB_ROR)     auxCases :+= ((io.ctrl === BIT_ROR)    -> io.rs2)

  var ex1ResultCases = Seq.empty[(Bool, UInt)]
  if (CONFIG_RV32_ZBB_ORC_B)  ex1ResultCases :+= ((io.ctrl === BIT_ORC_B)  -> orcResult)
  if (CONFIG_RV32_ZBB_ZEXT_H) ex1ResultCases :+= ((io.ctrl === BIT_ZEXT_H) -> zextHResult)

  io.bit_data   := MuxCase(0.U(32.W), dataCases)
  io.bit_aux    := MuxCase(0.U(32.W), auxCases)
  io.ex1_result := MuxCase(0.U(32.W), ex1ResultCases)
}

class BitManipEx2 extends Module {
  val io = IO(new Bundle {
    val ctrl       = Input(UInt(BIT_CTRL_WIDTH.W))
    val bit_data   = Input(UInt(REG_DATA_WIDTH.W))
    val bit_aux    = Input(UInt(REG_DATA_WIDTH.W))
    val result     = Output(UInt(REG_DATA_WIDTH.W))
  })

  private def rotateRightFixed(x: UInt, amount: Int): UInt =
    Cat(x(amount - 1, 0), x(31, amount))

  private def selectNibble(source: UInt, index: UInt): UInt = {
    val nibbles = VecInit((0 until 8).map(i => source(4 * i + 3, 4 * i)))
    Mux(index(3), 0.U(4.W), nibbles(index(2, 0)))
  }

  private def byteCount(data: UInt, byte: Int): UInt = data(4 * byte + 3, 4 * byte)

  val clzResult = if (CONFIG_RV32_ZBB_CLZ) {
    val c3 = byteCount(io.bit_data, 3)
    val c2 = byteCount(io.bit_data, 2)
    val c1 = byteCount(io.bit_data, 1)
    val c0 = byteCount(io.bit_data, 0)
    Mux(c3 =/= 8.U, c3,
      Mux(c2 =/= 8.U, 8.U(6.W) + c2,
        Mux(c1 =/= 8.U, 16.U(6.W) + c1,
          Mux(c0 =/= 8.U, 24.U(6.W) + c0, 32.U(6.W)))))
  } else 0.U(6.W)

  val ctzResult = if (CONFIG_RV32_ZBB_CTZ) {
    val c0 = byteCount(io.bit_data, 0)
    val c1 = byteCount(io.bit_data, 1)
    val c2 = byteCount(io.bit_data, 2)
    val c3 = byteCount(io.bit_data, 3)
    Mux(c0 =/= 8.U, c0,
      Mux(c1 =/= 8.U, 8.U(6.W) + c1,
        Mux(c2 =/= 8.U, 16.U(6.W) + c2,
          Mux(c3 =/= 8.U, 24.U(6.W) + c3, 32.U(6.W)))))
  } else 0.U(6.W)

  val cpopResult = if (CONFIG_RV32_ZBB_CPOP) {
    val c0 = byteCount(io.bit_data, 0)
    val c1 = byteCount(io.bit_data, 1)
    val c2 = byteCount(io.bit_data, 2)
    val c3 = byteCount(io.bit_data, 3)
    val lowHalf  = c0 +& c1
    val highHalf = c2 +& c3
    lowHalf +& highHalf
  } else 0.U(6.W)

  val xpermResult = if (CONFIG_RV32_ZBKX_XPERM4) {
    val highIndices = io.bit_aux(31, 16)
    val highResult = Cat((0 until 4).reverse.map(i =>
      selectNibble(io.bit_data, highIndices(4 * i + 3, 4 * i))))
    Cat(highResult, io.bit_aux(15, 0))
  } else 0.U(32.W)

  val rorResult = if (CONFIG_RV32_ZBB_ROR) {
    val by8 = Mux(io.bit_aux(3), rotateRightFixed(io.bit_data, 8), io.bit_data)
    Mux(io.bit_aux(4), rotateRightFixed(by8, 16), by8)
  } else 0.U(32.W)

  var resultCases = Seq.empty[(Bool, UInt)]
  if (CONFIG_RV32_ZBB_CLZ)     resultCases :+= ((io.ctrl === BIT_CLZ)    -> clzResult)
  if (CONFIG_RV32_ZBB_CTZ)     resultCases :+= ((io.ctrl === BIT_CTZ)    -> ctzResult)
  if (CONFIG_RV32_ZBB_CPOP)    resultCases :+= ((io.ctrl === BIT_CPOP)   -> cpopResult)
  if (CONFIG_RV32_ZBKX_XPERM4) resultCases :+= ((io.ctrl === BIT_XPERM4) -> xpermResult)
  if (CONFIG_RV32_ZBB_ROR)     resultCases :+= ((io.ctrl === BIT_ROR)    -> rorResult)

  io.result := MuxCase(0.U(32.W), resultCases)
}

class CarryLessMul extends Module {
  val io = IO(new Bundle {
    val valid = Input(Bool())
    val din1  = Input(UInt(REG_DATA_WIDTH.W))
    val din2  = Input(UInt(REG_DATA_WIDTH.W))
    val dout  = Output(UInt(REG_DATA_WIDTH.W))
    val stall = Output(Bool())
    val busy  = Output(Bool())
    val done  = Output(Bool())
  })

  val counter      = RegInit(0.U(log2Ceil(CLMUL_LATENCY + 1).W))
  val accumulator  = RegInit(0.U(32.W))
  val multiplicand = Reg(UInt(32.W))
  val multiplier   = Reg(UInt(32.W))

  val idle    = counter === 0.U
  val done    = counter === CLMUL_LATENCY.U
  val running = !idle && !done
  val start   = io.valid && idle

  when(start) {
    counter      := 1.U
    accumulator  := Mux(io.din2(0), io.din1, 0.U)
    multiplicand := (io.din1 << 1)(31, 0)
    multiplier   := io.din2 >> 1
  }.elsewhen(running) {
    counter      := counter + 1.U
    accumulator  := Mux(multiplier(0), accumulator ^ multiplicand, accumulator)
    multiplicand := (multiplicand << 1)(31, 0)
    multiplier   := multiplier >> 1
  }.elsewhen(done) {
    counter := 0.U
  }

  io.dout  := accumulator
  io.stall := io.valid && running
  io.busy  := !idle
  io.done  := done
}
