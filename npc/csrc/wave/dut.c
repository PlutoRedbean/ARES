/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <difftest.h>

#include <dlfcn.h>
#include <cpu.h>
#include <reg.h>
#include <mem.h>
#include <utils.h>
#include <trace.h>
#include <dbg.h>

void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction) = NULL;
void (*ref_difftest_regcpy)(void *dut, bool direction) = NULL;
void (*ref_difftest_exec)(uint64_t n) = NULL;
void (*ref_difftest_raise_intr)(uint64_t NO) = NULL;

#ifdef CONFIG_DIFFTEST

static bool is_skip_ref = false;
static int skip_dut_nr_inst = 0;

extern "C" void difftest_skip_ref() {
  is_skip_ref = true;
  skip_dut_nr_inst = 0;
}

void difftest_skip_dut(int nr_ref, int nr_dut) {
  skip_dut_nr_inst += nr_dut;

  while (nr_ref -- > 0) {
    ref_difftest_exec(1);
  }
}

static bool isa_difftest_checkregs(diff_context_t *ref_r, vaddr_t pc) {
  if (ref_r->pc != pc) {
    Log_err("Different pc, right = " FMT_WORD ", wrong = " FMT_WORD ", diff = " FMT_WORD, ref_r->pc, pc, ref_r->pc ^ pc);
    return false;
  }
  for (int i = 0; i < GPR_NUM; i++) {
    word_t dut = __dut__.gpr[i];
    word_t ref = ref_r->gpr[i];
    if (__dut__.gpr[i] != ref_r->gpr[i]) {
      Log_err("Reg: %s is different at pc = " FMT_WORD ", right = " FMT_WORD ", wrong = " FMT_WORD ", diff = " FMT_WORD,
                reg_name(i),                    pc,                   ref,                  dut,              ref ^ dut);
      return false;
    }
  }
  return true;
}

void init_difftest(char *ref_so_file, long img_size, int port) {
  assert(ref_so_file != NULL);

  void *handle;
  handle = dlopen(ref_so_file, RTLD_LAZY);
  assert(handle);

  ref_difftest_memcpy = (void (*)(paddr_t, void*, size_t, bool))dlsym(handle, "difftest_memcpy");
  assert(ref_difftest_memcpy);

  ref_difftest_regcpy = (void (*)(void*, bool))dlsym(handle, "difftest_regcpy");
  assert(ref_difftest_regcpy);

  ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  assert(ref_difftest_exec);

  ref_difftest_raise_intr = (void (*)(uint64_t))dlsym(handle, "difftest_raise_intr");
  assert(ref_difftest_raise_intr);

  void (*ref_difftest_init)(int) = (void (*)(int))dlsym(handle, "difftest_init");
  assert(ref_difftest_init);

  Log("Differential testing: %s", ANSI_FMT("ON", ANSI_FG_GREEN));
      
  ref_difftest_init(port);
#ifndef IS_JYD
  ref_difftest_memcpy(RESET_VECTOR, (void *)(uintptr_t)vir_to_phy(RESET_VECTOR), img_size, DIFFTEST_TO_REF);
#else
  ref_difftest_memcpy(0x80000000, (void *)(uintptr_t)vir_to_phy(0x80000000), CONFIG_IROM_SIZE_BYTES, DIFFTEST_TO_REF);
  if (img_size > 0x100000)
    ref_difftest_memcpy(0x80100000, (void *)(uintptr_t)vir_to_phy(0x80100000), img_size - 0x100000, DIFFTEST_TO_REF);
#endif
  ref_difftest_regcpy(&__dut__, DIFFTEST_TO_REF);
}

static void checkregs(diff_context_t *ref, vaddr_t pc) {
  if (!isa_difftest_checkregs(ref, pc)) {
    sim_state.state = ABORT;
    trace_log_output();
    isa_reg_display();
  }
}

void difftest_step(vaddr_t pc, vaddr_t npc) {
  diff_context_t ref_r;

  if (skip_dut_nr_inst > 0) {
    ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
    if (ref_r.pc == npc) {
      skip_dut_nr_inst = 0;
      checkregs(&ref_r, npc);
      return;
    }
    skip_dut_nr_inst --;
    if (skip_dut_nr_inst == 0)
      panic("can not catch up with ref.pc = " FMT_WORD " at pc = " FMT_WORD, ref_r.pc, pc);
    return;
  }

  if (is_skip_ref) {
    // to skip the checking of an instruction, just copy the reg state to reference design
    ref_difftest_regcpy(&__dut__, DIFFTEST_TO_REF);
    is_skip_ref = false;
    return;
  }

  ref_difftest_exec(1);
  ref_difftest_regcpy(&ref_r, DIFFTEST_TO_DUT);
  
  checkregs(&ref_r, pc);
}
#else
void difftest_skip_ref() { }
void init_difftest(char *ref_so_file, long img_size, int port) { }
#endif
