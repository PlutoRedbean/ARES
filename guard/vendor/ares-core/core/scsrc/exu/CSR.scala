package npc

import chisel3._
import chisel3.util._
import MundusConfig._
import CSRParams._
import RISCV_INST._

class CSR extends Module {
  val io = IO(new Bundle {
    val valid       = Input(Bool())
    val ctrl        = Input(UInt(CSR_CMD_WIDTH.W))
    val wdata       = Input(UInt(REG_DATA_WIDTH.W))
    val mask        = Input(UInt(CSR_MASK_WIDTH.W))

    val timer_irq = Input(Bool())
    val irq_take = Input(Bool())
    val irq_pc = Input(UInt(32.W))
    val irq_eligible = Output(Bool())
    val ecall       = Input(Bool())
    val mret        = Input(Bool())
    val trap_pc     = Input(UInt(PC_DATA_WIDTH.W))

    val rdata       = Output(UInt(REG_DATA_WIDTH.W))
    val mtvec       = Output(UInt(PC_DATA_WIDTH.W))
    val mepc        = Output(UInt(PC_DATA_WIDTH.W))
  })

  val csrRegs = CSR_ENABLED_SPECS.map { spec =>
    spec -> RegInit(spec.init.U(REG_DATA_WIDTH.W))
  }

  private def csrReg(name: String): UInt = {
    csrRegs.collectFirst { case (spec, reg) if spec.name == name => reg }.get
  }

  val mie = csrReg(CSR_NAME_MIE)
  val mstatus = csrReg(CSR_NAME_MSTATUS)
  val mepc    = csrReg(CSR_NAME_MEPC)
  val mtvec   = csrReg(CSR_NAME_MTVEC)
  val mcause  = csrReg(CSR_NAME_MCAUSE)

  val mstatus_mpie = mstatus(7)
  val mstatus_mie  = mstatus(3)

  val old_data = MuxLookup(io.mask, 0.U(REG_DATA_WIDTH.W))(
    csrRegs.map { case (spec, reg) => spec.mask -> (if (spec.name == CSR_NAME_MIP) (io.timer_irq.asUInt << 7) else reg) }
  )

  val csr_wdata = MuxLookup(io.ctrl, io.wdata)(Seq(
    CSR_RW -> io.wdata,
    CSR_RS -> (old_data | io.wdata),
    CSR_RC -> (old_data & ~io.wdata)
  ))

  val do_write = io.valid && io.ctrl =/= CSR_NONE && io.mask.orR

  io.irq_eligible := mstatus_mie && mie(7) && io.timer_irq

  when(io.irq_take || io.ecall) {
    mepc := Mux(io.irq_take, io.irq_pc, io.trap_pc) & "hfffffffc".U
    mcause := Mux(io.irq_take, "h80000007".U, 11.U)
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
    for ((spec, reg) <- csrRegs) {
      when(io.mask === spec.mask) {
        if (spec.name == CSR_NAME_MIE) {
          reg := csr_wdata & "h80".U
        } else if (spec.name == CSR_NAME_MSTATUS) {
          reg := (csr_wdata & "h88".U) | "h1800".U
        } else if (spec.name == CSR_NAME_MTVEC || spec.name == CSR_NAME_MEPC) {
          reg := csr_wdata & "hfffffffc".U
        } else if (spec.name != CSR_NAME_MIP) {
          reg := csr_wdata
        }
      }
    }
  }

  io.rdata := old_data
  io.mtvec := mtvec
  io.mepc  := mepc
}
