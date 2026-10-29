package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

class LSU extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new LS_INPUT_Payload))
    val out = (Decoupled(new LS_OUTPUT_Payload))

    val flush = Input(Bool())
    val stall = Input(Bool())
    val slow_ready = Input(Bool())

    val lookup_valid = Input(Bool())
    val lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val perip = new PERIP()
    val idle = Output(Bool())
  })

  val ls1_valid     = io.in.valid
  val ls1_addr      = io.in.bits.addr
  val ls1_L_sign    = io.in.bits.L_sign
  val ls1_mem_wen   = io.in.bits.mem_wen
  val ls1_mem_bytes = io.in.bits.mem_bytes
  val ls1_mem_wdata = io.in.bits.mem_wdata
  val ls1_mem_valid = ls1_valid && ls1_mem_bytes =/= MEM_NONE

  private def cacheable(addr: UInt): Bool =
    addr(31, 18) === "b1000_0000_0001_00".U(14.W)

  private def formatLoad(raw: UInt, addr: UInt, bytes: UInt, sign: Bool): UInt = {
    val aligned = raw >> Cat(addr(1, 0), 0.U(3.W))
    val byteData = aligned(7, 0)
    val halfData = aligned(15, 0)
    val extByte = Mux(sign,
      Cat(Fill(24, byteData(7)), byteData),
      Cat(0.U(24.W), byteData))
    val extHalf = Mux(sign,
      Cat(Fill(16, halfData(15)), halfData),
      Cat(0.U(16.W), halfData))

    MuxLookup(bytes, raw)(Seq(
      MEM_BYTE -> extByte,
      MEM_HALF -> extHalf,
      MEM_WORD -> raw
    ))
  }

  val pipe_ready = io.out.ready && !io.stall
  // Keep the request asserted while bridge backpressure freezes the pipeline.
  // io.stall only contains older long-latency stalls, avoiding a valid/ready
  // combinational loop through the bridge.
  io.perip.valid := !io.stall && ls1_mem_valid
  io.in.ready := pipe_ready && (!ls1_mem_valid || io.perip.ready)

  val ls2_valid     = RegEnable(ls1_valid && !io.flush, io.in.ready)
  val ls2_addr      = RegEnable(ls1_addr              , io.in.ready)
  val ls2_L_sign    = RegEnable(ls1_L_sign            , io.in.ready)
  val ls2_mem_wen   = RegEnable(ls1_mem_wen           , io.in.ready)
  val ls2_mem_bytes = RegEnable(ls1_mem_bytes         , io.in.ready)
  val ls2_mem_wdata = RegEnable(ls1_mem_wdata         , io.in.ready)

  val ls3_valid     = RegEnable(ls2_valid    , io.out.ready)
  val ls3_addr      = RegEnable(ls2_addr     , io.out.ready)
  val ls3_L_sign    = RegEnable(ls2_L_sign   , io.out.ready)
  val ls3_mem_wen   = RegEnable(ls2_mem_wen  , io.out.ready)
  val ls3_mem_bytes = RegEnable(ls2_mem_bytes, io.out.ready)
  val ls3_mem_wdata = RegEnable(ls2_mem_wdata, io.out.ready)

  val dcache = Module(new DCache)
  val ls1_cacheable = cacheable(ls1_addr)
  val cache_request = io.in.fire && ls1_mem_valid && ls1_cacheable

  // Start the BRAM lookup speculatively in Iss.  Cacheability is checked on
  // the registered Ls1 address before the lookup result can become a request.
  dcache.io.lookup_valid := io.lookup_valid
  dcache.io.lookup_addr := io.lookup_addr
  dcache.io.req_present := ls1_mem_valid && ls1_cacheable
  dcache.io.req_valid := cache_request
  dcache.io.req_addr := ls1_addr
  dcache.io.req_write := ls1_mem_wen
  dcache.io.req_wdata := ls1_mem_wdata
  dcache.io.req_bytes := ls1_mem_bytes
  dcache.io.resp_fire := io.out.fire

  io.out.valid := ls2_valid

  // Bridge backpressure holds the unaccepted Ls1 request, while an older
  // long-latency operation can freeze a request whose BRAM response already
  // belongs to Ls2.  Keep those two hold cases distinct.
  io.perip.addr  := Mux(io.stall, ls2_addr, ls1_addr)
  io.perip.wdata := ls1_mem_wdata
  io.perip.mask  := Mux(io.stall, ls2_mem_bytes, ls1_mem_bytes)
  io.perip.wen   := ls1_mem_wen

  val mem_rdata = io.perip.rdata
  val ls2_cacheable = cacheable(ls2_addr)
  val ls2_cache_hit = ls2_valid && !ls2_mem_wen &&
                      ls2_mem_bytes =/= MEM_NONE && ls2_cacheable &&
                      dcache.io.resp_hit
  val cache_rdata_raw = dcache.io.resp_data

  io.out.bits.cache_hit := ls2_cache_hit
  io.out.bits.rdata_fast := formatLoad(
    cache_rdata_raw, ls2_addr, ls2_mem_bytes, ls2_L_sign)

  val ls3_cacheable = RegEnable(ls2_cacheable, io.out.ready)
  val ls3_cache_hit = RegEnable(ls2_cache_hit, io.out.ready)
  val ls3_cache_rdata_raw = RegEnable(cache_rdata_raw, io.out.ready)

  // At most two accepted reads can still be in flight when an older DIV/CLMUL
  // freezes Ex2 and Ex3. Preserve both responses in order; a single hold
  // register loses the younger response when it arrives one cycle later.
  val slow_response_hold = Reg(Vec(2, UInt(MEM_DATA_WIDTH.W)))
  val slow_response_head = RegInit(0.U(1.W))
  val slow_response_tail = RegInit(0.U(1.W))
  val slow_response_count = RegInit(0.U(2.W))
  val slow_response_buffered = slow_response_count =/= 0.U

  // FENCE uses this conservative idle indication: no Ls1/Ls2/Ls3 request,
  // no buffered slow response, and no peripheral request in flight.  The SoC
  // additionally qualifies it with the peripheral bridge idle.
  io.idle := !(ls1_valid && ls1_mem_bytes =/= MEM_NONE) &&
             !(ls2_valid && ls2_mem_bytes =/= MEM_NONE) &&
             !(ls3_valid && ls3_mem_bytes =/= MEM_NONE) &&
             slow_response_count === 0.U && !io.perip.valid
  val ls3_read_valid = ls3_valid && !ls3_mem_wen &&
    ls3_mem_bytes =/= MEM_NONE

  // A response with an empty queue can be consumed directly by the current
  // Ex3 load.  Otherwise enqueue it behind responses already held by a stall.
  val slow_response_direct = io.perip.rvalid && io.slow_ready &&
    ls3_read_valid && !slow_response_buffered
  val slow_response_enqueue = io.perip.rvalid && !slow_response_direct
  val slow_response_dequeue = io.slow_ready && ls3_read_valid &&
    slow_response_buffered

  when(slow_response_enqueue) {
    slow_response_hold(slow_response_tail) := mem_rdata
    slow_response_tail := slow_response_tail + 1.U
  }
  when(slow_response_dequeue) {
    slow_response_head := slow_response_head + 1.U
  }
  switch(Cat(slow_response_enqueue, slow_response_dequeue)) {
    is("b10".U) { slow_response_count := slow_response_count + 1.U }
    is("b01".U) { slow_response_count := slow_response_count - 1.U }
  }

  val slow_rdata_raw = Mux(
    slow_response_buffered,
    slow_response_hold(slow_response_head),
    mem_rdata)

  io.out.bits.rdata_slow := formatLoad(
    slow_rdata_raw, ls3_addr, ls3_mem_bytes, ls3_L_sign)

  val slow_fire = ls3_valid && io.slow_ready
  val younger_store_same_word = ls2_valid && ls2_mem_wen &&
    ls2_mem_bytes =/= MEM_NONE &&
    ls2_addr(31, 2) === ls3_addr(31, 2)
  val refill_valid = slow_fire && !ls3_mem_wen &&
    ls3_mem_bytes =/= MEM_NONE && ls3_cacheable &&
    !ls3_cache_hit && !younger_store_same_word

  dcache.io.refill_valid := refill_valid
  dcache.io.refill_addr := ls3_addr
  dcache.io.refill_data := slow_rdata_raw

  if (CONFIG_SIMULATION) {
    val DPIC = Module(new LSU_DPIC)
    val trace_read = slow_fire && !ls3_mem_wen && ls3_mem_bytes =/= MEM_NONE
    val trace_rdata = Mux(ls3_cache_hit, ls3_cache_rdata_raw, slow_rdata_raw)
    DPIC.io.clk   := clock
    DPIC.io.rst   := reset
    DPIC.io.read  := trace_read
    DPIC.io.write := io.out.fire && ls2_mem_wen
    DPIC.io.addr  := Mux(trace_read, ls3_addr, ls2_addr)
    DPIC.io.rdata := trace_rdata
    DPIC.io.wdata := Mux(trace_read, ls3_mem_wdata, ls2_mem_wdata)
    DPIC.io.bytes := Mux(trace_read, ls3_mem_bytes, ls2_mem_bytes)
  }
}

class LSU_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val read = Input(Bool())
    val write = Input(Bool())
    val addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val rdata = Input(UInt(MEM_DATA_WIDTH.W))
    val wdata = Input(UInt(MEM_DATA_WIDTH.W))
    val bytes = Input(UInt(3.W))
  })
}
