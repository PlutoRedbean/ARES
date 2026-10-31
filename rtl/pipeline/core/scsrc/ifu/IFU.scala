package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._

class FetchMeta extends Bundle {
  val pc = UInt(PC_DATA_WIDTH.W)
  val snpc = UInt(PC_DATA_WIDTH.W)
  val predicted_taken = Bool()
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
}

class FetchBufferEntry extends Bundle {
  val pc = UInt(PC_DATA_WIDTH.W)
  val inst = UInt(32.W)
  val predicted_taken = Bool()
  val predicted_pc = UInt(PC_DATA_WIDTH.W)
}

class IFU extends Module {
  val io = IO(new Bundle {
    val ready         = Output(Bool())

    val irom          = new IROM()

    val out           = Decoupled(new IF_ID_Payload)

    val bpu_update_en = Input(Bool())
    val bpu_update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Input(Bool())) else None
    val bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Input(UInt(PC_DATA_WIDTH.W))) else None
    val actual_taken  = Input(Bool())
    val redirected    = Input(Bool())
    val redirected_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_update_is_branch = if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) Some(Input(Bool())) else None
  })

  private val FrontendBufferEnabled = CONFIG_FRONTEND_QUEUE
  private val FrontendBufferDepth = CONFIG_FRONTEND_QUEUE_DEPTH
  private val PtrWidth = math.max(1, log2Ceil(FrontendBufferDepth))
  private val CountWidth = log2Ceil(FrontendBufferDepth + 1)

  require(FrontendBufferDepth >= 2,
    "the fall-through instruction buffer requires at least two entries")

  val pc = Wire(UInt(PC_DATA_WIDTH.W))
  val snpc = pc + 4.U

  val fetchRespValid = RegInit(false.B)
  val fetchRespMeta = Reg(new FetchMeta)

  val bpu = Module(new BPU())
  bpu.io.update_en     := io.bpu_update_en
  bpu.io.update_pc     := io.bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    bpu.io.update_ras_push.get := io.bpu_update_ras_push.get
    bpu.io.update_ras_pop.get := io.bpu_update_ras_pop.get
    bpu.io.update_ras_addr.get := io.bpu_update_ras_addr.get
  }
  bpu.io.actual_taken  := io.actual_taken
  bpu.io.actual_target := io.redirected_pc
  if (CONFIG_BRANCH_LOOP_PREDICTOR_ENABLE != 0) {
    bpu.io.update_is_branch.get := io.bpu_update_is_branch.get
  }

  val currentPredTaken = Wire(Bool())
  val currentPredTarget = Wire(UInt(PC_DATA_WIDTH.W))
  val nextPc = Mux(currentPredTaken, currentPredTarget, snpc)

  val fetchReqFire = Wire(Bool())
  val ifIdSourceValid = Wire(Bool())
  val ifIdSourceBits = Wire(new IF_ID_Payload)

  bpu.io.req_valid  := io.redirected || fetchReqFire
  bpu.io.current_pc := Mux(io.redirected, io.redirected_pc, nextPc)

  val predHoldValid = RegInit(false.B)
  val predHoldTaken = Reg(Bool())
  val predHoldTarget = Reg(UInt(PC_DATA_WIDTH.W))

  val bpuRespValid = bpu.io.resp_valid
  currentPredTaken :=
    Mux(bpuRespValid, bpu.io.predicted_taken,
      predHoldValid && predHoldTaken)
  currentPredTarget :=
    Mux(bpuRespValid, bpu.io.predicted_pc, predHoldTarget)

  // 如果 redirect:
  //   所有旧预测作废，清掉 predHold。
  // 如果 BPU 返回了有效预测，但 IFU 没发出去:
  //   把当前 pc 和预测结果保存下来。
  // 如果之后 IFU 成功发出请求，并且用的是 predHold:
  //   说明这个暂存预测已经消费掉，清掉。

  when (io.redirected) {
    predHoldValid := false.B
  } .elsewhen (bpuRespValid && !fetchReqFire) {
    predHoldValid := true.B
    predHoldTaken := bpu.io.predicted_taken
    predHoldTarget := bpu.io.predicted_pc
  } .elsewhen (fetchReqFire && predHoldValid) {
    predHoldValid := false.B
  }

  val PC = Module(new Mundus_PC)
  PC.io.clk := clock
  PC.io.rst := reset
  pc := PC.io.dout
  PC.io.wen := io.redirected || fetchReqFire
  PC.io.din := Mux(io.redirected, io.redirected_pc, nextPc)

  val fetchRespBits = Wire(new IF_ID_Payload)
  fetchRespBits.pc := fetchRespMeta.pc
  fetchRespBits.snpc := fetchRespMeta.snpc
  fetchRespBits.inst := io.irom.data
  fetchRespBits.predicted_taken := fetchRespMeta.predicted_taken
  fetchRespBits.predicted_pc := fetchRespMeta.predicted_pc

  io.out.valid := ifIdSourceValid && !io.redirected
  io.out.bits := ifIdSourceBits

  if (FrontendBufferEnabled) {
    // Asynchronous-read, fall-through instruction buffer.  When it is empty,
    // the IROM response bypasses the storage and can enter IF/ID immediately.
    // Responses are stored only when an older buffered instruction must leave
    // first, or when the backend cannot accept the current response.
    val fqBits = Mem(FrontendBufferDepth, new FetchBufferEntry)
    val fqHead = RegInit(0.U(PtrWidth.W))
    val fqTail = RegInit(0.U(PtrWidth.W))
    val fqCount = RegInit(0.U(CountWidth.W))

    val fifoOutValid = fqCount =/= 0.U
    val fifoOutEntry = fqBits(fqHead)
    val fifoOutBits = Wire(new IF_ID_Payload)
    fifoOutBits.pc := fifoOutEntry.pc
    fifoOutBits.snpc := fifoOutEntry.pc + 4.U
    fifoOutBits.inst := fifoOutEntry.inst
    fifoOutBits.predicted_taken := fifoOutEntry.predicted_taken
    fifoOutBits.predicted_pc := fifoOutEntry.predicted_pc

    val fifoEnqBits = Wire(new FetchBufferEntry)
    fifoEnqBits.pc := fetchRespBits.pc
    fifoEnqBits.inst := fetchRespBits.inst
    fifoEnqBits.predicted_taken := fetchRespBits.predicted_taken
    fifoEnqBits.predicted_pc := fetchRespBits.predicted_pc

    ifIdSourceValid := fifoOutValid || fetchRespValid
    ifIdSourceBits := Mux(fifoOutValid, fifoOutBits, fetchRespBits)

    val fifoDeqFire = fifoOutValid && io.out.fire
    val responseBypassFire = !fifoOutValid && fetchRespValid && io.out.fire
    val fifoEnqFire = fetchRespValid && !responseBypassFire

    // The synchronous IROM response already in flight reserves one buffer
    // slot.  Deliberately do not credit a same-cycle dequeue here: doing so
    // would put the backend ready path back into PC/BPU request generation.
    val reservedCount = fqCount +& fetchRespValid.asUInt
    val fifoHasSpace = reservedCount < FrontendBufferDepth.U

    // An instruction-cache miss deasserts irom.ready; hold the PC and do not
    // allocate a response slot until the cache can return the word.
    fetchReqFire := !io.redirected && fifoHasSpace && io.irom.ready
    io.irom.addr := pc

    def ptrNext(ptr: UInt): UInt =
      Mux(ptr === (FrontendBufferDepth - 1).U, 0.U, ptr + 1.U)

    val fqCountNext =
      Mux(io.redirected, 0.U,
        fqCount + fifoEnqFire.asUInt - fifoDeqFire.asUInt)

    when (io.redirected) {
      fetchRespValid := false.B
      fqHead := 0.U
      fqTail := 0.U
      fqCount := 0.U
    } .otherwise {
      when (fifoEnqFire) {
        fqBits(fqTail) := fifoEnqBits
        fqTail := ptrNext(fqTail)
      }
      when (fifoDeqFire) {
        fqHead := ptrNext(fqHead)
      }
      fqCount := fqCountNext
      fetchRespValid := fetchReqFire

      when (fetchReqFire) {
        fetchRespMeta.pc := pc
        fetchRespMeta.snpc := snpc
        fetchRespMeta.predicted_taken := currentPredTaken
        fetchRespMeta.predicted_pc := Mux(currentPredTaken, currentPredTarget, snpc)
      }
    }

    assert(fqCount <= FrontendBufferDepth.U,
      "instruction buffer occupancy exceeded its depth")
    assert(!(fetchRespValid && fifoOutValid &&
      fqCount === FrontendBufferDepth.U),
      "instruction buffer received an unreserved IROM response")
  } else {
    // valid 响应且下游未接收时，响应槽必须整体保持。
    val respSlotHolding = fetchRespValid && !io.out.ready

    // Symmetric with the buffered path: a cache miss suppresses the request
    // and the response slot instead of producing a stale instruction.
    fetchReqFire := !io.redirected && !respSlotHolding && io.irom.ready
    ifIdSourceValid := fetchRespValid
    ifIdSourceBits := fetchRespBits

    io.irom.addr := Mux(respSlotHolding, fetchRespMeta.pc, pc)

    // 非 redirect 时，响应槽要么保持旧响应，要么接受一个新请求，
    // 因而下一拍必然有效。
    fetchRespValid := fetchReqFire || respSlotHolding

    when (fetchReqFire) {
      fetchRespMeta.pc := pc
      fetchRespMeta.snpc := snpc
      fetchRespMeta.predicted_taken := currentPredTaken
      fetchRespMeta.predicted_pc := Mux(currentPredTaken, currentPredTarget, snpc)
    }
  }

  io.ready := fetchReqFire

  if (CONFIG_SIMULATION) {
    val IFU_DPIC = Module(new IFU_DPIC)
    IFU_DPIC.io.clk := clock
    IFU_DPIC.io.valid := io.out.valid
    IFU_DPIC.io.bpu_resp_valid := bpu.io.resp_valid
    IFU_DPIC.io.bpu_resp_pc := bpu.io.resp_pc
    IFU_DPIC.io.bpu_predicted_pc := bpu.io.predicted_pc
    IFU_DPIC.io.bpu_predicted_taken := bpu.io.predicted_taken
  }
}

class IFU_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())

    val valid = Input(Bool())
    val bpu_resp_valid = Input(Bool())
    val bpu_resp_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_predicted_pc = Input(UInt(PC_DATA_WIDTH.W))
    val bpu_predicted_taken = Input(Bool())
  })
}
