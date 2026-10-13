#ifndef __CPU_H__
#define __CPU_H__

#include <common.h>
#include <reg.h>

#define SAFETY_CLK_CYCLE 10000

typedef struct {
  word_t pc;
  word_t pc_next;
  word_t *gpr;
  uint32_t inst;
} CPU;

typedef struct {
  word_t gpr[GPR_NUM];
  word_t pc;
} diff_context_t;

extern CPU cpu;

void init_cpu(word_t pc, word_t pc_next);
void init_dut();
bool retire_event_pending();
void cpu_exec(uint64_t n);
void cpu_quit();

#endif
