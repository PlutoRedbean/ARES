package npc

import chisel3._
import chisel3.util._
import AutoConfig._
import MundusConfig._
import MundusParams._
import DPUParams._
import Func._

class isu_rf extends Module {
  val io = IO(new Bundle {
    val gpr_rs1_val = Input(UInt(REG_DATA_WIDTH.W))
    val gpr_rs2_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex1_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex2_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex3_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val ex4_reg_val = Input(UInt(REG_DATA_WIDTH.W))
    val wb_reg_val  = Input(UInt(REG_DATA_WIDTH.W))

    val rs1_fwd_sel_iss = Input(UInt(ISU_FWD_SEL_WIDTH.W))
    val rs2_fwd_sel_iss = Input(UInt(ISU_FWD_SEL_WIDTH.W))

    val rs1_val = Output(UInt(REG_DATA_WIDTH.W))
    val rs2_val = Output(UInt(REG_DATA_WIDTH.W))
  })

  private def fwd_data(sel: UInt, rf_value: UInt): UInt = 
    Fill(32, sel(ISU_FWD_IDX_NONE)) & rf_value       |
    Fill(32, sel(ISU_FWD_IDX_EX1 )) & io.ex1_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX2 )) & io.ex2_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX3 )) & io.ex3_reg_val |
    Fill(32, sel(ISU_FWD_IDX_EX4 )) & io.ex4_reg_val |
    Fill(32, sel(ISU_FWD_IDX_WB  )) & io.wb_reg_val

  io.rs1_val := fwd_data(io.rs1_fwd_sel_iss, io.gpr_rs1_val)
  io.rs2_val := fwd_data(io.rs2_fwd_sel_iss, io.gpr_rs2_val)
}
