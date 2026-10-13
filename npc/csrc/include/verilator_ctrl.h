#ifndef __VERILATOR_CTRL_H__
#define __VERILATOR_CTRL_H__

#include <common.h>

#ifdef CONFIG_FORCE_WAVE
#define WAVE
#endif

extern "C" void get_npc_pc(int pc);
extern "C" void get_npc_pc_next(int pc_next);

word_t get_pc();
word_t get_pc_next();
int is_reset();
void init_verilator(int argc, char** argv);
void single_cycle();
void verilator_final();
void end_verilator();
bool finish();

#endif
