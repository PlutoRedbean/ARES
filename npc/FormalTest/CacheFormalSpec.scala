package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import AxiParams._

class Cache(
  val CACHE_BYTE_WIDTH : Int = 2,
  val CACHE_BLOCK_WIDTH: Int = 4,
  val CACHE_BYTE       : Int = 4,
  val CACHE_BLOCK      : Int = 16
) extends Module {
  val io = IO(new Bundle{
    val flush     = Input(Bool())
    val raddr     = Input(UInt(AXI_ADDR_WIDTH.W))
    val bus_data  = Input(UInt(AXI_DATA_WIDTH.W))
    val rdata     = Output(UInt(AXI_DATA_WIDTH.W))
    val len       = Output(UInt(8.W))
    val request   = Input(Bool())
    val last      = Input(Bool())
    val bus_valid = Input(Bool())
    val hit       = Output(Bool())
  })

  object State extends ChiselEnum {
    val IDLE, IS_HIT, READ = Value
  }
  import State._

  val TAG_WIDTH = AXI_ADDR_WIDTH - (CACHE_BYTE_WIDTH + CACHE_BLOCK_WIDTH)

  val state = RegInit(IDLE)
  val next = Wire(State())

  val tag    = Wire(UInt(TAG_WIDTH.W))
  val index  = Wire(UInt(CACHE_BLOCK_WIDTH.W))
  val offset = Wire(UInt((CACHE_BYTE_WIDTH-2).W))
  dontTouch(tag)
  dontTouch(index)
  dontTouch(offset)
  tag    := io.raddr(AXI_ADDR_WIDTH - 1, CACHE_BYTE_WIDTH + CACHE_BLOCK_WIDTH)
  index  := io.raddr(CACHE_BYTE_WIDTH + CACHE_BLOCK_WIDTH - 1, CACHE_BYTE_WIDTH)
  if (CACHE_BYTE_WIDTH > 2) {
    offset := io.raddr(CACHE_BYTE_WIDTH - 1, 2)
  } else {
    offset := 0.U
  }

  val wen = io.bus_valid

  val SUB_BLOCKS = CACHE_BYTE / 4
  val BURST_LENGTH = SUB_BLOCKS

  io.len := (BURST_LENGTH - 1).U

  val block_valid = RegInit(VecInit(Seq.fill(CACHE_BLOCK)(false.B)))
  val block_tag = Reg(Vec(CACHE_BLOCK, UInt(TAG_WIDTH.W)))
  val block = Reg(Vec(CACHE_BLOCK, Vec(SUB_BLOCKS, UInt(AXI_DATA_WIDTH.W))))

  io.hit := block_valid(index) & (block_tag(index) === tag)

  val burst_cnt = RegInit(0.U(log2Ceil(SUB_BLOCKS).W))

  when(wen) {
    block_tag(index) := tag
    block(index)(burst_cnt) := io.bus_data
    burst_cnt := burst_cnt + 1.U
  }

  val burst_done = io.bus_valid && io.last

  when(burst_done) {
    block_valid(index) := true.B
    burst_cnt := 0.U
  }

  when(io.flush) {
    block_valid.foreach(_ := false.B) 
  }

  val switch = Wire(Bool())
  switch := wen && burst_cnt === offset
  dontTouch(switch)

  io.rdata := Mux(switch, io.bus_data, block(index)(offset))

  next := MuxCase(IDLE, Seq(
    (state === IDLE)   -> Mux(io.request  , IS_HIT, IDLE),
    (state === IS_HIT) -> Mux(io.hit      , IDLE  , READ),
    (state === READ)   -> Mux(burst_done  , IDLE  , READ)
  ))
  state := next
/*
  if (CONFIG_SIMULATION) {
    val MAX_LEN = 7
    val dbg_state = Wire(UInt((MAX_LEN * 8).W))
    dontTouch(dbg_state)

    dbg_state := MuxCase(Func.str2UInt("UNKNOWN"  , MAX_LEN), Seq(
      (state === IDLE)   -> Func.str2UInt("IDLE"  , MAX_LEN),
      (state === IS_HIT) -> Func.str2UInt("IS_HIT", MAX_LEN),
      (state === READ)   -> Func.str2UInt("READ"  , MAX_LEN)
    ))
  }
*/
  // ========================
  // 形式化验证断言
  // ========================
  when(reset.asBool === false.B) {
    // 断言1：flush 之后所有有效位必须为 0
    when(RegNext(io.flush)) {
      assert(block_valid.asUInt === 0.U, "All cache entries should be invalid after flush")
    }

    // 断言2：READ 状态不会死锁
    assert(!(state === READ && !io.bus_valid && !io.last), "READ state should not deadlock")

    // 断言3：缺失时不能输出命中
    when(state === READ) {
      assert(!io.hit, "Should not assert hit on cache miss")
    }

    // 断言4：状态机跳转必须合法（命中必须回空闲，未命中必须去读总线）
    when(state === IS_HIT && io.hit) {
      assert(next === IDLE, "Hit must return to IDLE")
    }
    when(state === IS_HIT && !io.hit) {
      assert(next === READ, "Miss must go to READ")
    }

    // 断言5：只有 READ 状态才能接收总线数据
    when(io.bus_valid && state =/= READ) {
      assert(false.B, "bus valid only allowed in READ")
    }

    // 断言6：突发计数器不能溢出
    assert(burst_cnt < SUB_BLOCKS.U, "burst counter overflow")
  }
}

// ======================== 形式化验证测试 ========================
// for Formal Verification
import org.scalatest.flatspec.AnyFlatSpec
import chiseltest.formal._
import chiseltest._

/**
 * 形式化验证顶层：黑盒验证 Cache
 * 核心思想：Cache 对外行为必须 = 零延迟理想内存（等价性验证）
 */
class CacheFormalTop extends Module {
  // 验证输入接口
  val io = IO(new Bundle {
    val flush     = Input(Bool())
    val raddr     = Input(UInt(AXI_ADDR_WIDTH.W))
    val bus_data  = Input(UInt(AXI_DATA_WIDTH.W))
    val request   = Input(Bool())
    val last      = Input(Bool())
    val bus_valid = Input(Bool())
  })

  // ======================== 1. 待测设备 DUT ========================
  val dut = Module(new Cache())
  // 信号全连接
  dut.io.flush     := io.flush
  dut.io.raddr     := io.raddr
  dut.io.bus_data  := io.bus_data
  dut.io.request   := io.request
  dut.io.last      := io.last
  dut.io.bus_valid := io.bus_valid

  // ======================== 2. 参考模型 REF（零延迟理想内存） ========================
  val REF_MEM_SIZE = 1024                  // 参考内存大小
  val refMem       = Mem(REF_MEM_SIZE, UInt(AXI_DATA_WIDTH.W))// 理想内存
  val bus_word_addr = io.raddr >> 2        // 字对齐地址（忽略低2位）

  // 关键：总线回填时，同步写入参考内存（保证 DUT 与 REF 数据一致）
  when(io.bus_valid) {
    refMem(bus_word_addr) := io.bus_data
  }

  // ======================== 3. 形式化约束（限制合法输入） ========================
  // 约束1：last 必须和数据有效同时出现
  assume(!io.last || io.bus_valid)
  // 约束2：request 不能连续发送（单周期脉冲）
  assume(!(io.request && RegNext(io.request)))

  // ======================== 4. 请求同步寄存器（对齐 DUT 与 REF 时序） ========================
  // 锁存请求地址（请求发出后地址保持不变）
  val req_addr = RegEnable(io.raddr, 0.U, io.request)
  val req_word_addr = req_addr >> 2
  // 标记：是否有未完成的读请求
  val req_pending = RegInit(false.B)

  // 收到请求：标记请求等待
  when(io.request) {
    req_pending := true.B
  }
  // 请求等待期间：地址不变、不接收新请求
  when(req_pending) {
    assume(io.raddr === req_addr)
    assume(!io.request)
  }

  // ======================== 5. 请求完成判断 ========================
  // 命中完成：请求发出后一拍 + 命中（数据已输出）
  val hit_complete = RegNext(io.request) && dut.io.hit
  // 缺失完成：总线突发最后一拍（回填完成）
  val miss_complete = dut.io.bus_valid && dut.io.last
  // 总完成信号：等待请求 +（命中完成 OR 缺失完成）
  val req_complete = (hit_complete || miss_complete) && req_pending

  // 请求完成：清除等待标记
  when(req_complete) {
    req_pending := false.B
  }

  // ======================== 6. 核心等价性断言（讲义最重要验证） ========================
  // 请求完成时：Cache 输出数据 必须 = 参考内存数据
	when(req_complete) {
		assert(dut.io.rdata === refMem(req_word_addr), 
		  "FORMAL EQUIVALENCE FAIL: Cache data does not match reference memory")
	}

	// 补充断言1：总线回填最后一拍数据必须一致（英文）
	when(dut.io.bus_valid && dut.io.last) {
		assert(dut.io.rdata === io.bus_data, 
		  "REFILL DATA FAIL: Last beat data does not match bus data")
	}

	// 补充断言2：命中时数据必须正确（英文）
	when(RegNext(io.request) && dut.io.hit) {
		assert(dut.io.rdata === refMem(io.raddr >> 2), 
		  "HIT DATA FAIL: Cache hit returned wrong data")
	}
}

// ==============================
// 形式化验证启动类
// ==============================
class CacheFormalSpec extends AnyFlatSpec with ChiselScalatestTester with Formal {
  "Cache" should "pass formal verification" in {
    verify(new CacheFormalTop(), Seq(
      BoundedCheck(30),
      BtormcEngineAnnotation,
//      WriteVcdAnnotation // 不知道作用，先保留
    ))
  }
}

