#include <reg.h>
#include <cpu.h>
#include <verilator_ctrl.h>
#include <dbg.h>

word_t _gpr_[GPR_NUM] = {};

const char *regs[] = {
  "$0", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
  "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
};

extern "C" void write_reg(const int data, const int addr) { if (addr > 0) _gpr_[addr] = (word_t)data; }
extern "C" void init_reg(const int data, const int index) { _gpr_[index] = data; }

void isa_reg_display() {
  printf("pc%10c" FMT_WORD "\n", ' ', cpu.pc);
  for (int i = 0; i < GPR_NUM; i++) {
    printf("r%-2d\t%-3s " FMT_WORD "\n", i, regs[i], gpr(i));
  }
}

word_t isa_reg_str2val(const char *s, bool *success) {
  for (int i = 1; i < GPR_NUM; i++) {
    if (strcmp(s, regs[i]) == 0) {
      *success = true;
      return gpr(i);
    } else if (strcmp(s, "pc") == 0) {
      *success = true;
      return cpu.pc;
    }
  }

  Log_warn("Reg not found.");
  *success = false;
  return EOF;
}

word_t gpr(const int i) {
  return _gpr_[i];
}
