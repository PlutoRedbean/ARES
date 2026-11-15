package npc

import chisel3._
import chisel3.util._
import MundusConfig._
import MundusParams._
import DPUParams._

// EX1 forwarding for every unit that consumes rs1/rs2 in EX1.
//
// The ISS stage has already:
//   1. selected the newest value available in ISS;
//   2. captured that value as rs*_val_iss; and
//   3. converted where_iss into where_ex1, suppressing sources already used.
//
// This stage only needs to combine the registered where_ex1 with the current
// producer ready mask and overwrite the ISS value when a newer value becomes
// available in EX1.
class isu_ex1 extends Module {
  val io = IO(new Bundle {
    val rs1_where_ex1 = Input(UInt(WHERE_WIDTH.W))
    val rs2_where_ex1 = Input(UInt(WHERE_WIDTH.W))

    // Values selected by the ISS forwarding mux and captured in ISS -> EX1.
    val rs1_val_iss = Input(UInt(REG_DATA_WIDTH.W))
    val rs2_val_iss = Input(UInt(REG_DATA_WIDTH.W))

    val ex1_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val wb_reg_val  = Input(UInt(REG_DATA_WIDTH.W))

    val rs1_fwd_sel_ex1 = Input(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs2_fwd_sel_ex1 = Input(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs1_val_ex1 = Output(UInt(REG_DATA_WIDTH.W))
    val rs2_val_ex1 = Output(UInt(REG_DATA_WIDTH.W))
  })

  private def fwd_data(sel: UInt, rf_value: UInt): UInt = 
    Fill(32, sel(ISU_FWD_IDX_NONE)) & rf_value       |
    Fill(32, sel(ISU_FWD_IDX_EX1 )) & io.ex1_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX2 )) & io.ex2_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX3 )) & io.ex3_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX4 )) & io.ex4_reg_val |
    Fill(32, sel(ISU_FWD_IDX_WB  )) & io.wb_reg_val

  io.rs1_val_ex1 := fwd_data(io.rs1_fwd_sel_ex1, io.rs1_val_iss)
  io.rs2_val_ex1 := fwd_data(io.rs2_fwd_sel_ex1, io.rs2_val_iss)
}
