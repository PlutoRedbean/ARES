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
  // Only 0x8010_0000-0x8013_ffff is cacheable, so bits 31:18 are constant.
  private val TagWidth = 18 - IndexWidth - 2

  require(CONFIG_DCACHE_SIZE_KB > 0 &&
          (CONFIG_DCACHE_SIZE_KB & (CONFIG_DCACHE_SIZE_KB - 1)) == 0,
    "D-cache size must be a positive power of two")
  require(SizeBytes % BytesPerEntry == 0,
    "D-cache size must contain a whole number of entries")
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

    val resp_fire = Input(Bool())
    val resp_hit = Output(Bool())
    val resp_data = Output(UInt(MEM_DATA_WIDTH.W))

    val refill_valid = Input(Bool())
    val refill_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val refill_data = Input(UInt(MEM_DATA_WIDTH.W))

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

  // Iss continuously drives both BRAM read addresses. lookup_valid only
  // qualifies the request; it must not add hit/interlock logic to the BRAM
  // address path. The tag output is compared in Ls1 and the data output is
  // registered once more for use in Ls2.
  val data = Module(new DCacheData_BRAM(IndexWidth))
  val tags = Module(new DCacheTag_BRAM(IndexWidth, TagWidth))

  // Keep the valid bit beside the tag in BRAM.  A reset cannot clear BRAM
  // contents directly, so invalidate one entry per cycle and keep the cache
  // disabled for one extra cycle to drain the final READ_FIRST result.
  val tag_init_busy = RegInit(true.B)
  val tag_init_index = RegInit(0.U(IndexWidth.W))
  val tag_ready = RegNext(!tag_init_busy, false.B)
  when(tag_init_busy) {
    when(tag_init_index === (EntryCount - 1).U(IndexWidth.W)) {
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

  val refill_read_collision = refill_write && io.lookup_valid &&
                              lookup_index === refill_index
  val refill_read_collision_q = RegNext(refill_read_collision, false.B)
  val refill_read_same_word_q = RegEnable(
    tag(io.lookup_addr) === tag(io.refill_addr), false.B,
    refill_read_collision)
  // Capture every refill.  The registered collision bit still determines
  // whether this data is consumed on the following cycle.
  val refill_read_data_q = RegEnable(
    io.refill_data, 0.U(MEM_DATA_WIDTH.W), refill_write)

  val req_tag = tag(io.req_addr)
  val tag_req_hit = tag_ready && tags.io.doutb(TagWidth) &&
                    tags.io.doutb(TagWidth - 1, 0) === req_tag
  val raw_req_hit = Mux(
    refill_read_collision_q, refill_read_same_word_q, tag_req_hit)

  val resp_valid = RegInit(false.B)
  val resp_hit = RegInit(false.B)
  val resp_addr = RegInit(0.U(MEM_ADDR_WIDTH.W))
  val resp_write = RegInit(false.B)
  val resp_wdata = RegInit(0.U(MEM_DATA_WIDTH.W))
  val resp_bytes = RegInit(MEM_NONE)

  // A cache write and the next synchronous read may target the same word.
  // Forward the complete merged word so the inferred RAM's read-during-write
  // mode cannot expose stale or undefined data.
  val write_fwd_valid = RegInit(false.B)
  val write_fwd_addr = Reg(UInt(MEM_ADDR_WIDTH.W))
  val write_fwd_data = Reg(UInt(MEM_DATA_WIDTH.W))
  val resp_data = RegInit(0.U(MEM_DATA_WIDTH.W))

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
  val lookup_req_data = Mux(
    refill_read_collision_q && refill_read_same_word_q,
    refill_read_data_q,
    Mux(previous_store_fwd, write_fwd_data, data.io.doutb))
  val raw_req_data = Mux(
    current_store_fwd, merged_store_data, lookup_req_data)

  // A long-latency instruction can freeze a request in Ls1 after its Iss
  // lookup has already completed.  Preserve that lookup result while Ls1 is
  // held; the BRAM address itself continues to follow Iss unconditionally.
  val held_req_valid = RegInit(false.B)
  val held_req_hit = RegInit(false.B)
  val held_req_data = RegInit(0.U(MEM_DATA_WIDTH.W))
  val req_hit = Mux(held_req_valid, held_req_hit, raw_req_hit)
  // A store completing when the stall is released is newer than the saved
  // BRAM word and therefore retains forwarding priority.
  val req_data = Mux(
    current_store_fwd,
    merged_store_data,
    Mux(held_req_valid, held_req_data, lookup_req_data))

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
    resp_addr := io.req_addr
    resp_write := io.req_write
    resp_wdata := io.req_wdata
    resp_bytes := io.req_bytes
    resp_data := req_data
  }.elsewhen(io.resp_fire) {
    resp_valid := false.B
  }

  // A remote store invalidates the direct-mapped tag.  Clearing the whole
  // index (rather than comparing the remote tag) keeps the invalidate path
  // to a single tag-RAM write and cannot leave a stale alias behind.
  inv_write := tag_ready && io.coh.inv_valid

  // Do not install a line if any L2 write was accepted after this load left
  // L1.  The load itself may still return the older value (it was ordered
  // before that write), but the stale line must not become cached.
  val refill_epoch_ok = io.refill_epoch === io.coh.epoch
  refill_write := tag_ready && io.refill_valid && !store_write && refill_epoch_ok
  val cache_write = store_write || refill_write
  val cache_write_index = Mux(store_write, index(resp_addr), refill_index)
  val cache_write_data = Mux(store_write, merged_store_data, io.refill_data)

  data.io.clka := clock
  data.io.wea := cache_write
  data.io.addra := cache_write_index
  data.io.dina := cache_write_data
  data.io.clkb := clock
  data.io.addrb := lookup_index

  tags.io.clka := clock
  tags.io.wea := tag_init_busy || inv_write || refill_write
  tags.io.addra := Mux(tag_init_busy, tag_init_index,
    Mux(inv_write, inv_index, refill_index))
  tags.io.dina := Mux(tag_init_busy,
    0.U((TagWidth + 1).W),
    Mux(inv_write, 0.U((TagWidth + 1).W), Cat(true.B, tag(io.refill_addr))))
  tags.io.clkb := clock
  tags.io.addrb := lookup_index

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

class DCache_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val request = Input(Bool())
    val write = Input(Bool())
    val hit = Input(Bool())
  })
}
