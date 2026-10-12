//=============================================================================
// ARES simulation - DPI-C model seen by the RTL
//-----------------------------------------------------------------------------
// The temporary NPC (Mundus) RTL reaches the test bench through DPI-C in
// three groups:
//
//   1. functional:   irom_read / perip_read / perip_write / init_reg /
//                    get_npc_pc / get_npc_pc_next / retire_event_enqueue /
//                    interrupt_redirect / ebreak
//   2. statistics:   sim_stats_enabled + the get_*_counts collectors
//   3. predictor difftest: branch_difftest_*
//
// Group 1 is implemented for real.  Groups 2 and 3 are the npc performance
// analysis hooks; they are accepted (so the RTL links) and ignored, because
// the ARES port only needs functional verification.  sim_stats_enabled()
// returns 1 so the RTL keeps its normal behaviour.
//=============================================================================
#include "ares_sim.h"

#include <stdarg.h>

SimState sim;

bool sim_itrace = false;
bool sim_verbose = false;
bool sim_perip_trace = false;

#define ENVIR_EBREAK 2

//---------------------------------------------------------------------------
// Architecturally visible state
//---------------------------------------------------------------------------
extern "C" void init_reg(int data, int index) {
  if (index > 0 && index < 32) sim.gpr[index] = (uint32_t)data;
}

extern "C" void get_npc_pc(int pc) {
  sim.fetch_pc = (uint32_t)pc;
}

extern "C" void get_npc_pc_next(int pc_next) {
  sim.fetch_pc_next = (uint32_t)pc_next;
}

extern "C" void retire_event_enqueue(int valid, int pc, int pc_next,
                                     int rd_wen, int rd_addr, int rd_data,
                                     int environment) {
  if (!valid) return;

  uint32_t inst = mem_read32((uint32_t)pc);
  sim.retire_cnt++;
  sim.pc      = (uint32_t)pc;
  sim.pc_next = (uint32_t)pc_next;

  if (rd_wen && rd_addr != 0 && rd_addr < 32) {
    sim.gpr[rd_addr] = (uint32_t)rd_data;
  }

  if (sim_itrace) {
    sim_report("itrace     : %8llu  0x%08x: 0x%08x -> 0x%08x env=%d%s",
               (unsigned long long)sim.retire_cnt, sim.pc, inst,
               sim.pc_next, environment,
               (rd_wen && rd_addr != 0 && rd_addr < 32) ? "" : "");
  }
  (void)inst;
}

extern "C" void interrupt_redirect(int target) {
  if (sim_verbose) {
    sim_report("note       : interrupt redirect to 0x%08x", (uint32_t)target);
  }
}

// The EBREAK retirement request.  The halt code is sampled one evaluation
// later by the harness, which removes any dependence on the order in which
// the generated DPI callbacks run inside the same clock edge.
extern "C" void ebreak(void) {
  sim.halt_seen = true;
}

//---------------------------------------------------------------------------
// Instruction / peripheral ports
//---------------------------------------------------------------------------
extern "C" int irom_read(int addr) {
  return (int)mem_read_irom((uint32_t)addr);
}

// The peripheral model follows perip_bridge.sv:
//   * a read returns the word aligned to the request address and the LSU
//     extracts the addressed byte / half word itself (formatLoad)
//   * a store carries its payload in the low lane; the 2 bit size mask and the
//     address low bits select the byte lanes, and the payload is replicated
//     across those lanes first (store_word_data / store_byte_enable)
// Getting either wrong corrupts memory silently: the D-cache keeps the
// architecturally correct value while the backing memory diverges, and the
// next cache refill pulls the corruption back in.
extern "C" int perip_read(int addr) {
  return (int)mem_read32((uint32_t)addr & ~3u);
}

extern "C" void perip_write(int addr, int data, signed char mask) {
  const uint32_t a = (uint32_t)addr;
  uint32_t d = (uint32_t)data;
  uint8_t  strb;

  switch ((int)mask & 0x3) {
    case 0x2:  // word
      strb = 0xf;
      break;
    case 0x1:  // half word -> {2{wdata[15:0]}}
      d = (d & 0xffffu) * 0x00010001u;
      strb = (a & 0x2u) ? 0xc : 0x3;
      break;
    case 0x0:  // byte -> {4{wdata[7:0]}}
      d = (d & 0xffu) * 0x01010101u;
      strb = (uint8_t)(1u << (a & 0x3u));
      break;
    default:
      return;
  }
  mem_write(a, d, strb);
}

extern "C" void perip_trace(int kind, int addr, int data) {
  if (!sim_perip_trace) return;
  if (kind == 0) {
    sim_report("perip      : %8llu ACC  0x%08x %s 0x%08x",
               (unsigned long long)sim.cycles, (uint32_t)addr,
               (data == (int)0xdeadbeef) ? "rd" : "wr",
               (data == (int)0xdeadbeef) ? 0u : (uint32_t)data);
  } else {
    sim_report("perip      : %8llu RESP 0x%08x -> 0x%08x",
               (unsigned long long)sim.cycles, (uint32_t)addr, (uint32_t)data);
  }
}

//---------------------------------------------------------------------------
// Statistics hooks: accepted and ignored (functional port only)
//---------------------------------------------------------------------------
extern "C" int sim_stats_enabled(void) { return 1; }

extern "C" void get_dcache_counts(unsigned long long a, unsigned long long b,
                                  unsigned long long c, unsigned long long d) {
  (void)a; (void)b; (void)c; (void)d;
}

extern "C" void get_transient_refill_counts(
    unsigned long long a, unsigned long long b, unsigned long long c,
    unsigned long long d, unsigned long long e, unsigned long long f,
    unsigned long long g, unsigned long long h, unsigned long long i,
    unsigned long long j, unsigned long long k, unsigned long long l) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
  (void)g; (void)h; (void)i; (void)j; (void)k; (void)l;
}

extern "C" void get_transient_store_forward_counts(
    unsigned long long a, unsigned long long b, unsigned long long c,
    unsigned long long d, unsigned long long e, unsigned long long f,
    unsigned long long g, unsigned long long h, unsigned long long i,
    unsigned long long j) {
  (void)a; (void)b; (void)c; (void)d; (void)e;
  (void)f; (void)g; (void)h; (void)i; (void)j;
}

extern "C" void record_issue_operand_stall(unsigned int a, unsigned int b,
                                           unsigned int c, unsigned int d,
                                           unsigned int e, unsigned int f) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}

extern "C" void get_pipeline_counts(
    unsigned long long a0,  unsigned long long a1,  unsigned long long a2,
    unsigned long long a3,  unsigned long long a4,  unsigned long long a5,
    unsigned long long a6,  unsigned long long a7,  unsigned long long a8,
    unsigned long long a9,  unsigned long long a10, unsigned long long a11,
    unsigned long long a12, unsigned long long a13, unsigned long long a14,
    unsigned long long a15, unsigned long long a16, unsigned long long a17,
    unsigned long long a18, unsigned long long a19, unsigned long long a20,
    unsigned long long a21, unsigned long long a22, unsigned long long a23,
    unsigned long long a24, unsigned long long a25, unsigned long long a26,
    unsigned long long a27, unsigned long long a28, unsigned long long a29,
    unsigned long long a30, unsigned long long a31, unsigned long long a32,
    unsigned long long a33, unsigned long long a34) {
  (void)a0;  (void)a1;  (void)a2;  (void)a3;  (void)a4;  (void)a5;
  (void)a6;  (void)a7;  (void)a8;  (void)a9;  (void)a10; (void)a11;
  (void)a12; (void)a13; (void)a14; (void)a15; (void)a16; (void)a17;
  (void)a18; (void)a19; (void)a20; (void)a21; (void)a22; (void)a23;
  (void)a24; (void)a25; (void)a26; (void)a27; (void)a28; (void)a29;
  (void)a30; (void)a31; (void)a32; (void)a33; (void)a34;
}

extern "C" void get_pipeline_stall_counts(
    unsigned long long a0,  unsigned long long a1,  unsigned long long a2,
    unsigned long long a3,  unsigned long long a4,  unsigned long long a5,
    unsigned long long a6,  unsigned long long a7,  unsigned long long a8,
    unsigned long long a9,  unsigned long long a10, unsigned long long a11,
    unsigned long long a12, unsigned long long a13, unsigned long long a14,
    unsigned long long a15, unsigned long long a16, unsigned long long a17,
    unsigned long long a18, unsigned long long a19, unsigned long long a20,
    unsigned long long a21, unsigned long long a22, unsigned long long a23,
    unsigned long long a24, unsigned long long a25, unsigned long long a26,
    unsigned long long a27) {
  (void)a0;  (void)a1;  (void)a2;  (void)a3;  (void)a4;  (void)a5;
  (void)a6;  (void)a7;  (void)a8;  (void)a9;  (void)a10; (void)a11;
  (void)a12; (void)a13; (void)a14; (void)a15; (void)a16; (void)a17;
  (void)a18; (void)a19; (void)a20; (void)a21; (void)a22; (void)a23;
  (void)a24; (void)a25; (void)a26; (void)a27;
}

extern "C" void difftest_skip_ref(void) {}
//---------------------------------------------------------------------------
// Register dump (diagnostics)
//---------------------------------------------------------------------------
void sim_dump_regs(void) {
  static const char *abi[32] = {
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10","s11","t3", "t4", "t5", "t6"
  };
  for (int i = 0; i < 32; i += 4) {
    char line[128];
    int n = 0;
    for (int j = 0; j < 4; j++) {
      n += snprintf(line + n, sizeof(line) - (size_t)n, "%4s=0x%08x ",
                    abi[i + j], sim.gpr[i + j]);
    }
    sim_report("regs       : %s", line);
  }
}


//---------------------------------------------------------------------------
// Branch-predictor difftest hooks: accepted and ignored
//---------------------------------------------------------------------------
extern "C" void branch_difftest_on_bpu_response(int a, int b, int c, int d,
                                                int e, int f) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}

extern "C" void branch_difftest_on_frontend_cycle(
    int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7,
    int a8, int a9, int a10, int a11, int a12, int a13, int a14, int a15) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7; (void)a8; (void)a9; (void)a10; (void)a11; (void)a12; (void)a13;
  (void)a14; (void)a15;
}

extern "C" void branch_difftest_on_tage_response(int a, int b, int c, int d,
                                                 int e) {
  (void)a; (void)b; (void)c; (void)d; (void)e;
}

extern "C" void branch_difftest_on_tage_frontend(int a, int b, int c, int d,
                                                 int e) {
  (void)a; (void)b; (void)c; (void)d; (void)e;
}

extern "C" void branch_difftest_queue_update(int a, int b, int c, int d,
                                             int e, int f) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}

extern "C" void branch_difftest_loop_update(int a, int b, int c, int d,
                                            int e, int f, int g, int h) {
  (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h;
}
