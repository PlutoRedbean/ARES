#ifndef __REG_H__
#define __REG_H__

#include <common.h>
#include <svdpi.h>

#define GPR_NUM MUXDEF(CONFIG_RVE, 16, 32)

extern "C" void write_reg(const int data, const int addr);
extern "C" void init_reg(const int data, const int index);

void isa_reg_display();
word_t isa_reg_str2val(const char *s, bool *success);
word_t gpr(const int index);

static inline int check_reg_idx(int idx) {
  assert(idx >= 0 && idx < GPR_NUM);
  return idx;
}

static inline const char* reg_name(int idx) {
  extern const char* regs[];
  return regs[idx];
}

#endif
