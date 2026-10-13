package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

class SlowLoadRequest extends Bundle {
  val addr = UInt(MEM_ADDR_WIDTH.W)
  val bytes = UInt(2.W)
}

class LSU extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new LS_INPUT_Payload))
    val out = (Decoupled(new LS_OUTPUT_Payload))

    val flush = Input(Bool())
    val probe_flush = Input(Bool())
    val stall = Input(Bool())
    val hold_request = Input(Bool())
    val store_replay_conflict = Input(Bool())
    val store_replay_hold = Output(Bool())
    val store_replay_start = Output(Bool())
    val slow_ready = Input(Bool())

    val probe_valid = Input(Bool())
    val probe_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lookup_valid = Input(Bool())
    val lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lookup_match = Input(Bool())
    val early_valid = Output(Bool())
    val early_load_valid = Output(Bool())
    val early_is_load = Output(Bool())
    val early_lane = Output(UInt(log2Ceil(DualIssue.Width).W))
    val early_rd = Output(UInt(GPR_ADDR_WIDTH.W))
    val early_addr = Output(UInt(MEM_ADDR_WIDTH.W))
    val early_bytes = Output(UInt(2.W))
    val early_sign = Output(Bool())
    val early_cache_hit = Output(Bool())
    val early_rdata = Output(UInt(MEM_DATA_WIDTH.W))
    val early_store_cache_hit = Output(Bool())
    val early_store_cache_data = Output(UInt(MEM_DATA_WIDTH.W))
    val store = Flipped(Decoupled(new StoreCommitPayload))
    val store_buffer_empty = Output(Bool())
    val load_port_blocked = Output(Bool())
    val load_stall = Output(Bool())
    val slow_stall = Output(Bool())
    val perip = new PERIP()
  })

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

  private def storeByteEnable(addr: UInt, bytes: UInt): UInt =
    MuxLookup(bytes, 0.U(4.W))(Seq(
      MEM_BYTE -> UIntToOH(addr(1, 0), 4),
      MEM_HALF -> Mux(addr(1), "b1100".U, "b0011".U),
      MEM_WORD -> "b1111".U
    ))

  private def storeWordData(data: UInt, bytes: UInt): UInt =
    MuxLookup(bytes, 0.U(MEM_DATA_WIDTH.W))(Seq(
      MEM_BYTE -> Fill(4, data(7, 0)),
      MEM_HALF -> Fill(2, data(15, 0)),
      MEM_WORD -> data
    ))

  private def mergeStore(
      raw: UInt,
      forwardMask: UInt,
      forwardData: UInt): UInt = {
    val bitMask = FillInterleaved(8, forwardMask)
    (raw & ~bitMask) | (forwardData & bitMask)
  }

  val fallbackPrepareStall = Wire(Bool())
  val pipe_ready =
    io.out.ready && !io.stall && !fallbackPrepareStall

  // The holding queue supplies the normal cache probe one cycle before EX2.
  // AG0 retains only probe ownership metadata; a mismatched request uses the
  // already registered Ex1 address for its EX3 fallback lookup.
  val ag0_valid = RegInit(false.B)
  val ag0_fresh = RegInit(false.B)
  val ag0_probe_match = Reg(Bool())
  when(io.flush || io.probe_flush) {
    ag0_valid := false.B
    ag0_fresh := false.B
  }.otherwise {
    when(io.lookup_valid) {
      ag0_valid := true.B
      ag0_fresh := true.B
      ag0_probe_match := io.lookup_match
    }.elsewhen(io.in.fire) {
      ag0_valid := false.B
      ag0_fresh := false.B
    }.elsewhen(ag0_valid) {
      // A long operation can retain the issued request before Ex1. Its old
      // BRAM result is no longer aligned once another holding probe has used
      // the address port, so force a registered fallback when it arrives.
      ag0_fresh := false.B
    }
  }
  // DC1 receives the Ex1 memory metadata one cycle after AG0.  This register
  // is elastic with the main pipe: an older DC1 request can leave while the
  // next Ex1 request enters, so throughput remains one request per cycle.
  val dc1_valid = RegInit(false.B)
  val dc1_lane = Reg(UInt(log2Ceil(DualIssue.Width).W))
  val dc1_rd = Reg(UInt(GPR_ADDR_WIDTH.W))
  val dc1_addr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val dc1_probe_match = Reg(Bool())
  val dc1_optimistic_probe = Reg(Bool())
  val dc1_fallback_prepared = Reg(Bool())
  val dc1_L_sign = Reg(Bool())
  val dc1_mem_wen = Reg(Bool())
  val dc1_mem_bytes = Reg(UInt(2.W))
  val dc1_mem_wdata = Reg(UInt(MEM_DATA_WIDTH.W))
  val dc1_transient_fwd_mask = Reg(UInt(4.W))
  val dc1_transient_fwd_data = Reg(UInt(MEM_DATA_WIDTH.W))
  val dc1_transient_fwd_sources = Reg(UInt(3.W))
  val earlyProbeGrant = Wire(Bool())
  val ex1FallbackLookup = Wire(Bool())
  val storeReplayActive = RegInit(false.B)
  val storeReplayStart =
    io.store_replay_conflict && !storeReplayActive
  val storeReplayHold =
    io.store_replay_conflict || storeReplayActive
  io.store_replay_start := storeReplayStart
  io.store_replay_hold := storeReplayHold
  // AG0 is filled only when the corresponding issue group advances.  This
  // registered identity check rejects a stale sidecar after an Ex1 hold; the
  // shorter prepared-address index check was already completed in Issue.
  val ag0OwnsEx1 =
    ag0_valid && ag0_fresh &&
      ag0_probe_match === io.in.bits.cache_probe_match
  io.in.ready := pipe_ready && !io.hold_request && !storeReplayHold
  when(storeReplayStart) {
    storeReplayActive := true.B
  }.elsewhen(storeReplayActive && !io.store_replay_conflict &&
      dc1_fallback_prepared && !fallbackPrepareStall) {
    storeReplayActive := false.B
  }
  when(io.flush) {
    dc1_valid := false.B
    storeReplayActive := false.B
  }.elsewhen(storeReplayStart) {
    // The early BRAM response may predate the older store.  Retain the load
    // metadata in DC1 and force the registered fallback lookup path.
    dc1_probe_match := false.B
    dc1_fallback_prepared := false.B
  }.elsewhen(fallbackPrepareStall) {
    // The retried address has occupied a complete synchronous BRAM cycle.
    // Keep all request metadata in DC1 and arm capture for the next edge.
    dc1_fallback_prepared := true.B
  }.elsewhen(pipe_ready && !storeReplayHold) {
    dc1_valid := io.in.valid && !io.hold_request
    when(io.in.valid && !io.hold_request) {
      dc1_lane := io.in.bits.lane
      dc1_rd := io.in.bits.rd
      dc1_addr := io.in.bits.addr
      dc1_probe_match :=
        io.in.bits.cache_probe_match && earlyProbeGrant && ag0OwnsEx1
      dc1_optimistic_probe := io.in.bits.cache_probe_match
      dc1_fallback_prepared := Mux(
        io.in.bits.cache_probe_match,
        earlyProbeGrant && ag0OwnsEx1,
        ex1FallbackLookup)
      dc1_L_sign := io.in.bits.L_sign
      dc1_mem_wen := io.in.bits.mem_wen
      dc1_mem_bytes := io.in.bits.mem_bytes
      dc1_mem_wdata := io.in.bits.mem_wdata
      dc1_transient_fwd_mask := io.in.bits.transient_fwd_mask
      dc1_transient_fwd_data := io.in.bits.transient_fwd_data
      dc1_transient_fwd_sources := io.in.bits.transient_fwd_sources
    }
  }

  val ls1_valid     = dc1_valid
  val ls1_lane      = dc1_lane
  val ls1_rd        = dc1_rd
  val ls1_addr      = dc1_addr
  val ls1_probe_match = dc1_probe_match
  val ls1_optimistic_probe = dc1_optimistic_probe
  val ls1_fallback_prepared = dc1_fallback_prepared
  val ls1_L_sign    = dc1_L_sign
  val ls1_mem_wen   = dc1_mem_wen
  val ls1_mem_bytes = dc1_mem_bytes
  val ls1_mem_wdata = dc1_mem_wdata
  val ls1_transient_fwd_mask = dc1_transient_fwd_mask
  val ls1_transient_fwd_data = dc1_transient_fwd_data
  val ls1_transient_fwd_sources = dc1_transient_fwd_sources
  val ls1_mem_valid = ls1_valid && ls1_mem_bytes =/= MEM_NONE
  val ls1_load_valid = ls1_mem_valid && !ls1_mem_wen
  val ls1_store_valid = ls1_mem_valid && ls1_mem_wen
  val ls1_cacheable = cacheable(ls1_addr)
  val ls1_fire = pipe_ready && ls1_valid && !storeReplayHold

  val storeBuffer = Module(new CoreStoreBuffer)
  storeBuffer.io.enq <> io.store
  storeBuffer.io.lookup_valid := ls1_mem_valid && cacheable(ls1_addr)
  storeBuffer.io.lookup_addr := ls1_addr

  // The core store buffer remains the searchable forwarding structure.  A
  // one-entry output skid lets it release its oldest entry independently of
  // peripheral backpressure; the skid is included in load forwarding until
  // the external request is accepted.
  val storeDrainSkid = Module(new Queue(
    new StoreCommitPayload, 1, pipe = false, flow = false))
  storeDrainSkid.io.enq <> storeBuffer.io.deq
  val storeDrainCacheDone = RegInit(false.B)
  val storeDrainCacheRequest =
    storeDrainSkid.io.deq.valid && !storeDrainCacheDone
  when(storeDrainSkid.io.deq.fire) {
    storeDrainCacheDone := false.B
  }.elsewhen(storeDrainCacheRequest) {
    storeDrainCacheDone := true.B
  }.elsewhen(storeDrainSkid.io.enq.fire) {
    storeDrainCacheDone := false.B
  }
  io.store_buffer_empty :=
    storeBuffer.io.empty && !storeDrainSkid.io.deq.valid

  // Only D-cache misses enter the slow request path.  The registered DC2 hit
  // result is consumed in Ex3; misses continue into the registered Ex4 slow
  // completion boundary.
  val slowLoadRequests = Module(new Queue(
    new SlowLoadRequest, 4, pipe = false, flow = false))
  val slowLoadResponses = Module(new Queue(
    UInt(MEM_DATA_WIDTH.W), 4, pipe = false, flow = false))

  // DC1 never waits for the peripheral port: hits complete from the D-cache,
  // while misses are backpressured at the registered DC2 boundary below.
  io.load_stall := fallbackPrepareStall
  val fallbackPortBusy = Wire(Bool())
  // A fallback owns the synchronous BRAM address on its lookup edge. Its
  // response is registered on the following edge, when the address port can
  // already launch the next holding-queue probe.
  io.load_port_blocked := fallbackPortBusy

  // A local Ex1 wait keeps the younger request outside DC1 while allowing the
  // current DC1 response to advance.  Global stalls retain the old behavior.
  val ls2_advance = pipe_ready
  val ls2_capture = ls2_advance && !storeReplayHold
  val ls2_valid = RegInit(false.B)
  when(io.flush) {
    ls2_valid := false.B
  }.elsewhen(ls2_advance) {
    // A replaying DC1 load remains in place while an older DC2 response is
    // consumed.  Do not duplicate the retained request into DC2.
    ls2_valid := ls1_valid && !storeReplayHold
  }
  val ls2_lane      = RegEnable(ls1_lane              , ls2_capture)
  val ls2_rd        = RegEnable(ls1_rd                , ls2_capture)
  val ls2_addr      = RegEnable(ls1_addr              , ls2_capture)
  val ls2_probe_match = RegEnable(ls1_probe_match      , ls2_capture)
  val ls2_L_sign    = RegEnable(ls1_L_sign            , ls2_capture)
  val ls2_mem_wen   = RegEnable(ls1_mem_wen           , ls2_capture)
  val ls2_mem_bytes = RegEnable(ls1_mem_bytes         , ls2_capture)
  val ls2_mem_wdata = RegEnable(ls1_mem_wdata         , ls2_capture)
  val ls2_transient_fwd_mask =
    RegEnable(ls1_transient_fwd_mask, ls2_capture)
  val ls2_transient_fwd_data =
    RegEnable(ls1_transient_fwd_data, ls2_capture)
  val ls2_transient_fwd_sources =
    RegEnable(ls1_transient_fwd_sources, ls2_capture)

  val ls3_valid     = RegEnable(ls2_valid    , io.out.ready)
  val ls3_lane      = RegEnable(ls2_lane     , io.out.ready)
  val ls3_rd        = RegEnable(ls2_rd       , io.out.ready)
  val ls3_addr      = RegEnable(ls2_addr     , io.out.ready)
  val ls3_L_sign    = RegEnable(ls2_L_sign   , io.out.ready)
  val ls3_mem_wen   = RegEnable(ls2_mem_wen  , io.out.ready)
  val ls3_mem_bytes = RegEnable(ls2_mem_bytes, io.out.ready)
  val ls3_mem_wdata = RegEnable(ls2_mem_wdata, io.out.ready)
  val ls3_transient_fwd_mask =
    RegEnable(ls2_transient_fwd_mask, io.out.ready)
  val ls3_transient_fwd_data =
    RegEnable(ls2_transient_fwd_data, io.out.ready)
  val ls3_transient_fwd_sources =
    RegEnable(ls2_transient_fwd_sources, io.out.ready)

  val dcache = Module(new DCache)
  val ex1_mem_valid = io.in.valid && io.in.bits.mem_bytes =/= MEM_NONE
  val ex1_cacheable = cacheable(io.in.bits.addr)
  val optimistic_request_present =
    ex1_mem_valid && ex1_cacheable && io.in.bits.cache_probe_match
  fallbackPrepareStall :=
    ls1_mem_valid && ls1_cacheable && !ls1_probe_match &&
      !ls1_fallback_prepared
  val fallback_request_present =
    ls1_mem_valid && ls1_cacheable && !ls1_probe_match &&
      ls1_fallback_prepared
  val fallback_request =
    ls1_fire && ls1_mem_valid && ls1_cacheable && !ls1_probe_match
  // A mismatched request already resides in the registered Ex1 group. Use
  // that address directly for the synchronous lookup instead of closing an
  // Issue forwarding path through an AG0 address register.
  ex1FallbackLookup :=
    io.in.fire && ex1_cacheable && !io.in.bits.cache_probe_match
  // A registered fallback and the younger optimistic request may complete on
  // the same edge when their word addresses select different D-cache banks.
  // Same-bank traffic retains the conservative single-port downgrade.
  val earlyFallbackBankConflict =
    fallback_request_present &&
      ls1_addr(2) === io.in.bits.addr(2)
  earlyProbeGrant :=
    !fallbackPrepareStall && !earlyFallbackBankConflict
  val early_request_present =
    optimistic_request_present && earlyProbeGrant && ag0OwnsEx1
  val early_request =
    io.in.fire && ex1_cacheable && io.in.bits.cache_probe_match &&
      earlyProbeGrant && ag0OwnsEx1
  // A mismatched final AGU address has priority on its selected bank.  A
  // holding-queue probe may still use the other bank on the same edge.
  val fallback_lookup_window =
    ex1FallbackLookup || fallbackPrepareStall
  val fallback_lookup_addr =
    Mux(fallbackPrepareStall, ls1_addr, io.in.bits.addr)
  val fallback_probe_bank_conflict =
    fallback_lookup_window && io.probe_valid &&
      fallback_lookup_addr(2) === io.probe_addr(2)
  val alternate_probe_valid =
    fallback_lookup_window && io.probe_valid &&
      !fallback_probe_bank_conflict
  fallbackPortBusy :=
    fallback_lookup_window &&
      (!io.probe_valid || fallback_probe_bank_conflict)

  dcache.io.lookup_valid := fallback_lookup_window || io.probe_valid
  dcache.io.lookup_addr :=
    Mux(fallback_lookup_window, fallback_lookup_addr, io.probe_addr)
  dcache.io.lookup_alt_valid := alternate_probe_valid
  dcache.io.lookup_alt_addr := io.probe_addr
  dcache.io.req_present :=
    early_request_present || fallback_request_present
  dcache.io.req_valid := early_request || fallback_request
  dcache.io.req_addr :=
    Mux(early_request_present, io.in.bits.addr, ls1_addr)
  dcache.io.req_write :=
    Mux(early_request_present, io.in.bits.mem_wen, ls1_mem_wen)
  dcache.io.req_bytes :=
    Mux(early_request_present, io.in.bits.mem_bytes, ls1_mem_bytes)
  dcache.io.req_sign :=
    Mux(early_request_present, io.in.bits.L_sign, ls1_L_sign)
  dcache.io.req_result_addr := ls1_addr
  dcache.io.resp_fire :=
    (ls1_fire && ls1_probe_match) || io.out.fire
  dcache.io.store_valid := storeDrainCacheRequest &&
    cacheable(storeDrainSkid.io.deq.bits.addr)
  dcache.io.store_addr := storeDrainSkid.io.deq.bits.addr
  dcache.io.store_data := storeDrainSkid.io.deq.bits.data
  dcache.io.store_bytes := storeDrainSkid.io.deq.bits.bytes
  dcache.io.store_base_hit := storeDrainSkid.io.deq.bits.cache_hit
  dcache.io.store_base_data := storeDrainSkid.io.deq.bits.cache_data

  assert(!(early_request_present && fallback_request_present) ||
      io.in.bits.addr(2) =/= ls1_addr(2),
    "concurrent early and fallback requests must select different banks")

  io.out.valid := ls2_valid

  // Select the response owned by the registered DC1 request. Optimistic
  // probes already have a registered D-cache response; fallback probes are
  // sampled from the request-side result on their capture edge.
  val ls1_response_hit = Mux(
    ls1_probe_match, dcache.io.resp_hit, dcache.io.req_result_hit)
  val ls1_response_data = Mux(
    ls1_probe_match, dcache.io.resp_data, dcache.io.req_result_data)
  val ls1_load_cache_hit =
    ls1_load_valid && !io.flush && ls1_cacheable && ls1_response_hit
  val ls1_store_cache_hit =
    ls1_store_valid && !io.flush && ls1_cacheable && ls1_response_hit
  val ls2_is_load =
    RegEnable(
      ls1_load_valid && !io.flush && !storeReplayHold,
      false.B,
      ls2_advance)
  val ls2_cacheable =
    RegEnable(ls1_cacheable && !storeReplayHold, false.B, ls2_advance)
  val ls2_load_cache_hit =
    RegEnable(
      ls1_load_cache_hit && !storeReplayHold,
      false.B,
      ls2_advance)
  val ls2_store_cache_hit =
    RegEnable(
      ls1_store_cache_hit && !storeReplayHold,
      false.B,
      ls2_advance)
  val cache_rdata_raw =
    RegEnable(ls1_response_data, 0.U(MEM_DATA_WIDTH.W), ls2_capture)
  val ls2_cache_hit = ls2_load_cache_hit

  val ls2_load_miss = ls2_is_load && !ls2_load_cache_hit
  slowLoadRequests.io.enq.valid := ls2_load_miss && io.out.ready
  slowLoadRequests.io.enq.bits.addr := ls2_addr
  slowLoadRequests.io.enq.bits.bytes := ls2_mem_bytes

  // Slow loads and store drain use independent registered queues.  Once the
  // peripheral observes valid with ready low, retain the selected queue until
  // that exact request handshakes.
  val requestLocked = RegInit(false.B)
  val lockedStore = RegInit(false.B)
  val storeNeedsProgress =
    storeBuffer.io.full && storeDrainSkid.io.deq.valid
  val unlockedSelectStore = storeDrainSkid.io.deq.valid &&
    (storeNeedsProgress || !slowLoadRequests.io.deq.valid)
  val selectStoreRequest =
    Mux(requestLocked, lockedStore, unlockedSelectStore)
  val selectLoadRequest =
    !selectStoreRequest && slowLoadRequests.io.deq.valid
  val selectedRequestValid =
    Mux(selectStoreRequest,
      storeDrainSkid.io.deq.valid, slowLoadRequests.io.deq.valid)

  io.perip.valid := selectedRequestValid
  io.perip.addr := Mux(selectStoreRequest,
    storeDrainSkid.io.deq.bits.addr, slowLoadRequests.io.deq.bits.addr)
  io.perip.wdata := storeDrainSkid.io.deq.bits.data
  io.perip.mask := Mux(selectStoreRequest,
    storeDrainSkid.io.deq.bits.bytes, slowLoadRequests.io.deq.bits.bytes)
  io.perip.wen := selectStoreRequest

  storeDrainSkid.io.deq.ready :=
    selectStoreRequest && io.perip.ready
  slowLoadRequests.io.deq.ready :=
    selectLoadRequest && io.perip.ready

  when(selectedRequestValid && !io.perip.ready) {
    requestLocked := true.B
    lockedStore := selectStoreRequest
  }.elsewhen(selectedRequestValid && io.perip.ready) {
    requestLocked := false.B
  }

  slowLoadResponses.io.enq.valid := io.perip.rvalid
  slowLoadResponses.io.enq.bits := io.perip.rdata

  // Snapshot every older buffered store when the request is accepted.  A
  // precise commit crosses a register before it can update a held request,
  // keeping the Ex4 store result out of the load-data combinational path.
  val drainForwardSameWord = storeDrainSkid.io.deq.valid &&
    storeDrainSkid.io.deq.bits.addr(MEM_ADDR_WIDTH - 1, 2) ===
      ls1_addr(MEM_ADDR_WIDTH - 1, 2)
  val drainForwardMask = Mux(drainForwardSameWord,
    storeByteEnable(
      storeDrainSkid.io.deq.bits.addr,
      storeDrainSkid.io.deq.bits.bytes),
    0.U(4.W))
  val drainForwardData = Mux(drainForwardSameWord,
    storeWordData(
      storeDrainSkid.io.deq.bits.data,
      storeDrainSkid.io.deq.bits.bytes),
    0.U(MEM_DATA_WIDTH.W))
  val bufferedForwardMask =
    drainForwardMask | storeBuffer.io.forward_mask
  val bufferedForwardData = mergeStore(
    drainForwardData,
    storeBuffer.io.forward_mask,
    storeBuffer.io.forward_data)
  val registeredCommitValid = RegNext(io.store.fire, false.B)
  val registeredCommit = RegInit(0.U.asTypeOf(new StoreCommitPayload))
  when(io.store.fire) {
    registeredCommit := io.store.bits
  }
  val commitForwardValid = registeredCommitValid
  val commitForwardMask =
    storeByteEnable(registeredCommit.addr, registeredCommit.bytes)
  val commitForwardData =
    storeWordData(registeredCommit.data, registeredCommit.bytes)

  private def mergeRegisteredCommit(
      baseMask: UInt,
      baseData: UInt,
      requestAddr: UInt): (UInt, UInt, Bool) = {
    val sameWord = commitForwardValid &&
      registeredCommit.addr(MEM_ADDR_WIDTH - 1, 2) ===
        requestAddr(MEM_ADDR_WIDTH - 1, 2)
    val overlayMask = Mux(sameWord, commitForwardMask, 0.U(4.W))
    val overlayBitMask = FillInterleaved(8, overlayMask)
    val overlayData =
      (baseData & ~overlayBitMask) |
        (commitForwardData & overlayBitMask)
    (baseMask | overlayMask, overlayData, sameWord)
  }

  private def matchingForwardBytes(
      forwardMask: UInt,
      forwardData: UInt,
      expectedMask: UInt,
      expectedData: UInt): UInt =
    Cat((0 until 4).reverse.map { byte =>
      forwardMask(byte) && expectedMask(byte) &&
        forwardData(8 * byte + 7, 8 * byte) ===
          expectedData(8 * byte + 7, 8 * byte)
    })

  val (combinedForwardMask, combinedForwardData, _) =
    mergeRegisteredCommit(bufferedForwardMask, bufferedForwardData, ls1_addr)
  // In-flight same-word stores are held by the registered DC1 overlap check.
  // Therefore the EX2 fast result only needs the already registered store
  // buffer view. Folding the current Ex4 commit here would close a cycle from
  // EX2 result forwarding through store data and back into this load result.
  val early_cache_committed = mergeStore(
    dcache.io.resp_data, bufferedForwardMask, bufferedForwardData)
  val early_cache_forwarded = mergeStore(
    early_cache_committed,
    ls1_transient_fwd_mask,
    ls1_transient_fwd_data)
  val early_cache_hit =
    ls1_valid && ls1_probe_match && ls1_mem_valid && ls1_cacheable &&
      dcache.io.resp_hit
  io.early_valid :=
    ls1_valid && ls1_optimistic_probe && ls1_mem_valid
  io.early_load_valid := ls1_load_valid && ls1_cacheable
  io.early_is_load := io.early_valid && !ls1_mem_wen
  io.early_lane := ls1_lane
  io.early_rd := ls1_rd
  io.early_addr := ls1_addr
  io.early_bytes := ls1_mem_bytes
  io.early_sign := ls1_L_sign
  io.early_cache_hit := early_cache_hit && !ls1_mem_wen
  io.early_rdata := dcache.io.resp_load_data
  io.early_store_cache_hit := early_cache_hit && ls1_mem_wen
  io.early_store_cache_data := early_cache_forwarded

  when(storeReplayStart) {
    assert(ls1_load_valid && ls1_cacheable,
      "store replay must start on a cacheable DC1 load")
  }
  when(storeReplayActive) {
    assert(ls1_valid && ls1_load_valid,
      "store replay must retain the original DC1 load")
    assert(!ls1_fire,
      "a replaying DC1 load must not advance before revalidation")
  }

  val ls2_forward_mask = RegInit(0.U(4.W))
  val ls2_forward_data = RegInit(0.U(MEM_DATA_WIDTH.W))
  val (ls2ForwardMaskWithCommit, ls2ForwardDataWithCommit,
      ls2CommitSameWord) =
    mergeRegisteredCommit(ls2_forward_mask, ls2_forward_data, ls2_addr)

  val ls1_cache_committed = mergeStore(
    ls1_response_data, combinedForwardMask, combinedForwardData)
  val ls1_cache_forwarded = mergeStore(
    ls1_cache_committed,
    ls1_transient_fwd_mask,
    ls1_transient_fwd_data)
  val ls2_cache_committed_with_commit = mergeStore(
    cache_rdata_raw, ls2ForwardMaskWithCommit, ls2ForwardDataWithCommit)
  val ls2_cache_forwarded_with_commit = mergeStore(
    ls2_cache_committed_with_commit,
    ls2_transient_fwd_mask,
    ls2_transient_fwd_data)
  // Register the complete load value after store forwarding and formatting.
  // Ex3 consumers therefore see only this short registered path.
  val ls2_load_forward_data = RegInit(0.U(MEM_DATA_WIDTH.W))

  when(ls1_fire) {
    when(ls1_mem_valid && ls1_cacheable) {
      ls2_forward_mask := combinedForwardMask
      ls2_forward_data := combinedForwardData
      when(!ls1_mem_wen) {
        ls2_load_forward_data := formatLoad(
          ls1_cache_forwarded, ls1_addr, ls1_mem_bytes, ls1_L_sign)
      }
    }.otherwise {
      ls2_forward_mask := 0.U
      ls2_forward_data := 0.U
    }
  }.elsewhen(ls2_valid && ls2_mem_bytes =/= MEM_NONE && ls2_cacheable &&
      ls2CommitSameWord) {
    ls2_forward_mask := ls2ForwardMaskWithCommit
    ls2_forward_data := ls2ForwardDataWithCommit
    when(!ls2_mem_wen) {
      ls2_load_forward_data := formatLoad(
        ls2_cache_forwarded_with_commit,
        ls2_addr, ls2_mem_bytes, ls2_L_sign)
    }
  }
  val cache_rdata_committed = mergeStore(
    cache_rdata_raw, ls2_forward_mask, ls2_forward_data)
  val cache_rdata_forwarded = mergeStore(
    cache_rdata_committed,
    ls2_transient_fwd_mask,
    ls2_transient_fwd_data)

  io.out.bits.cache_hit := ls2_cache_hit
  io.out.bits.lane := ls2_lane
  io.out.bits.rd := ls2_rd
  io.out.bits.addr := ls2_addr
  io.out.bits.bytes := ls2_mem_bytes
  io.out.bits.sign := ls2_L_sign
  io.out.bits.slow_lane := ls3_lane
  io.out.bits.slow_rd := ls3_rd
  io.out.bits.is_load := ls2_is_load
  io.out.bits.rdata_fast := ls2_load_forward_data
  io.out.bits.store_cache_hit := ls2_store_cache_hit
  io.out.bits.store_cache_data := cache_rdata_forwarded

  val ls3_cacheable = RegEnable(ls2_cacheable, io.out.ready)
  val ls3_cache_hit = RegEnable(ls2_cache_hit, io.out.ready)
  val ls3_cache_rdata_raw = RegEnable(cache_rdata_raw, io.out.ready)
  val ls3_forward_mask = RegInit(0.U(4.W))
  val ls3_forward_data = RegInit(0.U(MEM_DATA_WIDTH.W))
  val (ls3ForwardMaskWithCommit, ls3ForwardDataWithCommit,
      ls3CommitSameWord) =
    mergeRegisteredCommit(ls3_forward_mask, ls3_forward_data, ls3_addr)

  when(io.out.ready) {
    when(ls2_valid && ls2_mem_bytes =/= MEM_NONE && ls2_cacheable) {
      ls3_forward_mask := ls2ForwardMaskWithCommit
      ls3_forward_data := ls2ForwardDataWithCommit
    }.otherwise {
      ls3_forward_mask := 0.U
      ls3_forward_data := 0.U
    }
  }.elsewhen(ls3_valid && ls3_mem_bytes =/= MEM_NONE && ls3_cacheable &&
      ls3CommitSameWord) {
    ls3_forward_mask := ls3ForwardMaskWithCommit
    ls3_forward_data := ls3ForwardDataWithCommit
  }

  val ls3_read_valid = ls3_valid && !ls3_mem_wen &&
    ls3_mem_bytes =/= MEM_NONE
  val ls3_slow_load = ls3_read_valid && !ls3_cache_hit

  // A slow response first enters a registered completion boundary.  The
  // response-queue RAM, store-forward merge, and load formatting therefore
  // cannot propagate through the recovering consumer and back into issue in
  // the cycle in which the peripheral data becomes available.  Cache hits
  // return through the separate registered DC2/Ex3 boundary above.
  val slowCompletionValid = RegInit(false.B)
  val slowCompletionRaw = Reg(UInt(MEM_DATA_WIDTH.W))
  val slowCompletionWord = Reg(UInt(MEM_DATA_WIDTH.W))
  val slowCompletionData = Reg(UInt(MEM_DATA_WIDTH.W))
  val slowCompletionCapture =
    ls3_slow_load && !slowCompletionValid &&
      slowLoadResponses.io.deq.valid
  val slowCompletionConsume =
    ls3_slow_load && slowCompletionValid && io.slow_ready
  slowLoadResponses.io.deq.ready := slowCompletionCapture

  val slow_response_raw = slowLoadResponses.io.deq.bits
  val slow_response_committed = mergeStore(
    slow_response_raw, ls3_forward_mask, ls3_forward_data)
  val slow_response_forwarded = mergeStore(
    slow_response_committed,
    ls3_transient_fwd_mask,
    ls3_transient_fwd_data)

  when(slowCompletionCapture) {
    slowCompletionValid := true.B
    slowCompletionRaw := slow_response_raw
    slowCompletionWord := slow_response_forwarded
    slowCompletionData := formatLoad(
      slow_response_forwarded, ls3_addr, ls3_mem_bytes, ls3_L_sign)
  }.elsewhen(slowCompletionConsume) {
    slowCompletionValid := false.B
  }

  val slow_response_valid =
    ls3_slow_load && slowCompletionValid

  // A full request queue holds Ls2; a miss in Ls3 holds the backend until its
  // registered completion is available.  Neither condition is driven by
  // peripheral rdata or by the peripheral ready path.
  val slowRequestStall =
    ls2_load_miss && !slowLoadRequests.io.enq.ready
  val slowResponseStall =
    ls3_slow_load && !slowCompletionValid
  io.slow_stall := slowRequestStall || slowResponseStall

  val slow_rdata_raw = slowCompletionRaw
  val slow_rdata_forwarded = slowCompletionWord

  io.out.bits.rdata_slow := slowCompletionData
  io.out.bits.slow_valid := slow_response_valid
  io.out.bits.slow_addr := ls3_addr
  io.out.bits.slow_bytes := ls3_mem_bytes
  io.out.bits.slow_sign := ls3_L_sign

  val slow_fire = ls3_valid && io.slow_ready
  val younger_store_same_word = ls2_valid && ls2_mem_wen &&
    ls2_mem_bytes =/= MEM_NONE &&
    ls2_addr(31, 2) === ls3_addr(31, 2)
  val refill_candidate = slow_fire && !ls3_mem_wen &&
    ls3_mem_bytes =/= MEM_NONE && ls3_cacheable &&
    !ls3_cache_hit && !younger_store_same_word
  val candidateRefillResolvedMask = matchingForwardBytes(
    ls3ForwardMaskWithCommit,
    ls3ForwardDataWithCommit,
    ls3_transient_fwd_mask,
    ls3_transient_fwd_data)
  val candidateRefillReady =
    !ls3_transient_fwd_mask.orR ||
      ((candidateRefillResolvedMask & ls3_transient_fwd_mask) ===
        ls3_transient_fwd_mask)
  val candidateRefillData = mergeStore(
    slow_rdata_raw, ls3ForwardMaskWithCommit, ls3ForwardDataWithCommit)

  // A transient miss may return in the same cycle as its producer reaches
  // precise commit.  Both the architectural result and the cache-only refill
  // wait for the registered commit boundary; if the producer has not crossed
  // it yet, retain one refill until it is safe.
  val pendingRefillValid = RegInit(false.B)
  val pendingRefillAddr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val pendingRefillRawData = Reg(UInt(MEM_DATA_WIDTH.W))
  val pendingRefillForwardMask = RegInit(0.U(4.W))
  val pendingRefillForwardData = RegInit(0.U(MEM_DATA_WIDTH.W))
  val pendingRefillTransientMask = RegInit(0.U(4.W))
  val pendingRefillTransientData = RegInit(0.U(MEM_DATA_WIDTH.W))
  val pendingRefillResolvedMask = RegInit(0.U(4.W))
  val (pendingForwardMaskWithCommit, pendingForwardDataWithCommit,
      pendingCommitSameWord) = mergeRegisteredCommit(
    pendingRefillForwardMask,
    pendingRefillForwardData,
    pendingRefillAddr)
  val pendingRefillResolvedWithCommit =
    pendingRefillResolvedMask | matchingForwardBytes(
      pendingForwardMaskWithCommit,
      pendingForwardDataWithCommit,
      pendingRefillTransientMask,
      pendingRefillTransientData)
  val pendingRefillReady =
    !pendingRefillTransientMask.orR ||
      ((pendingRefillResolvedWithCommit & pendingRefillTransientMask) ===
        pendingRefillTransientMask)
  val pendingRefillData = mergeStore(
    pendingRefillRawData,
    pendingForwardMaskWithCommit,
    pendingForwardDataWithCommit)

  val pendingRefillRequest = pendingRefillValid && pendingRefillReady
  val directRefillRequest =
    refill_candidate && candidateRefillReady && !pendingRefillValid
  dcache.io.refill_valid := pendingRefillRequest || directRefillRequest
  dcache.io.refill_addr :=
    Mux(pendingRefillRequest, pendingRefillAddr, ls3_addr)
  // Transient bytes enter the cache only after a matching precise commit has
  // supplied them; speculative data itself is never installed.
  dcache.io.refill_data :=
    Mux(pendingRefillRequest, pendingRefillData, candidateRefillData)

  val pendingRefillFire =
    pendingRefillRequest && dcache.io.refill_ready
  val directRefillFire =
    directRefillRequest && dcache.io.refill_ready
  val candidateBeforeCacheInit =
    refill_candidate && !dcache.io.refill_initialized
  val candidateNeedsPending =
    refill_candidate && dcache.io.refill_initialized && !directRefillFire
  val pendingRefillReplace =
    candidateNeedsPending && (!pendingRefillValid || pendingRefillFire)

  when(io.flush) {
    pendingRefillValid := false.B
  }.otherwise {
    when(pendingRefillValid && pendingCommitSameWord) {
      pendingRefillForwardMask := pendingForwardMaskWithCommit
      pendingRefillForwardData := pendingForwardDataWithCommit
      pendingRefillResolvedMask := pendingRefillResolvedWithCommit
    }
    when(pendingRefillFire) {
      pendingRefillValid := false.B
    }
    when(pendingRefillReplace) {
      pendingRefillValid := true.B
      pendingRefillAddr := ls3_addr
      pendingRefillRawData := slow_rdata_raw
      pendingRefillForwardMask := ls3ForwardMaskWithCommit
      pendingRefillForwardData := ls3ForwardDataWithCommit
      pendingRefillTransientMask := ls3_transient_fwd_mask
      pendingRefillTransientData := ls3_transient_fwd_data
      pendingRefillResolvedMask := candidateRefillResolvedMask
    }
  }

  if (CONFIG_SIMULATION) {
    val DPIC = Module(new LSU_DPIC)
    val trace_read = slow_fire && !ls3_mem_wen && ls3_mem_bytes =/= MEM_NONE
    val trace_rdata = Mux(
      ls3_cache_hit,
      mergeStore(
        mergeStore(
          ls3_cache_rdata_raw, ls3_forward_mask, ls3_forward_data),
        ls3_transient_fwd_mask,
        ls3_transient_fwd_data),
      slow_rdata_forwarded)
    DPIC.io.clk   := clock
    DPIC.io.rst   := reset
    DPIC.io.read  := trace_read
    DPIC.io.write := io.store.fire
    DPIC.io.addr  := Mux(trace_read, ls3_addr, io.store.bits.addr)
    DPIC.io.rdata := trace_rdata
    DPIC.io.wdata := Mux(trace_read, ls3_mem_wdata, io.store.bits.data)
    DPIC.io.bytes := Mux(trace_read, ls3_mem_bytes, io.store.bits.bytes)

    val RefillDPIC = Module(new TransientRefill_DPIC)
    RefillDPIC.io.clk := clock
    RefillDPIC.io.rst := reset
    RefillDPIC.io.candidate := refill_candidate
    RefillDPIC.io.transient_candidate :=
      refill_candidate && ls3_transient_fwd_mask.orR
    RefillDPIC.io.direct_fire := directRefillFire
    RefillDPIC.io.direct_transient_fire :=
      directRefillFire && ls3_transient_fwd_mask.orR
    RefillDPIC.io.pending_enqueue := pendingRefillReplace
    RefillDPIC.io.pending_transient_enqueue :=
      pendingRefillReplace && ls3_transient_fwd_mask.orR
    RefillDPIC.io.pending_fire := pendingRefillFire
    RefillDPIC.io.pending_transient_fire :=
      pendingRefillFire && pendingRefillTransientMask.orR
    RefillDPIC.io.pending_wait :=
      pendingRefillValid && !pendingRefillFire
    RefillDPIC.io.candidate_drop :=
      candidateNeedsPending && pendingRefillValid && !pendingRefillFire
    RefillDPIC.io.startup_suppressed := candidateBeforeCacheInit
    RefillDPIC.io.pending_flush := io.flush && pendingRefillValid
  }

  when(ls1_fire && ls1_transient_fwd_mask.orR) {
    assert(ls1_load_valid && cacheable(ls1_addr),
      "transient store forwarding is only valid for cacheable loads")
    assert(ls1_transient_fwd_sources.orR,
      "transient forwarding mask must identify a producer")
  }
  when(ls3_valid && ls3_transient_fwd_mask.orR) {
    assert(ls3_transient_fwd_sources.orR,
      "transient forwarding metadata must remain aligned with the load")
  }
  when(pendingRefillValid) {
    assert(
      (pendingRefillResolvedMask & ~pendingRefillTransientMask) === 0.U,
      "deferred refill resolved bytes must belong to transient producers")
  }
  if (CONFIG_SIMULATION) {
    when(storeDrainCacheDone) {
      assert(storeDrainSkid.io.deq.valid,
        "completed cache drain must retain its store until external write")
      assert(!dcache.io.store_valid,
        "a store must update the D-cache at most once while draining")
    }
    when(storeDrainSkid.io.deq.fire &&
        cacheable(storeDrainSkid.io.deq.bits.addr)) {
      assert(storeDrainCacheDone || dcache.io.store_valid,
        "cacheable store must update the D-cache before leaving drain skid")
    }
    when(ls2_valid) {
      assert(ls2_is_load ===
        (!ls2_mem_wen && ls2_mem_bytes =/= MEM_NONE),
        "registered DC2 load class must match its request metadata")
      assert(ls2_cacheable === cacheable(ls2_addr),
        "registered DC2 cacheability must match its request address")
    }
    assert(!(ls2_load_cache_hit && ls2_store_cache_hit),
      "registered DC2 load and store hits must be mutually exclusive")
    when(ls2_load_cache_hit) {
      assert(ls2_valid && ls2_is_load && ls2_cacheable,
        "registered DC2 load hit must belong to a cacheable load")
    }
    when(ls2_store_cache_hit) {
      assert(ls2_valid && ls2_mem_wen &&
        ls2_mem_bytes =/= MEM_NONE && ls2_cacheable,
        "registered DC2 store hit must belong to a cacheable store")
    }
    when(io.perip.rvalid) {
      assert(slowLoadResponses.io.enq.ready,
        "slow load response queue must cover every accepted request")
    }
    when(requestLocked) {
      assert(Mux(lockedStore,
        storeDrainSkid.io.deq.valid, slowLoadRequests.io.deq.valid),
        "locked peripheral request must remain present")
    }
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

class TransientRefill_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val candidate = Input(Bool())
    val transient_candidate = Input(Bool())
    val direct_fire = Input(Bool())
    val direct_transient_fire = Input(Bool())
    val pending_enqueue = Input(Bool())
    val pending_transient_enqueue = Input(Bool())
    val pending_fire = Input(Bool())
    val pending_transient_fire = Input(Bool())
    val pending_wait = Input(Bool())
    val candidate_drop = Input(Bool())
    val startup_suppressed = Input(Bool())
    val pending_flush = Input(Bool())
  })
}
