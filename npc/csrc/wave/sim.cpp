#include <sim.h>

#include <getopt.h>
#include <algorithm>
#include <cstdarg>
#include <unordered_map>
#include <vector>
#include <verilator_ctrl.h>
#include <sdb.h>
#include <cpu.h>
#include <device.h>
#include <mem.h>
#include <difftest.h>
#include <trace.h>
#include <reg.h>
#include <cache.h>
#include <branch_difftest.h>
#include <expr.h>
#include <dbg.h>

#define PIPELINE_REPORT_DEFAULT "./build/pipeline_report.txt"
#define MEMORY_REPORT_DEFAULT "./build/memory_report.txt"

typedef struct {
  char *diff_so_file;
  char *elf_file;
  char *log_file;
  char *csv_file;
  char *pc_trace_file;
  char *branch_report_file;
  char *pipeline_report_file;
  char *memory_report_file;
  char *stats_window;
  int difftest_port;
} SimOptions;

static SimOptions sim_options = {
  .diff_so_file = NULL,
  .elf_file = NULL,
  .log_file = NULL,
  .csv_file = NULL,
  .pc_trace_file = NULL,
  .branch_report_file = NULL,
  .pipeline_report_file = NULL,
  .memory_report_file = NULL,
  .stats_window = NULL,
  .difftest_port = 1234,
};

CacheInfo icache_dut = { 0, 0 };
uint32_t icache_access_time = 1;
double sdram_access_time;
double icache_miss_rate;
double icache_miss_penalty;

extern uint64_t cycle_cnt;
extern uint64_t inst_cnt[TYPE_COUNT];
extern const char *type_list[];

UNIT_COUNTER(DEFINE_COUNTER);

static bool stats_window_active = false;
static bool stats_window_complete = false;
static uint64_t stats_window_start_cycle = 0;
static uint64_t stats_window_end_cycle = 0;
static uint64_t stats_window_start_host_time = 0;
static uint64_t stats_window_host_time = 0;

extern "C" int sim_stats_enabled() {
  return sim_options.stats_window == NULL || stats_window_active;
}

void sim_stats_on_led_write(uint32_t value) {
  if (sim_options.stats_window == NULL ||
      strcmp(sim_options.stats_window, "led0") != 0) {
    return;
  }

  bool led0 = (value & 1U) != 0;
  if (led0 && !stats_window_active && !stats_window_complete) {
    memset(inst_cnt, 0, sizeof(uint64_t) * TYPE_COUNT);
    UNIT_COUNTER(RESET_COUNTER);
    branch_difftest_reset_statistics();
    stats_window_start_cycle = cycle_cnt;
    stats_window_start_host_time = get_time();
    stats_window_active = true;
    Log("statistics window started: led0, cycle %llu",
        (unsigned long long)stats_window_start_cycle);
  } else if (!led0 && stats_window_active) {
    stats_window_end_cycle = cycle_cnt;
    stats_window_host_time = get_time() - stats_window_start_host_time;
    stats_window_active = false;
    stats_window_complete = true;
    branch_difftest_freeze_statistics();
    Log("statistics window finished: led0, cycles %llu..%llu",
        (unsigned long long)stats_window_start_cycle,
        (unsigned long long)stats_window_end_cycle);
  }
}

static uint64_t report_cycle_count() {
  if (sim_options.stats_window == NULL) {
    return cycle_cnt;
  }
  if (stats_window_complete) {
    return stats_window_end_cycle - stats_window_start_cycle;
  }
  if (stats_window_active) {
    return cycle_cnt - stats_window_start_cycle;
  }
  return 0;
}

static uint64_t report_host_time() {
  if (sim_options.stats_window == NULL) {
    return timer;
  }
  if (stats_window_complete) {
    return stats_window_host_time;
  }
  if (stats_window_active) {
    return get_time() - stats_window_start_host_time;
  }
  return 0;
}

static int dtest = 0;
static uint64_t dcache_load_request_cnt = 0;
static uint64_t dcache_load_hit_cnt = 0;
static uint64_t dcache_store_request_cnt = 0;
static uint64_t dcache_store_hit_cnt = 0;
static uint64_t transient_refill_candidate_cnt = 0;
static uint64_t transient_refill_transient_candidate_cnt = 0;
static uint64_t transient_refill_direct_cnt = 0;
static uint64_t transient_refill_direct_transient_cnt = 0;
static uint64_t transient_refill_pending_enqueue_cnt = 0;
static uint64_t transient_refill_pending_transient_enqueue_cnt = 0;
static uint64_t transient_refill_pending_cnt = 0;
static uint64_t transient_refill_pending_transient_cnt = 0;
static uint64_t transient_refill_pending_wait_cnt = 0;
static uint64_t transient_refill_drop_cnt = 0;
static uint64_t transient_refill_startup_suppressed_cnt = 0;
static uint64_t transient_refill_flush_cnt = 0;
static uint64_t store_buffer_depth = 0;
static uint64_t store_buffer_enqueue_cnt = 0;
static uint64_t store_buffer_dequeue_cnt = 0;
static uint64_t store_buffer_overlap_cnt = 0;
static uint64_t store_buffer_read_accept_cnt = 0;
static uint64_t store_buffer_read_blocked_cycle_cnt = 0;
static uint64_t store_buffer_read_blocked_event_cnt = 0;
static uint64_t store_buffer_read_blocked_conflict_cycle_cnt = 0;
static uint64_t store_buffer_read_blocked_independent_cycle_cnt = 0;
static uint64_t store_buffer_read_write_overlap_cnt = 0;
static uint64_t store_buffer_read_write_same_word_cnt = 0;
static uint64_t store_buffer_read_forwarded_cnt = 0;
static uint64_t store_buffer_read_forwarded_byte_cnt = 0;
static uint64_t store_buffer_staged_forwarded_cnt = 0;
static uint64_t store_buffer_staged_forwarded_byte_cnt = 0;
static uint64_t store_buffer_read_blocked_staged_write_cnt = 0;
static uint64_t store_buffer_store_blocked_cycle_cnt = 0;
static uint64_t store_buffer_mmio_write_blocked_cycle_cnt = 0;
static uint64_t store_buffer_nonempty_cycle_cnt = 0;
static uint64_t store_buffer_full_cycle_cnt = 0;
static uint64_t store_buffer_occupancy_sum = 0;
static uint64_t store_buffer_max_occupancy = 0;
static uint64_t pipeline_cycle_cnt = 0;
static uint64_t pipeline_retire_cnt = 0;
static uint64_t pipeline_retire_width_cnt[2] = {};
static uint64_t pipeline_issue_width_cnt[3] = {};
static uint64_t pipeline_iq_occupancy_cnt[3] = {};
static uint64_t pipeline_pair_opportunity_cnt = 0;
static uint64_t pipeline_pair_success_cnt = 0;
static uint64_t pipeline_pair_reject_cnt[6] = {};
static uint64_t pipeline_waw_detail_cnt[4] = {};
static uint64_t pipeline_flat_bypass_cnt = 0;
static uint64_t pipeline_load_pair_hit_cnt = 0;
static uint64_t pipeline_load_pair_replay_cnt = 0;
static uint64_t pipeline_no_retire_cnt = 0;
static uint64_t pipeline_active_no_retire_cnt = 0;
static uint64_t pipeline_empty_no_retire_cnt = 0;
static uint64_t pipeline_backend_stall_cycle_cnt = 0;
static uint64_t pipeline_backend_stall_event_cnt = 0;
static uint64_t pipeline_long_stall_cycle_cnt = 0;
static uint64_t pipeline_long_stall_event_cnt = 0;
static uint64_t pipeline_issue_hazard_cycle_cnt = 0;
static uint64_t pipeline_issue_hazard_event_cnt = 0;
static uint64_t pipeline_control_redirect_cnt = 0;
static uint64_t pipeline_load_replay_cnt = 0;
static uint64_t transient_store_overlap_ex1_cnt = 0;
static uint64_t transient_store_overlap_ex2_cnt = 0;
static uint64_t transient_store_overlap_ready_cnt = 0;
static uint64_t transient_store_overlap_not_ready_cnt = 0;
static uint64_t transient_store_forward_cnt = 0;
static uint64_t transient_store_forward_byte_cnt = 0;
static uint64_t transient_store_unknown_addr_stall_cnt = 0;
static uint64_t transient_store_data_stall_cnt = 0;
static uint64_t transient_store_multi_store_cnt = 0;
static uint64_t transient_store_shadowed_not_ready_cnt = 0;
enum PipelineStallCause {
  PIPELINE_STALL_WB_DIV = 0,
  PIPELINE_STALL_BACKEND_STORE,
  PIPELINE_STALL_BACKEND_LOAD,
  PIPELINE_STALL_ISSUE_SYSTEM,
  PIPELINE_STALL_ISSUE_LONG,
  PIPELINE_STALL_ISSUE_STORE_OVERLAP,
  PIPELINE_STALL_ISSUE_MMIO_ORDER,
  PIPELINE_STALL_ISSUE_LOAD_PORT,
  PIPELINE_STALL_ISSUE_OPERAND,
  PIPELINE_STALL_CAUSE_COUNT,
};
static const char *pipeline_stall_cause_name[PIPELINE_STALL_CAUSE_COUNT] = {
  "wb-div",
  "backend-store",
  "backend-load",
  "issue-system",
  "issue-long",
  "issue-store-overlap",
  "issue-mmio-order",
  "issue-load-port",
  "issue-operand",
};
static uint64_t pipeline_primary_stall_cycle_cnt = 0;
static uint64_t
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_CAUSE_COUNT] = {};
static uint64_t
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_CAUSE_COUNT] = {};
static uint64_t
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_CAUSE_COUNT] = {};
enum IssueOperandProducerStage {
  ISSUE_OPERAND_PRODUCER_EX1 = 0,
  ISSUE_OPERAND_PRODUCER_EX2,
  ISSUE_OPERAND_PRODUCER_EX3,
  ISSUE_OPERAND_PRODUCER_EX4,
  ISSUE_OPERAND_PRODUCER_WB,
  ISSUE_OPERAND_PRODUCER_STAGE_COUNT,
};
enum IssueOperandProducerType {
  ISSUE_OPERAND_PRODUCER_ALU = 0,
  ISSUE_OPERAND_PRODUCER_LOAD,
  ISSUE_OPERAND_PRODUCER_MUL,
  ISSUE_OPERAND_PRODUCER_LOAD_PAIR_ALU,
  ISSUE_OPERAND_PRODUCER_TYPE_COUNT,
};
enum IssueOperandConsumerType {
  ISSUE_OPERAND_CONSUMER_ALU = 0,
  ISSUE_OPERAND_CONSUMER_BRANCH,
  ISSUE_OPERAND_CONSUMER_AGU,
  ISSUE_OPERAND_CONSUMER_STORE_DATA,
  ISSUE_OPERAND_CONSUMER_TYPE_COUNT,
};
static const char *issue_operand_stage_name[
  ISSUE_OPERAND_PRODUCER_STAGE_COUNT] = {
    "Ex1", "Ex2", "Ex3", "Ex4", "WB",
};
static const char *issue_operand_producer_name[
  ISSUE_OPERAND_PRODUCER_TYPE_COUNT] = {
    "ALU", "load", "MUL", "load-pair ALU",
};
static const char *issue_operand_consumer_name[
  ISSUE_OPERAND_CONSUMER_TYPE_COUNT] = {
    "ALU", "branch", "AGU", "store-data",
};
static uint64_t issue_operand_detail_cnt
  [2][2]
  [ISSUE_OPERAND_PRODUCER_STAGE_COUNT]
  [ISSUE_OPERAND_PRODUCER_TYPE_COUNT]
  [ISSUE_OPERAND_CONSUMER_TYPE_COUNT] = {};
static uint64_t issue_operand_blocked_source_cycle_cnt = 0;
struct IssueOperandPcStat {
  uint64_t stall_cycles;
  uint64_t blocked_source_cycles;
};
static std::unordered_map<uint32_t, IssueOperandPcStat>
  issue_operand_pc_stats;

static FILE *stats_report_fp = NULL;
static bool stats_report_active = false;

#define Stat(...) \
  do { \
    if (stats_report_active) { \
      if (stats_report_fp != NULL) { \
        fprintf(stats_report_fp, __VA_ARGS__); \
      } \
    } else { \
      _Log(__VA_ARGS__); \
    } \
  } while (0)

static void stats_report_begin(const char *path, const char *title) {
  Assert(!stats_report_active, "statistics report output is already active");
  stats_report_active = true;
  stats_report_fp = fopen(path, "w");
  if (stats_report_fp == NULL) {
    Log_warn("cannot write %s report file: %s", title, path);
    return;
  }
  fprintf(stats_report_fp, "%s Report\n", title);
  fprintf(stats_report_fp, "================================\n\n");
  fprintf(stats_report_fp, "Test Image: %s\n", PROGRAM);
  if (sim_options.stats_window != NULL) {
    if (stats_window_complete) {
      fprintf(stats_report_fp,
          "Statistics Window: %s (cycles %llu..%llu, startup excluded)\n",
          sim_options.stats_window,
          (unsigned long long)stats_window_start_cycle,
          (unsigned long long)stats_window_end_cycle);
    } else {
      fprintf(stats_report_fp,
          "Statistics Window: %s (complete window not observed)\n",
          sim_options.stats_window);
    }
  }
}

static void stats_report_end(const char *path, const char *title) {
  if (stats_report_fp != NULL) {
    fclose(stats_report_fp);
    stats_report_fp = NULL;
    Log("%s report: %s", title, path);
  }
  stats_report_active = false;
}

static const char *stats_metric_line =
  "+------------------------------------------"
  "+--------------------------------+\n";

static void stats_section(const char *title) {
  Stat("\n[%s]\n", title);
}

static void stats_metric_header() {
  Stat("%s", stats_metric_line);
  Stat("| %-40s | %-30s |\n", "Metric", "Value");
  Stat("%s", stats_metric_line);
}

static void stats_metric(const char *metric, const char *format, ...) {
  char value[128];
  va_list args;
  va_start(args, format);
  vsnprintf(value, sizeof(value), format, args);
  va_end(args);
  Stat("| %-40s | %30s |\n", metric, value);
}

static void stats_metric_end() {
  Stat("%s", stats_metric_line);
}

void init_disasm();

static void welcome() {
  Log("Build time: %s, %s", __TIME__, __DATE__);

  static const char *isa =
    "RV32IM"
    ;
#ifdef CONFIG_BRANCH_RAS
  static const char *ras = "on";
#else
  static const char *ras = "off";
#endif
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  static const char *loop_predictor = "on";
#else
  static const char *loop_predictor = "off";
#endif
#ifdef CONFIG_BRANCH_FAST_RECURRENCE
  static const char *fast_recurrence = "on";
#else
  static const char *fast_recurrence = "off";
#endif
#ifdef CONFIG_CUSTOM_CRC16
  static const char *custom_crc16 = "on";
#else
  static const char *custom_crc16 = "off";
#endif
#ifdef CONFIG_CUSTOM_MULBE
  static const char *custom_mulbe = "on";
#else
  static const char *custom_mulbe = "off";
#endif

  Log("Processor configuration:");
  Log("  Core: ISA=%s, issue=2-wide in-order", isa);
  Log("  Custom instructions: CRC16=%s, MULBE=%s",
      custom_crc16, custom_mulbe);
#ifdef CONFIG_FRONTEND_QUEUE
  Log("  Frontend: queue=%d entries, IROM latency=%d cycle(s)",
      CONFIG_FRONTEND_QUEUE_DEPTH, CONFIG_IROM_READ_LATENCY);
#else
  Log("  Frontend: queue=off, IROM latency=%d cycle(s)",
      CONFIG_IROM_READ_LATENCY);
#endif
#if defined(CONFIG_BP_TAGE)
  Log("  Branch: TAGE, BTB=%u entries, base counter=%d bits, "
      "TAGE=%d x %u entries, tag/counter/useful=%d/%d/%d bits",
      1U << CONFIG_BRANCH_BTB_WIDTH, CONFIG_BRANCH_BIMODAL_BITS,
      CONFIG_BRANCH_TAGE_TABLES, 1U << CONFIG_BRANCH_TAGE_INDEX_BITS,
      CONFIG_BRANCH_TAGE_TAG_BITS, CONFIG_BRANCH_TAGE_CTR_BITS,
      CONFIG_BRANCH_TAGE_USEFUL_BITS);
  Log("  Branch history: %d/%d/%d/%d, FTQ=%d entries",
      CONFIG_BRANCH_TAGE_HIST_0, CONFIG_BRANCH_TAGE_HIST_1,
      CONFIG_BRANCH_TAGE_HIST_2, CONFIG_BRANCH_TAGE_HIST_3,
      CONFIG_BRANCH_FTQ_DEPTH);
#elif defined(CONFIG_BP_BIMODAL)
  Log("  Branch: Bimodal, BTB=%u entries, counter=%d bits",
      1U << CONFIG_BRANCH_BTB_WIDTH, CONFIG_BRANCH_BIMODAL_BITS);
#else
  Log("  Branch: Always not taken");
#endif
  Log("  Branch extras: RAS=%s, loop=%s, fast-recurrence=%s",
      ras, loop_predictor, fast_recurrence);
#ifdef CONFIG_BRANCH_RAS
  Log("    RAS=%u entries", 1U << CONFIG_BRANCH_RAS_WIDTH);
#endif
#ifdef CONFIG_BRANCH_FAST_RECURRENCE
  Log("    Fast recurrence=%u entries",
      1U << CONFIG_BRANCH_FAST_RECURRENCE_INDEX_BITS);
#endif
  Log("  I-cache: block=%d B, blocks=%d, ways=%d",
      CONFIG_ICACHE_BYTE, CONFIG_ICACHE_BLOCK, CONFIG_ICACHE_WAY);
  Log("  D-cache: size=%d KiB, store buffer=%d entries",
      CONFIG_DCACHE_SIZE_KB, CONFIG_STORE_BUFFER_DEPTH);
  Log("  MDU: MUL latency=%d cycles, DIV/REM latency=%d cycles",
      CONFIG_MUL_LATENCY, CONFIG_DIV_LATENCY);
#ifndef CONFIG_SIMULATION
  Log_warn("Simulation is OFF");
#endif
#ifdef CONFIG_RVE
  Assert(0, "RISCV-32 E extension is ON!");
#endif
#ifndef BATCH
  printf("Welcome to %s Process Core!\n", str(NPC_NAME));
  printf("%s", welcome_name);
  printf("Arch: %s\n", ANSI_FMT(str(__GUEST_ISA__), ANSI_FG_YELLOW ANSI_BG_RED));
  printf("For help, type \"help\"\n");
#endif
}

static long load_img() {
  FILE *fp = fopen(PROGRAM, "rb");
  Assert(fp, "Can not open '%s'", PROGRAM);
  
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  Log("The image is %s, size = %ld", PROGRAM, size);
  
  program_ROM(fp);

  fclose(fp);
  return size;
}

enum SimLongOption {
  SIM_OPT_PIPELINE_REPORT = 256,
  SIM_OPT_MEMORY_REPORT,
  SIM_OPT_STATS_WINDOW,
};

static int parse_args(int argc, char *argv[]) {
  const struct option table[] = {
    {"diff"     , required_argument, NULL, 'd'},
    {"elf"      , required_argument, NULL, 'e'},
    {"log"      , required_argument, NULL, 'l'},
    {"csv"      , required_argument, NULL, 'c'},
    {"pc-trace" , required_argument, NULL, 't'},
    {"branch-report", required_argument, NULL, 'b'},
    {"pipeline-report", required_argument, NULL, SIM_OPT_PIPELINE_REPORT},
    {"memory-report", required_argument, NULL, SIM_OPT_MEMORY_REPORT},
    {"stats-window", required_argument, NULL, SIM_OPT_STATS_WINDOW},
    {"port"     , required_argument, NULL, 'p'},
    {0          , 0                , NULL,  0 },
  };
  int o;
  while ( (o = getopt_long(argc, argv, "-l:", table, NULL)) != -1) {
    switch (o) {
      case 'd': sim_options.diff_so_file = optarg; break;
      case 'e': sim_options.elf_file     = optarg; break;
      case 'l': sim_options.log_file     = optarg; break;
      case 'c': sim_options.csv_file     = optarg; break;
      case 't': sim_options.pc_trace_file= optarg; break;
      case 'b': sim_options.branch_report_file = optarg; break;
      case SIM_OPT_PIPELINE_REPORT:
        sim_options.pipeline_report_file = optarg;
        break;
      case SIM_OPT_MEMORY_REPORT:
        sim_options.memory_report_file = optarg;
        break;
      case SIM_OPT_STATS_WINDOW:
        sim_options.stats_window = optarg;
        break;
      case 'p': sscanf(optarg, "%d", &sim_options.difftest_port); break;
      case 1:
        if (optarg[0] == '+') {
          break;
        }
        break;
      default:
        printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
        printf("\t-l,--log=FILE           output log to FILE\n");
        printf("\t-b,--branch-report=FILE output branch difftest report to FILE\n");
        printf("\t--pipeline-report=FILE  output pipeline statistics to FILE\n");
        printf("\t--memory-report=FILE    output memory statistics to FILE\n");
        printf("\t--stats-window=led0     count only while JYD LED0 is on\n");
        printf("\n");
        exit(0);
    }
  }
  if (sim_options.stats_window != NULL &&
      strcmp(sim_options.stats_window, "led0") != 0) {
    fprintf(stderr, "unsupported statistics window '%s' (expected led0)\n",
        sim_options.stats_window);
    exit(1);
  }
  return 0;
}

// dump_instruction_stats() is generated by AI
#ifdef CONFIG_INST_TYPE_COUNTER
#define W_TYPE        10
#define W_CNT         12
#define W_INST_RATIO  14
#define T1_HEADER_FMT "| %-*s | %*s | %*s |\n"
#define T1_ROW_FMT    "| %-*s | %*lu | %*.2f |\n"
#define T1_SEP_LINE   "+------------"       \
                      "+--------------"     \
                      "+----------------+\n"
static void dump_instruction_stats() {
  uint64_t total_inst = inst_cnt[TYPE_TOTAL];
  
  stats_section("Instruction Breakdown");
  Stat(T1_SEP_LINE);
  Stat(T1_HEADER_FMT,
       W_TYPE, "Type",
       W_CNT,  "Inst Count",
       W_INST_RATIO, "Inst Ratio(%)");
  Stat(T1_SEP_LINE);

  for (int i = 0; i < TYPE_TOTAL; i++) {
      double inst_ratio = (total_inst > 0) ? (double)inst_cnt[i] / total_inst * 100.0 : 0.0;

      Stat(T1_ROW_FMT,
           W_TYPE, type_list[i],
           W_CNT,  inst_cnt[i],
           W_INST_RATIO, inst_ratio);
  }

  Stat(T1_SEP_LINE);
                          
  Stat(T1_ROW_FMT,
       W_TYPE, "TOTAL",
       W_CNT,  inst_cnt[TYPE_TOTAL],
       W_INST_RATIO, total_inst > 0 ? 100.00 : 0.00);
            
  Stat(T1_SEP_LINE);
}
#endif

#ifdef CONFIG_ICACHE_AMAT
extern "C" void get_icache_info(uint32_t total_sdram_req, uint32_t total_sdram_miss, uint64_t sdram_cnt) {
  icache_dut.total_sdram_req  = total_sdram_req ;
  icache_dut.total_sdram_miss = total_sdram_miss;
  icache_miss_penalty = (double)sdram_cnt / (double)total_sdram_req;
  icache_miss_rate = (double)total_sdram_miss / (double)total_sdram_req;
  sdram_access_time = (double)sdram_cnt / (double)total_sdram_miss;
}

static void dump_icache_stats() {
  stats_section("I-cache AMAT");
  stats_metric_header();
  stats_metric("SDRAM requests", "%u", icache_dut.total_sdram_req);
  stats_metric("SDRAM misses", "%u", icache_dut.total_sdram_miss);
  stats_metric("Average SDRAM access", "%.6f cycles", sdram_access_time);
  stats_metric("Miss rate", "%.6f", icache_miss_rate);
  stats_metric("Miss penalty", "%.6f cycles", icache_miss_penalty);
  stats_metric("AMAT", "%.6f cycles",
    (double)icache_access_time + icache_miss_rate * icache_miss_penalty);
  stats_metric_end();
}
#endif

static void dump_issue_operand_stats() {
  uint64_t lane_source_cnt[2][2] = {};
  uint64_t producer_stage_cnt[ISSUE_OPERAND_PRODUCER_STAGE_COUNT] = {};
  uint64_t producer_type_cnt[ISSUE_OPERAND_PRODUCER_TYPE_COUNT] = {};
  uint64_t consumer_type_cnt[ISSUE_OPERAND_CONSUMER_TYPE_COUNT] = {};

  for (int lane = 0; lane < 2; lane++) {
    for (int source = 0; source < 2; source++) {
      for (int stage = 0; stage < ISSUE_OPERAND_PRODUCER_STAGE_COUNT;
           stage++) {
        for (int producer = 0;
             producer < ISSUE_OPERAND_PRODUCER_TYPE_COUNT; producer++) {
          for (int consumer = 0;
               consumer < ISSUE_OPERAND_CONSUMER_TYPE_COUNT; consumer++) {
            uint64_t count = issue_operand_detail_cnt
              [lane][source][stage][producer][consumer];
            lane_source_cnt[lane][source] += count;
            producer_stage_cnt[stage] += count;
            producer_type_cnt[producer] += count;
            consumer_type_cnt[consumer] += count;
          }
        }
      }
    }
  }

  Assert(issue_operand_blocked_source_cycle_cnt ==
           lane_source_cnt[0][0] + lane_source_cnt[0][1] +
             lane_source_cnt[1][0] + lane_source_cnt[1][1],
         "issue operand source accounting mismatch");

  const char *breakdown_line =
    "+----------------+--------------+------------------------+----------+\n";
  stats_section("Issue Operand Breakdown");
  Stat("%s", breakdown_line);
  Stat("| %-14s | %-12s | %22s | %8s |\n",
       "Dimension", "Value", "Blocked source cycles", "Share");
  Stat("%s", breakdown_line);
  for (int lane = 0; lane < 2; lane++) {
    for (int source = 0; source < 2; source++) {
      double share = issue_operand_blocked_source_cycle_cnt == 0 ? 0.0 :
        100.0 * (double)lane_source_cnt[lane][source] /
          (double)issue_operand_blocked_source_cycle_cnt;
      char value[16];
      snprintf(value, sizeof(value), "lane%d/rs%d", lane, source + 1);
      Stat("| %-14s | %-12s | %22llu | %7.2f%% |\n",
           "lane/source",
           value,
           (unsigned long long)lane_source_cnt[lane][source],
           share);
    }
  }
  for (int stage = 0; stage < ISSUE_OPERAND_PRODUCER_STAGE_COUNT; stage++) {
    double share = issue_operand_blocked_source_cycle_cnt == 0 ? 0.0 :
      100.0 * (double)producer_stage_cnt[stage] /
        (double)issue_operand_blocked_source_cycle_cnt;
    Stat("| %-14s | %-12s | %22llu | %7.2f%% |\n",
         "producer stage",
         issue_operand_stage_name[stage],
         (unsigned long long)producer_stage_cnt[stage],
         share);
  }
  for (int producer = 0; producer < ISSUE_OPERAND_PRODUCER_TYPE_COUNT;
       producer++) {
    double share = issue_operand_blocked_source_cycle_cnt == 0 ? 0.0 :
      100.0 * (double)producer_type_cnt[producer] /
        (double)issue_operand_blocked_source_cycle_cnt;
    Stat("| %-14s | %-12s | %22llu | %7.2f%% |\n",
         "producer type",
         issue_operand_producer_name[producer],
         (unsigned long long)producer_type_cnt[producer],
         share);
  }
  for (int consumer = 0; consumer < ISSUE_OPERAND_CONSUMER_TYPE_COUNT;
       consumer++) {
    double share = issue_operand_blocked_source_cycle_cnt == 0 ? 0.0 :
      100.0 * (double)consumer_type_cnt[consumer] /
        (double)issue_operand_blocked_source_cycle_cnt;
    Stat("| %-14s | %-12s | %22llu | %7.2f%% |\n",
         "consumer type",
         issue_operand_consumer_name[consumer],
         (unsigned long long)consumer_type_cnt[consumer],
         share);
  }
  Stat("%s", breakdown_line);

  const char *detail_line =
    "+------+--------+-------+---------------+---------------"
    "+------------------------+\n";
  stats_section("Issue Operand Cross-dimension Detail");
  Stat("%s", detail_line);
  Stat("| %-4s | %-6s | %-5s | %-13s | %-13s | %22s |\n",
       "Lane", "Source", "Stage", "Producer", "Consumer",
       "Blocked source cycles");
  Stat("%s", detail_line);
  for (int lane = 0; lane < 2; lane++) {
    for (int source = 0; source < 2; source++) {
      for (int stage = 0; stage < ISSUE_OPERAND_PRODUCER_STAGE_COUNT;
           stage++) {
        for (int producer = 0;
             producer < ISSUE_OPERAND_PRODUCER_TYPE_COUNT; producer++) {
          for (int consumer = 0;
               consumer < ISSUE_OPERAND_CONSUMER_TYPE_COUNT; consumer++) {
            uint64_t count = issue_operand_detail_cnt
              [lane][source][stage][producer][consumer];
            if (count == 0) {
              continue;
            }
            Stat("| %4d | rs%-4d | %-5s | %-13s | %-13s | %22llu |\n",
                 lane,
                 source + 1,
                 issue_operand_stage_name[stage],
                 issue_operand_producer_name[producer],
                 issue_operand_consumer_name[consumer],
                 (unsigned long long)count);
          }
        }
      }
    }
  }
  Stat("%s", detail_line);

  std::vector<std::pair<uint32_t, IssueOperandPcStat>> top_pc(
    issue_operand_pc_stats.begin(), issue_operand_pc_stats.end());
  std::sort(top_pc.begin(), top_pc.end(),
    [](const auto &left, const auto &right) {
      if (left.second.stall_cycles != right.second.stall_cycles) {
        return left.second.stall_cycles > right.second.stall_cycles;
      }
      return left.first < right.first;
    });
  if (top_pc.size() > 10) {
    top_pc.resize(10);
  }
  const char *top_pc_line =
    "+------+------------+----------------+------------------------+\n";
  stats_section("Top Issue-Operand Stall PCs");
  Stat("%s", top_pc_line);
  Stat("| %4s | %-10s | %14s | %22s |\n",
       "Rank", "PC", "Stall cycles", "Blocked source cycles");
  Stat("%s", top_pc_line);
  for (size_t rank = 0; rank < top_pc.size(); rank++) {
    Stat("| %4zu | 0x%08x | %14llu | %22llu |\n",
         rank + 1,
         top_pc[rank].first,
         (unsigned long long)top_pc[rank].second.stall_cycles,
         (unsigned long long)top_pc[rank].second.blocked_source_cycles);
  }
  Stat("%s", top_pc_line);
}

static void performance() {
#ifdef CONFIG_HAS_VERILATOR
  uint64_t measured_cycle_cnt = report_cycle_count();
  uint64_t measured_host_time = report_host_time();
  double IPC = measured_cycle_cnt == 0 ? 0.0
    : (double)inst_cnt[TYPE_TOTAL] / (double)measured_cycle_cnt;
  uint64_t dcache_request_cnt = dcache_load_request_cnt + dcache_store_request_cnt;
  uint64_t dcache_hit_cnt = dcache_load_hit_cnt + dcache_store_hit_cnt;
  double dcache_hit_rate = dcache_request_cnt == 0 ? 0.0
    : 100.0 * (double)dcache_hit_cnt / (double)dcache_request_cnt;
  double dcache_load_hit_rate = dcache_load_request_cnt == 0 ? 0.0
    : 100.0 * (double)dcache_load_hit_cnt / (double)dcache_load_request_cnt;
  double dcache_store_hit_rate = dcache_store_request_cnt == 0 ? 0.0
    : 100.0 * (double)dcache_store_hit_cnt / (double)dcache_store_request_cnt;
  double store_buffer_read_blocked_ratio = measured_cycle_cnt == 0 ? 0.0
    : 100.0 * (double)store_buffer_read_blocked_cycle_cnt /
      (double)measured_cycle_cnt;
  double store_buffer_avg_read_wait =
    store_buffer_read_blocked_event_cnt == 0 ? 0.0
    : (double)store_buffer_read_blocked_cycle_cnt /
      (double)store_buffer_read_blocked_event_cnt;
  double store_buffer_avg_occupancy = measured_cycle_cnt == 0 ? 0.0
    : (double)store_buffer_occupancy_sum / (double)measured_cycle_cnt;
  double store_buffer_overlap_ratio = store_buffer_enqueue_cnt == 0 ? 0.0
    : 100.0 * (double)store_buffer_overlap_cnt /
      (double)store_buffer_enqueue_cnt;
  uint64_t cycles_without_store_buffer_read_wait =
    measured_cycle_cnt > store_buffer_read_blocked_cycle_cnt
      ? measured_cycle_cnt - store_buffer_read_blocked_cycle_cnt
      : 0;
  double ipc_without_store_buffer_read_wait =
    cycles_without_store_buffer_read_wait == 0 ? 0.0
      : (double)inst_cnt[TYPE_TOTAL] /
        (double)cycles_without_store_buffer_read_wait;
  double backend_stall_ratio = pipeline_cycle_cnt == 0 ? 0.0
    : 100.0 * (double)pipeline_backend_stall_cycle_cnt /
      (double)pipeline_cycle_cnt;
  uint64_t cycles_without_backend_stall =
    measured_cycle_cnt > pipeline_backend_stall_cycle_cnt
      ? measured_cycle_cnt - pipeline_backend_stall_cycle_cnt
      : 0;
  double ipc_without_backend_stall =
    cycles_without_backend_stall == 0 ? 0.0
      : (double)inst_cnt[TYPE_TOTAL] /
        (double)cycles_without_backend_stall;
  stats_section("Simulation Summary");
  stats_metric_header();
  if (sim_options.stats_window != NULL) {
    stats_metric("Statistics window", "%s%s", sim_options.stats_window,
      stats_window_complete ? " (startup excluded)" : " (incomplete)");
  }
  stats_metric("Host time", "%llu us",
    (unsigned long long)measured_host_time);
  stats_metric("Clock cycles", "%llu",
    (unsigned long long)measured_cycle_cnt);
  stats_metric("Guest instructions", "%llu",
    (unsigned long long)inst_cnt[TYPE_TOTAL]);
  stats_metric("IPC", "%.6f", IPC);
  stats_metric("Execution time", "%.9f s",
    measured_cycle_cnt / ((double)CORE_FREQ * 1000000));
  stats_metric("Core frequency", "%.3f MHz", (double)CORE_FREQ);
  if (measured_host_time > 0) {
    stats_metric("Simulation frequency", "%llu inst/s",
      (unsigned long long)(inst_cnt[TYPE_TOTAL] * 1000000 /
        measured_host_time));
  } else {
    stats_metric("Simulation frequency", "< 1 us (unavailable)");
  }
  stats_metric_end();

  const char *pipeline_report_path =
    sim_options.pipeline_report_file != NULL
      ? sim_options.pipeline_report_file
      : PIPELINE_REPORT_DEFAULT;
  stats_report_begin(pipeline_report_path, "Pipeline Statistics");
  if (pipeline_cycle_cnt != 0) {
    uint64_t issue_group_cnt =
      pipeline_issue_width_cnt[1] + pipeline_issue_width_cnt[2];
    uint64_t issued_inst_cnt =
      pipeline_issue_width_cnt[1] + 2 * pipeline_issue_width_cnt[2];
    uint64_t pair_outcome_cnt =
      pipeline_pair_success_cnt +
      pipeline_pair_reject_cnt[0] +
      pipeline_pair_reject_cnt[1] +
      pipeline_pair_reject_cnt[2] +
      pipeline_pair_reject_cnt[3] +
      pipeline_pair_reject_cnt[4] +
      pipeline_pair_reject_cnt[5];
    Assert(pipeline_retire_cnt ==
             pipeline_retire_width_cnt[0] +
               2 * pipeline_retire_width_cnt[1],
           "retirement width accounting mismatch");
    Assert(pipeline_cycle_cnt ==
             pipeline_no_retire_cnt +
               pipeline_retire_width_cnt[0] +
               pipeline_retire_width_cnt[1],
           "retirement cycle accounting mismatch");
    Assert(pipeline_cycle_cnt ==
             pipeline_issue_width_cnt[0] +
               pipeline_issue_width_cnt[1] +
               pipeline_issue_width_cnt[2],
           "issue width accounting mismatch");
    Assert(pipeline_cycle_cnt ==
             pipeline_iq_occupancy_cnt[0] +
               pipeline_iq_occupancy_cnt[1] +
               pipeline_iq_occupancy_cnt[2],
           "instruction queue occupancy accounting mismatch");
    Assert(pipeline_pair_opportunity_cnt == pair_outcome_cnt,
           "pair opportunity accounting mismatch");

    double issue_dual_rate = issue_group_cnt == 0 ? 0.0 :
      100.0 * (double)pipeline_issue_width_cnt[2] /
        (double)issue_group_cnt;
    double slot0_utilization =
      100.0 * (double)issue_group_cnt / (double)pipeline_cycle_cnt;
    double slot1_utilization =
      100.0 * (double)pipeline_issue_width_cnt[2] /
        (double)pipeline_cycle_cnt;
    double retire_ipc =
      (double)pipeline_retire_cnt / (double)pipeline_cycle_cnt;
    stats_section("Pipeline Throughput");
    stats_metric_header();
    stats_metric("Sampled cycles", "%llu",
      (unsigned long long)pipeline_cycle_cnt);
    stats_metric("Retired instructions", "%llu",
      (unsigned long long)pipeline_retire_cnt);
    stats_metric("No-retire cycles", "%llu",
      (unsigned long long)pipeline_no_retire_cnt);
    stats_metric("Active no-retire cycles", "%llu",
      (unsigned long long)pipeline_active_no_retire_cnt);
    stats_metric("Empty no-retire cycles", "%llu",
      (unsigned long long)pipeline_empty_no_retire_cnt);
    stats_metric("Retire width 1 cycles", "%llu",
      (unsigned long long)pipeline_retire_width_cnt[0]);
    stats_metric("Retire width 2 cycles", "%llu",
      (unsigned long long)pipeline_retire_width_cnt[1]);
    stats_metric("Issue width 0 cycles", "%llu",
      (unsigned long long)pipeline_issue_width_cnt[0]);
    stats_metric("Issue width 1 cycles", "%llu",
      (unsigned long long)pipeline_issue_width_cnt[1]);
    stats_metric("Issue width 2 cycles", "%llu",
      (unsigned long long)pipeline_issue_width_cnt[2]);
    stats_metric("Issued instructions", "%llu",
      (unsigned long long)issued_inst_cnt);
    stats_metric("Dual-issue rate", "%.2f%%", issue_dual_rate);
    stats_metric("Lane 0 utilization", "%.2f%%", slot0_utilization);
    stats_metric("Lane 1 utilization", "%.2f%%", slot1_utilization);
    stats_metric("Retire IPC", "%.6f", retire_ipc);
    stats_metric("IQ empty cycles", "%llu",
      (unsigned long long)pipeline_iq_occupancy_cnt[0]);
    stats_metric("IQ one-entry cycles", "%llu",
      (unsigned long long)pipeline_iq_occupancy_cnt[1]);
    stats_metric("IQ two-plus-entry cycles", "%llu",
      (unsigned long long)pipeline_iq_occupancy_cnt[2]);
    stats_metric("Same-group ALU0 -> ALU1 bypasses", "%llu",
      (unsigned long long)pipeline_flat_bypass_cnt);
    stats_metric("Same-group load -> slot1 hits", "%llu",
      (unsigned long long)pipeline_load_pair_hit_cnt);
    stats_metric("Same-group load -> slot1 replays", "%llu",
      (unsigned long long)pipeline_load_pair_replay_cnt);
    stats_metric("Control redirects", "%llu",
      (unsigned long long)pipeline_control_redirect_cnt);
    stats_metric("Load replays", "%llu",
      (unsigned long long)pipeline_load_replay_cnt);
    stats_metric("Projected IPC without backend stalls", "%.6f",
      ipc_without_backend_stall);
    stats_metric_end();

    const char *pair_line =
      "+------------------------+------------------+\n";
    stats_section("Pair Decisions");
    Stat("%s", pair_line);
    Stat("| %-22s | %16s |\n", "Outcome", "Count");
    Stat("%s", pair_line);
    Stat("| %-22s | %16llu |\n", "opportunities",
      (unsigned long long)pipeline_pair_opportunity_cnt);
    Stat("| %-22s | %16llu |\n", "success",
      (unsigned long long)pipeline_pair_success_cnt);
    Stat("| %-22s | %16llu |\n", "slot0-serial",
      (unsigned long long)pipeline_pair_reject_cnt[0]);
    Stat("| %-22s | %16llu |\n", "slot1-unsupported",
      (unsigned long long)pipeline_pair_reject_cnt[1]);
    Stat("| %-22s | %16llu |\n", "shared-resource",
      (unsigned long long)pipeline_pair_reject_cnt[2]);
    Stat("| %-22s | %16llu |\n", "WAW",
      (unsigned long long)pipeline_pair_reject_cnt[3]);
    Stat("| %-22s | %16llu |\n", "RAW",
      (unsigned long long)pipeline_pair_reject_cnt[4]);
    Stat("| %-22s | %16llu |\n", "slot1-late",
      (unsigned long long)pipeline_pair_reject_cnt[5]);
    Stat("%s", pair_line);

    stats_section("WAW Breakdown");
    stats_metric_header();
    stats_metric("WAW-only", "%llu",
      (unsigned long long)pipeline_waw_detail_cnt[0]);
    stats_metric("WAW + ALU0 flat RAW", "%llu",
      (unsigned long long)pipeline_waw_detail_cnt[1]);
    stats_metric("WAW + load RAW", "%llu",
      (unsigned long long)pipeline_waw_detail_cnt[2]);
    stats_metric("WAW + MUL RAW", "%llu",
      (unsigned long long)pipeline_waw_detail_cnt[3]);
    stats_metric_end();

    stats_section("Transient Store Forwarding");
    stats_metric_header();
    stats_metric("Ex1 store overlap cycles", "%llu",
      (unsigned long long)transient_store_overlap_ex1_cnt);
    stats_metric("Ex2 store overlap cycles", "%llu",
      (unsigned long long)transient_store_overlap_ex2_cnt);
    stats_metric("Final producers ready cycles", "%llu",
      (unsigned long long)transient_store_overlap_ready_cnt);
    stats_metric("Final producer not-ready cycles", "%llu",
      (unsigned long long)transient_store_overlap_not_ready_cnt);
    stats_metric("Forwarded loads", "%llu",
      (unsigned long long)transient_store_forward_cnt);
    stats_metric("Forwarded bytes", "%llu",
      (unsigned long long)transient_store_forward_byte_cnt);
    stats_metric("Unknown-address stall cycles", "%llu",
      (unsigned long long)transient_store_unknown_addr_stall_cnt);
    stats_metric("Not-ready-data stall cycles", "%llu",
      (unsigned long long)transient_store_data_stall_cnt);
    stats_metric("Multi-store merges", "%llu",
      (unsigned long long)transient_store_multi_store_cnt);
    stats_metric("Shadowed not-ready producer loads", "%llu",
      (unsigned long long)transient_store_shadowed_not_ready_cnt);
    stats_metric_end();

    const char *stall_summary_line =
      "+------------------+----------------+----------------+----------+\n";
    stats_section("Pipeline Stall Summary");
    Stat("%s", stall_summary_line);
    Stat("| %-16s | %14s | %14s | %8s |\n",
         "Class", "Cycles", "Events", "Cycle %");
    Stat("%s", stall_summary_line);
    Stat("| %-16s | %14llu | %14llu | %7.2f%% |\n",
         "backend",
         (unsigned long long)pipeline_backend_stall_cycle_cnt,
         (unsigned long long)pipeline_backend_stall_event_cnt,
         backend_stall_ratio);
    Stat("| %-16s | %14llu | %14llu | %7.2f%% |\n",
         "long-op",
         (unsigned long long)pipeline_long_stall_cycle_cnt,
         (unsigned long long)pipeline_long_stall_event_cnt,
         100.0 * (double)pipeline_long_stall_cycle_cnt /
           (double)pipeline_cycle_cnt);
    Stat("| %-16s | %14llu | %14llu | %7.2f%% |\n",
         "issue",
         (unsigned long long)pipeline_issue_hazard_cycle_cnt,
         (unsigned long long)pipeline_issue_hazard_event_cnt,
         100.0 * (double)pipeline_issue_hazard_cycle_cnt /
           (double)pipeline_cycle_cnt);
    Stat("%s", stall_summary_line);
    uint64_t primary_stall_accounted = 0;
    uint64_t raw_stall_sum = 0;
    uint64_t raw_long_sum = 0;
    uint64_t raw_backend_sum = 0;
    uint64_t raw_issue_sum = 0;
    for (int cause = 0; cause < PIPELINE_STALL_CAUSE_COUNT; cause++) {
      primary_stall_accounted +=
        pipeline_primary_stall_cause_cycle_cnt[cause];
      raw_stall_sum += pipeline_raw_stall_cause_cycle_cnt[cause];
      if (cause <= PIPELINE_STALL_WB_DIV) {
        raw_long_sum += pipeline_raw_stall_cause_cycle_cnt[cause];
      } else if (cause <= PIPELINE_STALL_BACKEND_LOAD) {
        raw_backend_sum += pipeline_raw_stall_cause_cycle_cnt[cause];
      } else {
        raw_issue_sum += pipeline_raw_stall_cause_cycle_cnt[cause];
      }
    }
    Assert(pipeline_primary_stall_cycle_cnt == primary_stall_accounted,
           "primary stall cause accounting mismatch");
    Assert(raw_stall_sum >= pipeline_primary_stall_cycle_cnt,
           "raw stall causes do not cover every primary stall cycle");
    Assert(raw_long_sum >= pipeline_long_stall_cycle_cnt,
           "raw long-op causes do not cover aggregate long stalls");
    Assert(raw_backend_sum >= pipeline_backend_stall_cycle_cnt,
           "raw backend causes do not cover aggregate backend stalls");
    Assert(raw_issue_sum >= pipeline_issue_hazard_cycle_cnt,
           "raw issue causes do not cover aggregate issue stalls");
    stats_section("Pipeline Stall Accounting");
    stats_metric_header();
    stats_metric("Frozen cycles", "%llu",
      (unsigned long long)pipeline_primary_stall_cycle_cnt);
    stats_metric("Accounted primary cycles", "%llu",
      (unsigned long long)primary_stall_accounted);
    stats_metric("Raw overlap sum", "%llu",
      (unsigned long long)raw_stall_sum);
    stats_metric_end();

    const char *stall_cause_line =
      "+-----------------------+--------------+--------------+----------"
      "+--------------+---------------+\n";
    stats_section("Pipeline Stall Causes");
    Stat("%s", stall_cause_line);
    Stat("| %-21s | %12s | %12s | %8s | %12s | %13s |\n",
         "Cause", "Primary cyc", "Events", "Frozen %",
         "Raw cycles", "Projected IPC");
    Stat("%s", stall_cause_line);
    for (int cause = 0; cause < PIPELINE_STALL_CAUSE_COUNT; cause++) {
      uint64_t primary_cycles =
        pipeline_primary_stall_cause_cycle_cnt[cause];
      uint64_t cycles_without_cause =
        measured_cycle_cnt > primary_cycles
          ? measured_cycle_cnt - primary_cycles : 0;
      double frozen_ratio =
        pipeline_primary_stall_cycle_cnt == 0 ? 0.0 :
          100.0 * (double)primary_cycles /
            (double)pipeline_primary_stall_cycle_cnt;
      double projected_ipc =
        cycles_without_cause == 0 ? 0.0 :
          (double)inst_cnt[TYPE_TOTAL] / (double)cycles_without_cause;
      Stat("| %-21s | %12llu | %12llu | %7.2f%% | %12llu | %13.6f |\n",
           pipeline_stall_cause_name[cause],
           (unsigned long long)primary_cycles,
           (unsigned long long)
             pipeline_primary_stall_cause_event_cnt[cause],
           frozen_ratio,
           (unsigned long long)pipeline_raw_stall_cause_cycle_cnt[cause],
           projected_ipc);
    }
    Stat("%s", stall_cause_line);
    dump_issue_operand_stats();
  }
#if defined(CONFIG_IF_COUNTER) || defined(CONFIG_LS_COUNTER) || \
    defined(CONFIG_EX_COUNTER)
  stats_section("Unit Counters");
  stats_metric_header();
#define DISPLAY_COUNTER_TABLE(name) \
  stats_metric(#name "u counter", "%llu", \
    (unsigned long long)name##_cnt)
  UNIT_COUNTER(DISPLAY_COUNTER_TABLE);
#undef DISPLAY_COUNTER_TABLE
  stats_metric_end();
#endif
  IFDEF(CONFIG_INST_TYPE_COUNTER, dump_instruction_stats());
  stats_report_end(pipeline_report_path, "pipeline statistics");

  const char *memory_report_path =
    sim_options.memory_report_file != NULL
      ? sim_options.memory_report_file
      : MEMORY_REPORT_DEFAULT;
  stats_report_begin(memory_report_path, "Memory Statistics");
  const char *dcache_line =
    "+----------+--------------+--------------+--------------+----------+\n";
  stats_section("D-cache");
  Stat("%s", dcache_line);
  Stat("| %-8s | %12s | %12s | %12s | %8s |\n",
       "Access", "Requests", "Hits", "Misses", "Hit rate");
  Stat("%s", dcache_line);
  Stat("| %-8s | %12llu | %12llu | %12llu | %7.2f%% |\n",
       "all",
       (unsigned long long)dcache_request_cnt,
       (unsigned long long)dcache_hit_cnt,
       (unsigned long long)(dcache_request_cnt - dcache_hit_cnt),
       dcache_hit_rate);
  Stat("| %-8s | %12llu | %12llu | %12llu | %7.2f%% |\n",
       "load",
       (unsigned long long)dcache_load_request_cnt,
       (unsigned long long)dcache_load_hit_cnt,
       (unsigned long long)
         (dcache_load_request_cnt - dcache_load_hit_cnt),
       dcache_load_hit_rate);
  Stat("| %-8s | %12llu | %12llu | %12llu | %7.2f%% |\n",
       "store",
       (unsigned long long)dcache_store_request_cnt,
       (unsigned long long)dcache_store_hit_cnt,
       (unsigned long long)
         (dcache_store_request_cnt - dcache_store_hit_cnt),
       dcache_store_hit_rate);
  Stat("%s", dcache_line);
  stats_section("Transient Refill");
  stats_metric_header();
  stats_metric("Refill candidates", "%llu",
    (unsigned long long)transient_refill_candidate_cnt);
  stats_metric("Transient candidates", "%llu",
    (unsigned long long)transient_refill_transient_candidate_cnt);
  stats_metric("Direct refills", "%llu",
    (unsigned long long)transient_refill_direct_cnt);
  stats_metric("Direct transient refills", "%llu",
    (unsigned long long)transient_refill_direct_transient_cnt);
  stats_metric("Deferred enqueues", "%llu",
    (unsigned long long)transient_refill_pending_enqueue_cnt);
  stats_metric("Deferred transient enqueues", "%llu",
    (unsigned long long)transient_refill_pending_transient_enqueue_cnt);
  stats_metric("Deferred refills", "%llu",
    (unsigned long long)transient_refill_pending_cnt);
  stats_metric("Deferred transient refills", "%llu",
    (unsigned long long)transient_refill_pending_transient_cnt);
  stats_metric("Pending wait cycles", "%llu",
    (unsigned long long)transient_refill_pending_wait_cnt);
  stats_metric("Dropped refill candidates", "%llu",
    (unsigned long long)transient_refill_drop_cnt);
  stats_metric("Startup-suppressed candidates", "%llu",
    (unsigned long long)transient_refill_startup_suppressed_cnt);
  stats_metric("Flushed pending refills", "%llu",
    (unsigned long long)transient_refill_flush_cnt);
  stats_metric_end();
  if (store_buffer_depth != 0) {
    stats_section("Store Buffer");
    stats_metric_header();
    stats_metric("Depth", "%llu",
      (unsigned long long)store_buffer_depth);
    stats_metric("Enqueues", "%llu",
      (unsigned long long)store_buffer_enqueue_cnt);
    stats_metric("Drains", "%llu",
      (unsigned long long)store_buffer_dequeue_cnt);
    stats_metric("Enqueue + drain overlaps", "%llu (%.2f%%)",
      (unsigned long long)store_buffer_overlap_cnt,
      store_buffer_overlap_ratio);
    stats_metric("Average occupancy", "%.3f", store_buffer_avg_occupancy);
    stats_metric("Maximum occupancy", "%llu / %llu",
      (unsigned long long)store_buffer_max_occupancy,
      (unsigned long long)store_buffer_depth);
    stats_metric("Nonempty cycles", "%llu",
      (unsigned long long)store_buffer_nonempty_cycle_cnt);
    stats_metric("Full cycles", "%llu",
      (unsigned long long)store_buffer_full_cycle_cnt);
    stats_metric("Accepted reads", "%llu",
      (unsigned long long)store_buffer_read_accept_cnt);
    stats_metric("Blocked read events", "%llu",
      (unsigned long long)store_buffer_read_blocked_event_cnt);
    stats_metric("Blocked read cycles", "%llu (%.2f%%)",
      (unsigned long long)store_buffer_read_blocked_cycle_cnt,
      store_buffer_read_blocked_ratio);
    stats_metric("Average read wait", "%.2f cycles",
      store_buffer_avg_read_wait);
    stats_metric("Same-word conflict cycles", "%llu",
      (unsigned long long)
        store_buffer_read_blocked_conflict_cycle_cnt);
    stats_metric("Independent blocked cycles", "%llu",
      (unsigned long long)
        store_buffer_read_blocked_independent_cycle_cnt);
    stats_metric("Concurrent BRAM reads + writes", "%llu",
      (unsigned long long)store_buffer_read_write_overlap_cnt);
    stats_metric("Same-word BRAM reads + writes", "%llu",
      (unsigned long long)store_buffer_read_write_same_word_cnt);
    stats_metric("Forwarded reads", "%llu",
      (unsigned long long)store_buffer_read_forwarded_cnt);
    stats_metric("Forwarded bytes", "%llu",
      (unsigned long long)store_buffer_read_forwarded_byte_cnt);
    stats_metric("Staged-write forwarded reads", "%llu",
      (unsigned long long)store_buffer_staged_forwarded_cnt);
    stats_metric("Staged-write forwarded bytes", "%llu",
      (unsigned long long)store_buffer_staged_forwarded_byte_cnt);
    stats_metric("Reads blocked by staged writes", "%llu",
      (unsigned long long)store_buffer_read_blocked_staged_write_cnt);
    stats_metric("Full-stall write cycles", "%llu",
      (unsigned long long)store_buffer_store_blocked_cycle_cnt);
    stats_metric("MMIO write wait cycles", "%llu",
      (unsigned long long)store_buffer_mmio_write_blocked_cycle_cnt);
    stats_metric("Projected IPC without read waits", "%.6f",
      ipc_without_store_buffer_read_wait);
    stats_metric_end();
  }
  IFDEF(CONFIG_ICACHE_AMAT, dump_icache_stats());
  stats_report_end(memory_report_path, "memory statistics");
#endif
}

void statistic() {
  verilator_final();
  trace_log_output();
  branch_difftest_dump_report();
  performance();
}

void assert_fail_msg() {
  isa_reg_display();
  trace_log_output();
  statistic();
}

extern "C" void test_data(int din) {
  Log("test data: " FMT_WORD, din);
}

extern "C" void ebreak() {
  sim_state.halt_val = cpu.gpr[10];
  sim_state.state = END;
}

extern "C" void get_dcache_counts(uint64_t load_request_cnt, uint64_t load_hit_cnt,
                                   uint64_t store_request_cnt, uint64_t store_hit_cnt) {
  dcache_load_request_cnt = load_request_cnt;
  dcache_load_hit_cnt = load_hit_cnt;
  dcache_store_request_cnt = store_request_cnt;
  dcache_store_hit_cnt = store_hit_cnt;
}

extern "C" void get_transient_refill_counts(
    uint64_t candidate_cnt,
    uint64_t transient_candidate_cnt,
    uint64_t direct_cnt,
    uint64_t direct_transient_cnt,
    uint64_t pending_enqueue_cnt,
    uint64_t pending_transient_enqueue_cnt,
    uint64_t pending_cnt,
    uint64_t pending_transient_cnt,
    uint64_t pending_wait_cnt,
    uint64_t drop_cnt,
    uint64_t startup_suppressed_cnt,
    uint64_t flush_cnt) {
  transient_refill_candidate_cnt = candidate_cnt;
  transient_refill_transient_candidate_cnt = transient_candidate_cnt;
  transient_refill_direct_cnt = direct_cnt;
  transient_refill_direct_transient_cnt = direct_transient_cnt;
  transient_refill_pending_enqueue_cnt = pending_enqueue_cnt;
  transient_refill_pending_transient_enqueue_cnt =
    pending_transient_enqueue_cnt;
  transient_refill_pending_cnt = pending_cnt;
  transient_refill_pending_transient_cnt = pending_transient_cnt;
  transient_refill_pending_wait_cnt = pending_wait_cnt;
  transient_refill_drop_cnt = drop_cnt;
  transient_refill_startup_suppressed_cnt = startup_suppressed_cnt;
  transient_refill_flush_cnt = flush_cnt;
}

extern "C" void get_store_buffer_counts(
    uint64_t depth,
    uint64_t store_enqueue_cnt,
    uint64_t store_dequeue_cnt,
    uint64_t store_overlap_cnt,
    uint64_t read_accept_cnt,
    uint64_t read_blocked_cycle_cnt,
    uint64_t read_blocked_event_cnt,
    uint64_t read_blocked_conflict_cycle_cnt,
    uint64_t read_blocked_independent_cycle_cnt,
    uint64_t read_write_overlap_cnt,
    uint64_t read_write_same_word_cnt,
    uint64_t read_forwarded_cnt,
    uint64_t read_forwarded_byte_cnt,
    uint64_t staged_forwarded_cnt,
    uint64_t staged_forwarded_byte_cnt,
    uint64_t read_blocked_staged_write_cnt,
    uint64_t store_blocked_cycle_cnt,
    uint64_t mmio_write_blocked_cycle_cnt,
    uint64_t nonempty_cycle_cnt,
    uint64_t full_cycle_cnt,
    uint64_t occupancy_sum,
    uint64_t max_occupancy) {
  store_buffer_depth = depth;
  store_buffer_enqueue_cnt = store_enqueue_cnt;
  store_buffer_dequeue_cnt = store_dequeue_cnt;
  store_buffer_overlap_cnt = store_overlap_cnt;
  store_buffer_read_accept_cnt = read_accept_cnt;
  store_buffer_read_blocked_cycle_cnt = read_blocked_cycle_cnt;
  store_buffer_read_blocked_event_cnt = read_blocked_event_cnt;
  store_buffer_read_blocked_conflict_cycle_cnt =
    read_blocked_conflict_cycle_cnt;
  store_buffer_read_blocked_independent_cycle_cnt =
    read_blocked_independent_cycle_cnt;
  store_buffer_read_write_overlap_cnt = read_write_overlap_cnt;
  store_buffer_read_write_same_word_cnt = read_write_same_word_cnt;
  store_buffer_read_forwarded_cnt = read_forwarded_cnt;
  store_buffer_read_forwarded_byte_cnt = read_forwarded_byte_cnt;
  store_buffer_staged_forwarded_cnt = staged_forwarded_cnt;
  store_buffer_staged_forwarded_byte_cnt = staged_forwarded_byte_cnt;
  store_buffer_read_blocked_staged_write_cnt =
    read_blocked_staged_write_cnt;
  store_buffer_store_blocked_cycle_cnt = store_blocked_cycle_cnt;
  store_buffer_mmio_write_blocked_cycle_cnt = mmio_write_blocked_cycle_cnt;
  store_buffer_nonempty_cycle_cnt = nonempty_cycle_cnt;
  store_buffer_full_cycle_cnt = full_cycle_cnt;
  store_buffer_occupancy_sum = occupancy_sum;
  store_buffer_max_occupancy = max_occupancy;
}

extern "C" void get_pipeline_counts(
    uint64_t sampled_cycle_cnt,
    uint64_t retire_cnt,
    uint64_t retire_width_1_cnt,
    uint64_t retire_width_2_cnt,
    uint64_t issue_width_0_cnt,
    uint64_t issue_width_1_cnt,
    uint64_t issue_width_2_cnt,
    uint64_t iq_empty_cnt,
    uint64_t iq_one_cnt,
    uint64_t iq_two_plus_cnt,
    uint64_t pair_opportunity_cnt,
    uint64_t pair_success_cnt,
    uint64_t reject_slot0_serial_cnt,
    uint64_t reject_slot1_unsupported_cnt,
    uint64_t reject_shared_resource_cnt,
    uint64_t reject_waw_cnt,
    uint64_t reject_raw_cnt,
    uint64_t reject_slot1_late_cnt,
    uint64_t waw_only_cnt,
    uint64_t waw_flat_raw_cnt,
    uint64_t waw_load_raw_cnt,
    uint64_t waw_mul_raw_cnt,
    uint64_t flat_bypass_cnt,
    uint64_t load_pair_hit_cnt,
    uint64_t load_pair_replay_cnt,
    uint64_t no_retire_cnt,
    uint64_t active_no_retire_cnt,
    uint64_t empty_no_retire_cnt,
    uint64_t backend_stall_cycle_cnt,
    uint64_t backend_stall_event_cnt,
    uint64_t long_stall_cycle_cnt,
    uint64_t long_stall_event_cnt,
    uint64_t issue_hazard_cycle_cnt,
    uint64_t issue_hazard_event_cnt,
    uint64_t control_redirect_cnt,
    uint64_t load_replay_cnt) {
  pipeline_cycle_cnt = sampled_cycle_cnt;
  pipeline_retire_cnt = retire_cnt;
  pipeline_retire_width_cnt[0] = retire_width_1_cnt;
  pipeline_retire_width_cnt[1] = retire_width_2_cnt;
  pipeline_issue_width_cnt[0] = issue_width_0_cnt;
  pipeline_issue_width_cnt[1] = issue_width_1_cnt;
  pipeline_issue_width_cnt[2] = issue_width_2_cnt;
  pipeline_iq_occupancy_cnt[0] = iq_empty_cnt;
  pipeline_iq_occupancy_cnt[1] = iq_one_cnt;
  pipeline_iq_occupancy_cnt[2] = iq_two_plus_cnt;
  pipeline_pair_opportunity_cnt = pair_opportunity_cnt;
  pipeline_pair_success_cnt = pair_success_cnt;
  pipeline_pair_reject_cnt[0] = reject_slot0_serial_cnt;
  pipeline_pair_reject_cnt[1] = reject_slot1_unsupported_cnt;
  pipeline_pair_reject_cnt[2] = reject_shared_resource_cnt;
  pipeline_pair_reject_cnt[3] = reject_waw_cnt;
  pipeline_pair_reject_cnt[4] = reject_raw_cnt;
  pipeline_pair_reject_cnt[5] = reject_slot1_late_cnt;
  pipeline_waw_detail_cnt[0] = waw_only_cnt;
  pipeline_waw_detail_cnt[1] = waw_flat_raw_cnt;
  pipeline_waw_detail_cnt[2] = waw_load_raw_cnt;
  pipeline_waw_detail_cnt[3] = waw_mul_raw_cnt;
  pipeline_flat_bypass_cnt = flat_bypass_cnt;
  pipeline_load_pair_hit_cnt = load_pair_hit_cnt;
  pipeline_load_pair_replay_cnt = load_pair_replay_cnt;
  pipeline_no_retire_cnt = no_retire_cnt;
  pipeline_active_no_retire_cnt = active_no_retire_cnt;
  pipeline_empty_no_retire_cnt = empty_no_retire_cnt;
  pipeline_backend_stall_cycle_cnt = backend_stall_cycle_cnt;
  pipeline_backend_stall_event_cnt = backend_stall_event_cnt;
  pipeline_long_stall_cycle_cnt = long_stall_cycle_cnt;
  pipeline_long_stall_event_cnt = long_stall_event_cnt;
  pipeline_issue_hazard_cycle_cnt = issue_hazard_cycle_cnt;
  pipeline_issue_hazard_event_cnt = issue_hazard_event_cnt;
  pipeline_control_redirect_cnt = control_redirect_cnt;
  pipeline_load_replay_cnt = load_replay_cnt;
}

extern "C" void get_transient_store_forward_counts(
    uint64_t store_overlap_ex1_cnt,
    uint64_t store_overlap_ex2_cnt,
    uint64_t store_overlap_ready_cnt,
    uint64_t store_overlap_not_ready_cnt,
    uint64_t transient_forward_cnt,
    uint64_t transient_forward_byte_cnt,
    uint64_t transient_unknown_addr_stall_cnt,
    uint64_t transient_data_stall_cnt,
    uint64_t transient_multi_store_cnt,
    uint64_t transient_shadowed_not_ready_cnt) {
  transient_store_overlap_ex1_cnt = store_overlap_ex1_cnt;
  transient_store_overlap_ex2_cnt = store_overlap_ex2_cnt;
  transient_store_overlap_ready_cnt = store_overlap_ready_cnt;
  transient_store_overlap_not_ready_cnt = store_overlap_not_ready_cnt;
  transient_store_forward_cnt = transient_forward_cnt;
  transient_store_forward_byte_cnt = transient_forward_byte_cnt;
  transient_store_unknown_addr_stall_cnt =
    transient_unknown_addr_stall_cnt;
  transient_store_data_stall_cnt = transient_data_stall_cnt;
  transient_store_multi_store_cnt = transient_multi_store_cnt;
  transient_store_shadowed_not_ready_cnt =
    transient_shadowed_not_ready_cnt;
}

extern "C" void get_pipeline_stall_counts(
    uint64_t primary_stall_cycle_cnt,
    uint64_t primary_wb_div_cycle_cnt,
    uint64_t primary_backend_store_cycle_cnt,
    uint64_t primary_backend_load_cycle_cnt,
    uint64_t primary_issue_system_cycle_cnt,
    uint64_t primary_issue_long_cycle_cnt,
    uint64_t primary_issue_store_overlap_cycle_cnt,
    uint64_t primary_issue_mmio_order_cycle_cnt,
    uint64_t primary_issue_load_port_cycle_cnt,
    uint64_t primary_issue_operand_cycle_cnt,
    uint64_t primary_wb_div_event_cnt,
    uint64_t primary_backend_store_event_cnt,
    uint64_t primary_backend_load_event_cnt,
    uint64_t primary_issue_system_event_cnt,
    uint64_t primary_issue_long_event_cnt,
    uint64_t primary_issue_store_overlap_event_cnt,
    uint64_t primary_issue_mmio_order_event_cnt,
    uint64_t primary_issue_load_port_event_cnt,
    uint64_t primary_issue_operand_event_cnt,
    uint64_t raw_wb_div_cycle_cnt,
    uint64_t raw_backend_store_cycle_cnt,
    uint64_t raw_backend_load_cycle_cnt,
    uint64_t raw_issue_system_cycle_cnt,
    uint64_t raw_issue_long_cycle_cnt,
    uint64_t raw_issue_store_overlap_cycle_cnt,
    uint64_t raw_issue_mmio_order_cycle_cnt,
    uint64_t raw_issue_load_port_cycle_cnt,
    uint64_t raw_issue_operand_cycle_cnt) {
  pipeline_primary_stall_cycle_cnt = primary_stall_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_WB_DIV] =
    primary_wb_div_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_BACKEND_STORE] =
    primary_backend_store_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_BACKEND_LOAD] =
    primary_backend_load_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_SYSTEM] =
    primary_issue_system_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_LONG] =
    primary_issue_long_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[
    PIPELINE_STALL_ISSUE_STORE_OVERLAP] =
      primary_issue_store_overlap_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_MMIO_ORDER] =
    primary_issue_mmio_order_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_LOAD_PORT] =
    primary_issue_load_port_cycle_cnt;
  pipeline_primary_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_OPERAND] =
    primary_issue_operand_cycle_cnt;

  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_WB_DIV] =
    primary_wb_div_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_BACKEND_STORE] =
    primary_backend_store_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_BACKEND_LOAD] =
    primary_backend_load_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_ISSUE_SYSTEM] =
    primary_issue_system_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_ISSUE_LONG] =
    primary_issue_long_event_cnt;
  pipeline_primary_stall_cause_event_cnt[
    PIPELINE_STALL_ISSUE_STORE_OVERLAP] =
      primary_issue_store_overlap_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_ISSUE_MMIO_ORDER] =
    primary_issue_mmio_order_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_ISSUE_LOAD_PORT] =
    primary_issue_load_port_event_cnt;
  pipeline_primary_stall_cause_event_cnt[PIPELINE_STALL_ISSUE_OPERAND] =
    primary_issue_operand_event_cnt;

  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_WB_DIV] =
    raw_wb_div_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_BACKEND_STORE] =
    raw_backend_store_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_BACKEND_LOAD] =
    raw_backend_load_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_SYSTEM] =
    raw_issue_system_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_LONG] =
    raw_issue_long_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_STORE_OVERLAP] =
    raw_issue_store_overlap_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_MMIO_ORDER] =
    raw_issue_mmio_order_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_LOAD_PORT] =
    raw_issue_load_port_cycle_cnt;
  pipeline_raw_stall_cause_cycle_cnt[PIPELINE_STALL_ISSUE_OPERAND] =
    raw_issue_operand_cycle_cnt;
}

extern "C" void record_issue_operand_stall(
    uint32_t stall_mask,
    uint32_t pc0,
    uint32_t pc1,
    uint32_t producer_stage,
    uint32_t producer_type,
    uint32_t consumer_type) {
  const uint32_t pc[2] = {pc0, pc1};
  for (int lane = 0; lane < 2; lane++) {
    uint32_t lane_mask = (stall_mask >> (lane * 2)) & 0x3;
    if (lane_mask == 0) {
      continue;
    }

    IssueOperandPcStat &pc_stat = issue_operand_pc_stats[pc[lane]];
    pc_stat.stall_cycles++;
    pc_stat.blocked_source_cycles +=
      (lane_mask & 1) + ((lane_mask >> 1) & 1);

    for (int source = 0; source < 2; source++) {
      int operand = lane * 2 + source;
      if ((stall_mask & (1u << operand)) == 0) {
        continue;
      }
      uint32_t stage = (producer_stage >> (operand * 3)) & 0x7;
      uint32_t producer = (producer_type >> (operand * 2)) & 0x3;
      uint32_t consumer = (consumer_type >> (operand * 2)) & 0x3;
      Assert(stage < ISSUE_OPERAND_PRODUCER_STAGE_COUNT,
             "invalid issue operand producer stage %u", stage);
      Assert(producer < ISSUE_OPERAND_PRODUCER_TYPE_COUNT,
             "invalid issue operand producer type %u", producer);
      issue_operand_detail_cnt
        [lane][source][stage][producer][consumer]++;
      issue_operand_blocked_source_cycle_cnt++;
    }
  }
}

static void init_output_files() {
  init_log(sim_options.log_file);

#ifdef CONFIG_MTRACE_SCATTER_PLOT
  init_csv(sim_options.csv_file);
#endif
}

static void init_trace_tools() {
  init_regex();

#ifdef CONFIG_ITRACE
  init_disasm();
#endif
}

static long load_program() {
  long img_size = load_img();

#if defined(CONFIG_FTRACE) || defined(BLTRACE)
  load_elf(sim_options.elf_file);
#endif

  return img_size;
}

static void init_runtime(long img_size) {
  init_device();

  init_cpu(CORE_ENTRY, 0);
  branch_difftest_set_test_file(PROGRAM);
  branch_difftest_set_report_path(sim_options.branch_report_file);

#ifdef CONFIG_CACHE_DIFF
  init_cache();
#endif

#ifdef CONFIG_DIFFTEST
  init_dut();

  init_difftest(sim_options.diff_so_file, img_size, sim_options.difftest_port);
#endif
}

void sim_start() {
#ifdef BATCH
  cpu_exec(-1);
#else
  sdb_mainloop();
#endif
}

void sim_init(int argc, char** argv) {
  
  init_verilator(argc, argv);
  
  parse_args(argc, argv);

  init_output_files();
  welcome();
  init_trace_tools();
  long img_size = load_program();
  init_runtime(img_size);
}

bool sim_run() {
  return sim_state.state == RUN;
}

void sim_end() {
  end_verilator();
}
