#include <cpu.h>

#include <verilator_ctrl.h>
#include <trace.h>
#include <difftest.h>
#include <device.h>
#include <mem.h>
#include <sim.h>
#include <cache.h>
#include <dbg.h>
#include <inst_type.h>

extern word_t _gpr_[GPR_NUM];

static bool print_step = false;

typedef struct {
  word_t pc;
  word_t pc_next;
  bool rd_wen;
  uint8_t rd_addr;
  word_t rd_data;
  uint8_t environment;
} RetireEvent;

#define RETIRE_QUEUE_DEPTH 8
static RetireEvent retire_queue[RETIRE_QUEUE_DEPTH];
static unsigned retire_queue_head = 0;
static unsigned retire_queue_tail = 0;
static bool interrupt_redirect_pending = false;
static word_t interrupt_redirect_target = 0;

static bool retire_queue_empty() {
  return retire_queue_head == retire_queue_tail;
}

bool retire_event_pending() {
  return !retire_queue_empty();
}

extern "C" void retire_event_enqueue(
    int valid, int pc, int pc_next, int rd_wen, int rd_addr, int rd_data,
    int environment) {
  if (!valid) return;

  unsigned next_tail = (retire_queue_tail + 1) % RETIRE_QUEUE_DEPTH;
  Assert(next_tail != retire_queue_head, "retirement event queue overflow");
  retire_queue[retire_queue_tail] = (RetireEvent) {
    .pc = (word_t)pc,
    .pc_next = (word_t)pc_next,
    .rd_wen = rd_wen != 0,
    .rd_addr = (uint8_t)rd_addr,
    .rd_data = (word_t)rd_data,
    .environment = (uint8_t)environment,
  };
  retire_queue_tail = next_tail;
}

extern "C" void interrupt_redirect(int target) {
  Assert(!interrupt_redirect_pending,
      "interrupt redirect arrived before the previous redirect was consumed");
  interrupt_redirect_target = (word_t)target;
  interrupt_redirect_pending = true;
}

static RetireEvent retire_event_pop() {
  Assert(!retire_queue_empty(), "retirement event queue underflow");
  RetireEvent event = retire_queue[retire_queue_head];
  retire_queue_head = (retire_queue_head + 1) % RETIRE_QUEUE_DEPTH;
  return event;
}

uint64_t timer = 0; // unit: us

CPU cpu;
diff_context_t __dut__;

extern ringbuf ptrace;
extern trace_log ptrace_list[PTRACE_SIZE];

const char *type_list[] = {
#define func(name) #name,
    TYPE_LIST
#undef func
};

uint64_t inst_cnt[TYPE_COUNT] = {0};
uint64_t cycle_cnt = 0;

#ifdef CONFIG_DIFFTEST
static void dut_update() {
  __dut__.pc = cpu.pc;
  for (int i = 0; i < GPR_NUM; i++) {
    __dut__.gpr[i] = _gpr_[i];
  }
}

void init_dut() {
  dut_update();
}
#endif

static void execute_once(trace_log *logbuf) {
  int clk_cycle = 0;
  while (retire_queue_empty()) {
    if (finish()) { cpu_quit(); break; }
#ifdef CONFIG_HAS_VERILATOR
    if (clk_cycle >= SAFETY_CLK_CYCLE) {
      Log_warn("Single instruction recycling for %d times.", SAFETY_CLK_CYCLE);
      Log_warn("This should never happen");
      trace_log_output();
      sim_state.state = ABORT;
      break;
    }
#endif
    single_cycle();
    clk_cycle++;
  }

  if (retire_queue_empty()) return;

  RetireEvent event = retire_event_pop();
  if (interrupt_redirect_pending) {
    Assert(event.pc == interrupt_redirect_target,
        "first retirement after interrupt: expected " FMT_WORD ", got " FMT_WORD,
        interrupt_redirect_target, event.pc);
    cpu.pc = interrupt_redirect_target;
    cpu.pc_next = interrupt_redirect_target;
    interrupt_redirect_pending = false;
  }
  Assert(event.pc == cpu.pc,
      "retirement PC discontinuity: expected " FMT_WORD ", got " FMT_WORD,
      cpu.pc, event.pc);
  cpu.inst = vaddr_read(cpu.pc);
  if (event.rd_wen && event.rd_addr != 0) {
    Assert(event.rd_addr < GPR_NUM,
        "retirement event register index out of range: %u",
        event.rd_addr);
    _gpr_[event.rd_addr] = event.rd_data;
  }

  Type type = decode_inst_type(cpu.inst);
  if (sim_stats_enabled()) {
    inst_cnt[type]++;
  }
#ifdef CONFIG_PTRACE
  if (sim_stats_enabled() && PTRACE_COND) {
    trace_log msg;
    snprintf(msg, LOGBUF_SIZE, "inst: " FMT_WORD "\ttype: %-10s",
                                cpu.inst, type_list[type]);
    add_log(msg, ptrace, ptrace_list);
  }
#endif

  device_update();

#ifdef CONFIG_ITRACE
  char *p = *logbuf;
  p += snprintf(p, LOGBUF_SIZE, FMT_WORD ":", cpu.pc);
  int ilen = 4;
  int i;
  uint8_t *inst = (uint8_t *)&(cpu.inst);
  for (i = ilen - 1; i >= 0; i--) {
    p += snprintf(p, 4, " %02x", inst[i]);
  }
  int ilen_max = 4;
  int space_len = ilen_max - ilen;
  if (space_len < 0) space_len = 0;
  space_len = space_len * 3 + 1;
  memset(p, ' ', space_len);
  p += space_len;

  void disassemble(char *str, int size, uint64_t pc, uint8_t *code, int nbyte);
  int size = LOGBUF_SIZE - (int)(intptr_t)(p - *logbuf);
  disassemble(p, size, cpu.pc, (uint8_t *)&(cpu.inst), ilen);
#endif

#ifdef CONFIG_CACHE_DIFF
  cache_step(cpu.pc);
#endif
  
  cpu.pc = event.pc_next;
  cpu.pc_next = event.pc_next;

#ifdef CONFIG_DIFFTEST
  dut_update();
#endif
}

static void trace_and_difftest(const trace_log logbuf, const int prev_pc) {
#ifdef ITRACE_COND
  if (ITRACE_COND) add_log(logbuf, itrace, itrace_list);
#endif
  if (print_step) { IFDEF(CONFIG_ITRACE, puts(logbuf)); }
  IFDEF(CONFIG_DIFFTEST, difftest_step(cpu.pc, cpu.pc_next));

  IFDEF(CONFIG_FTRACE, ftrace_init(prev_pc, cpu.pc));
  IFDEF(BLTRACE, bltrace_init(prev_pc, cpu.pc));
}

static void execute(uint64_t n) {
  for (;n > 0; n --) {
    int prev_pc = cpu.pc;
    trace_log logbuf;
    execute_once(&logbuf);
    if (sim_state.state != RUN) break;
    if (sim_stats_enabled()) {
      inst_cnt[TYPE_TOTAL]++;
    }
    trace_and_difftest(logbuf, prev_pc);
  }
}

void init_cpu(word_t pc, word_t pc_next) {
  cpu.pc = pc;
  cpu.pc_next = pc_next;
  cpu.gpr = _gpr_;

  cycle_cnt = 0;
  retire_queue_head = 0;
  retire_queue_tail = 0;
  interrupt_redirect_pending = false;
  interrupt_redirect_target = 0;
}

void cpu_exec(uint64_t n) {
  print_step = n < 10;
  switch (sim_state.state) {
    case END: case ABORT: case QUIT:
      printf("Program execution has ended. To restart the program, exit sdb and run again.\n");
      return;
    default: sim_state.state = RUN;
  }

  uint64_t timer_start = get_time();

  execute(n);

  uint64_t timer_end = get_time();
  timer += timer_end - timer_start;

  switch (sim_state.state) {
    case RUN: case STOP: sim_state.state = STOP; break;

    case END: case ABORT:
      if (sim_state.halt_val == 0) Log(ANSI_FMT("HIT GOOD TRAP", ANSI_FG_GREEN));
      else Log(ANSI_FMT("HIT BAD TRAP", ANSI_FG_RED));
      
      // fall through
    case QUIT: 
      statistic();
  }
}

void cpu_quit() {
  trace_log_output();
  sim_state.state = QUIT;
}
