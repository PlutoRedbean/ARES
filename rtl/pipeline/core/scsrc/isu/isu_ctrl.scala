package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import DPUParams._
import Func._

class isu_ctrl extends Module {
  val io = IO(new Bundle {
    val ex1_valid = Input(Bool())
    val ex2_valid = Input(Bool())
    val ex3_valid = Input(Bool())
    val ex4_valid = Input(Bool())
    val wb_valid  = Input(Bool())

    val idu_valid = Input(Bool())
    val iss_rs1   = Input(new ConsumerBundle)
    val iss_rs2   = Input(new ConsumerBundle)
    val idu_rs1   = Input(new ConsumerBundle)
    val idu_rs2   = Input(new ConsumerBundle)

    val ex1_rd    = Input(new ProducerBundle)
    val ex2_rd    = Input(new ProducerBundle)
    val ex3_rd    = Input(new ProducerBundle)
    val ex4_rd    = Input(new ProducerBundle)
    val wb_rd     = Input(new ProducerBundle)

    val rs1_where_ex1     = Input(UInt(WHERE_WIDTH.W))
    val rs2_where_ex1     = Input(UInt(WHERE_WIDTH.W))
    val nxt_rs1_where_ex1 = Output(UInt(WHERE_WIDTH.W))
    val nxt_rs2_where_ex1 = Output(UInt(WHERE_WIDTH.W))

    val rs1_fwd_sel_iss = Output(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs2_fwd_sel_iss = Output(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs1_fwd_sel_ex1 = Output(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs2_fwd_sel_ex1 = Output(UInt(ISU_FWD_SEL_WIDTH.W))

    val agu_fwd_sel_iss = Output(UInt(AGU_FWD_SEL_WIDTH.W))

    val raw_long_valid_iss = Input(Bool())
    val long_stall_wb  = Input(Bool())
    val backend_stall  = Input(Bool())
    val long_in_flight = Input(Bool())
    val interlock   = Output(Bool())
  })

  // N     cycle: idu -> ex1
  // N + 1 cycle: iss -> ex2
  private def addrCmp(consumer: ConsumerBundle): UInt = Cat(
    dataHazard(consumer, io.ex1_rd) & io.ex1_valid,
    dataHazard(consumer, io.ex2_rd) & io.ex2_valid,
    dataHazard(consumer, io.ex3_rd) & io.ex3_valid,
    dataHazard(consumer, io.ex4_rd) & io.ex4_valid
  )

  val early_addr_cmp_agu_iss = Reg(UInt(ADDR_CMP_WIDTH.W))
  val early_addr_cmp_iss_rs1 = Reg(UInt(ADDR_CMP_WIDTH.W))
  val early_addr_cmp_iss_rs2 = Reg(UInt(ADDR_CMP_WIDTH.W))

  val addr_cmp_idu_rs1 = addrCmp(io.idu_rs1)
  val addr_cmp_idu_rs2 = addrCmp(io.idu_rs2)
  val addr_cmp_iss_rs1 = addrCmp(io.iss_rs1)
  val addr_cmp_iss_rs2 = addrCmp(io.iss_rs2)

  // These registered comparisons are aligned with the synchronous GPR read
  // and the ID -> Iss payload.  Bridge backpressure holds both of those, so
  // hold the comparisons as well instead of sampling the younger ID request.
  when (!(io.long_stall_wb || io.backend_stall)) {
    early_addr_cmp_agu_iss := Mux(io.interlock, addr_cmp_iss_rs1, addr_cmp_idu_rs1)
    early_addr_cmp_iss_rs1 := Mux(io.interlock, addr_cmp_iss_rs1, addr_cmp_idu_rs1)
    early_addr_cmp_iss_rs2 := Mux(io.interlock, addr_cmp_iss_rs2, addr_cmp_idu_rs2)
  }

  // where 记录依赖所处位置
  private def where(consumer: ConsumerBundle, early_addr_cmp: UInt): UInt = Cat(
    false.B,
    dataHazard(consumer, io.ex1_rd) & io.ex1_valid,
    early_addr_cmp(3),
    early_addr_cmp(2),
    early_addr_cmp(1),
    early_addr_cmp(0)
  )

  // 根据 where_iss 选择正确的 cannot_fwd_from_* 掩码，作为新的 when 相对时间坐标
  // 使用 cannot_fwd_from_* 掩码，使 ABS_WHEN 时间坐标平移，生成 REL_WHEN
  private def rel_when(where_iss: UInt, cannot_fwd_from: CannotFwdBundle): UInt = {
    (Cat(Fill(NEED_WHEN_WIDTH, where_iss(WHR_IDX_EX1))) & cannot_fwd_from.ex1) |
    (Cat(Fill(NEED_WHEN_WIDTH, where_iss(WHR_IDX_EX2))) & cannot_fwd_from.ex2) |
    (Cat(Fill(NEED_WHEN_WIDTH, where_iss(WHR_IDX_EX3))) & cannot_fwd_from.ex3) |
    (Cat(Fill(NEED_WHEN_WIDTH, where_iss(WHR_IDX_EX4))) & cannot_fwd_from.ex4) |
    (Cat(Fill(NEED_WHEN_WIDTH, where_iss(WHR_IDX_WB ))) & cannot_fwd_from.wb )
  }

  // 地址匹配 & 数据就绪
  // available[WHR_IDX_EX1, WHR_IDX_EX2, WHR_IDX_EX3, WHR_IDX_EX4, WHR_IDX_WB]
  private def fwd_available(where_iss: UInt, ready_mask: UInt): UInt = where_iss & ready_mask

  // 当消费者从当前级进入下一级时，生产者的位置也向后移动一级。
  // 一旦某个较新的生产者已经被旁路，清除它以及所有更老的匹配项，
  // 防止后续流水级用旧值覆盖已经取得的新值。
  private def advance_where(where: UInt, available: UInt): UInt = Cat(
    false.B,
    where(WHR_IDX_ISS) & !available(WHR_IDX_ISS),
    where(WHR_IDX_EX1) & !available(WHR_IDX_ISS, WHR_IDX_EX1).orR,
    where(WHR_IDX_EX2) & !available(WHR_IDX_ISS, WHR_IDX_EX2).orR,
    where(WHR_IDX_EX3) & !available(WHR_IDX_ISS, WHR_IDX_EX3).orR,
    where(WHR_IDX_EX4) & !available(WHR_IDX_ISS, WHR_IDX_EX4).orR
  )

  // fwd_sel
  private def fwd_sel(available: UInt): UInt = MuxCase(ISU_FWD_NONE, Seq(
    available(WHR_IDX_EX1) -> ISU_FWD_EX1,
    available(WHR_IDX_EX2) -> ISU_FWD_EX2,
    available(WHR_IDX_EX3) -> ISU_FWD_EX3,
    available(WHR_IDX_EX4) -> ISU_FWD_EX4,
    available(WHR_IDX_WB ) -> ISU_FWD_WB ,
  ))

  // 生产者 ready_mask[WHR_IDX_ISS, WHR_IDX_EX1, WHR_IDX_EX2, WHR_IDX_EX3, WHR_IDX_EX4, WHR_IDX_WB]
  // Iss 位没有当拍旁路源；如果未来增加双发射，它会在 advance_where 中推进为 Ex1。
  // val WHR_IDX_ISS   = 5    MSB    |
  // val WHR_IDX_EX1   = 4           |
  // val WHR_IDX_EX2   = 3           |
  // val WHR_IDX_EX3   = 2           |
  // val WHR_IDX_EX4   = 1           |
  // val WHR_IDX_WB    = 0    LSB    v
  val ready_mask = Cat(
    false.B,
    ~io.ex1_rd.when(WHN_IDX_EX1) & io.ex1_valid & io.ex1_rd.wen,
    ~io.ex2_rd.when(WHN_IDX_EX2) & io.ex2_valid & io.ex2_rd.wen,
    ~io.ex3_rd.when(WHN_IDX_EX3) & io.ex3_valid & io.ex3_rd.wen,
    ~io.ex4_rd.when(WHN_IDX_EX4) & io.ex4_valid & io.ex4_rd.wen,
                                   io.wb_valid  & io.wb_rd.wen
  )

  val when_ex1 = io.ex1_rd.when
  val when_ex2 = io.ex2_rd.when
  val when_ex3 = io.ex3_rd.when
  val when_ex4 = io.ex4_rd.when
  val when_wb  = io.wb_rd.when

  // 生成 when_iss 所需的 cannot_fwd_* masks
  val cannot_fwd_from = Wire(new CannotFwdBundle)
  //                                          ex1                    ex2                    ex3                    ex4                    wb
  cannot_fwd_from.ex1 := Cat(when_ex1(WHN_IDX_EX4), when_ex1(WHN_IDX_EX3), when_ex1(WHN_IDX_EX2), when_ex1(WHN_IDX_EX1), true.B               )
  cannot_fwd_from.ex2 := Cat(false.B              , when_ex2(WHN_IDX_EX4), when_ex2(WHN_IDX_EX3), when_ex2(WHN_IDX_EX2), when_ex2(WHN_IDX_EX1))
  cannot_fwd_from.ex3 := Cat(false.B              , false.B              , when_ex3(WHN_IDX_EX4), when_ex3(WHN_IDX_EX3), when_ex3(WHN_IDX_EX2))
  cannot_fwd_from.ex4 := Cat(false.B              , false.B              , false.B              , when_ex4(WHN_IDX_EX4), when_ex4(WHN_IDX_EX3))
  cannot_fwd_from.wb  := Cat(false.B              , false.B              , false.B              , false.B              , when_wb (WHN_IDX_WB ) | io.long_stall_wb)

  val rs1_where_iss = where(io.iss_rs1, early_addr_cmp_iss_rs1)
  val rs2_where_iss = where(io.iss_rs2, early_addr_cmp_iss_rs2)
  val rs1_where_ex1 = io.rs1_where_ex1
  val rs2_where_ex1 = io.rs2_where_ex1

  val rs1_available_iss = fwd_available(rs1_where_iss, ready_mask)
  val rs2_available_iss = fwd_available(rs2_where_iss, ready_mask)
  val rs1_available_ex1 = fwd_available(rs1_where_ex1, ready_mask)
  val rs2_available_ex1 = fwd_available(rs2_where_ex1, ready_mask)

  val rs1_when_iss = rel_when(rs1_where_iss, cannot_fwd_from)
  val rs2_when_iss = rel_when(rs2_where_iss, cannot_fwd_from)

  val rs1_fwd_sel_iss = fwd_sel(rs1_available_iss)
  val rs2_fwd_sel_iss = fwd_sel(rs2_available_iss)
  val rs1_fwd_sel_ex1 = fwd_sel(rs1_available_ex1)
  val rs2_fwd_sel_ex1 = fwd_sel(rs2_available_ex1)

  val agu_fwd_sel_iss = MuxCase(AGU_FWD_NONE, Seq(
    early_addr_cmp_agu_iss(3)      -> AGU_FWD_EX1_Q,  // ex2_in
    early_addr_cmp_agu_iss(2)      -> AGU_FWD_EX2_Q,  // ex3_in
    early_addr_cmp_agu_iss(1)      -> AGU_FWD_EX3_Q,  // ex4_in
    early_addr_cmp_agu_iss(0)      -> AGU_FWD_EX4_Q   // wbu_in
  ))

  val long_stall_iss = io.raw_long_valid_iss &
                       (io.long_in_flight | io.long_stall_wb)

  io.rs1_fwd_sel_iss := rs1_fwd_sel_iss
  io.rs2_fwd_sel_iss := rs2_fwd_sel_iss
  io.rs1_fwd_sel_ex1 := rs1_fwd_sel_ex1
  io.rs2_fwd_sel_ex1 := rs2_fwd_sel_ex1
  io.agu_fwd_sel_iss := agu_fwd_sel_iss
  io.nxt_rs1_where_ex1 := advance_where(rs1_where_iss, rs1_available_iss)
  io.nxt_rs2_where_ex1 := advance_where(rs2_where_iss, rs2_available_iss)
  io.interlock := long_stall_iss ||
                  ((io.iss_rs1.need & rs1_when_iss) |
                   (io.iss_rs2.need & rs2_when_iss)).orR

  if (CONFIG_SIMULATION) {
    dontTouch(rs1_when_iss)
    dontTouch(rs2_when_iss)
    dontTouch(rs1_where_iss)
    dontTouch(rs2_where_iss)
  }
}
