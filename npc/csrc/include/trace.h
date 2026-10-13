#ifndef __TRACE_H__
#define __TRACE_H__

#include <common.h>
#include <ringbuf.h>
#include <elf.h>
#include <stack.h>

typedef Elf32_Ehdr Elf_Ehdr;
typedef Elf32_Shdr Elf_Shdr;
typedef Elf32_Sym Elf_Sym;

#define ELF_ST_TYPE ELF32_ST_TYPE

#define FUNC_NAME_BUF 32

#define READ  0
#define WRITE 1

// #define BLTRACE  1

#define RET 0x00008067
#define JALR_RA 0x0e7
#define JAL_RA 0x0ef

extern ringbuf itrace;
extern trace_log itrace_list[ITRACE_SIZE];

extern ringbuf mtrace;
extern trace_log mtrace_list[MTRACE_SIZE];

extern ringbuf dtrace;
extern trace_log dtrace_list[DTRACE_SIZE];

extern ringbuf ptrace;
extern trace_log ptrace_list[PTRACE_SIZE];

#define index_maintain(buffer) buffer.index %= buffer.size

#define add_log(logbuf, buffer, list) do { \
  index_maintain(buffer); \
  snprintf(list[buffer.index++], LOGBUF_SIZE, "%s", logbuf); \
  if (buffer.len == buffer.size) del_log(buffer); \
  else if (buffer.len < buffer.size) buffer.len++; \
} while (0)

#define del_log(buffer) do { \
  index_maintain(buffer); \
  buffer.head++; \
} while (0)

#define log_all_print(buffer, list) do { \
  int read_index = buffer.head; \
  log_write("        " #buffer ": %d\n", buffer.len); \
  for (int i = 0; i < buffer.len; i++, read_index++) { \
    read_index %= buffer.size; \
    if (i < buffer.len - 1) log_write("        "); \
    else log_write("Latest: "); \
    log_write("%s\n", list[read_index]); \
  } \
} while (0)

typedef struct Func{
  char name[FUNC_NAME_BUF];
  paddr_t upper;
  paddr_t lower;
} Func;

extern "C" void mread_trace(int raddr, unsigned int rdata, char num);
extern "C" void mwrite_trace(int waddr, int wdata, char num);

void mtrace_csv(int type, word_t pc, word_t address, int size);
void trace_log_output();

void ftrace_init(const vaddr_t pc, const vaddr_t dnpc);
void ftrace_end();
Func *get_func(const vaddr_t pc);
void print_indentation(const vaddr_t pc);
bool is_call(const word_t rd_opcode);
bool is_ret(const word_t inst);
void elf_head_init(FILE *fp);
void elf_section_init(FILE *fp);
void elf_read(FILE *fp);
void elf_end(FILE *fp);
void load_elf(const char *elf_file);

#endif
