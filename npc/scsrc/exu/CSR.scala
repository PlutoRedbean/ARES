package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import CSRParams._
import RISCV_INST._

class CSR extends Module {
  val io = IO(new Bundle {
    val read_mask   = Input(UInt(CSR_MASK_WIDTH.W))

    val valid       = Input(Bool())
    val ctrl        = Input(UInt(CSR_CMD_WIDTH.W))
    val wdata       = Input(UInt(REG_DATA_WIDTH.W))
    val mask        = Input(UInt(CSR_MASK_WIDTH.W))

    val ecall       = Input(Bool())
    val mret        = Input(Bool())
    val trap_pc     = Input(UInt(PC_DATA_WIDTH.W))
    val timer_irq   = Input(Bool())
    val interrupt_take = Input(Bool())
    val interrupt_pc = Input(UInt(PC_DATA_WIDTH.W))

    val rdata       = Output(UInt(REG_DATA_WIDTH.W))
    val mtvec       = Output(UInt(PC_DATA_WIDTH.W))
    val mepc        = Output(UInt(PC_DATA_WIDTH.W))
    val interrupt_pending = Output(Bool())
  })

  val csrRegs = CSR_ENABLED_SPECS.map { spec =>
    spec -> RegInit(spec.init.U(REG_DATA_WIDTH.W))
  }

  private def csrReg(name: String): UInt = {
    csrRegs.collectFirst { case (spec, reg) if spec.name == name => reg }.get
  }

  val mstatus = csrReg(CSR_NAME_MSTATUS)
  val mie     = if (CONFIG_HAS_CSR_MIE) csrReg(CSR_NAME_MIE) else 0.U(REG_DATA_WIDTH.W)
  val mip     = if (CONFIG_HAS_CSR_MIP) csrReg(CSR_NAME_MIP) else 0.U(REG_DATA_WIDTH.W)
  val mepc    = csrReg(CSR_NAME_MEPC)
  val mtvec   = csrReg(CSR_NAME_MTVEC)
  val mcause  = csrReg(CSR_NAME_MCAUSE)
  val mcycle  = if (CONFIG_HAS_CSR_MCYCLE) csrReg(CSR_NAME_MCYCLE) else 0.U(REG_DATA_WIDTH.W)
  val mcycleh = if (CONFIG_HAS_CSR_MCYCLE) csrReg(CSR_NAME_MCYCLEH) else 0.U(REG_DATA_WIDTH.W)

  val mstatus_mpie = mstatus(7)
  val mstatus_mie  = mstatus(3)

  val read_data = MuxLookup(io.read_mask, 0.U(REG_DATA_WIDTH.W))(
    csrRegs.map { case (spec, reg) => spec.mask -> reg }
  )
  val write_old_data = MuxLookup(io.mask, 0.U(REG_DATA_WIDTH.W))(
    csrRegs.map { case (spec, reg) => spec.mask -> reg }
  )

  val csr_wdata = MuxLookup(io.ctrl, io.wdata)(Seq(
    CSR_RW -> io.wdata,
    CSR_RS -> (write_old_data | io.wdata),
    CSR_RC -> (write_old_data & ~io.wdata)
  ))

  /* CSRRS/CSRRC with a zero source are reads and must not freeze mcycle. */
  val do_write = io.valid && io.ctrl =/= CSR_NONE && io.mask.orR &&
    (io.ctrl === CSR_RW || io.wdata.orR)
  val machine_timer_bit = (1.U(REG_DATA_WIDTH.W) << 7)

  when(io.interrupt_take) {
    mepc := io.interrupt_pc
    mcause := "h80000007".U(REG_DATA_WIDTH.W)
    mstatus := Cat(
      mstatus(REG_DATA_WIDTH - 1, 8),
      mstatus_mie,
      mstatus(6, 4),
      false.B,
      mstatus(2, 0)
    )
  } .elsewhen(io.ecall) {
    mepc := io.trap_pc
    mcause := 0xb.U(REG_DATA_WIDTH.W)
    mstatus := Cat(
      mstatus(REG_DATA_WIDTH - 1, 8), 
      mstatus_mie,                     // bit 7 更新为 MIE 的旧值
      mstatus(6, 4),
      false.B,                         // bit 3 更新为 0
      mstatus(2, 0)
    )
  } .elsewhen(io.mret) {
    mstatus := Cat(
      mstatus(REG_DATA_WIDTH - 1, 8),
      true.B,                          // bit 7 更新为 1
      mstatus(6, 4),
      mstatus_mpie,                    // bit 3 更新为 MPIE 的旧值
      mstatus(2, 0)
    )
  }.elsewhen(do_write) {
    for ((spec, reg) <- csrRegs
         if spec.name != CSR_NAME_MIP &&
            spec.name != CSR_NAME_MCYCLE &&
            spec.name != CSR_NAME_MCYCLEH) {
      when(io.mask === spec.mask) {
        reg := csr_wdata
      }
    }
  }

  if (CONFIG_HAS_CSR_MCYCLE) {
    val mcycle_next = Cat(mcycleh, mcycle) + 1.U
    when(do_write && io.mask === CSR_MASK_MCYCLE) {
      mcycle := csr_wdata
    }.elsewhen(do_write && io.mask === CSR_MASK_MCYCLEH) {
      mcycleh := csr_wdata
    }.otherwise {
      mcycle := mcycle_next(31, 0)
      mcycleh := mcycle_next(63, 32)
    }
  }

  /* MTIP is event-latched so a one-cycle peripheral pulse cannot be lost. */
  if (CONFIG_HAS_CSR_MIP) {
    when(io.interrupt_take) {
      mip := mip & ~machine_timer_bit
    }.elsewhen(io.timer_irq) {
      mip := mip | machine_timer_bit
    }.elsewhen(do_write && io.mask === CSR_MASK_MIP) {
      mip := csr_wdata
    }
  }

  io.rdata := read_data
  io.mtvec := mtvec
  io.mepc  := mepc
  io.interrupt_pending := (if (CONFIG_HAS_CSR_MIE && CONFIG_HAS_CSR_MIP) {
      mstatus(3) && mie(7) && mip(7)
    } else {
      false.B
    })
}
