package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

//===========================================================================
// ARES pipeline SoC - 2-way set-associative L1 D-cache
//-----------------------------------------------------------------------------
// Competition requirement: the D-cache is 2-way set associative.  The total
// capacity stays CONFIG_DCACHE_SIZE_KB (8 KiB), so associativity is paid for
// with half the set count (the I-cache keeps its own 4 KiB / 4-way geometry):
//
//   capacity   8 KiB          = CONFIG_DCACHE_WAYS x 1024 sets x 1 word (4 B)
//   index      addr[11:2]     (SetCount = DCACHE_SIZE_KB*256/DCACHE_WAYS)
//   tag        addr[17:12]    (6 bits; 0x8010_0000-0x8013_ffff is the only
//                              cacheable window, so addr[31:18] is constant)
//   offset     addr[1:0]
//
// The cache stores single words (there is no line fill): a request hits when
// its tag matches in either Way, and a miss is refilled with the single word
// the peripheral returned.
//
// Structure and why it protects the clock:
//   * Every Way owns its own 1W1R Data RAM and Tag RAM.  Both Ways are read in
//     parallel straight from the speculative Iss lookup address, exactly like
//     the old direct-mapped array, so the lookup is still one cycle and the
//     RAMs stay plain (addressable) block RAMs.
//   * The only logic added in front of the response register is the 2:1 Way
//     mux on the RAM data output (one LUT per data bit) and the OR of the two
//     tag comparators on the hit path.  Nothing was added in front of a RAM
//     address port: the per-Way write enables are driven by flops only.
//   * The per-set replacement state has its own 1-bit 1W1R RAM that is read in
//     parallel with the Tag RAM (same registered latency), so the Victim Way of
//     a request is available together with its tag comparison.  It is carried
//     to the refill by the LSU (ls2/ls3), which keeps the refill write port a
//     flop-to-flop path and stops the critical path from growing with the set
//     count (no 1024:1 Victim mux).
//
// Replacement: fill/hit LRU.  `lru[s]` is the Way of set `s` used most
// recently (filled or hit); the Victim is an invalid Way if one exists and
// otherwise the Way after `lru[s]`.  For two Ways that is the classic
// bi-state LRU: a fill makes the other Way the next Victim, and a hit
// refreshes the Way that was used.
//
// Coherence: the shared L2 is write-invalidate and bumps `epoch` on every
// accepted write.  A remote write invalidates the whole Set (both Ways; the
// sideband is registered in the L2, so this is a flop-to-flop tag write) and a
// refill is dropped when the epoch changed while it was in flight, which
// closes the read-then-remote-write race.
//
// A refill and an invalidate never share the directory write port: the
// invalidate wins and the refill is dropped.  Dropping a fill is always safe,
// the word is simply not cached.
//
// Stores write every Way that hit when the request was accepted.  Two Ways can
// only ever hold the same tag if one word was refilled twice back-to-back (the
// Victim of a request is decided one cycle after its lookup); updating both
// copies means such a duplicate can never leave a stale Way behind.
//===========================================================================
class DCache extends Module {
  private val SizeBytes     = CONFIG_DCACHE_SIZE_KB * 1024
  private val BytesPerEntry = MEM_DATA_WIDTH / 8
  private val WayCount      = CONFIG_DCACHE_WAYS
  private val EntryCount    = SizeBytes / BytesPerEntry
  private val SetCount      = EntryCount / WayCount
  private val IndexWidth    = log2Ceil(SetCount)
  private val WayWidth      = math.max(log2Ceil(WayCount), 1)
  // Only 0x8010_0000-0x8013_ffff is cacheable, so bits 31:18 are constant.
  private val TagWidth      = 18 - IndexWidth - 2

  require(CONFIG_DCACHE_SIZE_KB > 0 &&
          (CONFIG_DCACHE_SIZE_KB & (CONFIG_DCACHE_SIZE_KB - 1)) == 0,
    "D-cache size must be a positive power of two")
  require(WayCount >= 2 && (WayCount & (WayCount - 1)) == 0,
    "D-cache need at least two power-of-two ways")
  require(SizeBytes % BytesPerEntry == 0,
    "D-cache size must contain a whole number of entries")
  require((EntryCount & (EntryCount - 1)) == 0 && EntryCount % WayCount == 0,
    "D-cache entry count must be a power of two that divides into the ways")
  require(TagWidth > 0,
    "D-cache is too large for the 0x8010_0000-0x8013_ffff cacheable region")

  val io = IO(new Bundle {
    val lookup_valid = Input(Bool())
    val lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))

    val req_present = Input(Bool())
    val req_valid = Input(Bool())
    val req_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val req_write = Input(Bool())
    val req_wdata = Input(UInt(MEM_DATA_WIDTH.W))
    val req_bytes = Input(UInt(2.W))
    // Eviction candidate of this request's Set.  The LSU captures it with the
    // request and hands it back with the refill of the same request.
    val req_way = Output(UInt(WayWidth.W))

    val resp_fire = Input(Bool())
    val resp_hit = Output(Bool())
    val resp_data = Output(UInt(MEM_DATA_WIDTH.W))

    val refill_valid = Input(Bool())
    val refill_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val refill_data = Input(UInt(MEM_DATA_WIDTH.W))
    val refill_way = Input(UInt(WayWidth.W))

    // Write-invalidate coherence sideband and the epoch captured when the
    // corresponding L1 miss was issued.  The tag write below is the only
    // invalidate action; L1 data is a copy of the shared L2 line.
    val coh = new COH()
    val refill_epoch = Input(UInt(8.W))
  })

  private def index(addr: UInt): UInt = addr(IndexWidth + 1, 2)
  private def tag(addr: UInt): UInt = addr(17, IndexWidth + 2)
  private def sameWord(lhs: UInt, rhs: UInt): Bool =
    lhs(MEM_ADDR_WIDTH - 1, 2) === rhs(MEM_ADDR_WIDTH - 1, 2)

  // Iss continuously drives every RAM read address with lookup_addr.
  // lookup_valid only qualifies the request; it must not add hit/interlock
  // logic to the RAM address path.
  val dataRam = Seq.tabulate(WayCount) { _ => Module(new DCacheData_BRAM(IndexWidth)) }
  val tagRam  = Seq.tabulate(WayCount) { _ => Module(new DCacheTag_BRAM(IndexWidth, TagWidth)) }
  val lruRam  = Module(new DCacheLru_BRAM(IndexWidth, WayWidth))

  // Keep the Valid bit beside the Tag in RAM.  A reset cannot clear RAM
  // contents directly, so invalidate one Set per cycle in every Way (and clear
  // its Victim state) and keep the cache disabled for one extra cycle to drain
  // the final READ_FIRST result.
  val tag_init_busy = RegInit(true.B)
  val tag_init_index = RegInit(0.U(IndexWidth.W))
  val tag_ready = RegNext(!tag_init_busy, false.B)
  when(tag_init_busy) {
    when(tag_init_index === (SetCount - 1).U(IndexWidth.W)) {
      tag_init_busy := false.B
    }.otherwise {
      tag_init_index := tag_init_index + 1.U
    }
  }

  val lookup_index = index(io.lookup_addr)
  val refill_index = index(io.refill_addr)
  val inv_index    = index(io.coh.inv_addr)
  val refill_write = Wire(Bool())
  val inv_write    = Wire(Bool())

  // A refill to the Set that Iss is looking up corrupts that read (the Tag and
  // Data of the written Way, and the Victim state of the Set).  The word that
  // was just written is forwarded to the request consuming the corrupted read
  // one cycle later.  Everything captured here is qualified by the collision,
  // so it always pairs with refill_read_collision_q even for back-to-back
  // refills.
  val refill_read_collision = refill_write && io.lookup_valid &&
                              lookup_index === refill_index
  val refill_read_collision_q = RegNext(refill_read_collision, false.B)
  val refill_read_way_q = Reg(UInt(WayWidth.W))
  val refill_read_same_word_q = Reg(Bool())
  val refill_read_data_q = Reg(UInt(MEM_DATA_WIDTH.W))
  when(refill_read_collision) {
    refill_read_way_q := io.refill_way
    refill_read_same_word_q := tag(io.lookup_addr) === tag(io.refill_addr)
    refill_read_data_q := io.refill_data
  }

  // A refill can also steal the Way that a store hit: the hit is resolved from
  // the read that preceded the request, while the store's merged word (built on
  // the old line) is written one cycle after the request.  Remember every Way
  // a refill has taken since the held response was accepted and drop the
  // store's write into that Way - the line it hit is gone by then.
  val refill_take = (0 until WayCount).map(w =>
    refill_write && io.refill_way === w.U(WayWidth.W))
  val store_clash = RegInit(VecInit(Seq.fill(WayCount)(false.B)))

  // Tag comparison of every Way, in parallel.
  val req_tag = tag(io.req_addr)
  val way_match = VecInit((0 until WayCount).map { w =>
    tag_ready && tagRam(w).io.doutb(TagWidth) &&
    tagRam(w).io.doutb(TagWidth - 1, 0) === req_tag
  })
  // Collision override: the read of the Way that was written is undefined, so
  // replace its result with "this request is the word that was just filled".
  val collision_way = VecInit((0 until WayCount).map { w =>
    refill_read_collision_q && refill_read_way_q === w.U(WayWidth.W)
  })
  val raw_hit_vec = VecInit((0 until WayCount).map { w =>
    Mux(collision_way(w), refill_read_same_word_q, way_match(w))
  })
  // 2:1 Way mux on the RAM output.  The forwarded word replaces the Way that
  // was written in the collision cycle.
  val way_data = VecInit((0 until WayCount).map { w =>
    Mux(collision_way(w), refill_read_data_q, dataRam(w).io.doutb)
  })

  // Replacement: an invalid Way if there is one, else the Way after the most
  // recently used Way (bi-state LRU).
  val way_valid = VecInit((0 until WayCount).map(w => tagRam(w).io.doutb(TagWidth)))
  val victim_way =
    if (WayCount == 1) {
      0.U(WayWidth.W)
    } else {
      val invalid_way = VecInit(way_valid.map(v => !v))
      val mru_way = lruRam.io.doutb
      val next_way = Mux(mru_way === (WayCount - 1).U(WayWidth.W),
                         0.U(WayWidth.W), mru_way + 1.U)
      Mux(invalid_way.asUInt.orR, PriorityEncoder(invalid_way.asUInt), next_way)
    }

  // A long-latency instruction can freeze a request in Ls1 after its Iss
  // lookup has already completed.  Preserve that lookup result (hit vector,
  // word and Victim) while Ls1 is held; the RAM addresses themselves continue
  // to follow Iss unconditionally.
  val held_req_valid = RegInit(false.B)
  val held_req_hit_vec = Reg(Vec(WayCount, Bool()))
  val held_req_data = Reg(UInt(MEM_DATA_WIDTH.W))
  val held_req_victim = Reg(UInt(WayWidth.W))

  val req_hit_vec = VecInit((0 until WayCount).map { w =>
    Mux(held_req_valid, held_req_hit_vec(w), raw_hit_vec(w))
  })
  val req_hit = req_hit_vec.asUInt.orR
  // Priority over Ways: a duplicate (if it ever happens) always resolves to the
  // lowest Way for both the hit and the data, so the two can never disagree.
  val hit_way = PriorityEncoder(req_hit_vec.asUInt)
  val req_victim = Mux(held_req_valid, held_req_victim, victim_way)
  io.req_way := req_victim

  // resp_valid is the only control bit here; the rest is payload that is
  // rewritten whenever io.req_valid fires, so it needs no reset.
  val resp_valid = RegInit(false.B)
  val resp_hit = Reg(Bool())
  val resp_hit_vec = Reg(Vec(WayCount, Bool()))
  val resp_addr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val resp_write = Reg(Bool())
  val resp_wdata = Reg(UInt(MEM_DATA_WIDTH.W))
  val resp_bytes = Reg(UInt(2.W))

  // A cache write and the next synchronous read may target the same word.
  // Forward the complete merged word so the inferred RAM's read-during-write
  // mode cannot expose stale or undefined data.
  val write_fwd_valid = RegInit(false.B)
  val write_fwd_addr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val write_fwd_data = Reg(UInt(MEM_DATA_WIDTH.W))
  val resp_data = Reg(UInt(MEM_DATA_WIDTH.W))

  val byte_mask = MuxLookup(resp_addr(1, 0), "h000000ff".U)(Seq(
    0.U -> "h000000ff".U,
    1.U -> "h0000ff00".U,
    2.U -> "h00ff0000".U,
    3.U -> "hff000000".U
  ))
  val half_mask = Mux(resp_addr(1), "hffff0000".U, "h0000ffff".U)
  val store_mask = MuxLookup(resp_bytes, "hffffffff".U)(Seq(
    MEM_BYTE -> byte_mask,
    MEM_HALF -> half_mask,
    MEM_WORD -> "hffffffff".U
  ))

  val byte_wdata = MuxLookup(resp_addr(1, 0), resp_wdata)(Seq(
    0.U -> Cat(0.U(24.W), resp_wdata(7, 0)),
    1.U -> Cat(0.U(16.W), resp_wdata(7, 0), 0.U(8.W)),
    2.U -> Cat(0.U(8.W), resp_wdata(7, 0), 0.U(16.W)),
    3.U -> Cat(resp_wdata(7, 0), 0.U(24.W))
  ))
  val half_wdata = Mux(resp_addr(1),
    Cat(resp_wdata(15, 0), 0.U(16.W)),
    Cat(0.U(16.W), resp_wdata(15, 0)))
  val shifted_wdata = MuxLookup(resp_bytes, resp_wdata)(Seq(
    MEM_BYTE -> byte_wdata,
    MEM_HALF -> half_wdata,
    MEM_WORD -> resp_wdata
  ))
  val merged_store_data = (resp_data & ~store_mask) | (shifted_wdata & store_mask)

  val store_write = resp_valid && io.resp_fire && resp_write && resp_hit
  val current_store_fwd = store_write && sameWord(resp_addr, io.req_addr)
  val previous_store_fwd = write_fwd_valid && sameWord(write_fwd_addr, io.req_addr)
  val lookup_req_data = Mux(previous_store_fwd, write_fwd_data, way_data(hit_way))
  val raw_req_data = Mux(current_store_fwd, merged_store_data, lookup_req_data)
  // A store completing when the stall is released is newer than the saved RAM
  // word and therefore retains forwarding priority.
  val req_data = Mux(held_req_valid, held_req_data, raw_req_data)

  when(io.req_valid) {
    for (w <- 0 until WayCount) {
      store_clash(w) := refill_take(w) && refill_index === index(io.req_addr)
    }
  }.otherwise {
    when(resp_valid) {
      for (w <- 0 until WayCount) {
        when(refill_take(w) && refill_index === index(resp_addr)) {
          store_clash(w) := true.B
        }
      }
    }
  }

  when(!io.req_present || io.req_valid) {
    held_req_valid := false.B
  }.elsewhen(!held_req_valid) {
    held_req_valid := true.B
    held_req_hit_vec := raw_hit_vec
    held_req_data := raw_req_data
    held_req_victim := victim_way
  }

  when(io.req_valid) {
    resp_valid := true.B
    resp_hit := req_hit
    resp_hit_vec := req_hit_vec
    resp_addr := io.req_addr
    resp_write := io.req_write
    resp_wdata := io.req_wdata
    resp_bytes := io.req_bytes
    resp_data := req_data
  }.elsewhen(io.resp_fire) {
    resp_valid := false.B
  }

  // A remote store invalidates the whole Set (every Way).  Clearing the Set
  // (rather than comparing the remote tag) keeps the invalidate path to one
  // tag-RAM write per Way and cannot leave a stale alias behind.
  inv_write := tag_ready && io.coh.inv_valid

  // Do not install a line if any L2 write was accepted after this load left
  // L1.  The load itself may still return the older value (it was ordered
  // before that write), but the stale line must not become cached.  An
  // invalidate in the same cycle owns the directory write port, so the refill
  // is dropped instead (dropping a fill is always safe).
  val refill_epoch_ok = io.refill_epoch === io.coh.epoch
  refill_write := tag_ready && io.refill_valid && !store_write &&
                  !inv_write && refill_epoch_ok

  val tag_waddr = Mux(tag_init_busy, tag_init_index,
    Mux(inv_write, inv_index, refill_index))
  val tag_wdata = Mux(tag_init_busy || inv_write, 0.U((TagWidth + 1).W),
    Cat(true.B, tag(io.refill_addr)))
  val data_waddr = Mux(store_write, index(resp_addr), refill_index)
  val data_wdata = Mux(store_write, merged_store_data, io.refill_data)

  for (w <- 0 until WayCount) {
    val t = tagRam(w)
    t.io.clka := clock
    t.io.wea := tag_init_busy || inv_write || refill_take(w)
    t.io.addra := tag_waddr
    t.io.dina := tag_wdata
    t.io.clkb := clock
    t.io.addrb := lookup_index

    val d = dataRam(w)
    d.io.clka := clock
    d.io.wea := (store_write && resp_hit_vec(w) && !store_clash(w)) || refill_take(w)
    d.io.addra := data_waddr
    d.io.dina := data_wdata
    d.io.clkb := clock
    d.io.addrb := lookup_index
  }

  // Replacement state: the Way of this Set used most recently.  A hit updates
  // it when the request is accepted, a refill when the word is installed.
  // Losing one of two same-cycle updates only affects replacement quality.
  val hit_lru_update = io.req_valid && req_hit
  lruRam.io.clka := clock
  lruRam.io.wea := tag_init_busy || refill_write || hit_lru_update
  lruRam.io.addra := Mux(tag_init_busy, tag_init_index,
    Mux(refill_write, refill_index, index(io.req_addr)))
  lruRam.io.dina := Mux(tag_init_busy, 0.U(WayWidth.W),
    Mux(refill_write, io.refill_way, hit_way))
  lruRam.io.clkb := clock
  lruRam.io.addrb := lookup_index

  write_fwd_valid := store_write
  when(store_write) {
    write_fwd_addr := resp_addr
    write_fwd_data := merged_store_data
  }

  io.resp_hit := resp_valid && resp_hit
  io.resp_data := resp_data

  if (CONFIG_SIMULATION) {
    val DPIC = Module(new DCache_DPIC)
    DPIC.io.clk := clock
    DPIC.io.rst := reset
    DPIC.io.request := io.req_valid
    DPIC.io.write := io.req_write
    DPIC.io.hit := req_hit
  }
}

class DCacheData_BRAM(indexWidth: Int) extends BlackBox {
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

class DCacheTag_BRAM(indexWidth: Int, tagWidth: Int) extends BlackBox {
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

class DCacheLru_BRAM(indexWidth: Int, wayWidth: Int) extends BlackBox {
  override def desiredName = "DCacheLru_BRAM"

  val io = IO(new Bundle {
    val clka = Input(Clock())
    val wea = Input(Bool())
    val addra = Input(UInt(indexWidth.W))
    val dina = Input(UInt(wayWidth.W))
    val clkb = Input(Clock())
    val addrb = Input(UInt(indexWidth.W))
    val doutb = Output(UInt(wayWidth.W))
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
