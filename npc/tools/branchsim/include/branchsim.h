#ifndef _BRANCH_SIM_H_
#define _BRANCH_SIM_H_

#include <ctype.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_THREADS 16
#define HASH_TABLE_SIZE 131071

typedef enum {
  TYPE_ALU = 0,
  TYPE_LD_ST,
  TYPE_MUL,
  TYPE_DIV,
  TYPE_BRANCH,
  TYPE_COUNT
} InstrType;

typedef enum {
  BR_BEQ = 0,
  BR_BNE,
  BR_BLT,
  BR_BGE,
  BR_BLTU,
  BR_BGEU,
  BR_JAL,
  BR_JALR,
  BR_J,
  BR_OTHER,
  BR_TYPE_COUNT
} BranchType;

typedef struct {
  uint32_t pc;
  InstrType type;
  char mnemonic[32];
  char operands[128];
  int src_regs[3];
  int src_count;
  int dst_reg;
} Instruction;

typedef struct {
  uint32_t pc;
  int index;
  int used;
} HashEntry;

typedef struct {
  int64_t matched;
  int64_t type_count[TYPE_COUNT];
  int64_t reg_used[32];
  int64_t branch_type_count[BR_TYPE_COUNT];
  int64_t branch_taken_per_type[BR_TYPE_COUNT];
  int64_t branch_not_taken_per_type[BR_TYPE_COUNT];
  int64_t branch_forward;
  int64_t branch_backward;
  int64_t branch_taken_total;
  uint64_t branch_distance_sum;
  uint64_t max_jump_distance;
} ThreadResult;

typedef struct {
  const uint32_t *pc_sequence;
  int total_count;
  int start_idx;
  int end_idx;
  const Instruction *instructions;
  const HashEntry *hash_table;
  ThreadResult result;
} ThreadWork;

typedef struct {
  const char *name;
  int id;
} RegMap;

#endif