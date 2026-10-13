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
import Func._
import DPUParams._
import OperandStats._
import StoreForward._

class EXU extends Module {
  val io = IO(new Bundle {
    val in = Flipped(Decoupled(new IS_EX_Payload))
    val side_valid = Input(Bool())
    val side = Input(new IS_EX_Payload)
    val out  = Decoupled(new EX_WB_Payload)
    val flush = Input(Bool())
    val hold_ex1 = Input(Bool())
    val replay_dep_ex2 = Input(UInt(DualIssue.Width.W))
    val replay_dep_ex3 = Input(UInt(DualIssue.Width.W))
    val load_miss_replay = Output(Bool())
    val load_miss_hold = Output(Bool())
    val store_replay_conflict = Input(Bool())
    val store_replay_hold = Output(Bool())
    val store_replay_start = Output(Bool())
    val backend_stall = Output(Bool())
    val backend_load_stall = Output(Bool())
    val backend_store_stall = Output(Bool())

    val ex1_ex2_stall = Input(Bool())
    val ex2_ex3_stall = Input(Bool())
    val ex3_ex4_stall = Input(Bool())

    val ex1_ex2_bubble = Input(Bool())
    val ex2_ex3_bubble = Input(Bool())
    val ex3_ex4_bubble = Input(Bool())

    val perip = new PERIP()

    val lsu_probe_valid = Input(Bool())
    val lsu_probe_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lsu_lookup_valid = Input(Bool())
    val lsu_lookup_addr = Input(UInt(MEM_ADDR_WIDTH.W))
    val lsu_lookup_match = Input(Bool())
    val lsu_ex2_lane =
      Output(UInt(log2Ceil(DualIssue.Width).W))
    val lsu_ex2_valid = Output(Bool())
    val lsu_ex2_load_valid = Output(Bool())
    val lsu_ex2_rd = Output(UInt(GPR_ADDR_WIDTH.W))
    val lsu_ex2_addr = Output(UInt(MEM_ADDR_WIDTH.W))
    val lsu_ex2_bytes = Output(UInt(2.W))
    val lsu_ex2_sign = Output(Bool())
    val lsu_ex2_cache_hit = Output(Bool())
    val lsu_ex2_rdata = Output(UInt(MEM_DATA_WIDTH.W))
    val lsu_ex2_store_cache_hit = Output(Bool())
    val lsu_ex2_store_cache_data = Output(UInt(MEM_DATA_WIDTH.W))
    val lsu_fast_lane =
      Output(UInt(log2Ceil(DualIssue.Width).W))
    val lsu_load_valid = Output(Bool())
    val lsu_fast_valid = Output(Bool())
    val lsu_fast_rd = Output(UInt(GPR_ADDR_WIDTH.W))
    val lsu_fast_addr = Output(UInt(MEM_ADDR_WIDTH.W))
    val lsu_fast_bytes = Output(UInt(2.W))
    val lsu_fast_sign = Output(Bool())
    val lsu_slow_lane =
      Output(UInt(log2Ceil(DualIssue.Width).W))
    val lsu_slow_valid = Output(Bool())
    val lsu_slow_rd = Output(UInt(GPR_ADDR_WIDTH.W))
    val lsu_slow_addr = Output(UInt(MEM_ADDR_WIDTH.W))
    val lsu_slow_bytes = Output(UInt(2.W))
    val lsu_slow_sign = Output(Bool())
    val lsu_cache_hit = Output(Bool())
    val lsu_rdata_fast = Output(UInt(MEM_DATA_WIDTH.W))
    val lsu_rdata_slow = Output(UInt(MEM_DATA_WIDTH.W))
    val lsu_store_cache_hit = Output(Bool())
    val lsu_store_cache_data = Output(UInt(MEM_DATA_WIDTH.W))

    val rs1_val_iss = Output(UInt(REG_DATA_WIDTH.W))
    val rs2_val_iss = Output(UInt(REG_DATA_WIDTH.W))
    val rs1_val_ex1 = Input(UInt(REG_DATA_WIDTH.W))
    val rs2_val_ex1 = Input(UInt(REG_DATA_WIDTH.W))

    val ex1_valid = Output(Bool())
    val ex1_present = Output(Bool())
    val ex2_valid = Output(Bool())
    val ex3_valid = Output(Bool())
    val ex4_valid = Output(Bool())
    val ex1_ready = Output(Bool())
    val ex2_ready = Output(Bool())
    val ex3_ready = Output(Bool())
    val ex4_ready = Output(Bool())
    val ex1_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val = Output(UInt(REG_DATA_WIDTH.W))
    val ex1_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val_q = Output(UInt(REG_DATA_WIDTH.W))

    val bpu_update_en = Output(Bool())
    val bpu_update_pc = Output(UInt(PC_DATA_WIDTH.W))
    val bpu_update_ras_push = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_pop = if (CONFIG_BRANCH_RAS) Some(Output(Bool())) else None
    val bpu_update_ras_addr = if (CONFIG_BRANCH_RAS) Some(Output(UInt(PC_DATA_WIDTH.W))) else None
    val branch_resolve = Output(new BranchResolveBundle)
    val frp_event = if (CONFIG_BRANCH_FAST_RECURRENCE)
      Some(Output(new FrpExecutionEventBundle)) else None
    val side_branch_pc_next = Output(UInt(PC_DATA_WIDTH.W))
    val mul_out = Output(UInt(MUL_OUT_WIDTH.W))
    val mulbe_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_out = Output(UInt(REG_DATA_WIDTH.W))
    val div_busy = Output(Bool())
    val div_done = Output(Bool())
    val long_in_flight = Output(Bool())

    val ex1_rd = Output(new ProducerBundle)
    val ex2_rd = Output(new ProducerBundle)
    val ex3_rd = Output(new ProducerBundle)
    val ex4_rd = Output(new ProducerBundle)
    val stores = Output(Vec(4, new StoreAddressBundle))
    val side_stores = Input(Vec(4, new StoreAddressBundle))
    val side_store_valid = Input(Bool())
    val side_store = Input(new StoreCommitPayload)
    val store_buffer_empty = Output(Bool())
    val load_port_blocked = Output(Bool())
    val system_in_flight = Output(Bool())

    val timer_interrupt = Input(Bool())
    val interrupt_take = Input(Bool())
    val interrupt_pc = Input(UInt(PC_DATA_WIDTH.W))
    val interrupt_pending = Output(Bool())
    val interrupt_target = Output(UInt(PC_DATA_WIDTH.W))

    val side_ex2 = Input(new ForwardProducerGroup)
    val side_ex3 = Input(new ForwardProducerGroup)
    val side_ex4 = Input(new ForwardProducerGroup)
    val wb = Input(new ForwardProducerGroup)
  })

  io.rs1_val_iss := io.in.bits.rs1_val
  io.rs2_val_iss := io.in.bits.rs2_val

  val ex1_ex2_stall  = io.ex1_ex2_stall
  val ex2_ex3_stall  = io.ex2_ex3_stall
  val ex3_ex4_stall  = io.ex3_ex4_stall

  val ex1_ex2_bubble = io.ex1_ex2_bubble
  val ex2_ex3_bubble = io.ex2_ex3_bubble
  val ex3_ex4_bubble = io.ex3_ex4_bubble

  val exu_ex1 = Module(new exu_ex1)
  val exu_ex2 = Module(new exu_ex2)
  val exu_ex3 = Module(new exu_ex3)
  val exu_ex4 = Module(new exu_ex4)
  val ex1MulDrain = Wire(Bool())
  exu_ex1.io.mul_drain := ex1MulDrain
  val csrFile = Module(new CSR)

  csrFile.io.read_mask := exu_ex1.io.in.bits.csr_mask
  exu_ex1.io.csr_rdata := csrFile.io.rdata
  exu_ex1.io.csr_mtvec := csrFile.io.mtvec
  exu_ex1.io.csr_mepc := csrFile.io.mepc
  csrFile.io.timer_irq := io.timer_interrupt
  csrFile.io.interrupt_take := io.interrupt_take
  csrFile.io.interrupt_pc := io.interrupt_pc
  io.interrupt_pending := csrFile.io.interrupt_pending
  io.interrupt_target := csrFile.io.mtvec

  private def producerGroup(
      valid: Bool,
      rd: ProducerBundle,
      value: UInt,
      side: ForwardProducerGroup): ForwardProducerGroup = {
    val group = WireDefault(side)
    group.laneValid :=
      side.laneValid | Mux(valid, "b01".U, 0.U)
    group.rd(0) := rd
    group.value(0) := value
    group
  }

  private def advanceLate(
      operand: LateOperandStateBundle,
      ex2: ForwardProducerGroup,
      ex3: ForwardProducerGroup,
      ex4: ForwardProducerGroup,
      wb: ForwardProducerGroup): LateOperandStateBundle =
    LateOperandForward.advance(operand, ex2, ex3, ex4, wb)

  val ex2Group = producerGroup(
    exu_ex2.io.out.valid, exu_ex2.io.rd, exu_ex2.io.reg_val, io.side_ex2)
  val ex3Group = producerGroup(
    exu_ex3.io.out.valid, exu_ex3.io.rd, exu_ex3.io.reg_val, io.side_ex3)
  val ex4Group = producerGroup(
    exu_ex4.io.out.valid, exu_ex4.io.rd, exu_ex4.io.reg_val, io.side_ex4)
  exu_ex1.io.forwardEx2 := ex2Group
  exu_ex1.io.forwardEx3 := ex3Group
  exu_ex1.io.forwardEx4 := ex4Group
  exu_ex1.io.forwardWb := io.wb

  val lsu = Module(new LSU)
  // Port ownership is metadata, not an architectural request.  Keep it on
  // the pre-quash input so a late redirect cannot feed the wide LSU/ready
  // cone; exu_ex1.out.valid still suppresses the request and all younger
  // side effects in the redirect cycle.
  val ex1RequestPresent = io.in.valid
  val memoryCandidates = Wire(Vec(DualIssue.Width, Bool()))
  memoryCandidates(0) :=
    ex1RequestPresent &&
      exu_ex1.io.out.bits.mem_bytes =/= MEM_NONE
  memoryCandidates(1) :=
    ex1RequestPresent && io.side_valid &&
      io.side.mem_bytes =/= MEM_NONE
  val memoryGrant = PriorityEncoderOH(memoryCandidates)
  val memoryOwner1 = memoryGrant(1)
  val sideStoreData =
    Mux(io.side.flat_rs2, exu_ex1.io.reg_val, io.side.rs2_val)

  // Both lanes present an AGU candidate.  The current one-port LSU accepts a
  // one-hot grant; the lane tag remains attached to fast and slow responses.
  // A locally held group keeps its already-started BRAM lookup present, but
  // io.hold_ex1 below prevents the peripheral request and pipeline advance.
  // This preserves an independent memory lane without adding a mux to the
  // D-cache lookup address path.
  val heldMemoryLookup = io.hold_ex1 && memoryCandidates.asUInt.orR
  lsu.io.in.valid          := exu_ex1.io.out.valid || heldMemoryLookup
  lsu.io.in.bits.lane      := memoryOwner1
  lsu.io.in.bits.rd        := Mux(
    memoryOwner1, io.side.rd_addr, io.in.bits.rd_addr)
  lsu.io.in.bits.addr      := Mux(
    memoryOwner1, io.side.addr, exu_ex1.io.out.bits.addr)
  lsu.io.in.bits.cache_probe_match := Mux(
    memoryOwner1,
    io.side.cache_probe_match,
    io.in.bits.cache_probe_match)
  lsu.io.in.bits.L_sign    := Mux(
    memoryOwner1, io.side.L_sign, exu_ex1.io.out.bits.L_sign)
  lsu.io.in.bits.mem_wdata := Mux(
    memoryOwner1, sideStoreData, exu_ex1.io.out.bits.mem_wdata)
  lsu.io.in.bits.mem_bytes := Mux(
    memoryOwner1, io.side.mem_bytes, exu_ex1.io.out.bits.mem_bytes)
  lsu.io.in.bits.mem_wen   := Mux(
    memoryOwner1, io.side.mem_wen, exu_ex1.io.out.bits.mem_wen)
  lsu.io.in.bits.transient_fwd_mask := Mux(
    memoryOwner1,
    io.side.transient_fwd_mask,
    io.in.bits.transient_fwd_mask)
  lsu.io.in.bits.transient_fwd_data := Mux(
    memoryOwner1,
    io.side.transient_fwd_data,
    io.in.bits.transient_fwd_data)
  lsu.io.in.bits.transient_fwd_sources := Mux(
    memoryOwner1,
    io.side.transient_fwd_sources,
    io.in.bits.transient_fwd_sources)
  lsu.io.probe_valid       := io.lsu_probe_valid
  lsu.io.probe_addr        := io.lsu_probe_addr
  lsu.io.lookup_valid      := io.lsu_lookup_valid
  lsu.io.lookup_addr       := io.lsu_lookup_addr
  lsu.io.lookup_match      := io.lsu_lookup_match
  lsu.io.out.ready         := exu_ex3.io.out.ready
  lsu.io.slow_ready        := exu_ex4.io.out.ready
  lsu.io.flush             := ex1_ex2_bubble
  // A redirect only invalidates the younger Issue/AG0 probe. Requests that
  // already reached DC1 are older than the resolved control instruction and
  // must continue to completion.
  lsu.io.probe_flush       := io.flush || ex1_ex2_bubble
  lsu.io.stall             := ex1_ex2_stall
  lsu.io.hold_request      := io.hold_ex1
  lsu.io.store_replay_conflict := io.store_replay_conflict
  lsu.io.perip             <> io.perip
  io.store_replay_hold := lsu.io.store_replay_hold
  io.store_replay_start := lsu.io.store_replay_start
  val earlyOwner0 = lsu.io.early_lane === 0.U
  exu_ex2.io.cache_hit :=
    earlyOwner0 && lsu.io.early_cache_hit
  exu_ex2.io.rdata_fast := lsu.io.early_rdata
  exu_ex2.io.store_cache_hit :=
    earlyOwner0 && lsu.io.early_store_cache_hit
  exu_ex2.io.store_cache_data := lsu.io.early_store_cache_data
  io.lsu_ex2_lane := lsu.io.early_lane
  io.lsu_ex2_valid := lsu.io.early_valid
  io.lsu_ex2_load_valid := lsu.io.early_load_valid
  io.lsu_ex2_rd := lsu.io.early_rd
  io.lsu_ex2_addr := lsu.io.early_addr
  io.lsu_ex2_bytes := lsu.io.early_bytes
  io.lsu_ex2_sign := lsu.io.early_sign
  io.lsu_ex2_cache_hit := lsu.io.early_cache_hit
  io.lsu_ex2_rdata := lsu.io.early_rdata
  io.lsu_ex2_store_cache_hit := lsu.io.early_store_cache_hit
  io.lsu_ex2_store_cache_data := lsu.io.early_store_cache_data
  val fastOwner0 = lsu.io.out.bits.lane === 0.U
  exu_ex3.io.cache_hit := fastOwner0 && lsu.io.out.bits.cache_hit
  exu_ex3.io.rdata_fast := lsu.io.out.bits.rdata_fast
  exu_ex3.io.store_cache_hit :=
    fastOwner0 && lsu.io.out.bits.store_cache_hit
  exu_ex3.io.store_cache_data := lsu.io.out.bits.store_cache_data
  exu_ex4.io.rdata_slow := Mux(
    lsu.io.out.bits.slow_valid && lsu.io.out.bits.slow_lane === 0.U,
    lsu.io.out.bits.rdata_slow,
    0.U)
  io.lsu_fast_lane := lsu.io.out.bits.lane
  io.lsu_fast_addr := lsu.io.out.bits.addr
  io.lsu_fast_bytes := lsu.io.out.bits.bytes
  io.lsu_fast_sign := lsu.io.out.bits.sign
  io.lsu_slow_lane := lsu.io.out.bits.slow_lane
  io.lsu_slow_valid := lsu.io.out.bits.slow_valid
  io.lsu_slow_rd := lsu.io.out.bits.slow_rd
  io.lsu_slow_addr := lsu.io.out.bits.slow_addr
  io.lsu_slow_bytes := lsu.io.out.bits.slow_bytes
  io.lsu_slow_sign := lsu.io.out.bits.slow_sign
  io.lsu_cache_hit := lsu.io.out.bits.cache_hit
  io.lsu_rdata_fast := lsu.io.out.bits.rdata_fast
  io.lsu_rdata_slow := lsu.io.out.bits.rdata_slow
  io.lsu_store_cache_hit := lsu.io.out.bits.store_cache_hit
  io.lsu_store_cache_data := lsu.io.out.bits.store_cache_data
  val fastLoadLane = lsu.io.out.bits.lane
  val fastLoadRd = lsu.io.out.bits.rd
  val loadResponseValid =
    lsu.io.out.valid && lsu.io.out.bits.is_load
  val fastLoadValid =
    loadResponseValid &&
      lsu.io.out.bits.cache_hit
  io.lsu_load_valid := loadResponseValid
  io.lsu_fast_valid := fastLoadValid
  io.lsu_fast_rd := fastLoadRd
  val ex4Late = advanceLate(
    exu_ex4.io.in.bits.late_data, ex2Group, ex3Group, ex4Group, io.wb)
  val ex4Store = exu_ex4.io.out.valid &&
    exu_ex4.io.in.bits.mem_wen &&
    exu_ex4.io.in.bits.mem_bytes =/= MEM_NONE
  val ex4Csr = exu_ex4.io.in.bits.csr_ctrl =/= CSR_NONE
  val ex4Ecall = exu_ex4.io.in.bits.envir === ENVIR_ECALL
  val ex4Mret = exu_ex4.io.in.bits.envir === ENVIR_MRET
  val ex4System = ex4Csr || ex4Ecall || ex4Mret
  val csrCommit = exu_ex4.io.out.fire && ex4System

  csrFile.io.valid := csrCommit
  csrFile.io.ctrl := exu_ex4.io.in.bits.csr_ctrl(1, 0)
  csrFile.io.wdata := ex4Late.value
  csrFile.io.mask := exu_ex4.io.in.bits.csr_mask
  csrFile.io.ecall := csrCommit && ex4Ecall
  csrFile.io.mret := csrCommit && ex4Mret
  csrFile.io.trap_pc := exu_ex4.io.in.bits.trap_pc

  val sideEx4Store = io.side_store_valid
  val sharedEx4Store = ex4Store || sideEx4Store
  val lane0Store =
    WireDefault(0.U.asTypeOf(new StoreCommitPayload))
  lane0Store.addr := exu_ex4.io.in.bits.addr
  lane0Store.data := ex4Late.value
  lane0Store.bytes := exu_ex4.io.in.bits.mem_bytes
  lane0Store.cache_hit := exu_ex4.io.in.bits.store_cache_hit
  lane0Store.cache_data := exu_ex4.io.in.bits.store_cache_data
  lsu.io.store.valid := sharedEx4Store && io.out.ready
  lsu.io.store.bits := Mux(sideEx4Store, io.side_store, lane0Store)
  io.store_buffer_empty := lsu.io.store_buffer_empty
  io.load_port_blocked := lsu.io.load_port_blocked

  private def storeAddress(
      valid: Bool,
      addr: UInt,
      bytes: UInt,
      wen: Bool,
      lateData: LateOperandStateBundle,
      stage: Int,
      lane: Int): StoreAddressBundle = {
    val store = WireDefault(0.U.asTypeOf(new StoreAddressBundle))
    store.valid := valid && wen && bytes =/= MEM_NONE
    store.addrValid := store.valid
    store.addr := addr
    store.bytes := bytes
    store.byteMask := byteEnable(addr, bytes)
    store.data := wordData(lateData.value, bytes)
    store.dataValid := store.valid && !lateData.token.pending
    store.stage := stage.U
    store.lane := lane.U
    store
  }

  val lane0Stores = Wire(Vec(4, new StoreAddressBundle))
  lane0Stores(0) := storeAddress(
    exu_ex1.io.out.valid, exu_ex1.io.out.bits.addr,
    exu_ex1.io.out.bits.mem_bytes, exu_ex1.io.out.bits.mem_wen,
    advanceLate(
      exu_ex1.io.out.bits.late_data,
      ex2Group, ex3Group, ex4Group, io.wb),
    stage = 0, lane = 0)
  lane0Stores(1) := storeAddress(
    exu_ex2.io.out.valid, exu_ex2.io.out.bits.addr,
    exu_ex2.io.out.bits.mem_bytes, exu_ex2.io.out.bits.mem_wen,
    advanceLate(
      exu_ex2.io.out.bits.late_data,
      ex2Group, ex3Group, ex4Group, io.wb),
    stage = 1, lane = 0)
  lane0Stores(2) := storeAddress(
    exu_ex3.io.out.valid, exu_ex3.io.out.bits.addr,
    exu_ex3.io.out.bits.mem_bytes, exu_ex3.io.out.bits.mem_wen,
    advanceLate(
      exu_ex3.io.out.bits.late_data,
      ex2Group, ex3Group, ex4Group, io.wb),
    stage = 2, lane = 0)
  lane0Stores(3) := storeAddress(
    exu_ex4.io.out.valid, exu_ex4.io.in.bits.addr,
    exu_ex4.io.in.bits.mem_bytes, exu_ex4.io.in.bits.mem_wen,
    ex4Late, stage = 3, lane = 0)
  for (stage <- 0 until 4) {
    io.stores(stage) := Mux(
      io.side_stores(stage).valid,
      io.side_stores(stage),
      lane0Stores(stage))
  }

  private def systemInstruction(
      valid: Bool,
      csrCtrl: UInt,
      envir: UInt): Bool =
    valid && (csrCtrl =/= CSR_NONE || envir =/= ENVIR_NORMAL)

  io.system_in_flight :=
    systemInstruction(
      exu_ex1.io.out.valid,
      exu_ex1.io.out.bits.csr_ctrl,
      exu_ex1.io.out.bits.envir) ||
    systemInstruction(
      exu_ex2.io.out.valid,
      exu_ex2.io.out.bits.csr_ctrl,
      exu_ex2.io.out.bits.envir) ||
    systemInstruction(
      exu_ex3.io.out.valid,
      exu_ex3.io.out.bits.csr_ctrl,
      exu_ex3.io.out.bits.envir) ||
    systemInstruction(
      exu_ex4.io.out.valid,
      exu_ex4.io.in.bits.csr_ctrl,
      exu_ex4.io.in.bits.envir)

  io.ex1_valid              := exu_ex1.io.out.valid
  // Occupancy metadata deliberately excludes the late redirect quash.  The
  // execution-valid output above still suppresses every side effect.
  io.ex1_present            := exu_ex1.io.in.valid
  io.ex2_valid              := exu_ex2.io.out.valid
  io.ex3_valid              := exu_ex3.io.out.valid
  io.ex4_valid              := exu_ex4.io.out.valid
  io.ex1_ready              := exu_ex1.io.in.ready
  io.ex2_ready              := exu_ex2.io.in.ready
  io.ex3_ready              := exu_ex3.io.in.ready
  io.ex4_ready              := exu_ex4.io.in.ready

  exu_ex1.io.in.bits        := io.in.bits
  exu_ex1.io.in.valid       := io.in.valid && !io.hold_ex1
  // side_valid is registered Issue -> Ex1 ownership metadata.  Keep it
  // independent of a local execution hold so LSU hazards cannot select the
  // shared BRU input; exu_ex1.in.valid/exu_fire still gate every side effect.
  exu_ex1.io.side_valid     := io.side_valid
  exu_ex1.io.side           := io.side
  io.in.ready               := exu_ex1.io.in.ready && !io.hold_ex1
  exu_ex1.io.flush          := io.flush
  io.bpu_update_en          := exu_ex1.io.bpu_update_en
  io.bpu_update_pc          := exu_ex1.io.bpu_update_pc
  if (CONFIG_BRANCH_RAS) {
    io.bpu_update_ras_push.get := exu_ex1.io.bpu_update_ras_push.get
    io.bpu_update_ras_pop.get := exu_ex1.io.bpu_update_ras_pop.get
    io.bpu_update_ras_addr.get := exu_ex1.io.bpu_update_ras_addr.get
  }
  io.branch_resolve         := exu_ex1.io.branch_resolve
  if (CONFIG_BRANCH_FAST_RECURRENCE) {
    io.frp_event.get := exu_ex1.io.frp_event.get
  }
  io.side_branch_pc_next    := exu_ex1.io.side_branch_pc_next
  io.mul_out                := exu_ex1.io.mul_out
  io.mulbe_out              := exu_ex1.io.mulbe_out
  io.div_out                := exu_ex1.io.div_out
  io.div_busy               := exu_ex1.io.div_busy
  io.div_done               := exu_ex1.io.div_done
  io.ex1_reg_val            := exu_ex1.io.reg_val
  io.ex1_rd.wen             := exu_ex1.io.rd.wen
  io.ex1_rd.addr            := exu_ex1.io.rd.addr
  io.ex1_rd.producerType    := exu_ex1.io.rd.producerType
  // A validated holding-queue probe advertises EX2 optimistically. The miss
  // check below retains only the single younger group that consumed it;
  // address-mismatch loads advertise the conservative EX3 fallback instead.
  io.ex1_rd.when            := exu_ex1.io.rd.when

  val ex1Out = Wire(Decoupled(new EX1_EX2_Payload))
  ex1Out.valid := exu_ex1.io.out.valid
  ex1Out.bits := exu_ex1.io.out.bits
  ex1Out.bits.late_data := advanceLate(
    exu_ex1.io.out.bits.late_data, ex2Group, ex3Group, ex4Group, io.wb)
  exu_ex1.io.out.ready := ex1Out.ready

  val ex2_load_miss =
    lsu.io.early_valid && lsu.io.early_is_load &&
      !lsu.io.early_cache_hit && !lsu.io.store_replay_hold
  val ex2LoadLane = lsu.io.early_lane
  val ex1_depends_on_ex2_load =
    io.in.valid && io.replay_dep_ex2(ex2LoadLane)
  val ex2WaitStart =
    ex2_load_miss && ex1_depends_on_ex2_load && exu_ex2.io.out.fire

  val ex3_load_miss =
    lsu.io.out.valid && lsu.io.out.bits.is_load &&
      !lsu.io.out.bits.cache_hit
  val ex3LoadLane = lsu.io.out.bits.lane
  val ex1_depends_on_ex3_load =
    io.in.valid && io.replay_dep_ex3(ex3LoadLane)
  val ex3WaitStart =
    ex3_load_miss && ex1_depends_on_ex3_load && lsu.io.out.fire
  val scalarWaitStart = ex2WaitStart || ex3WaitStart
  val scalarWaitValid = RegInit(false.B)
  val scalarWaitLane = Reg(UInt(log2Ceil(DualIssue.Width).W))
  val scalarWaitRd = Reg(UInt(GPR_ADDR_WIDTH.W))
  val scalarWaitWordAddr = Reg(UInt((MEM_ADDR_WIDTH - 2).W))
  val scalarWaitBytes = Reg(UInt(2.W))
  val scalarWaitSign = Reg(Bool())
  val scalarSlowMatch =
    scalarWaitValid && lsu.io.out.bits.slow_valid &&
      lsu.io.out.bits.slow_lane === scalarWaitLane &&
      lsu.io.out.bits.slow_rd === scalarWaitRd &&
      lsu.io.out.bits.slow_addr(MEM_ADDR_WIDTH - 1, 2) ===
      scalarWaitWordAddr &&
      lsu.io.out.bits.slow_bytes === scalarWaitBytes &&
      lsu.io.out.bits.slow_sign === scalarWaitSign
  val scalarFastMatch =
    scalarWaitValid && lsu.io.out.valid && lsu.io.out.bits.is_load &&
      lsu.io.out.bits.cache_hit &&
      lsu.io.out.bits.lane === scalarWaitLane &&
      lsu.io.out.bits.rd === scalarWaitRd &&
      lsu.io.out.bits.addr(MEM_ADDR_WIDTH - 1, 2) ===
        scalarWaitWordAddr &&
      lsu.io.out.bits.bytes === scalarWaitBytes &&
      lsu.io.out.bits.sign === scalarWaitSign
  val scalarWaitResolved = scalarFastMatch || scalarSlowMatch
  io.load_miss_replay := scalarWaitStart
  // Retain the consumer through the resolving edge.  A miss is advertised as
  // WB-available, so this extra miss-only cycle advances its late token from
  // Ex4 to WB before Ex1 is released; a fallback hit is captured while held.
  io.load_miss_hold :=
    scalarWaitStart || scalarWaitValid

  // The LSU runs beside the Ex1 -> Ex2 pipeline register. If the peripheral
  // bridge cannot accept a request, hold Ex1 and every younger stage until the
  // same request completes its valid/ready handshake.
  val store_commit_stall = sharedEx4Store && !lsu.io.store.ready
  val lsu_backend_stall =
    lsu.io.load_stall || lsu.io.slow_stall || store_commit_stall
  ex1MulDrain := lsu.io.store_replay_hold &&
    !ex1_ex2_stall && !lsu_backend_stall
  io.backend_stall := lsu_backend_stall
  io.backend_load_stall := lsu.io.load_stall || lsu.io.slow_stall
  io.backend_store_stall := store_commit_stall

  when(io.flush) {
    scalarWaitValid := false.B
  }.elsewhen(scalarWaitStart) {
    scalarWaitValid := true.B
    scalarWaitLane := Mux(
      ex2WaitStart, lsu.io.early_lane, lsu.io.out.bits.lane)
    scalarWaitRd := Mux(
      ex2WaitStart, lsu.io.early_rd, lsu.io.out.bits.rd)
    scalarWaitWordAddr :=
      Mux(ex2WaitStart,
        lsu.io.early_addr,
        lsu.io.out.bits.addr)(MEM_ADDR_WIDTH - 1, 2)
    scalarWaitBytes := Mux(
      ex2WaitStart, lsu.io.early_bytes, lsu.io.out.bits.bytes)
    scalarWaitSign := Mux(
      ex2WaitStart, lsu.io.early_sign, lsu.io.out.bits.sign)
  }.elsewhen(scalarWaitResolved) {
    scalarWaitValid := false.B
  }
  pipelineConnect(
    ex1Out,
    exu_ex2.io.in,
    ex1_ex2_stall || lsu_backend_stall || lsu.io.store_replay_hold,
    ex1_ex2_bubble)

  io.ex1_reg_val_q  := exu_ex2.io.in.bits.reg_data
  io.ex2_reg_val    := exu_ex2.io.reg_val
  io.ex2_rd         := exu_ex2.io.rd

  val ex2Out = Wire(Decoupled(new EX2_EX3_Payload))
  ex2Out.valid := exu_ex2.io.out.valid
  ex2Out.bits := exu_ex2.io.out.bits
  ex2Out.bits.late_data := advanceLate(
    exu_ex2.io.out.bits.late_data, ex2Group, ex3Group, ex4Group, io.wb)
  exu_ex2.io.out.ready := ex2Out.ready

  // A store-conflicting load is retained in Ex2 while an older Ex3 payload
  // drains.  The ordinary pipelineConnect stall freezes both sides, so use an
  // elastic valid here: consume the older Ex3 entry without accepting Ex2.
  val ex2Ex3GlobalStall = ex2_ex3_stall || lsu_backend_stall
  val ex2Ex3Capture =
    exu_ex3.io.in.ready && !ex2Ex3GlobalStall && !lsu.io.store_replay_hold
  val ex2Ex3Valid = RegInit(false.B)
  val ex2Ex3Bits = RegEnable(ex2Out.bits, ex2Ex3Capture)
  ex2Out.ready := ex2Ex3Capture
  when(!ex2Ex3GlobalStall) {
    when(lsu.io.store_replay_hold) {
      when(exu_ex3.io.in.ready) {
        ex2Ex3Valid := false.B
      }
    }.otherwise {
      ex2Ex3Valid := ex2Out.valid && !ex2_ex3_bubble
    }
  }
  exu_ex3.io.in.valid := ex2Ex3Valid
  exu_ex3.io.in.bits := ex2Ex3Bits

  io.ex2_reg_val_q := exu_ex3.io.in.bits.reg_data
  io.ex3_reg_val   := exu_ex3.io.reg_val
  io.ex3_rd        := exu_ex3.io.rd

  val ex3Out = Wire(Decoupled(new EX3_EX4_Payload))
  ex3Out.valid := exu_ex3.io.out.valid
  ex3Out.bits := exu_ex3.io.out.bits
  ex3Out.bits.late_data := advanceLate(
    exu_ex3.io.out.bits.late_data, ex2Group, ex3Group, ex4Group, io.wb)
  exu_ex3.io.out.ready := ex3Out.ready

  pipelineConnect(
    ex3Out,
    exu_ex4.io.in,
    ex3_ex4_stall || lsu_backend_stall,
    ex3_ex4_bubble)

  io.ex3_reg_val_q := exu_ex4.io.in.bits.rd.data
  io.ex4_reg_val   := exu_ex4.io.reg_val
  io.ex4_rd        := exu_ex4.io.rd
  io.out.bits      := exu_ex4.io.out.bits
  io.out.valid     := exu_ex4.io.out.valid
  exu_ex4.io.out.ready := io.out.ready

  when(lsu.io.store.fire) {
    assert(sideEx4Store || !ex4Late.token.pending,
      "Ex4 store data must be resolved before store-buffer enqueue")
  }
  when(csrCommit && ex4Csr) {
    assert(!ex4Late.token.pending,
      "Ex4 CSR data must be resolved before architectural commit")
  }

  private def isLong(mdu_ctrl: UInt): Bool =
    mdu_ctrl(MDU_MUX_WIDTH - 1, 0) === MD_DIV

  val long_in_ex1 = exu_ex1.io.out.valid && isLong(exu_ex1.io.out.bits.mdu_ctrl)
  val long_in_ex2 = exu_ex2.io.out.valid && isLong(exu_ex2.io.out.bits.mdu_ctrl)
  val long_in_ex3 = exu_ex3.io.out.valid && isLong(exu_ex3.io.out.bits.mdu_ctrl)
  val long_in_ex4 = exu_ex4.io.out.valid && isLong(exu_ex4.io.out.bits.mdu_ctrl)

  io.long_in_flight := (io.div_busy && !io.div_done) ||
                       long_in_ex1 || long_in_ex2 || long_in_ex3 || long_in_ex4

  assert(PopCount(memoryCandidates) <= 1.U,
    "current shared AGU/LSU accepts at most one lane candidate")
  if (CONFIG_SIMULATION) {
    def replayDependencyMask(
        where: Int,
        requireLoadSpec: Boolean): UInt = {
      VecInit((0 until DualIssue.Width).map { producerLane =>
        def sourceDepends(
            valid: Bool,
            need: UInt,
            operand: LateOperandBundle): Bool =
          valid && need.orR && operand.pending &&
            operand.stage(where) && operand.lane === producerLane.U &&
            ((!requireLoadSpec).B || operand.loadSpec)

        sourceDepends(
          io.in.valid, io.in.bits.rs1_need, io.in.bits.rs1_late) ||
          sourceDepends(
            io.in.valid, io.in.bits.rs2_need, io.in.bits.rs2_late) ||
          sourceDepends(
            io.in.valid && io.side_valid,
            io.side.rs1_need, io.side.rs1_late) ||
          sourceDepends(
            io.in.valid && io.side_valid,
            io.side.rs2_need, io.side.rs2_late)
      }).asUInt
    }
    val referenceReplayDepEx2 =
      replayDependencyMask(WHR_IDX_EX2, requireLoadSpec = true)
    val referenceReplayDepEx3 =
      replayDependencyMask(WHR_IDX_EX3, requireLoadSpec = false)
    when(io.in.valid) {
      assert(io.replay_dep_ex2 === referenceReplayDepEx2,
        "registered Ex2 load replay dependency must match Ex1 operands")
      assert(io.replay_dep_ex3 === referenceReplayDepEx3,
        "registered Ex3 load replay dependency must match Ex1 operands")
    }
  }
  when(scalarWaitStart) {
    assert(io.hold_ex1 && !exu_ex1.io.out.valid && !lsu.io.in.fire,
      "a scalar load miss must suppress its Ex1 group side effects")
    assert(!io.bpu_update_en,
      "a scalar load miss must suppress branch predictor updates")
  }
  assert(!(ex4Store && sideEx4Store),
    "current shared store pipe accepts at most one lane candidate")
}
