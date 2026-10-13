package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import ALUParams._

// Core-side queue for stores whose address is known early but whose data is
// resolved in Ex4.  Entries are kept oldest first so a lookup can visit them
// in program order and let the youngest matching store win for each byte.
class CoreStoreBuffer extends Module {
  private val Depth = CONFIG_STORE_BUFFER_DEPTH
  private val CountWidth = log2Ceil(Depth + 1)
  private val IndexWidth = math.max(1, log2Ceil(Depth))
  private val CacheMetaWidth = MEM_DATA_WIDTH + 1

  require(Depth > 0, "core store buffer must contain at least one entry")

  val io = IO(new Bundle {
    val enq = Flipped(Decoupled(new StoreCommitPayload))
    val deq = Decoupled(new StoreCommitPayload)

    val lookup_valid = Input(Bool())
    val lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val forward_mask = Output(UInt(4.W))
    val forward_data = Output(UInt(MEM_DATA_WIDTH.W))

    val empty = Output(Bool())
    val full = Output(Bool())
  })

  val addr = Reg(Vec(Depth, UInt(MEM_ADDR_WIDTH.W)))
  val data = Reg(Vec(Depth, UInt(MEM_DATA_WIDTH.W)))
  val bytes = Reg(Vec(Depth, UInt(2.W)))
  val cacheMeta = Mem(Depth, UInt(CacheMetaWidth.W))
  val cacheMetaHead = RegInit(0.U(IndexWidth.W))
  val cacheMetaTail = RegInit(0.U(IndexWidth.W))
  val count = RegInit(0.U(CountWidth.W))

  private def nextMetaIndex(index: UInt): UInt = {
    if (Depth == 1) {
      0.U
    } else if (isPow2(Depth)) {
      index + 1.U
    } else {
      Mux(index === (Depth - 1).U, 0.U, index + 1.U)
    }
  }

  io.empty := count === 0.U
  io.full := count === Depth.U
  io.enq.ready := !io.full
  io.deq.valid := !io.empty
  io.deq.bits.addr := addr(0)
  io.deq.bits.data := data(0)
  io.deq.bits.bytes := bytes(0)
  val deqCacheMeta = cacheMeta.read(cacheMetaHead)
  io.deq.bits.cache_hit := deqCacheMeta(CacheMetaWidth - 1)
  io.deq.bits.cache_data := deqCacheMeta(MEM_DATA_WIDTH - 1, 0)

  val enq = io.enq.fire
  val deq = io.deq.fire

  when(deq) {
    for (entry <- 0 until Depth - 1) {
      addr(entry) := addr(entry + 1)
      data(entry) := data(entry + 1)
      bytes(entry) := bytes(entry + 1)
    }
    cacheMetaHead := nextMetaIndex(cacheMetaHead)
  }

  val enqIndex = Mux(deq, count - 1.U, count)
  when(enq) {
    if (Depth == 1) {
      addr(0) := io.enq.bits.addr
      data(0) := io.enq.bits.data
      bytes(0) := io.enq.bits.bytes
    } else {
      addr(enqIndex(IndexWidth - 1, 0)) := io.enq.bits.addr
      data(enqIndex(IndexWidth - 1, 0)) := io.enq.bits.data
      bytes(enqIndex(IndexWidth - 1, 0)) := io.enq.bits.bytes
    }
    cacheMeta.write(cacheMetaTail,
      Cat(io.enq.bits.cache_hit, io.enq.bits.cache_data))
    cacheMetaTail := nextMetaIndex(cacheMetaTail)
  }

  switch(Cat(enq, deq)) {
    is("b10".U) { count := count + 1.U }
    is("b01".U) { count := count - 1.U }
  }

  private def byteEnable(storeAddr: UInt, storeBytes: UInt): UInt =
    MuxLookup(storeBytes, 0.U(4.W))(Seq(
      MEM_BYTE -> UIntToOH(storeAddr(1, 0), 4),
      MEM_HALF -> Mux(storeAddr(1), "b1100".U, "b0011".U),
      MEM_WORD -> "b1111".U
    ))

  private def wordData(storeData: UInt, storeBytes: UInt): UInt =
    MuxLookup(storeBytes, 0.U(MEM_DATA_WIDTH.W))(Seq(
      MEM_BYTE -> Fill(4, storeData(7, 0)),
      MEM_HALF -> Fill(2, storeData(15, 0)),
      MEM_WORD -> storeData
    ))

  var mergedMask = 0.U(4.W)
  var mergedData = 0.U(MEM_DATA_WIDTH.W)
  for (entry <- 0 until Depth) {
    val sameWord = addr(entry)(MEM_ADDR_WIDTH - 1, 2) ===
      io.lookup_addr(MEM_ADDR_WIDTH - 1, 2)
    val hit = io.lookup_valid && entry.U < count && sameWord
    val entryMask = Mux(hit, byteEnable(addr(entry), bytes(entry)), 0.U)
    val bitMask = FillInterleaved(8, entryMask)
    mergedData = (mergedData & ~bitMask) |
      (wordData(data(entry), bytes(entry)) & bitMask)
    mergedMask = mergedMask | entryMask
  }

  io.forward_mask := mergedMask
  io.forward_data := mergedData

  assert(count <= Depth.U, "core store buffer count overflow")
}
