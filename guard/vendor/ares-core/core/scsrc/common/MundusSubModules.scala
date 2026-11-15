package npc
import chisel3._
import chisel3.util._
import chisel3.experimental.ExtModule
import MundusConfig._

// BlackBox for DPIC and Simulation Functions
class Mundus_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val pc_next_in = Input(UInt(PC_DATA_WIDTH.W))
    val cycle_done = Input(Bool())
    val bpu_update_en = Input(Bool())
    val bpu_update_pc = Input(UInt(PC_DATA_WIDTH.W))
    val predicted_pc = Input(UInt(PC_DATA_WIDTH.W))
    val predicted_taken = Input(Bool())
    val actual_pc = Input(UInt(PC_DATA_WIDTH.W))
    val actual_taken = Input(Bool())
    val environment = Input(UInt(ENVIR_WIDTH.W))
  })
}

class PipelineStats_DPIC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val retire = Input(Bool())
    val pipeline_active = Input(Bool())
    val backend_stall = Input(Bool())
    val long_stall = Input(Bool())
    val issue_hazard = Input(Bool())
    val control_redirect = Input(Bool())
    val load_replay = Input(Bool())
  })
}

class Mundus_PC extends BlackBox {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst = Input(Bool())
    val din = Input(UInt(PC_DATA_WIDTH.W))
    val dout = Output(UInt(PC_DATA_WIDTH.W))
    val wen = Input(Bool())
  })
}

class RegisterFile extends BlackBox(Map(
  "ADDR_WIDTH" -> GPR_ADDR_WIDTH,
  "DATA_WIDTH" -> REG_DATA_WIDTH)) {
  val io = IO(new Bundle {
    val clk = Input(Clock())
    val wen = Input(Bool())
    val waddr = Input(UInt(GPR_ADDR_WIDTH.W))
    val wdata = Input(UInt(REG_DATA_WIDTH.W))
    val ren = Input(Bool())
    val raddr1 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata1 = Output(UInt(REG_DATA_WIDTH.W))
    val raddr2 = Input(UInt(GPR_ADDR_WIDTH.W))
    val rdata2 = Output(UInt(REG_DATA_WIDTH.W))
  })
}
