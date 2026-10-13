/********Verilator Headers********/
#include <verilator_ctrl.h>
#include <verilated.h>
#ifdef WAVE
#include <verilated_fst_c.h>
#endif
#include <svdpi.h>

#include VERILATOR_H
#include VERILATOR__DPI_H
/*********************************/

#include <utils.h>
#include <sim.h>
#ifdef IS_JYD
#include <seven_segment_display.h>
#endif

/*********NVBoard Headers*********/
#ifdef HAS_NVBOARD
#include <nvboard.h>
void nvboard_bind_all_pins(TOP_NAME* top);
#endif
/*********************************/

typedef struct {
  VerilatedContext *context;
#ifdef WAVE
  VerilatedFstC *trace;
#endif
  TOP_NAME *top;
  int pc;
  int pc_next;
  bool final_called;
} VerilatorRuntime;

static VerilatorRuntime runtime = {
  new VerilatedContext,
#ifdef WAVE
  new VerilatedFstC,
#endif
  NULL,
  0,
  0,
  false,
};

extern uint64_t cycle_cnt;

#ifdef IS_JYD
static void virtual_led_print(uint32_t led_data) {
  for (int i = 0; i < 32; i++) {
    if (((led_data << i) & 0x80000000) && (i & 0x8))
      printf(ANSI_FMT("X", ANSI_FG_GREEN));
    else if ((led_data << i) & 0x80000000)
      printf(ANSI_FMT("X", ANSI_FG_RED));
    else
      printf(" ");
    if (i % 8 == 7) printf("\n");
  }
}

extern "C" void sim_led_write(int value) {
  const uint32_t led_data = static_cast<uint32_t>(value);

  printf("[LED] cycle=%lu value=0x%08x\n",
         (unsigned long)cycle_cnt, led_data);
  virtual_led_print(led_data);
  sim_stats_on_led_write(led_data);
  fflush(stdout);
}
#endif

word_t get_pc() { return runtime.pc; }
word_t get_pc_next() { return runtime.pc_next; }

extern "C" void get_npc_pc(int pc) { runtime.pc = pc; }
extern "C" void get_npc_pc_next(int pc_next) { runtime.pc_next = pc_next; }

static void half_cycle() {
  runtime.top->clock ^= 1;
  runtime.top->eval();

  runtime.context->timeInc(1);
#ifdef WAVE
  runtime.trace->dump(runtime.context->time());
#endif
}

static void reset(int n) {
  runtime.top->reset = 1;
  while (n -- > 0) single_cycle();
  // half_cycle();
  runtime.top->reset = 0;
}

int is_reset() {
  return runtime.top->reset;
}

void init_verilator(int argc, char** argv) {
  runtime.context->commandArgs(argc, argv);
  runtime.top = new TOP_NAME{runtime.context};
#ifdef WAVE
  runtime.context->traceEverOn(true);
  runtime.top->trace(runtime.trace, 10);
  runtime.trace->open("./waveform.fst");
#endif

#ifdef HAS_NVBOARD
  nvboard_bind_all_pins(runtime.top);
  nvboard_init();
#endif

  reset(20);
}

void verilator_final() {
  if (runtime.top == NULL || runtime.final_called) {
    return;
  }

#ifdef IS_JYD
  seven_segment_display_print();
  virtual_led_print(runtime.top->virtual_led);
#endif

  runtime.top->final();
  runtime.final_called = true;
}

void single_cycle() {
#ifdef HAS_NVBOARD
    nvboard_update();
#endif
  half_cycle();
  half_cycle();
#ifdef IS_JYD
  seven_segment_display_update(runtime.top->virtual_seg);
#endif
  cycle_cnt++;
}

void end_verilator() {
#ifdef HAS_NVBOARD
  nvboard_quit();
#endif

  verilator_final();

#ifdef WAVE
  runtime.context->timeInc(1);
  runtime.trace->dump(runtime.context->time());
  runtime.trace->close();
#endif

  delete runtime.top;
  delete runtime.context;
#ifdef WAVE
  delete runtime.trace;
#endif
}

bool finish() {
  return Verilated::gotFinish();
}
