#include <trace.h>

#include <stdio.h>
#include <cpu.h>
#include <mem.h>
#include <sim.h>
#include <dbg.h>

Elf_Ehdr elf_head;
Elf_Shdr *shdr;
int shstr_ndx;
int symtab_ndx;
int strtab_ndx;

int indentation = 0;

static bool bootloader_done = false;
static word_t cpy_tmp = 0;
static word_t cpy_len = 0;
static word_t cpy_in  = 0;
static word_t cpy_end = 0x0;

extern uint64_t inst_cnt[TYPE_COUNT];

enum { FSBL, SSBL, FSBL_MEMCPY, SSBL_MEMCPY, SSBL_MEMSET };

const char *bl_name_lut[] = {
  "_fsbl",
  "_ssbl",
  "_fsbl_memcpy",
  "_ssbl_memcpy",
  "_ssbl_memset"
};

Stack *func_list;

ringbuf itrace = {0, 0, 0, ITRACE_SIZE};
trace_log itrace_list[ITRACE_SIZE];

ringbuf mtrace = {0, 0, 0, MTRACE_SIZE};
trace_log mtrace_list[MTRACE_SIZE];

ringbuf dtrace = {0, 0, 0, DTRACE_SIZE};
trace_log dtrace_list[DTRACE_SIZE];

ringbuf ptrace = {0, 0, 0, PTRACE_SIZE};
trace_log ptrace_list[PTRACE_SIZE];

#ifdef CONFIG_MTRACE
extern "C" void mread_trace(int addr, unsigned int rdata, char num) {
  // rdata is the original data from databus
  int addr_low = addr & 0x3;
  int offset = addr_low << 3;
  int bytes = (num <= 2) ? (1 << num) : 0;
  rdata >>= offset;
  char data_msg[4][3] = {"XX", "XX", "XX", "XX"};
  for (int i = 0; i < bytes; i++) {
    int byte_lane = addr_low + i;
    if (byte_lane < 4) {
      snprintf(data_msg[byte_lane], 3, "%02x", (uint8_t)rdata);
    }
    rdata >>= 8;
  }
  if (MTRACE_COND) {
    trace_log msg;
    snprintf(msg, LOGBUF_SIZE, "reading %d bytes to addr: " FMT_WORD "\tdata: %s %s %s %s\tat PC: " FMT_WORD,
                                        bytes, addr, data_msg[3], data_msg[2], data_msg[1], data_msg[0], cpu.pc);
    add_log(msg, mtrace, mtrace_list);
  }
  mtrace_csv(READ,cpu.pc,addr,bytes);
}

extern "C" void mwrite_trace(int addr, int wdata, char num) {
  // wdata has been shifted by LSU
  int addr_low = addr & 0x3;
  int bytes = (num <= 2) ? (1 << num) : 0;
  char data_msg[4][3] = {"XX", "XX", "XX", "XX"};
  for (int i = 0; i < bytes; i++) {
    int byte_lane = addr_low + i;
    if (byte_lane < 4) {
      snprintf(data_msg[byte_lane], 3, "%02x", (uint8_t)wdata);
    }
    wdata >>= 8;
  }
  if (MTRACE_COND) {
    trace_log msg;
    snprintf(msg, LOGBUF_SIZE, "writing %d bytes to addr: " FMT_WORD "\tdata: %s %s %s %s\tat PC: " FMT_WORD,
                                        bytes, addr, data_msg[3], data_msg[2], data_msg[1], data_msg[0], cpu.pc);
    add_log(msg, mtrace, mtrace_list);
  }
  mtrace_csv(WRITE,cpu.pc,addr,bytes);
}
#else
extern "C" void mread_trace(int raddr, unsigned int rdata, char num) {}
extern "C" void mwrite_trace(int waddr, int wdata, char num) {}
#endif

void mtrace_csv(int type, word_t pc, word_t address, int size) {
#ifdef CONFIG_MTRACE_SCATTER_PLOT
  if (type == READ) {
    csv_write("read,%u,%u,%u,%lu\n", pc, address, size, inst_cnt[TYPE_TOTAL] + 1);
    
  }
  else if (type == WRITE) {
    csv_write("write,%u,%u,%u,%lu\n", pc, address, size, inst_cnt[TYPE_TOTAL] + 1);
  }
#endif
}

void trace_log_output() {
  static bool __executed__ = false;
  if (__executed__ == true) return;
  
  IFDEF(CONFIG_FTRACE, ftrace_end());
#ifdef CONFIG_ITRACE
  log_write("===================STARTING ITRACE===================\n");
  log_write("\n");
  log_all_print(itrace, itrace_list);
  log_write("\n");
  log_write("====================ENDING ITRACE===================\n");
#endif
  
#ifdef CONFIG_MTRACE
  log_write("\n===================STARTING MTRACE===================\n");
  log_write("\n");
  log_all_print(mtrace, mtrace_list);
  log_write("\n");
  log_write("====================ENDING MTRACE===================\n");
#endif
  
#ifdef CONFIG_PTRACE
  log_write("\n===================STARTING PTRACE===================\n");
  log_write("\n");
  log_all_print(ptrace, ptrace_list);
  log_write("\n");
  log_write("====================ENDING PTRACE===================\n");
#endif
  __executed__ = true;
}

#if defined(CONFIG_FTRACE) || defined(BLTRACE)
bool is_call(const word_t rd_opcode) {
  Assert(indentation >= 0, "Invalid indentation.");

  bool ret = (rd_opcode == JALR_RA) || (rd_opcode == JAL_RA); 
  return ret;
}

bool is_ret(const word_t inst) {
  Assert(indentation >= 0, "Invalid indentation.");

  bool ret = inst == RET;
  return ret;
}

#ifdef CONFIG_FTRACE
void ftrace_init(const vaddr_t pc, const vaddr_t dnpc) {
  word_t inst = paddr_read(vir_to_phy(pc));
  word_t rd_opcode = BITS(inst, 11, 0);
  if (is_call(rd_opcode)) {
    Func *func = get_func(dnpc);
    Assert(func, "Fail to get func");

    print_indentation(pc);
    printf("call [%s@" FMT_WORD "]\n", func->name, dnpc);
    
    indentation++;
  } else if (is_ret(inst)) {
    indentation--;

    Func *func = get_func(pc);
    Assert(func, "Fail to get func");
    
    print_indentation(pc);
    printf("ret  [%s@" FMT_WORD "]\n", func->name, dnpc);
    
  }
}
#endif

#ifdef BLTRACE
static bool is_memcpy(Func * func) {
  return strcmp(func->name, bl_name_lut[FSBL_MEMCPY]) == 0 ||
         strcmp(func->name, bl_name_lut[SSBL_MEMCPY]) == 0;
}

void bltrace_init(const vaddr_t pc, const vaddr_t dnpc) {
  word_t inst = paddr_read(vir_to_phy(pc));
  word_t rd_opcode = BITS(inst, 11, 0);
  Func *this_func = get_func(pc);
  Func *next_func = get_func(dnpc);
  Assert(next_func, "Fail to get func");

  if (dnpc == next_func->lower) {
    if (strcmp(next_func->name, bl_name_lut[FSBL]) == 0) {
      printf("FSBL processing: ");
      fflush(stdout);
    } else if (strcmp(next_func->name, bl_name_lut[SSBL]) == 0) {
      printf("SSBL processing: ");
      fflush(stdout);
    } else if (is_memcpy(next_func)) {
      cpy_in  = gpr(11);
      cpy_tmp = cpy_in;
      cpy_len = gpr(12);
      cpy_end = cpy_in + cpy_len;
      Log("%d", cpy_len);
    }
  }
  
  // Log("%s, " FMT_WORD, this_func->name, inst);
  if (is_ret(inst) &&
     (strcmp(next_func->name, bl_name_lut[FSBL]) == 0 ||
      strcmp(next_func->name, bl_name_lut[SSBL]) == 0)) {
    printf(" done.\n");
    fflush(stdout);
  }

  if (is_memcpy(next_func) && gpr(11) != cpy_tmp) {
    cpy_tmp = gpr(11);
    if (cpy_len == 0) {
      return;
    } else if ((gpr(11) - cpy_in) % (cpy_len / 10) == 0) {
      printf("#");
      fflush(stdout);
    }
  }
}
#endif

void print_indentation(const vaddr_t pc) {
  printf(FMT_WORD ": ", pc);
  for (int i = 0; i < indentation; i++) {
    printf("  ");
  }
}

Func *get_func(const vaddr_t pc) {
  Assert(func_list, "Empty func_list.");
  
  Func *__out__ = NULL;
  STACK_FOREACH(func_list, cur) {
    __out__ = (Func *)cur->value;
    if (pc >= __out__->lower && pc <= __out__->upper) {
      break;
    }
  }

  return __out__;
}

void ftrace_end() {
  STACK_FOREACH(func_list, cur) {
    free(cur->value);
  }
  Stack_destroy(func_list);
}

void load_elf(const char *elf_file) {
  Assert(elf_file, "No elf is given.");

  func_list = Stack_create();
  Assert(func_list, "Out of memory.");

  FILE *fp = fopen(elf_file, "r");
  Assert(fp, "Fail to open '%s'", elf_file);

  elf_head_init(fp);
  elf_section_init(fp);
  elf_read(fp);
  elf_end(fp);

  Log("%s is loaded.", elf_file);
  
  fclose(fp);
}

void elf_head_init(FILE *fp) {
  int r = fread(&elf_head, sizeof(Elf_Ehdr), 1, fp);
  Assert(r, "Fail to open the elf file.");

  unsigned char mag_num[5] = {elf_head.e_ident[EI_MAG0], elf_head.e_ident[EI_MAG1], elf_head.e_ident[EI_MAG2], elf_head.e_ident[EI_MAG3]};
  Assert(strcmp((char *)mag_num, ELFMAG) == 0, "Incorrect magic number.");

  char elf_class = elf_head.e_ident[EI_CLASS];
  Assert(ELFCLASS32 == elf_class, "OP and elf-object unmatched. Did you give the incorrect elf file?");

  Assert(elf_head.e_shstrndx != SHN_UNDEF, "The file has no section name string table.");
}

void elf_section_init(FILE *fp) {
  shdr = (Elf_Shdr *)calloc(elf_head.e_shnum, sizeof(Elf_Shdr));
  Assert(shdr, "Out of memory.");

  int r = fseek(fp, elf_head.e_shoff, SEEK_SET);
  Assert(r != EOF, "Fail to fseek.");

  r = fread(shdr, sizeof(Elf_Shdr) * elf_head.e_shnum, 1, fp);
  Assert(r != EOF, "Fail to fread.");

  shstr_ndx = elf_head.e_shstrndx;
  char shstrtab[shdr[shstr_ndx].sh_size];
  char *temp = shstrtab;

  r = fseek(fp, shdr[shstr_ndx].sh_offset, SEEK_SET);
  Assert(r != EOF, "Fail to fseek.");
  r = fread(shstrtab, shdr[shstr_ndx].sh_size, 1, fp);
  Assert(r != EOF, "Fail to fread.");

  for (int i = 0; i < elf_head.e_shnum; i++) {
    temp = shstrtab;
    temp = temp + shdr[i].sh_name;
    if (strcmp(temp, ".symtab") == 0) symtab_ndx = i;
    if (strcmp(temp, ".strtab") == 0) strtab_ndx = i;
  }
}

void elf_read(FILE *fp) {
  char strtab[shdr[strtab_ndx].sh_size];
  int r = fseek(fp, shdr[strtab_ndx].sh_offset, SEEK_SET);
  Assert(r != EOF, "Fail to fseek.");
  r = fread(strtab, shdr[strtab_ndx].sh_size, 1, fp);
  Assert(r != EOF, "Fail to fread.");

  Elf_Sym sym[shdr[symtab_ndx].sh_size];
  r = fseek(fp, shdr[symtab_ndx].sh_offset, SEEK_SET);
  Assert(r != EOF, "Fail to fseek.");
  r = fread(sym, shdr[symtab_ndx].sh_size, 1, fp);
  Assert(r != EOF, "Fail to fread.");

  int symnum = shdr[symtab_ndx].sh_size / sizeof(Elf32_Sym);
  char *temp = strtab;

  for (int i = 0; i < symnum; i++)
  {
    temp = strtab;
    temp = temp + sym[i].st_name;
    if (ELF_ST_TYPE(sym[i].st_info) == STT_FUNC) {
      Func *func = (Func *)calloc(1, sizeof(Func));
      snprintf(func->name, FUNC_NAME_BUF, "%s", temp);
      func->upper = sym[i].st_value + sym[i].st_size - 0x4;
      func->lower = sym[i].st_value;
      Stack_push(func_list, func);
      // printf("函数的名称: %s\n", temp);
      // printf("函数的范围: [0x%08x, 0x%08x]\n", sym[i].st_value, sym[i].st_value + sym[i].st_size - 0x4);
    }
  }
}

void elf_end(FILE *fp) {
  free(shdr);
}
#endif
