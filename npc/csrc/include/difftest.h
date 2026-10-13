#ifndef __DIFFTEST_H__
#define __DIFFTEST_H__

#include <common.h>
#include <cpu.h>

#define RISCV_GPR_TYPE uint32_t
#define RISCV_GPR_NUM  GPR_NUM
#define DIFFTEST_REG_SIZE (sizeof(RISCV_GPR_TYPE) * (RISCV_GPR_NUM + 1)) // GPRs + pc

extern diff_context_t __dut__;

enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };

extern "C" void difftest_skip_ref();
void difftest_skip_dut(int nr_ref, int nr_dut);
void difftest_step(vaddr_t pc, vaddr_t npc);
void init_difftest(char *ref_so_file, long img_size, int port);

#endif
