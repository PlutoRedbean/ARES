package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import ALUParams._
import BRUParams._
import MDUParams._
import CSRParams._
import DPUParams._
import Func._
import OperandStats._
import StoreForward._

// Slot 1 owns an integer ALU and accesses group-level shared resources.  The
// side pipeline mirrors the scalar Ex1..Ex4 metadata flow so a shared LSU
// response can be returned to either lane without changing retirement order.
class GroupIntegerLanes extends Module {
  val io = IO(new Bundle {
    val inValid = Input(Bool())
    val in = Input(new IS_EX_Group)
    val lane0Value = Input(UInt(REG_DATA_WIDTH.W))
    val branchPcNext = Input(UInt(PC_DATA_WIDTH.W))
    val flush = Input(Bool())
    val stall = Input(Bool())
    val holdEx2 = Input(Bool())

    val lsuEx2Lane =
      Input(UInt(log2Ceil(DualIssue.Width).W))
    val lsuEx2Valid = Input(Bool())
    val lsuEx2CacheHit = Input(Bool())
    val lsuEx2Rdata = Input(UInt(MEM_DATA_WIDTH.W))
    val lsuEx2StoreCacheHit = Input(Bool())
    val lsuEx2StoreCacheData = Input(UInt(MEM_DATA_WIDTH.W))
    val lsuFastLane =
      Input(UInt(log2Ceil(DualIssue.Width).W))
    val lsuLoadValid = Input(Bool())
    val lsuFastValid = Input(Bool())
    val lsuFastRd = Input(UInt(GPR_ADDR_WIDTH.W))
    val lsuFastAddr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lsuFastBytes = Input(UInt(2.W))
    val lsuFastSign = Input(Bool())
    val lsuSlowLane =
      Input(UInt(log2Ceil(DualIssue.Width).W))
    val lsuSlowValid = Input(Bool())
    val lsuSlowRd = Input(UInt(GPR_ADDR_WIDTH.W))
    val lsuSlowAddr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lsuSlowBytes = Input(UInt(2.W))
    val lsuSlowSign = Input(Bool())
    val lsuCacheHit = Input(Bool())
    val lsuRdataFast = Input(UInt(MEM_DATA_WIDTH.W))
    val lsuRdataSlow = Input(UInt(MEM_DATA_WIDTH.W))
    val lsuStoreCacheHit = Input(Bool())
    val lsuStoreCacheData = Input(UInt(MEM_DATA_WIDTH.W))

    val mainEx2Valid = Input(Bool())
    val mainEx2Rd = Input(new ProducerBundle)
    val mainEx2Value = Input(UInt(REG_DATA_WIDTH.W))
    val mainEx3Valid = Input(Bool())
    val mainEx3Rd = Input(new ProducerBundle)
    val mainEx3Value = Input(UInt(REG_DATA_WIDTH.W))
    val mainEx4Valid = Input(Bool())
    val mainEx4Rd = Input(new ProducerBundle)
    val mainEx4Value = Input(UInt(REG_DATA_WIDTH.W))
    val wb = Input(new ForwardProducerGroup)

    val ex1 = Output(new ForwardProducerGroup)
    val ex2 = Output(new ForwardProducerGroup)
    val ex3 = Output(new ForwardProducerGroup)
    val ex4 = Output(new ForwardProducerGroup)
    val ex4Payload = Output(new EX_WB_Group)
    val stores = Output(Vec(4, new StoreAddressBundle))
    val storeValid = Output(Bool())
    val store = Output(new StoreCommitPayload)
    val mulOut = Output(UInt(MUL_OUT_WIDTH.W))
    val mulbeOut = Output(UInt(REG_DATA_WIDTH.W))
    val flatBypass = Output(Bool())
    val holdEx1 = Output(Bool())
    val delayedBranchUpdate = Output(Bool())
    val delayedBranchUpdatePc = Output(UInt(PC_DATA_WIDTH.W))
    val delayedBranchResolve = Output(new BranchResolveBundle)
    val frpEvent = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(new FrpExecutionEventBundle)) else None
    val frpDelayedEvent = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(new FrpExecutionEventBundle)) else None
  })

  private def stageGroup(
      mainValid: Bool,
      mainRd: ProducerBundle,
      mainValue: UInt,
      sideValid: Bool,
      sideRd: ProducerBundle,
      sideValue: UInt): ForwardProducerGroup = {
    val result =
      WireDefault(0.U.asTypeOf(new ForwardProducerGroup))
    result.laneValid :=
      Mux(mainValid, "b01".U, 0.U) |
        Mux(sideValid, "b10".U, 0.U)
    result.rd(0) := mainRd
    result.value(0) := mainValue
    result.rd(1) := sideRd
    result.value(1) := sideValue
    result
  }

  private def advanceLate(
      operand: LateOperandStateBundle,
      ex2: ForwardProducerGroup,
      ex3: ForwardProducerGroup,
      ex4: ForwardProducerGroup,
      wb: ForwardProducerGroup): LateOperandStateBundle =
    LateOperandForward.advance(operand, ex2, ex3, ex4, wb)

  private def storeAddress(
      valid: Bool,
      addr: UInt,
      bytes: UInt,
      wen: Bool,
      lateData: LateOperandStateBundle,
      stage: Int): StoreAddressBundle = {
    val result =
      WireDefault(0.U.asTypeOf(new StoreAddressBundle))
    result.valid := valid && wen && bytes =/= MEM_NONE
    result.addrValid := result.valid
    result.addr := addr
    result.bytes := bytes
    result.byteMask := byteEnable(addr, bytes)
    result.data := wordData(lateData.value, bytes)
    result.dataValid := result.valid && !lateData.token.pending
    result.stage := stage.U
    result.lane := 1.U
    result
  }

  val ex2Group = Wire(new ForwardProducerGroup)
  val ex3Group = Wire(new ForwardProducerGroup)
  val ex4Group = Wire(new ForwardProducerGroup)

  val issued = io.in.lane(1)
  val ex1Present = io.inValid && io.in.laneValid(1)
  val ex1Valid = ex1Present && !io.flush

  private def forwardSource(
      operand: LateOperandBundle): Ex1ForwardSource =
    LateOperandForward.select(
      operand, ex2Group, ex3Group, ex4Group, io.wb)

  private def forwardedValue(
      base: UInt,
      operand: LateOperandBundle,
      source: Ex1ForwardSource): UInt =
    // The late token is the registered forwarding select.  Availability may
    // hold/replay the group, but it must not select the Ex1 operand data.
    Mux(operand.pending, source.value, base)

  val rs1Source = forwardSource(issued.rs1_late)
  val rs2Source = forwardSource(issued.rs2_late)
  val rs1Value =
    forwardedValue(
      Mux(issued.flat_rs1, io.lane0Value, issued.rs1_val),
      issued.rs1_late, rs1Source)
  val rs2Value =
    forwardedValue(
      Mux(issued.flat_rs2, io.lane0Value, issued.rs2_val),
      issued.rs2_late, rs2Source)

  val sideAluDin1 =
    forwardedValue(issued.alu_din1, issued.rs1_late, rs1Source)
  val sideAluDin2 =
    forwardedValue(issued.alu_din2, issued.rs2_late, rs2Source)
  val skewEx1 =
    ex1Valid && (issued.flat_rs1 || issued.flat_rs2) &&
      issued.mem_bytes === MEM_NONE &&
      issued.mdu_ctrl === MDU_NONE &&
      issued.bru_ctrl === BRU_NONE &&
      !issued.jump &&
      issued.csr_ctrl === CSR_NONE &&
      issued.envir === ENVIR_NORMAL

  val alu = Module(new ALU)
  alu.io.alu_ctrl := issued.alu_ctrl
  alu.io.din1 := sideAluDin1
  alu.io.din2 := sideAluDin2

  // Slot 1 has an independent fixed-latency MAC.  Its clock enable follows
  // the side metadata pipeline exactly so the result reaches WB with the
  // matching instruction even when an older backend stall freezes the group.
  val mul = Module(new MUL)
  mul.io.mdu_ctrl := issued.mdu_ctrl
  mul.io.enable := !io.stall
  mul.io.din1 := rs1Value
  mul.io.din2 := rs2Value
  io.mulOut := mul.io.dout
  io.mulbeOut := mul.io.mulbeDout

  val ex1Bits =
    WireDefault(0.U.asTypeOf(new EX1_EX2_Payload))
  val slot1Control =
    issued.bru_ctrl =/= BRU_NONE || issued.jump
  ex1Bits.pc := issued.pc
  ex1Bits.pc_next :=
    Mux(slot1Control, io.branchPcNext, issued.snpc)
  ex1Bits.addr := issued.addr
  ex1Bits.mem_wdata := rs2Value
  ex1Bits.mem_wen := issued.mem_wen
  ex1Bits.late_data.token := issued.rs2_late
  // Store data becomes an architectural payload only after the Ex1 source
  // mux.  The Issue late bundle remains metadata-only, including the
  // dedicated same-group ALU0-to-ALU1 forwarding case.
  ex1Bits.late_data.value := rs2Value
  ex1Bits.reg_data := alu.io.dout
  ex1Bits.mdu_ctrl := issued.mdu_ctrl
  ex1Bits.L_sign := issued.L_sign
  ex1Bits.mem_bytes := issued.mem_bytes
  ex1Bits.rd_addr := issued.rd_addr
  ex1Bits.rd_wen := issued.rd_wen
  ex1Bits.is_load :=
    issued.mem_bytes =/= MEM_NONE && !issued.mem_wen
  ex1Bits.csr_ctrl := CSR_NONE
  ex1Bits.csr_mask := 0.U
  ex1Bits.trap_pc := issued.pc
  ex1Bits.envir := ENVIR_NORMAL
  ex1Bits.when := issued.when

  val ex2Valid = RegInit(false.B)
  val ex2Bits =
    RegInit(0.U.asTypeOf(new EX1_EX2_Payload))
  val ex3Valid = RegInit(false.B)
  val ex3Bits =
    RegInit(0.U.asTypeOf(new EX2_EX3_Payload))
  val ex4Valid = RegInit(false.B)
  val ex4Bits =
    RegInit(0.U.asTypeOf(new EX3_EX4_Payload))
  val skewEx2Valid = RegInit(false.B)
  val skewEx2Din1 = RegInit(0.U(REG_DATA_WIDTH.W))
  val skewEx2Din2 = RegInit(0.U(REG_DATA_WIDTH.W))
  val skewEx2Op = RegInit(VecInit(
    Seq.fill(REG_DATA_WIDTH)(0.U(SideSkewALUCtrl.Width.W))))
  dontTouch(skewEx2Op)
  val skewEx3Valid = RegInit(false.B)
  val skewEx3Data = RegInit(0.U(REG_DATA_WIDTH.W))
  val skewAlu = Module(new SideSkewALU)
  skewAlu.io.op := skewEx2Op
  skewAlu.io.din1 := skewEx2Din1
  skewAlu.io.din2 := skewEx2Din2
  // Same-group load consumers are serialized in GroupIDU.  Keep the legacy
  // observation ports tied off, but do not retain a second ALU/BRU or local
  // replay state in the side lane for an unreachable execution mode.
  io.holdEx1 := false.B

  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    val event = io.frpEvent.get
    event.valid := ex1Valid && !io.stall
    event.rdWen := issued.rd_wen
    event.rdAddr := issued.rd_addr
    event.bitTest := issued.frp_bit_test.get
    event.bitState := rs1Value
    event.zeroBranch := issued.frp_zero_branch.get
    event.branchPc := issued.pc
    event.testReg := issued.frp_test_reg.get
    event.branchBeqz := issued.frp_branch_beqz.get

    val delayedEvent = io.frpDelayedEvent.get
    delayedEvent := 0.U.asTypeOf(new FrpExecutionEventBundle)
  }

  io.delayedBranchUpdate := false.B
  io.delayedBranchUpdatePc := 0.U
  io.delayedBranchResolve :=
    0.U.asTypeOf(new BranchResolveBundle)

  val sideEx2 = Module(new exu_ex2)
  sideEx2.io.in.valid := ex2Valid
  sideEx2.io.in.bits := ex2Bits
  sideEx2.io.out.ready := true.B
  val earlyOwner1 = io.lsuEx2Lane === 1.U
  sideEx2.io.cache_hit :=
    earlyOwner1 && io.lsuEx2Valid && io.lsuEx2CacheHit
  sideEx2.io.rdata_fast := io.lsuEx2Rdata
  sideEx2.io.store_cache_hit :=
    earlyOwner1 && io.lsuEx2Valid && io.lsuEx2StoreCacheHit
  sideEx2.io.store_cache_data := io.lsuEx2StoreCacheData

  val sideEx3 = Module(new exu_ex3)
  val sideEx3Input = WireDefault(ex3Bits)
  sideEx3Input.reg_data :=
    Mux(skewEx3Valid, skewEx3Data, ex3Bits.reg_data)
  sideEx3.io.in.valid := ex3Valid
  sideEx3.io.in.bits := sideEx3Input
  sideEx3.io.out.ready := true.B
  val fastOwner1 = io.lsuFastLane === 1.U
  sideEx3.io.cache_hit := fastOwner1 && io.lsuCacheHit
  sideEx3.io.rdata_fast := io.lsuRdataFast
  sideEx3.io.store_cache_hit :=
    fastOwner1 && io.lsuStoreCacheHit
  sideEx3.io.store_cache_data := io.lsuStoreCacheData

  val sideEx4 = Module(new exu_ex4)
  sideEx4.io.in.valid := ex4Valid
  sideEx4.io.in.bits := ex4Bits
  sideEx4.io.out.ready := true.B
  sideEx4.io.rdata_slow := Mux(
    io.lsuSlowValid && io.lsuSlowLane === 1.U,
    io.lsuRdataSlow,
    0.U)

  ex2Group := stageGroup(
    io.mainEx2Valid, io.mainEx2Rd, io.mainEx2Value,
    sideEx2.io.out.valid, sideEx2.io.rd, sideEx2.io.reg_val)
  ex3Group := stageGroup(
    io.mainEx3Valid, io.mainEx3Rd, io.mainEx3Value,
    sideEx3.io.out.valid, sideEx3.io.rd, sideEx3.io.reg_val)
  ex4Group := stageGroup(
    io.mainEx4Valid, io.mainEx4Rd, io.mainEx4Value,
    sideEx4.io.out.valid, sideEx4.io.rd, sideEx4.io.reg_val)

  val ex1Capture = WireDefault(ex1Bits)
  ex1Capture.late_data :=
    advanceLate(ex1Bits.late_data, ex2Group, ex3Group,
      ex4Group, io.wb)
  val ex2Capture = WireDefault(sideEx2.io.out.bits)
  ex2Capture.late_data :=
    advanceLate(sideEx2.io.out.bits.late_data, ex2Group,
      ex3Group, ex4Group, io.wb)
  val ex3Capture = WireDefault(sideEx3.io.out.bits)
  ex3Capture.late_data :=
    advanceLate(sideEx3.io.out.bits.late_data, ex2Group,
      ex3Group, ex4Group, io.wb)

  when(!io.stall) {
    ex4Valid := sideEx3.io.out.valid
    ex4Bits := ex3Capture
    when(io.holdEx2) {
      // Keep the store-conflicting group in Ex2, but let an older side-lane
      // Ex3 entry advance to Ex4 exactly once.
      ex3Valid := false.B
      skewEx3Valid := false.B
    }.otherwise {
      ex2Valid := ex1Valid
      ex2Bits := ex1Capture
      skewEx2Valid := skewEx1
      for (bit <- 0 until REG_DATA_WIDTH) {
        skewEx2Op(bit) := SideSkewALUCtrl.encode(issued.alu_ctrl)
      }
      skewEx2Din1 := Mux(issued.flat_rs1, io.lane0Value, sideAluDin1)
      skewEx2Din2 := Mux(issued.flat_rs2, io.lane0Value, sideAluDin2)
      ex3Valid := sideEx2.io.out.valid
      ex3Bits := ex2Capture
      skewEx3Valid := skewEx2Valid
      skewEx3Data := skewAlu.io.dout
    }
  }

  private def producer(
      valid: Bool,
      rd: ProducerBundle,
      value: UInt): ForwardProducerGroup = {
    val result =
      WireDefault(0.U.asTypeOf(new ForwardProducerGroup))
    result.laneValid := Mux(valid, "b10".U, 0.U)
    result.rd(1) := rd
    result.value(1) := value
    result
  }

  val ex1Rd = Wire(new ProducerBundle)
  ex1Rd.wen := issued.rd_wen
  ex1Rd.addr := issued.rd_addr
  ex1Rd.when := issued.when
  ex1Rd.producerType := producerType(
    issued.mem_bytes =/= MEM_NONE && !issued.mem_wen,
    issued.mdu_ctrl)
  io.ex1 := producer(ex1Present, ex1Rd, alu.io.dout)
  io.ex2 := producer(
    sideEx2.io.out.valid, sideEx2.io.rd, sideEx2.io.reg_val)
  io.ex3 := producer(
    sideEx3.io.out.valid, sideEx3.io.rd, sideEx3.io.reg_val)
  io.ex4 := producer(
    sideEx4.io.out.valid, sideEx4.io.rd, sideEx4.io.reg_val)

  io.ex4Payload :=
    0.U.asTypeOf(new EX_WB_Group)
  io.ex4Payload.laneValid :=
    Mux(sideEx4.io.out.valid, "b10".U, 0.U)
  io.ex4Payload.lane(1) := sideEx4.io.out.bits

  io.stores(0) := storeAddress(
    ex1Valid, issued.addr, issued.mem_bytes, issued.mem_wen,
    advanceLate(
      ex1Bits.late_data, ex2Group, ex3Group, ex4Group, io.wb),
    stage = 0)
  io.stores(1) := storeAddress(
    ex2Valid, ex2Bits.addr, ex2Bits.mem_bytes, ex2Bits.mem_wen,
    advanceLate(
      ex2Bits.late_data, ex2Group, ex3Group, ex4Group, io.wb),
    stage = 1)
  io.stores(2) := storeAddress(
    ex3Valid, ex3Bits.addr, ex3Bits.mem_bytes, ex3Bits.mem_wen,
    advanceLate(
      ex3Bits.late_data, ex2Group, ex3Group, ex4Group, io.wb),
    stage = 2)
  io.stores(3) := storeAddress(
    ex4Valid, ex4Bits.addr, ex4Bits.mem_bytes, ex4Bits.mem_wen,
    advanceLate(
      ex4Bits.late_data, ex2Group, ex3Group, ex4Group, io.wb),
    stage = 3)

  val ex4Late =
    advanceLate(ex4Bits.late_data, ex2Group, ex3Group,
      ex4Group, io.wb)
  io.storeValid :=
    ex4Valid && ex4Bits.mem_wen && ex4Bits.mem_bytes =/= MEM_NONE
  io.store.addr := ex4Bits.addr
  io.store.data := ex4Late.value
  io.store.bytes := ex4Bits.mem_bytes
  io.store.cache_hit := ex4Bits.store_cache_hit
  io.store.cache_data := ex4Bits.store_cache_data

  io.flatBypass :=
    io.inValid && io.in.laneValid(1) &&
      (issued.flat_rs1 || issued.flat_rs2)

  private def ex1SourceUsable(
      operand: LateOperandBundle,
      source: Ex1ForwardSource): Bool =
    source.valueAvailable ||
      (operand.loadSpec && operand.pending &&
        source.stage(WHR_IDX_EX2))

  when(ex1Valid && !io.stall &&
      issued.rs1_need === NEED_EX1 &&
      issued.rs1_late.pending) {
    assert(ex1SourceUsable(issued.rs1_late, rs1Source),
      "side Ex1 rs1 selected producer is not available")
  }
  when(ex1Valid && !io.stall &&
      issued.rs2_need === NEED_EX1 &&
      issued.rs2_late.pending) {
    assert(ex1SourceUsable(issued.rs2_late, rs2Source),
      "side Ex1 rs2 selected producer is not available")
  }

  when(skewEx1 && !io.stall) {
    assert(SideSkewALUCtrl.legal(issued.alu_ctrl),
      "side ALU skew received an unsupported operation")
    assert(issued.when === WHEN_ABS_EX3,
      "side ALU skew result must advertise EX3 availability")
  }
  when(skewEx2Valid) {
    for (bit <- 1 until REG_DATA_WIDTH) {
      assert(skewEx2Op(bit) === skewEx2Op(0),
        "side ALU skew replicated opcodes must remain identical")
    }
    assert(ex2Valid && ex2Bits.when === WHEN_ABS_EX3,
      "side ALU skew operand token must align with side EX2 metadata")
    assert(sideEx2.io.rd.when(WHN_IDX_EX2),
      "side ALU skew must not forward from EX2")
  }
  when(skewEx3Valid) {
    assert(ex3Valid && ex3Bits.when === WHEN_ABS_EX3,
      "side ALU skew result register must align with side EX3 metadata")
  }

  if (CONFIG_SIMULATION) {
    LateOperandForward.assertIdentity(
      issued.rs1_late, ex2Group, ex3Group, ex4Group, io.wb,
      issued.rs1_assert_addr.get,
      ex1Valid && !io.stall && issued.rs1_need.orR,
      "side Ex1 rs1")
    LateOperandForward.assertIdentity(
      issued.rs2_late, ex2Group, ex3Group, ex4Group, io.wb,
      issued.rs2_assert_addr.get,
      ex1Valid && !io.stall && issued.rs2_need.orR,
      "side Ex1 rs2")
  }

  when(io.inValid && io.in.laneValid(1)) {
    assert((issued.mdu_ctrl === MDU_NONE ||
      issued.mdu_ctrl(MDU_MUX_WIDTH - 1, 0) === MD_MULT) &&
      issued.csr_ctrl === CSR_NONE &&
      issued.envir === ENVIR_NORMAL,
      "slot 1 received an unsupported side-lane instruction")
    assert(io.in.lane(1).pc === io.in.lane(0).pc + 4.U,
      "dual-issued instruction PCs must be consecutive")
    when(issued.mem_bytes =/= MEM_NONE) {
      assert(!issued.flat_rs1,
        "slot 1 memory address cannot use same-group flat bypass")
    }
    assert(!(issued.load_pair_rs1 || issued.load_pair_rs2),
      "dependent same-group loads must serialize before execution")
  }
  when(io.storeValid) {
    assert(!ex4Late.token.pending,
      "slot 1 Ex4 store data must be resolved before commit")
  }

  assert(!io.ex1.laneValid(1) || io.ex1.laneValid === "b10".U,
    "side execution stage must contain only slot 1")
}
