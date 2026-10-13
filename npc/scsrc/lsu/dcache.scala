package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

class DCache extends Module {
  private val SizeBytes = CONFIG_DCACHE_SIZE_KB * 1024
  private val BytesPerEntry = MEM_DATA_WIDTH / 8
  private val EntryCount = SizeBytes / BytesPerEntry
  private val IndexWidth = log2Ceil(EntryCount)
  private val BankCount = 2
  private val BankEntryCount = EntryCount / BankCount
  private val BankIndexWidth = IndexWidth - log2Ceil(BankCount)
  private val StoreHistoryDepth = 4
  // Only 0x8010_0000-0x8013_ffff is cacheable, so bits 31:18 are constant.
  private val TagWidth = 18 - IndexWidth - 2

  require(CONFIG_DCACHE_SIZE_KB > 0 &&
          (CONFIG_DCACHE_SIZE_KB & (CONFIG_DCACHE_SIZE_KB - 1)) == 0,
    "D-cache size must be a positive power of two")
  require(SizeBytes % BytesPerEntry == 0,
    "D-cache size must contain a whole number of entries")
  require(EntryCount >= BankCount && EntryCount % BankCount == 0,
    "D-cache entries must split evenly across two banks")
  require(TagWidth > 0,
    "D-cache is too large for the 0x8010_0000-0x8013_ffff cacheable region")

  val io = IO(new Bundle {
    val lookup_valid = Input(Bool())
    val lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    // A fallback lookup has priority on the primary input.  A holding-queue
    // probe may use the alternate input only when it selects the other bank.
    val lookup_alt_valid = Input(Bool())
    val lookup_alt_addr = Input(UInt(MEM_ADDR_WIDTH.W))

    val req_present = Input(Bool())
    val req_valid = Input(Bool())
    val req_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val req_write = Input(Bool())
    val req_bytes = Input(UInt(2.W))
    val req_sign = Input(Bool())

    val resp_fire = Input(Bool())
    val resp_hit = Output(Bool())
    val resp_data = Output(UInt(MEM_DATA_WIDTH.W))
    val resp_load_data = Output(UInt(MEM_DATA_WIDTH.W))
    // The request-side result is used only to capture a load result in LSU.
    // Keeping this separate from the registered response preserves the normal
    // response queue while allowing a fallback lookup to be sampled at DC1.
    val req_result_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val req_result_hit = Output(Bool())
    val req_result_data = Output(UInt(MEM_DATA_WIDTH.W))

    val refill_valid = Input(Bool())
    val refill_ready = Output(Bool())
    val refill_initialized = Output(Bool())
    val refill_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val refill_data = Input(UInt(MEM_DATA_WIDTH.W))

    val store_valid = Input(Bool())
    val store_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val store_data = Input(UInt(MEM_DATA_WIDTH.W))
    val store_bytes = Input(UInt(2.W))
    val store_base_hit = Input(Bool())
    val store_base_data = Input(UInt(MEM_DATA_WIDTH.W))
  })

  private def index(addr: UInt): UInt = addr(IndexWidth + 1, 2)
  private def bank(addr: UInt): UInt = addr(2)
  private def bankIndex(addr: UInt): UInt =
    addr(IndexWidth + 1, 3)
  private def tag(addr: UInt): UInt = addr(17, IndexWidth + 2)
  private def sameWord(lhs: UInt, rhs: UInt): Bool =
    lhs(MEM_ADDR_WIDTH - 1, 2) === rhs(MEM_ADDR_WIDTH - 1, 2)

  private def formatLoad(
      raw: UInt,
      addr: UInt,
      bytes: UInt,
      sign: Bool): UInt = {
    val byteData = MuxLookup(addr(1, 0), raw(7, 0))(Seq(
      1.U -> raw(15, 8),
      2.U -> raw(23, 16),
      3.U -> raw(31, 24)
    ))
    val halfData = Mux(addr(1), raw(31, 16), raw(15, 0))
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

  // The registered AG0 stage continuously drives both BRAM read addresses.
  // lookup_valid only
  // qualifies the request; it must not add hit/interlock logic to the BRAM
  // address path. The tag output is compared in Ls1 and the data output is
  // registered once more for use in Ls2.
  val data = Seq.fill(BankCount)(Module(
    new DCacheData_BRAM(BankIndexWidth, BankEntryCount)))
  val tags = Seq.fill(BankCount)(Module(
    new DCacheTag_BRAM(BankIndexWidth, TagWidth, BankEntryCount)))

  // Keep the valid bit beside the tag in BRAM.  A reset cannot clear BRAM
  // contents directly, so invalidate one entry per cycle and keep the cache
  // disabled for one extra cycle to drain the final READ_FIRST result.
  val tag_init_busy = RegInit(true.B)
  val tag_init_index = RegInit(0.U(BankIndexWidth.W))
  val tag_ready = RegNext(!tag_init_busy, false.B)
  io.refill_initialized := tag_ready
  when(tag_init_busy) {
    when(tag_init_index === (BankEntryCount - 1).U(BankIndexWidth.W)) {
      tag_init_busy := false.B
    }.otherwise {
      tag_init_index := tag_init_index + 1.U
    }
  }

  val primaryBank = bank(io.lookup_addr)
  val alternateBank = bank(io.lookup_alt_addr)
  val bankLookupAddr = Wire(Vec(BankCount, UInt(MEM_ADDR_WIDTH.W)))
  for (bankId <- 0 until BankCount) {
    val primaryOwns = io.lookup_valid && primaryBank === bankId.U
    bankLookupAddr(bankId) := Mux(
      primaryOwns, io.lookup_addr, io.lookup_alt_addr)
  }
  val refill_write = Wire(Bool())

  // A lookup and refill both enter the synchronous BRAMs on this edge.  Defer
  // their collision comparison to Ls1, where req_addr is the registered
  // request that owns the BRAM output.  This keeps the Iss AGU and forwarding
  // network out of the refill-collision register input without changing the
  // read-during-write forwarding cycle.
  val refillBankRead =
    (io.lookup_valid && primaryBank === bank(io.refill_addr)) ||
      (io.lookup_alt_valid && alternateBank === bank(io.refill_addr))
  val refill_lookup_valid_q = RegNext(
    refill_write && refillBankRead, false.B)
  val refill_lookup_addr_q = RegEnable(
    io.refill_addr, 0.U(MEM_ADDR_WIDTH.W),
    refill_write && refillBankRead)
  val refill_read_collision_q = refill_lookup_valid_q &&
    index(io.req_addr) === index(refill_lookup_addr_q)
  val refill_read_same_word_q =
    tag(io.req_addr) === tag(refill_lookup_addr_q)
  // Capture every refill.  Registered refill metadata still determines
  // whether this data is consumed on the following cycle.
  val refill_read_data_q = RegEnable(
    io.refill_data, 0.U(MEM_DATA_WIDTH.W), refill_write)

  val req_tag = tag(io.req_addr)
  val reqTagData = Mux(bank(io.req_addr).asBool,
    tags(1).io.doutb, tags(0).io.doutb)
  val resultTagData = Mux(bank(io.req_result_addr).asBool,
    tags(1).io.doutb, tags(0).io.doutb)
  val tag_req_hit = tag_ready && reqTagData(TagWidth) &&
                    reqTagData(TagWidth - 1, 0) === req_tag
  val raw_req_hit = Mux(
    refill_read_collision_q, refill_read_same_word_q, tag_req_hit)
  val result_refill_collision = refill_lookup_valid_q &&
    index(io.req_result_addr) === index(refill_lookup_addr_q)
  val result_refill_same_word =
    tag(io.req_result_addr) === tag(refill_lookup_addr_q)
  val result_tag_hit = tag_ready && resultTagData(TagWidth) &&
    resultTagData(TagWidth - 1, 0) === tag(io.req_result_addr)
  val raw_result_hit = Mux(
    result_refill_collision, result_refill_same_word, result_tag_hit)

  val resp_valid = RegInit(false.B)
  val resp_hit = RegInit(false.B)
  // A cache write and the next synchronous read may target the same word.
  // Forward the complete merged word so the inferred RAM's read-during-write
  // mode cannot expose stale or undefined data.
  val write_fwd_valid = RegInit(false.B)
  val write_fwd_addr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val write_fwd_data = Reg(UInt(MEM_DATA_WIDTH.W))
  val resp_data = RegInit(0.U(MEM_DATA_WIDTH.W))
  // Capture the fully formatted candidate beside the ordinary cache response.
  // EX2 therefore sees only a register-Q forwarding path; byte selection and
  // sign extension cannot become part of the EX2 -> EX1 ALU timing cone.
  val resp_load_data = RegInit(0.U(MEM_DATA_WIDTH.W))

  val byte_mask = MuxLookup(io.store_addr(1, 0), "h000000ff".U)(Seq(
    0.U -> "h000000ff".U,
    1.U -> "h0000ff00".U,
    2.U -> "h00ff0000".U,
    3.U -> "hff000000".U
  ))
  val half_mask = Mux(io.store_addr(1), "hffff0000".U, "h0000ffff".U)
  val store_mask = MuxLookup(io.store_bytes, "hffffffff".U)(Seq(
    MEM_BYTE -> byte_mask,
    MEM_HALF -> half_mask,
    MEM_WORD -> "hffffffff".U
  ))

  val byte_wdata = MuxLookup(io.store_addr(1, 0), io.store_data)(Seq(
    0.U -> Cat(0.U(24.W), io.store_data(7, 0)),
    1.U -> Cat(0.U(16.W), io.store_data(7, 0), 0.U(8.W)),
    2.U -> Cat(0.U(8.W), io.store_data(7, 0), 0.U(16.W)),
    3.U -> Cat(io.store_data(7, 0), 0.U(24.W))
  ))
  val half_wdata = Mux(io.store_addr(1),
    Cat(io.store_data(15, 0), 0.U(16.W)),
    Cat(0.U(16.W), io.store_data(15, 0)))
  val shifted_wdata = MuxLookup(io.store_bytes, io.store_data)(Seq(
    MEM_BYTE -> byte_wdata,
    MEM_HALF -> half_wdata,
    MEM_WORD -> io.store_data
  ))

  // A store's BRAM snapshot was taken several cycles before Ex4. Remember the
  // last few completed cache writes (stores or refills) so it can merge
  // against the youngest full word rather than stale lookup data. Four
  // entries cover the Iss-to-Ex4 distance.
  val store_history_valid =
    RegInit(VecInit(Seq.fill(StoreHistoryDepth)(false.B)))
  val store_history_addr =
    Reg(Vec(StoreHistoryDepth, UInt(MEM_ADDR_WIDTH.W)))
  val store_history_data =
    Reg(Vec(StoreHistoryDepth, UInt(MEM_DATA_WIDTH.W)))
  val history_hits = VecInit((0 until StoreHistoryDepth).map { entry =>
    val superseded = (0 until entry).map { younger =>
      store_history_valid(younger) &&
        index(store_history_addr(younger)) === index(io.store_addr)
    }.foldLeft(false.B)(_ || _)
    store_history_valid(entry) &&
      sameWord(store_history_addr(entry), io.store_addr) &&
      !superseded
  })
  val history_hit = history_hits.asUInt.orR
  val history_data =
    PriorityMux(history_hits, store_history_data)
  // A refill can install a line after the store took its speculative BRAM
  // snapshot but immediately before that store reaches Ex4. Reuse the
  // read-after-write forwarding register as the youngest merge base so the
  // later store cannot leave the just-refilled line stale.
  val recent_write_hit =
    write_fwd_valid && sameWord(write_fwd_addr, io.store_addr)
  val store_base_hit =
    io.store_base_hit || history_hit || recent_write_hit
  val store_base_data =
    Mux(recent_write_hit, write_fwd_data,
      Mux(history_hit, history_data, io.store_base_data))
  val merged_store_data =
    (store_base_data & ~store_mask) | (shifted_wdata & store_mask)
  val store_write = io.store_valid && store_base_hit

  val current_store_fwd = store_write && sameWord(io.store_addr, io.req_addr)
  val previous_store_fwd = write_fwd_valid && sameWord(write_fwd_addr, io.req_addr)
  val reqBankData = Mux(bank(io.req_addr).asBool,
    data(1).io.doutb, data(0).io.doutb)
  val resultBankData = Mux(bank(io.req_result_addr).asBool,
    data(1).io.doutb, data(0).io.doutb)
  val lookup_req_data = Mux(
    refill_read_collision_q && refill_read_same_word_q,
    refill_read_data_q,
    Mux(previous_store_fwd, write_fwd_data, reqBankData))
  val raw_req_data = Mux(
    current_store_fwd, merged_store_data, lookup_req_data)

  // A long-latency instruction can freeze a request in Ls1 after its AG0
  // lookup has already completed.  Preserve that lookup result while Ls1 is
  // held; the BRAM address itself continues to follow AG0 unconditionally.
  val held_req_valid = RegInit(false.B)
  val held_req_hit = RegInit(false.B)
  val held_req_data = RegInit(0.U(MEM_DATA_WIDTH.W))
  val req_hit = Mux(
    current_store_fwd || previous_store_fwd,
    true.B,
    Mux(held_req_valid, held_req_hit, raw_req_hit))
  // A store completing when the stall is released is newer than the saved
  // BRAM word and therefore retains forwarding priority.
  val req_data = Mux(
    current_store_fwd,
    merged_store_data,
    Mux(held_req_valid, held_req_data, lookup_req_data))

  // The fallback result is compared against the registered DC1 address, not
  // the shared request-address mux that also carries the current Issue AGU.
  // This keeps the Issue address cone out of the final load-data register.
  val result_current_store_fwd =
    store_write && sameWord(io.store_addr, io.req_result_addr)
  val result_previous_store_fwd =
    write_fwd_valid && sameWord(write_fwd_addr, io.req_result_addr)
  val result_lookup_data = Mux(
    result_refill_collision && result_refill_same_word,
    refill_read_data_q,
    Mux(result_previous_store_fwd, write_fwd_data, resultBankData))
  val req_result_hit = Mux(
    result_current_store_fwd || result_previous_store_fwd,
    true.B,
    Mux(held_req_valid, held_req_hit, raw_result_hit))
  val req_result_data = Mux(
    result_current_store_fwd,
    merged_store_data,
    Mux(held_req_valid, held_req_data, result_lookup_data))

  when(!io.req_present || io.req_valid) {
    held_req_valid := false.B
  }.elsewhen(!held_req_valid) {
    held_req_valid := true.B
    held_req_hit := raw_req_hit
    held_req_data := raw_req_data
  }

  when(io.req_valid) {
    resp_valid := true.B
    resp_hit := req_hit
    resp_data := req_data
    when(!io.req_write) {
      resp_load_data :=
        formatLoad(req_data, io.req_addr, io.req_bytes, io.req_sign)
    }
  }.elsewhen(io.resp_fire) {
    resp_valid := false.B
  }

  // A write-through store miss leaves the unrelated resident line intact.
  // Only a hit consumes the BRAM write port; a miss can coexist with refill.
  io.refill_ready := tag_ready && !store_write
  refill_write := io.refill_valid && io.refill_ready
  val cache_write = store_write || refill_write
  val cache_write_data = Mux(store_write, merged_store_data, io.refill_data)

  val cacheWriteAddr = Mux(store_write, io.store_addr, io.refill_addr)
  val cacheWriteBank = bank(cacheWriteAddr)
  for (bankId <- 0 until BankCount) {
    data(bankId).io.clka := clock
    data(bankId).io.wea :=
      cache_write && cacheWriteBank === bankId.U
    data(bankId).io.addra := bankIndex(cacheWriteAddr)
    data(bankId).io.dina := cache_write_data
    data(bankId).io.clkb := clock
    data(bankId).io.addrb := bankIndex(bankLookupAddr(bankId))

    tags(bankId).io.clka := clock
    tags(bankId).io.wea := tag_init_busy ||
      (cache_write && cacheWriteBank === bankId.U)
    tags(bankId).io.addra := Mux(
      tag_init_busy, tag_init_index, bankIndex(cacheWriteAddr))
    tags(bankId).io.dina := Mux(tag_init_busy,
      0.U((TagWidth + 1).W),
      Cat(true.B, tag(cacheWriteAddr)))
    tags(bankId).io.clkb := clock
    tags(bankId).io.addrb := bankIndex(bankLookupAddr(bankId))
  }

  write_fwd_valid := cache_write
  when(cache_write) {
    write_fwd_addr := Mux(store_write, io.store_addr, io.refill_addr)
    write_fwd_data := cache_write_data
  }

  when(cache_write) {
    for (entry <- StoreHistoryDepth - 1 to 1 by -1) {
      store_history_valid(entry) := store_history_valid(entry - 1)
      store_history_addr(entry) := store_history_addr(entry - 1)
      store_history_data(entry) := store_history_data(entry - 1)
    }
    store_history_valid(0) := true.B
    store_history_addr(0) :=
      Mux(store_write, io.store_addr, io.refill_addr)
    store_history_data(0) := cache_write_data
  }

  io.resp_hit := resp_valid && resp_hit
  io.resp_data := resp_data
  io.resp_load_data := resp_load_data
  io.req_result_hit := req_result_hit
  io.req_result_data := req_result_data

  if (CONFIG_SIMULATION) {
    when(io.lookup_valid && io.lookup_alt_valid) {
      assert(primaryBank =/= alternateBank,
        "dual-bank D-cache lookups must select different banks")
    }
    val DPIC = Module(new DCache_DPIC)
    DPIC.io.clk := clock
    DPIC.io.rst := reset
    DPIC.io.request := io.req_valid
    DPIC.io.write := io.req_write
    DPIC.io.hit := req_hit
  }
}

class DCacheData_BRAM(indexWidth: Int, entryCount: Int) extends BlackBox(
  if (CONFIG_SIMULATION)
    Map[String, chisel3.experimental.Param](
      "ENTRY_COUNT" -> entryCount,
      "INDEX_WIDTH" -> indexWidth)
  else
    Map.empty[String, chisel3.experimental.Param]) {
  override def desiredName = "DCacheData_BRAM"

  val io = IO(new Bundle {
    val clka = Input(Clock())
    val wea = Input(Bool())
    val addra = Input(UInt(indexWidth.W))
    val dina = Input(UInt(32.W))
    val clkb = Input(Clock())
    val addrb = Input(UInt(indexWidth.W))
    val doutb = Output(UInt(32.W))
  })
}

class DCacheTag_BRAM(
    indexWidth: Int,
    tagWidth: Int,
    entryCount: Int) extends BlackBox(
  if (CONFIG_SIMULATION)
    Map[String, chisel3.experimental.Param](
      "ENTRY_COUNT" -> entryCount,
      "INDEX_WIDTH" -> indexWidth,
      "TAG_WIDTH" -> tagWidth)
  else
    Map.empty[String, chisel3.experimental.Param]) {
  override def desiredName = "DCacheTag_BRAM"

  val io = IO(new Bundle {
    val clka = Input(Clock())
    val wea = Input(Bool())
    val addra = Input(UInt(indexWidth.W))
    val dina = Input(UInt((tagWidth + 1).W))
    val clkb = Input(Clock())
    val addrb = Input(UInt(indexWidth.W))
    val doutb = Output(UInt((tagWidth + 1).W))
  })
}

class DCache_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val request = Input(Bool())
    val write = Input(Bool())
    val hit = Input(Bool())
  })
}
