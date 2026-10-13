#include <branch_difftest.h>

#include <autoconf.h>
#include <dbg.h>
#include <mem.h>

#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define BR_REPORT_DEFAULT "./build/branch_difftest_report.txt"
#define BR_PC_STAT_BUCKETS 8192

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
#define TAGE_TABLES 4
#define TAGE_INDEX_BITS 10
#define TAGE_ENTRIES (1U << TAGE_INDEX_BITS)
#define TAGE_TAG_BITS 12
#define TAGE_TAG_MASK ((1U << TAGE_TAG_BITS) - 1)
#define TAGE_BASE_ENTRIES 1024
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
#define LOCAL_HISTORY_BITS CONFIG_BRANCH_DIFFTEST_LOCAL_HISTORY_BITS
#define LOCAL_LHT_BITS CONFIG_BRANCH_DIFFTEST_LOCAL_LHT_BITS
#define LOCAL_LHT_ENTRIES (1U << LOCAL_LHT_BITS)
#define LOCAL_PHT_BITS CONFIG_BRANCH_DIFFTEST_LOCAL_PHT_BITS
#define LOCAL_PHT_ENTRIES (1U << LOCAL_PHT_BITS)
#define LOCAL_TARGET_PC ((uint32_t)CONFIG_BRANCH_DIFFTEST_LOCAL_TARGET_PC)
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_TOPN
#define BR_TOPN CONFIG_BRANCH_DIFFTEST_TOPN
#else
#define BR_TOPN 10
#endif

#ifdef CONFIG_BRANCH_DIFFTEST

typedef struct {
  bool pred_taken;
  uint32_t target_pc;
  bool hit;
  uint8_t slot;
} PredictResult;

typedef struct BranchPredictor BranchPredictor;

struct BranchPredictor {
  const char *name;
  PredictResult (*predict)(BranchPredictor *p, uint32_t pc);
  void (*update)(BranchPredictor *p, uint32_t pc, uint32_t actual_target,
      bool actual_taken);
  void (*reset)(BranchPredictor *p);
  void (*destroy)(BranchPredictor *p);
  void *priv;
};

static const char *configured_predictor_name(void) {
  return
#if CONFIG_BRANCH_PRED_TYPE == 2
      "TAGE"
#elif CONFIG_BRANCH_PRED_TYPE == 1
      "Bimodal"
#else
      "Always-Not-Taken"
#endif
#ifdef CONFIG_BRANCH_RAS
      "-R"
#endif
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
      "-L"
#endif
#ifdef CONFIG_BRANCH_FAST_RECURRENCE
      "-CRC"
#endif
      ;
}

#if CONFIG_BRANCH_PRED_TYPE == 1 || CONFIG_BRANCH_PRED_TYPE == 2
typedef struct {
  uint32_t btb_width;
  uint32_t entries;
  uint32_t idx_mask;
  uint8_t *valid;
  uint32_t *tag;
  uint32_t *target;
  uint8_t *counter;
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  uint8_t loop_valid[16];
  uint32_t loop_tag[16];
  uint16_t loop_trip_count[16];
  uint16_t loop_iter_count[16];
  uint8_t loop_confidence[16];
  uint8_t loop_prediction[16];
  uint8_t loop_slot[16];
#endif
#ifdef CONFIG_BRANCH_RAS
  uint8_t *is_return;
  uint32_t ras_entries;
  uint32_t ras_count;
  uint32_t *ras_stack;
#endif
} BimodalPriv;
#endif

typedef struct {
  bool used;
  uint32_t pc;
  uint32_t inst;
  bool is_branch;
  int64_t total;
  int64_t miss;
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  int64_t tage_total;
  int64_t tage_miss;
#endif
#ifdef CONFIG_BRANCH_FAST_RECURRENCE
  int64_t frp_candidate;
  int64_t frp_candidate_correct;
  int64_t frp_owned;
  int64_t frp_correct;
  int64_t frp_active;
  int64_t frp_boundary;
#endif
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  int64_t loop_candidate;
  int64_t loop_correct;
  int64_t tage_on_loop_correct;
  int64_t final_on_loop_correct;
  int64_t loop_tage_disagree;
  int64_t disagree_choose_loop;
  int64_t disagree_choose_tage;
#endif
} BranchPcStat;

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
typedef struct {
  uint16_t tag;
  int8_t counter;
  uint8_t useful;
  bool valid;
} TageEntry;

typedef struct {
  uint8_t base[TAGE_BASE_ENTRIES];
  TageEntry table[TAGE_TABLES][TAGE_ENTRIES];
  uint64_t history;
  int64_t predictions;
  int64_t correct;
} TageModel;

typedef struct {
  bool taken;
  bool alternate_taken;
  int provider;
  uint16_t index[TAGE_TABLES];
  uint16_t tag[TAGE_TABLES];
} TagePrediction;

static const uint8_t g_tage_history_length[TAGE_TABLES] = {4, 12, 32, 64};
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
typedef struct {
  uint8_t *history_valid;
  uint32_t *history_tag;
  uint64_t *history;
  uint8_t *pattern;
  uint64_t history_mask;
  int64_t predictions;
  int64_t correct;
  int64_t target_predictions;
  int64_t target_correct;
  int64_t target_taken;
} LocalHistoryModel;
#endif

typedef struct {
  int64_t fetch_events;
  int64_t fetch_branch_events;
  int64_t fetch_jump_events;
  int64_t fetch_branch_dir_mismatch;
  int64_t fetch_branch_target_mismatch;
  int64_t fetch_jump_dir_mismatch;
  int64_t fetch_jump_target_mismatch;

  int64_t update_events;
  int64_t update_branch_events;
  int64_t update_jump_events;
  int64_t rtl_branch_full_correct;
  int64_t rtl_jump_full_correct;
  int64_t rtl_branch_direction_miss;
  int64_t rtl_branch_target_miss;
  int64_t rtl_jump_direction_miss;
  int64_t rtl_jump_target_miss;

  int64_t tage_response_events;
  int64_t tage_branch_response_events;
  int64_t tage_override_events;
  int64_t tage_frontend_override_events;
  int64_t tage_override_restart_events;
  int64_t tage_override_blocked_events;
  int64_t tage_fast_loop_provisional_events;
  int64_t tage_override_replaced_loop_events;

  int64_t frontend_cycles;
  int64_t frontend_request_candidate_cycles;
  int64_t frontend_request_fire_cycles;
  int64_t frontend_response_blocks;
  int64_t frontend_enqueued_instructions;
  int64_t frontend_dequeued_instructions;
  int64_t frontend_pause_cycles[5];
  int64_t frontend_restart_events[5];
  int64_t frontend_credit_pause_by_queue[17];
  int64_t frontend_credit_restart_by_queue[17];
  int64_t frontend_low_water_events[2];
  int64_t frontend_low_water_inflight[2][3];
  int64_t frontend_low_water_enqueue[2][3];
  int64_t frontend_low_water_external_refill[2];
  int64_t frontend_external_refill_events;
  int64_t frontend_external_refill_cycles;
  int64_t frontend_external_refill_max;
  int64_t frontend_external_refill_histogram[10];
  int64_t frontend_external_refill_superseded;
  int64_t frontend_iq_credit_blocked_cycles;
  int64_t frontend_ftq_credit_blocked_cycles;
  int64_t frontend_ftq_cycles;
  int64_t frontend_ftq_occupancy_sum;
  int64_t frontend_ftq_empty_cycles;
  int64_t frontend_ftq_empty_candidate_cycles;
  int64_t frontend_ftq_empty_iq_empty_cycles;
  int64_t frontend_ftq_full_cycles;
  int64_t frontend_ftq_allocated_blocks;
  int64_t frontend_ftq_released_blocks;
  int64_t frontend_ftq_rollback_events;
  int64_t frontend_ftq_rollback_blocks;
  int64_t frontend_ftq_occupancy_histogram[17];

  int64_t frp_candidate_events;
  int64_t frp_candidate_correct_events;
  int64_t frp_update_events;
  int64_t frp_correct_events;
  int64_t frp_active_events;
  int64_t frp_boundary_events;
  int64_t frp_token_created_events;
  int64_t frp_token_consumed_events;
  int64_t frp_blocked_by_issued_events;

  int64_t rtl_tage_update_events;
  int64_t rtl_tage_correct_events;
  int64_t loop_candidate_events;
  int64_t loop_correct_events;
  int64_t tage_on_loop_correct_events;
  int64_t final_on_loop_correct_events;
  int64_t loop_tage_disagree_events;
  int64_t disagree_choose_loop_events;
  int64_t disagree_choose_tage_events;

  bool first_mismatch_seen;
  uint32_t first_mismatch_pc;
  bool first_rtl_taken;
  bool first_model_taken;
  uint32_t first_rtl_target;
  uint32_t first_model_target;

  int64_t pc_stat_overflow;
} BranchDifftestStats;

typedef struct {
  bool valid;
  uint32_t update_pc;
  uint32_t predicted_pc;
  bool predicted_taken;
  bool actual_taken;
  uint32_t actual_target;
} PendingBpuUpdate;

static BranchPredictor g_predictor;
static BranchDifftestStats g_stats;
static BranchDifftestStats g_frozen_stats;
static PendingBpuUpdate g_pending_update;
static BranchPcStat g_pc_stats[BR_PC_STAT_BUCKETS];
static BranchPcStat g_frozen_pc_stats[BR_PC_STAT_BUCKETS];

enum FrontendPauseCause {
  FRONTEND_PAUSE_NONE = 0,
  FRONTEND_PAUSE_EXTERNAL_REDIRECT = 1,
  FRONTEND_PAUSE_RESERVATION = 2,
  FRONTEND_PAUSE_NO_CANDIDATE = 3,
  FRONTEND_PAUSE_OTHER = 4,
};

typedef struct {
  FrontendPauseCause pending_pause;
  bool external_refill_active;
  int external_refill_latency;
} FrontendDiagState;

static FrontendDiagState g_frontend_diag;
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
static TageModel g_tage;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
static LocalHistoryModel g_local;
#endif
static bool g_inited = false;
static bool g_report_dumped = false;
static bool g_early_stop_reported = false;
static bool g_statistics_windowed = false;
static bool g_statistics_frozen = false;
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
static int64_t g_frozen_tage_predictions = 0;
static int64_t g_frozen_tage_correct = 0;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
static int64_t g_frozen_local_predictions = 0;
static int64_t g_frozen_local_correct = 0;
static int64_t g_frozen_local_target_predictions = 0;
static int64_t g_frozen_local_target_correct = 0;
static int64_t g_frozen_local_target_taken = 0;
#endif
static const char *g_report_path = BR_REPORT_DEFAULT;
static const char *g_test_file = NULL;

#ifdef CONFIG_BRANCH_DIFFTEST_MISMATCH_ABORT
static void mismatch_abort(const char *kind,
        uint32_t pc,
        bool rtl_taken,
        bool model_taken,
        uint32_t rtl_target,
        uint32_t model_target) {
  Log_err("branch predictor mismatch (%s)", kind);
  Log_err("pc=" FMT_WORD ", rtl_taken=%d, model_taken=%d",
    pc, rtl_taken ? 1 : 0, model_taken ? 1 : 0);
  Log_err("rtl_target=" FMT_WORD ", model_target=" FMT_WORD,
    rtl_target, model_target);
  sim_state.state = ABORT;
}
#endif

static inline bool is_conditional_branch_opcode(uint32_t inst) {
  return (inst & 0x7fU) == 0x63U;
}

static inline bool is_jump_opcode(uint32_t inst) {
  uint32_t opcode = inst & 0x7fU;
  return opcode == 0x6fU || opcode == 0x67U;
}

static inline bool is_predictor_opcode(uint32_t inst) {
  uint32_t opcode = inst & 0x7fU;
  return opcode == 0x63U || opcode == 0x6fU || opcode == 0x67U;
}

#ifdef CONFIG_BRANCH_RAS
static inline bool is_link_reg(uint32_t reg) {
  return reg == 1U || reg == 5U;
}

static void decode_ras_action(uint32_t inst, bool *push, bool *pop) {
  uint32_t opcode = inst & 0x7fU;
  uint32_t rd = (inst >> 7) & 0x1fU;
  uint32_t rs1 = (inst >> 15) & 0x1fU;
  bool is_jal = opcode == 0x6fU;
  bool is_jalr = opcode == 0x67U;
  bool rd_is_link = is_link_reg(rd);
  bool rs1_is_link = is_link_reg(rs1);

  *push = (is_jal || is_jalr) && rd_is_link;
  *pop = is_jalr && rs1_is_link && (!rd_is_link || rd != rs1);
}

static void ras_update(BimodalPriv *priv, bool push, bool pop,
    uint32_t return_addr) {
  if (push && !pop) {
    for (uint32_t i = priv->ras_entries - 1; i > 0; i--) {
      priv->ras_stack[i] = priv->ras_stack[i - 1];
    }
    priv->ras_stack[0] = return_addr;
    if (priv->ras_count != priv->ras_entries) {
      priv->ras_count++;
    }
  } else if (!push && pop) {
    if (priv->ras_count != 0) {
      for (uint32_t i = 0; i + 1 < priv->ras_entries; i++) {
        priv->ras_stack[i] = priv->ras_stack[i + 1];
      }
      priv->ras_count--;
    }
  } else if (push && pop) {
    priv->ras_stack[0] = return_addr;
    if (priv->ras_count == 0) {
      priv->ras_count = 1;
    }
  }
}
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_MISMATCH_ABORT
static inline const char *predictor_class_name(uint32_t inst) {
  return is_conditional_branch_opcode(inst) ? "branch" :
         is_jump_opcode(inst) ? "jump" : "other";
}
#endif

static inline void maybe_mismatch_abort(uint32_t inst,
        uint32_t pc,
        bool rtl_taken,
        bool model_taken,
        uint32_t rtl_target,
        uint32_t model_target) {
#ifdef CONFIG_BRANCH_DIFFTEST_MISMATCH_ABORT
  mismatch_abort(predictor_class_name(inst), pc, rtl_taken, model_taken,
      rtl_target, model_target);
#else
  (void)inst;
  (void)pc;
  (void)rtl_taken;
  (void)model_taken;
  (void)rtl_target;
  (void)model_target;
#endif
}

static inline uint32_t fetch_inst(uint32_t pc) {
  return (uint32_t)vaddr_read((int)pc);
}

static inline uint32_t pc_stat_hash(uint32_t pc) {
  return ((pc >> 2) ^ (pc >> 13) ^ (pc >> 23)) & (BR_PC_STAT_BUCKETS - 1);
}

static BranchPcStat *find_or_create_pc_stat(uint32_t pc, uint32_t inst,
    bool is_branch) {
  uint32_t idx = pc_stat_hash(pc);

  for (uint32_t probe = 0; probe < BR_PC_STAT_BUCKETS; probe++) {
    BranchPcStat *stat = &g_pc_stats[(idx + probe) & (BR_PC_STAT_BUCKETS - 1)];
    if (!stat->used) {
      memset(stat, 0, sizeof(*stat));
      stat->used = true;
      stat->pc = pc;
      stat->inst = inst;
      stat->is_branch = is_branch;
      return stat;
    }
    if (stat->pc == pc) {
      return stat;
    }
  }

  g_stats.pc_stat_overflow++;
  return NULL;
}

static void record_pc_stat(uint32_t pc, uint32_t inst, bool is_branch,
    bool full_ok, bool tage_valid, bool tage_ok) {
  BranchPcStat *stat = find_or_create_pc_stat(pc, inst, is_branch);
  if (stat == NULL) {
    return;
  }

  stat->total++;
  if (!full_ok) {
    stat->miss++;
  }
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  if (tage_valid) {
    stat->tage_total++;
    if (!tage_ok) {
      stat->tage_miss++;
    }
  }
#else
  (void)tage_valid;
  (void)tage_ok;
#endif
}

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
static inline uint64_t tage_history_mask(uint32_t length) {
  return length == 64 ? UINT64_MAX : ((1ULL << length) - 1);
}

static inline uint64_t tage_hash(uint64_t value) {
  value ^= value >> 30;
  value *= 0xbf58476d1ce4e5b9ULL;
  value ^= value >> 27;
  value *= 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}

static inline uint64_t tage_key(uint32_t pc, uint32_t table) {
  uint64_t history = g_tage.history &
      tage_history_mask(g_tage_history_length[table]);
  return tage_hash(((uint64_t)pc >> 2) ^ history ^
      (history << 17) ^ (0x9e3779b97f4a7c15ULL * (table + 1)));
}

static TagePrediction tage_predict(uint32_t pc) {
  TagePrediction prediction;
  prediction.provider = -1;

  int alternate = -1;
  for (uint32_t i = 0; i < TAGE_TABLES; i++) {
    uint64_t key = tage_key(pc, i);
    prediction.index[i] = key & (TAGE_ENTRIES - 1);
    prediction.tag[i] = (key >> TAGE_INDEX_BITS) & TAGE_TAG_MASK;
  }

  for (int i = TAGE_TABLES - 1; i >= 0; i--) {
    TageEntry *entry = &g_tage.table[i][prediction.index[i]];
    if (entry->valid && entry->tag == prediction.tag[i]) {
      if (prediction.provider < 0) {
        prediction.provider = i;
      } else {
        alternate = i;
        break;
      }
    }
  }

  bool base_taken = g_tage.base[(pc >> 2) & (TAGE_BASE_ENTRIES - 1)] >= 2;
  prediction.alternate_taken = alternate >= 0 ?
      g_tage.table[alternate][prediction.index[alternate]].counter >= 0 :
      base_taken;
  prediction.taken = prediction.provider >= 0 ?
      g_tage.table[prediction.provider]
          [prediction.index[prediction.provider]].counter >= 0 :
      base_taken;
  return prediction;
}

static inline int8_t tage_counter_update(int8_t counter, bool taken) {
  if (taken) {
    return counter == 3 ? 3 : counter + 1;
  }
  return counter == -4 ? -4 : counter - 1;
}

static inline uint8_t tage_base_update(uint8_t counter, bool taken) {
  if (taken) {
    return counter == 3 ? 3 : counter + 1;
  }
  return counter == 0 ? 0 : counter - 1;
}

static void tage_update(uint32_t pc, bool actual_taken,
    const TagePrediction *prediction) {
  uint32_t base_index = (pc >> 2) & (TAGE_BASE_ENTRIES - 1);
  g_tage.base[base_index] =
      tage_base_update(g_tage.base[base_index], actual_taken);

  if (prediction->provider >= 0) {
    TageEntry *provider = &g_tage.table[prediction->provider]
        [prediction->index[prediction->provider]];
    provider->counter = tage_counter_update(provider->counter, actual_taken);

    if (prediction->taken != prediction->alternate_taken) {
      if (prediction->taken == actual_taken) {
        if (provider->useful != 3) {
          provider->useful++;
        }
      } else if (provider->useful != 0) {
        provider->useful--;
      }
    }
  }

  if (prediction->taken != actual_taken) {
    uint32_t allocated = 0;
    int first_longer = prediction->provider + 1;
    for (int i = first_longer; i < TAGE_TABLES && allocated < 2; i++) {
      TageEntry *entry = &g_tage.table[i][prediction->index[i]];
      if (!entry->valid || entry->useful == 0) {
        entry->valid = true;
        entry->tag = prediction->tag[i];
        entry->counter = actual_taken ? 0 : -1;
        entry->useful = 0;
        allocated++;
      }
    }

    if (allocated == 0) {
      for (int i = first_longer; i < TAGE_TABLES; i++) {
        TageEntry *entry = &g_tage.table[i][prediction->index[i]];
        if (entry->useful != 0) {
          entry->useful--;
        }
      }
    }
  }

  g_tage.history = (g_tage.history << 1) | actual_taken;
}

static bool tage_step(uint32_t pc, bool actual_taken) {
  TagePrediction prediction = tage_predict(pc);
  bool correct = prediction.taken == actual_taken;
  g_tage.predictions++;
  if (correct) {
    g_tage.correct++;
  }
  tage_update(pc, actual_taken, &prediction);
  return correct;
}
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
static inline uint32_t local_history_index(uint32_t pc) {
  return (pc >> 2) & (LOCAL_LHT_ENTRIES - 1);
}

static inline uint32_t local_history_tag(uint32_t pc) {
  return pc >> (LOCAL_LHT_BITS + 2);
}

static uint32_t local_fold_history(uint64_t history) {
  uint32_t folded = 0;
  while (history != 0) {
    folded ^= history & (LOCAL_PHT_ENTRIES - 1);
    history >>= LOCAL_PHT_BITS;
  }
  return folded & (LOCAL_PHT_ENTRIES - 1);
}

static bool local_history_step(uint32_t pc, bool actual_taken) {
  uint32_t history_index = local_history_index(pc);
  uint32_t history_tag = local_history_tag(pc);
  bool history_hit = g_local.history_valid[history_index] &&
      g_local.history_tag[history_index] == history_tag;
  uint64_t history = history_hit ? g_local.history[history_index] : 0;
  uint32_t pattern_index = ((pc >> 2) ^ local_fold_history(history)) &
      (LOCAL_PHT_ENTRIES - 1);
  bool predicted_taken = g_local.pattern[pattern_index] >= 2;
  uint8_t counter = g_local.pattern[pattern_index];

  if (actual_taken) {
    g_local.pattern[pattern_index] = counter == 3 ? 3 : counter + 1;
  } else {
    g_local.pattern[pattern_index] = counter == 0 ? 0 : counter - 1;
  }

  g_local.history_valid[history_index] = 1;
  g_local.history_tag[history_index] = history_tag;
  g_local.history[history_index] = ((history << 1) | actual_taken) &
      g_local.history_mask;

  bool correct = predicted_taken == actual_taken;
  g_local.predictions++;
  if (correct) {
    g_local.correct++;
  }
  if (pc == LOCAL_TARGET_PC) {
    g_local.target_predictions++;
    if (correct) {
      g_local.target_correct++;
    }
    if (actual_taken) {
      g_local.target_taken++;
    }
  }
  return correct;
}

static bool init_local_history_model(void) {
  memset(&g_local, 0, sizeof(g_local));
  g_local.history_valid = (uint8_t *)calloc(LOCAL_LHT_ENTRIES, sizeof(uint8_t));
  g_local.history_tag = (uint32_t *)calloc(LOCAL_LHT_ENTRIES, sizeof(uint32_t));
  g_local.history = (uint64_t *)calloc(LOCAL_LHT_ENTRIES, sizeof(uint64_t));
  g_local.pattern = (uint8_t *)malloc(LOCAL_PHT_ENTRIES * sizeof(uint8_t));
  if (!g_local.history_valid || !g_local.history_tag || !g_local.history ||
      !g_local.pattern) {
    free(g_local.history_valid);
    free(g_local.history_tag);
    free(g_local.history);
    free(g_local.pattern);
    memset(&g_local, 0, sizeof(g_local));
    return false;
  }
  memset(g_local.pattern, 1, LOCAL_PHT_ENTRIES * sizeof(uint8_t));
  g_local.history_mask = UINT64_MAX >> (64 - LOCAL_HISTORY_BITS);
  return true;
}

static void destroy_local_history_model(void) {
  free(g_local.history_valid);
  free(g_local.history_tag);
  free(g_local.history);
  free(g_local.pattern);
  g_local.history_valid = NULL;
  g_local.history_tag = NULL;
  g_local.history = NULL;
  g_local.pattern = NULL;
}
#endif

#if CONFIG_BRANCH_PRED_TYPE == 1 || CONFIG_BRANCH_PRED_TYPE == 2
static inline uint32_t branch_index(const BimodalPriv *priv, uint32_t pc) {
  return (pc >> 3) & priv->idx_mask;
}

static inline uint32_t branch_tag(const BimodalPriv *priv, uint32_t pc) {
  return pc >> (priv->btb_width + 3);
}

static inline uint32_t branch_entry(uint32_t block_idx, uint32_t slot) {
  return (block_idx << 1) | slot;
}
#endif

static PredictResult always_not_taken_predict(BranchPredictor *p, uint32_t pc) {
  (void)p;
  PredictResult res = { false, pc + 4, false, 0 };
  return res;
}

static void always_not_taken_update(BranchPredictor *p, uint32_t pc,
    uint32_t actual_target, bool actual_taken) {
  (void)p;
  (void)pc;
  (void)actual_target;
  (void)actual_taken;
}

static void always_not_taken_reset(BranchPredictor *p) {
  (void)p;
}

static void always_not_taken_destroy(BranchPredictor *p) {
  (void)p;
}

#if CONFIG_BRANCH_PRED_TYPE == 1 || CONFIG_BRANCH_PRED_TYPE == 2
static PredictResult bimodal_predict(BranchPredictor *p, uint32_t pc) {
  BimodalPriv *priv = (BimodalPriv *)p->priv;
  uint32_t block_idx = branch_index(priv, pc);
  uint32_t tag = branch_tag(priv, pc);
  uint32_t entry0 = branch_entry(block_idx, 0);
  uint32_t entry1 = branch_entry(block_idx, 1);
  bool hit0 = priv->valid[entry0] && priv->tag[entry0] == tag;
  bool hit1 = priv->valid[entry1] && priv->tag[entry1] == tag;
  bool select0 = ((pc >> 2) & 1U) == 0 && hit0;
  uint32_t entry = select0 ? entry0 : entry1;

  PredictResult res = { false, pc + 4, false, 0 };
  if (select0 || hit1) {
    res.hit = true;
    res.slot = select0 ? 0 : 1;
    res.pred_taken = priv->counter[entry] >= 2;
    res.target_pc = priv->target[entry];
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    uint32_t loop_idx = (pc >> 3) & 0xfU;
    uint32_t loop_tag = pc >> 7;
    if (priv->loop_valid[loop_idx] &&
        priv->loop_tag[loop_idx] == loop_tag &&
        priv->loop_slot[loop_idx] == res.slot &&
        (priv->loop_confidence[loop_idx] & 2U)) {
      res.pred_taken = priv->loop_prediction[loop_idx] != 0;
    }
#endif
#ifdef CONFIG_BRANCH_RAS
    if (priv->is_return[entry] && priv->ras_count != 0) {
      res.pred_taken = true;
      res.target_pc = priv->ras_stack[0];
    }
#endif
  }
  return res;
}

static void bimodal_update(BranchPredictor *p, uint32_t pc,
    uint32_t actual_target, bool actual_taken) {
  BimodalPriv *priv = (BimodalPriv *)p->priv;
  uint32_t block_idx = branch_index(priv, pc);
  uint32_t tag = branch_tag(priv, pc);
  uint8_t update_slot = (pc >> 2) & 1U;
  uint32_t entry = branch_entry(block_idx, update_slot);
  bool hit = priv->valid[entry] && priv->tag[entry] == tag;

#ifdef CONFIG_BRANCH_RAS
  bool ras_push = false;
  bool ras_pop = false;
  decode_ras_action(fetch_inst(pc), &ras_push, &ras_pop);
  (void)ras_push;
#endif

  if (hit) {
    uint8_t c = priv->counter[entry];
    if (actual_taken) {
      priv->counter[entry] = (c == 3) ? 3 : (uint8_t)(c + 1);
      priv->target[entry] = actual_target;
    } else {
      priv->counter[entry] = (c == 0) ? 0 : (uint8_t)(c - 1);
    }
  } else if (actual_taken) {
    priv->valid[entry] = 1;
    priv->tag[entry] = tag;
    priv->target[entry] = actual_target;
    priv->counter[entry] = 2;
#ifdef CONFIG_BRANCH_RAS
    priv->is_return[entry] = ras_pop ? 1 : 0;
#endif
  }

#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  if (is_conditional_branch_opcode(fetch_inst(pc))) {
    uint32_t loop_idx = (pc >> 3) & 0xfU;
    uint32_t loop_tag = pc >> 7;
    bool loop_hit = priv->loop_valid[loop_idx] &&
        priv->loop_tag[loop_idx] == loop_tag &&
        priv->loop_slot[loop_idx] == update_slot;
    if (loop_hit) {
      if (actual_taken) {
        uint16_t iter = priv->loop_iter_count[loop_idx];
        uint16_t iter_inc =
            (iter == UINT16_MAX) ? iter : (uint16_t)(iter + 1);
        priv->loop_iter_count[loop_idx] = iter_inc;
        priv->loop_prediction[loop_idx] =
            priv->loop_trip_count[loop_idx] != 0 &&
            iter_inc == priv->loop_trip_count[loop_idx] ? 0 : 1;
      } else {
        if (priv->loop_iter_count[loop_idx] != 0 &&
            priv->loop_iter_count[loop_idx] ==
                priv->loop_trip_count[loop_idx]) {
          if (priv->loop_confidence[loop_idx] != 3) {
            priv->loop_confidence[loop_idx]++;
          }
        } else {
          priv->loop_trip_count[loop_idx] =
              priv->loop_iter_count[loop_idx];
          priv->loop_confidence[loop_idx] = 0;
        }
        priv->loop_iter_count[loop_idx] = 0;
        priv->loop_prediction[loop_idx] = 1;
      }
    } else if (actual_taken && actual_target < pc) {
      priv->loop_valid[loop_idx] = 1;
      priv->loop_tag[loop_idx] = loop_tag;
      priv->loop_slot[loop_idx] = update_slot;
      priv->loop_trip_count[loop_idx] = 0;
      priv->loop_iter_count[loop_idx] = 1;
      priv->loop_confidence[loop_idx] = 0;
      priv->loop_prediction[loop_idx] = 1;
    } else {
      priv->loop_valid[loop_idx] = 0;
    }
  }
#endif
}

static void bimodal_reset(BranchPredictor *p) {
  BimodalPriv *priv = (BimodalPriv *)p->priv;
  uint32_t table_entries = priv->entries * 2;
  memset(priv->valid, 0, table_entries * sizeof(uint8_t));
  memset(priv->tag, 0, table_entries * sizeof(uint32_t));
  memset(priv->target, 0, table_entries * sizeof(uint32_t));
  memset(priv->counter, 1, table_entries * sizeof(uint8_t));
#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  memset(priv->loop_valid, 0, sizeof(priv->loop_valid));
#endif
#ifdef CONFIG_BRANCH_RAS
  memset(priv->is_return, 0, table_entries * sizeof(uint8_t));
  memset(priv->ras_stack, 0, priv->ras_entries * sizeof(uint32_t));
  priv->ras_count = 0;
#endif
}

static void bimodal_destroy(BranchPredictor *p) {
  BimodalPriv *priv = (BimodalPriv *)p->priv;
  if (!priv) return;
  free(priv->valid);
  free(priv->tag);
  free(priv->target);
  free(priv->counter);
#ifdef CONFIG_BRANCH_RAS
  free(priv->is_return);
  free(priv->ras_stack);
#endif
  free(priv);
  p->priv = NULL;
}

static bool init_bimodal_predictor(BranchPredictor *p) {
  BimodalPriv *priv = (BimodalPriv *)calloc(1, sizeof(BimodalPriv));
  if (!priv) {
    return false;
  }

#ifdef CONFIG_BRANCH_BTB_WIDTH
  priv->btb_width = CONFIG_BRANCH_BTB_WIDTH;
#else
  priv->btb_width = 4;
#endif
  if (priv->btb_width > 16) {
    priv->btb_width = 16;
  }
  priv->entries = 1U << priv->btb_width;
  priv->idx_mask = priv->entries - 1;
  uint32_t table_entries = priv->entries * 2;

  priv->valid = (uint8_t *)calloc(table_entries, sizeof(uint8_t));
  priv->tag = (uint32_t *)calloc(table_entries, sizeof(uint32_t));
  priv->target = (uint32_t *)calloc(table_entries, sizeof(uint32_t));
  priv->counter = (uint8_t *)malloc(table_entries * sizeof(uint8_t));
#ifdef CONFIG_BRANCH_RAS
  priv->is_return = (uint8_t *)calloc(table_entries, sizeof(uint8_t));
#ifdef CONFIG_BRANCH_RAS_WIDTH
  uint32_t ras_width = CONFIG_BRANCH_RAS_WIDTH;
#else
  uint32_t ras_width = 3;
#endif
  if (ras_width > 31) {
    ras_width = 31;
  }
  priv->ras_entries = 1U << ras_width;
  priv->ras_stack = (uint32_t *)calloc(priv->ras_entries, sizeof(uint32_t));
#endif

  if (!priv->valid || !priv->tag || !priv->target || !priv->counter
#ifdef CONFIG_BRANCH_RAS
      || !priv->is_return || !priv->ras_stack
#endif
  ) {
    free(priv->valid);
    free(priv->tag);
    free(priv->target);
    free(priv->counter);
#ifdef CONFIG_BRANCH_RAS
    free(priv->is_return);
    free(priv->ras_stack);
#endif
    free(priv);
    return false;
  }

  p->name = configured_predictor_name();
  p->predict = bimodal_predict;
  p->update = bimodal_update;
  p->reset = bimodal_reset;
  p->destroy = bimodal_destroy;
  p->priv = priv;
  p->reset(p);
  return true;
}
#endif

static bool init_predictor(BranchPredictor *p) {
  memset(p, 0, sizeof(*p));

#if CONFIG_BRANCH_PRED_TYPE == 1 || CONFIG_BRANCH_PRED_TYPE == 2
    return init_bimodal_predictor(p);
#endif

  p->name = configured_predictor_name();
  p->predict = always_not_taken_predict;
  p->update = always_not_taken_update;
  p->reset = always_not_taken_reset;
  p->destroy = always_not_taken_destroy;
  p->priv = NULL;
  return true;
}

static void ensure_inited(void) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  return;
#else
  if (g_inited) {
    return;
  }

  memset(&g_stats, 0, sizeof(g_stats));
  memset(&g_frontend_diag, 0, sizeof(g_frontend_diag));
  memset(g_pc_stats, 0, sizeof(g_pc_stats));
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  memset(&g_tage, 0, sizeof(g_tage));
  memset(g_tage.base, 1, sizeof(g_tage.base));
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  if (!init_local_history_model()) {
    panic("branch difftest local-history model init failed");
  }
#endif
  if (!init_predictor(&g_predictor)) {
    panic("branch difftest predictor init failed");
  }
  const char *predictor_name = g_predictor.name ? g_predictor.name : "unknown";
  Log("branch predictor: %s%s%s",
      ANSI_FG_GREEN, predictor_name, ANSI_NONE);
  g_inited = true;
#endif
}

#endif

void branch_difftest_set_report_path(const char *path) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  (void)path;
#else
  ensure_inited();
  if (path && path[0] != '\0') {
    g_report_path = path;
  }
  Log("branch difftest: %sON%s", ANSI_FG_GREEN, ANSI_NONE);
#endif
}

void branch_difftest_set_test_file(const char *path) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  (void)path;
#else
  ensure_inited();
  if (path && path[0] != '\0') {
    g_test_file = path;
  }
#endif
}

void branch_difftest_reset_statistics(void) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  return;
#else
  ensure_inited();
  memset(&g_stats, 0, sizeof(g_stats));
  memset(&g_frontend_diag, 0, sizeof(g_frontend_diag));
  memset(g_pc_stats, 0, sizeof(g_pc_stats));
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  g_tage.predictions = 0;
  g_tage.correct = 0;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  g_local.predictions = 0;
  g_local.correct = 0;
  g_local.target_predictions = 0;
  g_local.target_correct = 0;
  g_local.target_taken = 0;
#endif
  g_early_stop_reported = false;
  g_statistics_windowed = true;
  g_statistics_frozen = false;
#endif
}

void branch_difftest_freeze_statistics(void) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  return;
#else
  if (!g_inited || !g_statistics_windowed) {
    return;
  }
  g_frozen_stats = g_stats;
  memcpy(g_frozen_pc_stats, g_pc_stats, sizeof(g_pc_stats));
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  g_frozen_tage_predictions = g_tage.predictions;
  g_frozen_tage_correct = g_tage.correct;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  g_frozen_local_predictions = g_local.predictions;
  g_frozen_local_correct = g_local.correct;
  g_frozen_local_target_predictions = g_local.target_predictions;
  g_frozen_local_target_correct = g_local.target_correct;
  g_frozen_local_target_taken = g_local.target_taken;
#endif
  g_statistics_frozen = true;
#endif
}

#ifdef CONFIG_BRANCH_DIFFTEST
static void compare_bpu_response(int valid, int fetch_pc,
    int predicted_pc, int predicted_taken, int predicted_slot,
    int predicted_hit) {
  if (sim_state.state != RUN) {
    return;
  }

  if (!valid) {
    return;
  }

  ensure_inited();
  g_stats.fetch_events++;

  uint32_t request_pc = (uint32_t)fetch_pc;
  PredictResult model = g_predictor.predict(&g_predictor, request_pc);
  bool rtl_hit = predicted_hit != 0;
  uint8_t rtl_slot = (uint8_t)predicted_slot & 1U;

  if (model.hit != rtl_hit || (rtl_hit && model.slot != rtl_slot)) {
    uint32_t pc = (request_pc & ~0x7U) |
        ((uint32_t)(rtl_hit ? rtl_slot : model.slot) << 2);
    uint32_t inst = fetch_inst(pc);
    bool is_branch = is_conditional_branch_opcode(inst);
    if (is_branch) {
      g_stats.fetch_branch_dir_mismatch++;
    } else {
      g_stats.fetch_jump_dir_mismatch++;
    }
    if (!g_stats.first_mismatch_seen) {
      g_stats.first_mismatch_seen = true;
      g_stats.first_mismatch_pc = pc;
      g_stats.first_rtl_taken = rtl_hit && predicted_taken != 0;
      g_stats.first_model_taken = model.hit && model.pred_taken;
      g_stats.first_rtl_target = (uint32_t)predicted_pc;
      g_stats.first_model_target = model.target_pc;
    }
    maybe_mismatch_abort(inst, pc, rtl_hit && predicted_taken != 0,
        model.hit && model.pred_taken, (uint32_t)predicted_pc,
        model.target_pc);
    return;
  }

  if (!rtl_hit) {
    return;
  }

  uint32_t pc = (request_pc & ~0x7U) | ((uint32_t)rtl_slot << 2);
  uint32_t inst = fetch_inst(pc);
  if (!is_predictor_opcode(inst)) {
    return;
  }

  bool is_branch = is_conditional_branch_opcode(inst);
  if (is_branch) {
    g_stats.fetch_branch_events++;
  } else {
    g_stats.fetch_jump_events++;
  }

  bool rtl_taken = predicted_taken != 0;
  uint32_t rtl_target = (uint32_t)predicted_pc;
  bool model_taken = model.pred_taken;
  uint32_t model_target = model.target_pc;

  if (model_taken != rtl_taken) {
    if (is_branch) {
      g_stats.fetch_branch_dir_mismatch++;
    } else {
      g_stats.fetch_jump_dir_mismatch++;
    }
    if (!g_stats.first_mismatch_seen) {
      g_stats.first_mismatch_seen = true;
      g_stats.first_mismatch_pc = pc;
      g_stats.first_rtl_taken = rtl_taken;
      g_stats.first_model_taken = model_taken;
      g_stats.first_rtl_target = rtl_target;
      g_stats.first_model_target = model_target;
    }
    maybe_mismatch_abort(inst, pc, rtl_taken, model_taken, rtl_target, model_target);
    return;
  }

  if (rtl_taken && model_target != rtl_target) {
    if (is_branch) {
      g_stats.fetch_branch_target_mismatch++;
    } else {
      g_stats.fetch_jump_target_mismatch++;
    }
    if (!g_stats.first_mismatch_seen) {
      g_stats.first_mismatch_seen = true;
      g_stats.first_mismatch_pc = pc;
      g_stats.first_rtl_taken = rtl_taken;
      g_stats.first_model_taken = model_taken;
      g_stats.first_rtl_target = rtl_target;
      g_stats.first_model_target = model_target;
    }
    maybe_mismatch_abort(inst, pc, rtl_taken, model_taken, rtl_target, model_target);
  }
}

#ifdef CONFIG_BRANCH_RAS
static void apply_bpu_ras_update(const PendingBpuUpdate *update) {
  if (sim_state.state != RUN || !update->valid) {
    return;
  }

  uint32_t inst = fetch_inst(update->update_pc);
  if (!is_predictor_opcode(inst)) {
    return;
  }

  bool ras_push = false;
  bool ras_pop = false;
  decode_ras_action(inst, &ras_push, &ras_pop);
  BimodalPriv *priv = (BimodalPriv *)g_predictor.priv;
  ras_update(priv, ras_push, ras_pop, update->update_pc + 4);
}
#endif

static void apply_bpu_update(const PendingBpuUpdate *update) {
  if (sim_state.state != RUN) {
    return;
  }

  ensure_inited();
  g_stats.update_events++;

#ifdef CONFIG_BRANCH_DIFFTEST_EARLY_STOP
  if (!g_early_stop_reported &&
      g_stats.update_events >= (int64_t)CONFIG_BRANCH_DIFFTEST_EARLY_STOP_COUNT) {
    g_early_stop_reported = true;
    Log("branch difftest early stop: collected %" PRId64 " branch predictor updates",
        g_stats.update_events);
    sim_state.state = QUIT;
  }
#endif

  uint32_t pc = update->update_pc;
  uint32_t inst = fetch_inst(pc);
  if (!is_predictor_opcode(inst)) {
    return;
  }

  bool is_branch = is_conditional_branch_opcode(inst);
  bool rtl_taken = update->predicted_taken;
  bool taken = update->actual_taken;
  bool direction_ok = rtl_taken == taken;
  bool target_ok = update->predicted_pc == update->actual_target;
  bool full_ok = direction_ok && target_ok;
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  bool tage_ok = is_branch && tage_step(pc, taken);
#else
  bool tage_ok = false;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  if (is_branch) {
    local_history_step(pc, taken);
  }
#endif

  if (is_branch) {
    g_stats.update_branch_events++;
    if (!direction_ok) {
      g_stats.rtl_branch_direction_miss++;
    } else if (!target_ok) {
      g_stats.rtl_branch_target_miss++;
    }
    if (full_ok) {
      g_stats.rtl_branch_full_correct++;
    }
  } else {
    g_stats.update_jump_events++;
    if (!direction_ok) {
      g_stats.rtl_jump_direction_miss++;
    } else if (!target_ok) {
      g_stats.rtl_jump_target_miss++;
    }
    if (full_ok) {
      g_stats.rtl_jump_full_correct++;
    }
  }

  record_pc_stat(pc, inst, is_branch, full_ok, is_branch, tage_ok);
  g_predictor.update(&g_predictor, pc, update->actual_target, taken);
}
#endif

void branch_difftest_queue_update(int update_en, int update_pc, int predicted_pc,
    int predicted_taken, int actual_taken, int actual_target) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  (void)update_en;
  (void)update_pc;
  (void)predicted_pc;
  (void)predicted_taken;
  (void)actual_taken;
  (void)actual_target;
#else
  g_pending_update.valid = update_en != 0;
  g_pending_update.update_pc = (uint32_t)update_pc;
  g_pending_update.predicted_pc = (uint32_t)predicted_pc;
  g_pending_update.predicted_taken = predicted_taken != 0;
  g_pending_update.actual_taken = actual_taken != 0;
  g_pending_update.actual_target = (uint32_t)actual_target;
#endif
}

void branch_difftest_frp_update(int valid, int candidate, int active,
    int boundary, int pc, int predicted_taken, int actual_taken) {
#if !defined(CONFIG_BRANCH_DIFFTEST) || \
    !defined(CONFIG_BRANCH_FAST_RECURRENCE)
  (void)valid;
  (void)candidate;
  (void)active;
  (void)boundary;
  (void)pc;
  (void)predicted_taken;
  (void)actual_taken;
#else
  if (sim_state.state != RUN || (!valid && !candidate && !active && !boundary)) {
    return;
  }
  ensure_inited();
  uint32_t update_pc = (uint32_t)pc;
  BranchPcStat *stat = find_or_create_pc_stat(update_pc,
      fetch_inst(update_pc), true);

  if (candidate) {
    bool final_correct = (predicted_taken != 0) == (actual_taken != 0);
    g_stats.frp_candidate_events++;
    g_stats.frp_candidate_correct_events += final_correct;
    if (stat != NULL) {
      stat->frp_candidate++;
      stat->frp_candidate_correct += final_correct;
    }
  }
  if (valid) {
    bool correct = (predicted_taken != 0) == (actual_taken != 0);
    g_stats.frp_update_events++;
    if (correct) {
      g_stats.frp_correct_events++;
    }
    if (stat != NULL) {
      stat->frp_owned++;
      if (correct) {
        stat->frp_correct++;
      }
    }
  }
  if (active) {
    g_stats.frp_active_events++;
    if (stat != NULL) {
      stat->frp_active++;
    }
  }
  if (boundary) {
    g_stats.frp_boundary_events++;
    if (stat != NULL) {
      stat->frp_boundary++;
    }
  }
#endif
}

void branch_difftest_frp_activity(int token_created, int token_consumed,
    int blocked_by_issued) {
#if !defined(CONFIG_BRANCH_DIFFTEST) || \
    !defined(CONFIG_BRANCH_FAST_RECURRENCE)
  (void)token_created;
  (void)token_consumed;
  (void)blocked_by_issued;
#else
  if (sim_state.state != RUN) {
    return;
  }
  g_stats.frp_token_created_events += token_created;
  g_stats.frp_token_consumed_events += token_consumed;
  g_stats.frp_blocked_by_issued_events += blocked_by_issued;
#endif
}

void branch_difftest_loop_update(int valid, int pc, int loop_candidate,
    int loop_prediction, int reference_valid, int reference_prediction,
    int final_prediction, int actual_taken) {
#if !defined(CONFIG_BRANCH_DIFFTEST) || \
    !defined(CONFIG_BRANCH_LOOP_PREDICTOR)
  (void)valid;
  (void)pc;
  (void)loop_candidate;
  (void)loop_prediction;
  (void)reference_valid;
  (void)reference_prediction;
  (void)final_prediction;
  (void)actual_taken;
#else
  if (sim_state.state != RUN || !valid) {
    return;
  }

  ensure_inited();
  bool loop_taken = loop_prediction != 0;
  bool reference_taken = reference_prediction != 0;
  bool final_taken = final_prediction != 0;
  bool actual = actual_taken != 0;
  uint32_t update_pc = (uint32_t)pc;
  BranchPcStat *stat = find_or_create_pc_stat(update_pc,
      fetch_inst(update_pc), true);

  if (reference_valid) {
    g_stats.rtl_tage_update_events++;
    if (reference_taken == actual) {
      g_stats.rtl_tage_correct_events++;
    }
  }

  if (!loop_candidate || !reference_valid) {
    return;
  }

  bool loop_correct = loop_taken == actual;
  bool reference_correct = reference_taken == actual;
  bool final_correct = final_taken == actual;
  bool disagree = loop_taken != reference_taken;

  g_stats.loop_candidate_events++;
  g_stats.loop_correct_events += loop_correct;
  g_stats.tage_on_loop_correct_events += reference_correct;
  g_stats.final_on_loop_correct_events += final_correct;
  g_stats.loop_tage_disagree_events += disagree;
  if (disagree && final_taken == loop_taken) {
    g_stats.disagree_choose_loop_events++;
  }
  if (disagree && final_taken == reference_taken) {
    g_stats.disagree_choose_tage_events++;
  }

  if (stat != NULL) {
    stat->loop_candidate++;
    stat->loop_correct += loop_correct;
    stat->tage_on_loop_correct += reference_correct;
    stat->final_on_loop_correct += final_correct;
    stat->loop_tage_disagree += disagree;
    if (disagree && final_taken == loop_taken) {
      stat->disagree_choose_loop++;
    }
    if (disagree && final_taken == reference_taken) {
      stat->disagree_choose_tage++;
    }
  }
#endif
}

void branch_difftest_on_bpu_response(int resp_valid, int resp_pc,
    int predicted_pc, int predicted_taken, int predicted_slot,
    int predicted_hit) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  (void)resp_valid;
  (void)resp_pc;
  (void)predicted_pc;
  (void)predicted_taken;
  (void)predicted_slot;
  (void)predicted_hit;
#else
  // The RAS top is an asynchronous output, so the response sampled at the
  // falling edge observes a push/pop made on the preceding rising edge.
  // Apply only the RAS part before comparing the response.
#ifdef CONFIG_BRANCH_RAS
  apply_bpu_ras_update(&g_pending_update);
#endif

  // The Bimodal arrays are synchronously read before their same-edge write,
  // so advance the BTB/counter model only after comparing the response.
  // The predictor reads its tables before applying the update on the same
  // rising edge.  Compare that response first, then advance the software model
  // with the update captured by Mundus_DPIC at that edge.
  compare_bpu_response(resp_valid, resp_pc, predicted_pc, predicted_taken,
      predicted_slot, predicted_hit);

  if (g_pending_update.valid) {
    apply_bpu_update(&g_pending_update);
  }
  g_pending_update.valid = false;
#endif
}

void branch_difftest_on_frontend_cycle(int external_redirect, int queue_count,
    int downstream_ready, int dequeue_count, int request_candidate,
    int reservation_available, int request_fire, int inflight_count,
    int response_usable, int enqueue_count, int iq_reservation_available,
    int ftq_reservation_available, int ftq_count, int ftq_alloc_count,
    int ftq_pop_count, int ftq_rollback_count) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  (void)external_redirect;
  (void)queue_count;
  (void)downstream_ready;
  (void)dequeue_count;
  (void)request_candidate;
  (void)reservation_available;
  (void)request_fire;
  (void)inflight_count;
  (void)response_usable;
  (void)enqueue_count;
  (void)iq_reservation_available;
  (void)ftq_reservation_available;
  (void)ftq_count;
  (void)ftq_alloc_count;
  (void)ftq_pop_count;
  (void)ftq_rollback_count;
#else
  if (sim_state.state != RUN) {
    return;
  }

  ensure_inited();
  bool redirected = external_redirect != 0;
  bool candidate = request_candidate != 0;
  bool reservation = reservation_available != 0;
  bool fired = request_fire != 0;
  int queued = queue_count < 0 ? 0 : queue_count;
  int inflight = inflight_count < 0 ? 0 : inflight_count;
  int enqueued = enqueue_count < 0 ? 0 : enqueue_count;
  int dequeued = dequeue_count < 0 ? 0 : dequeue_count;
  bool iq_reservation = iq_reservation_available != 0;
  bool ftq_reservation = ftq_reservation_available != 0;
  int ftq_occupancy = ftq_count < 0 ? 0 : ftq_count;
  int ftq_allocated = ftq_alloc_count < 0 ? 0 : ftq_alloc_count;
  int ftq_released = ftq_pop_count < 0 ? 0 : ftq_pop_count;
  int ftq_rollback = ftq_rollback_count < 0 ? 0 : ftq_rollback_count;
  if (inflight > 2) inflight = 2;
  if (enqueued > 2) enqueued = 2;
  if (dequeued > 2) dequeued = 2;
  if (ftq_occupancy > 16) ftq_occupancy = 16;
  if (ftq_allocated > 1) ftq_allocated = 1;
  if (ftq_released > 2) ftq_released = 2;
  if (ftq_rollback > 16) ftq_rollback = 16;

  g_stats.frontend_cycles++;
  g_stats.frontend_request_candidate_cycles += candidate;
  g_stats.frontend_request_fire_cycles += fired;
  g_stats.frontend_dequeued_instructions += dequeued;
  if (response_usable) {
    g_stats.frontend_response_blocks++;
  }
  g_stats.frontend_enqueued_instructions += enqueued;

#ifdef CONFIG_BP_TAGE
  g_stats.frontend_ftq_cycles++;
  g_stats.frontend_ftq_occupancy_sum += ftq_occupancy;
  g_stats.frontend_ftq_occupancy_histogram[ftq_occupancy]++;
  g_stats.frontend_ftq_allocated_blocks += ftq_allocated;
  g_stats.frontend_ftq_released_blocks += ftq_released;
  if (ftq_occupancy == 0) {
    g_stats.frontend_ftq_empty_cycles++;
    g_stats.frontend_ftq_empty_candidate_cycles += candidate;
    g_stats.frontend_ftq_empty_iq_empty_cycles += queued == 0;
  }
  if (ftq_occupancy == CONFIG_BRANCH_FTQ_DEPTH) {
    g_stats.frontend_ftq_full_cycles++;
  }
  if (ftq_rollback != 0) {
    g_stats.frontend_ftq_rollback_events++;
    g_stats.frontend_ftq_rollback_blocks += ftq_rollback;
  }
  if (candidate && !fired && !redirected) {
    if (!iq_reservation) {
      g_stats.frontend_iq_credit_blocked_cycles++;
    } else if (!ftq_reservation) {
      g_stats.frontend_ftq_credit_blocked_cycles++;
    }
  }
#else
  (void)iq_reservation;
  (void)ftq_reservation;
  (void)ftq_occupancy;
  (void)ftq_allocated;
  (void)ftq_released;
  (void)ftq_rollback;
#endif

  if (!fired) {
    FrontendPauseCause cause;
    if (redirected) {
      cause = FRONTEND_PAUSE_EXTERNAL_REDIRECT;
    } else if (candidate && !reservation) {
      cause = FRONTEND_PAUSE_RESERVATION;
    } else if (!candidate) {
      cause = FRONTEND_PAUSE_NO_CANDIDATE;
    } else {
      cause = FRONTEND_PAUSE_OTHER;
    }
    g_stats.frontend_pause_cycles[cause]++;
    if (cause == FRONTEND_PAUSE_RESERVATION) {
      int queue_bucket = queued < 16 ? queued : 16;
      g_stats.frontend_credit_pause_by_queue[queue_bucket]++;
    }
    if (g_frontend_diag.pending_pause == FRONTEND_PAUSE_NONE ||
        cause == FRONTEND_PAUSE_EXTERNAL_REDIRECT ||
        (g_frontend_diag.pending_pause == FRONTEND_PAUSE_NO_CANDIDATE &&
         cause == FRONTEND_PAUSE_RESERVATION)) {
      g_frontend_diag.pending_pause = cause;
    }
  } else if (g_frontend_diag.pending_pause != FRONTEND_PAUSE_NONE) {
    if (g_frontend_diag.pending_pause == FRONTEND_PAUSE_RESERVATION) {
      int queue_bucket = queued < 16 ? queued : 16;
      g_stats.frontend_credit_restart_by_queue[queue_bucket]++;
    }
    g_stats.frontend_restart_events[g_frontend_diag.pending_pause]++;
    g_frontend_diag.pending_pause = FRONTEND_PAUSE_NONE;
  }

  if (downstream_ready && queued <= 1) {
    int low_index = queued;
    g_stats.frontend_low_water_events[low_index]++;
    g_stats.frontend_low_water_inflight[low_index][inflight]++;
    g_stats.frontend_low_water_enqueue[low_index][enqueued]++;
    g_stats.frontend_low_water_external_refill[low_index] +=
        g_frontend_diag.external_refill_active;
  }

  if (redirected) {
    if (g_frontend_diag.external_refill_active) {
      g_stats.frontend_external_refill_superseded++;
    }
    g_frontend_diag.external_refill_active = true;
    g_frontend_diag.external_refill_latency = 0;
  } else if (g_frontend_diag.external_refill_active) {
    g_frontend_diag.external_refill_latency++;
    if (enqueued != 0) {
      int latency = g_frontend_diag.external_refill_latency;
      int bucket = latency < 9 ? latency : 9;
      g_stats.frontend_external_refill_events++;
      g_stats.frontend_external_refill_cycles += latency;
      if (latency > g_stats.frontend_external_refill_max) {
        g_stats.frontend_external_refill_max = latency;
      }
      g_stats.frontend_external_refill_histogram[bucket]++;
      g_frontend_diag.external_refill_active = false;
    }
  }
#endif
}

void branch_difftest_on_tage_response(int resp_valid, int resp_pc,
    int provisional_pc, int final_pc, int final_taken) {
#if !defined(CONFIG_BRANCH_DIFFTEST) || !defined(CONFIG_BP_TAGE)
  (void)resp_valid;
  (void)resp_pc;
  (void)provisional_pc;
  (void)final_pc;
  (void)final_taken;
#else
  if (sim_state.state != RUN || !resp_valid) {
    return;
  }

  ensure_inited();
  uint32_t pc = (uint32_t)resp_pc;
  uint32_t inst = fetch_inst(pc);
  g_stats.tage_response_events++;
  if (is_conditional_branch_opcode(inst)) {
    g_stats.tage_branch_response_events++;
  }
  if ((uint32_t)provisional_pc != (uint32_t)final_pc) {
    g_stats.tage_override_events++;
  }
  (void)final_taken;
#endif
}

void branch_difftest_on_tage_frontend(int override_valid, int restarted,
    int blocked, int fast_loop_provisional, int override_replaced_loop) {
#if !defined(CONFIG_BRANCH_DIFFTEST) || !defined(CONFIG_BP_TAGE)
  (void)override_valid;
  (void)restarted;
  (void)blocked;
  (void)fast_loop_provisional;
  (void)override_replaced_loop;
#else
  if (sim_state.state != RUN) {
    return;
  }

  ensure_inited();
  if (fast_loop_provisional) {
    g_stats.tage_fast_loop_provisional_events++;
  }
  if (!override_valid) {
    return;
  }
  g_stats.tage_frontend_override_events++;
  if (restarted) {
    g_stats.tage_override_restart_events++;
  }
  if (blocked) {
    g_stats.tage_override_blocked_events++;
  }
  if (override_replaced_loop) {
    g_stats.tage_override_replaced_loop_events++;
  }
#endif
}

#ifdef CONFIG_BRANCH_DIFFTEST
static const char *report_metric_line =
    "+------------------------------------------"
    "+--------------------------------+\n";

static void report_section(FILE *fp, const char *title) {
  fprintf(fp, "\n[%s]\n", title);
}

static void report_metric_header(FILE *fp) {
  fputs(report_metric_line, fp);
  fprintf(fp, "| %-40s | %30s |\n", "Metric", "Value");
  fputs(report_metric_line, fp);
}

static void report_metric(FILE *fp, const char *metric,
    const char *format, ...) {
  char value[128];
  va_list ap;
  va_start(ap, format);
  vsnprintf(value, sizeof(value), format, ap);
  va_end(ap);
  fprintf(fp, "| %-40s | %30s |\n", metric, value);
}

static void report_metric_end(FILE *fp) {
  fputs(report_metric_line, fp);
}

static void dump_frontend_summary(FILE *fp) {
  int64_t pause_total =
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_EXTERNAL_REDIRECT] +
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_RESERVATION] +
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_NO_CANDIDATE] +
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_OTHER];
  double average_refill = (g_stats.frontend_external_refill_events > 0)
      ? (double)g_stats.frontend_external_refill_cycles /
          (double)g_stats.frontend_external_refill_events
      : 0.0;
  double iq_empty_rate = (g_stats.frontend_cycles > 0)
      ? 100.0 * (double)g_stats.frontend_low_water_events[0] /
          (double)g_stats.frontend_cycles
      : 0.0;
  double iq_one_rate = (g_stats.frontend_cycles > 0)
      ? 100.0 * (double)g_stats.frontend_low_water_events[1] /
          (double)g_stats.frontend_cycles
      : 0.0;

  report_section(fp, "Frontend");
  report_metric_header(fp);
  report_metric(fp, "IQ empty cycles / rate", "%" PRId64 " / %.2f%%",
      g_stats.frontend_low_water_events[0], iq_empty_rate);
  report_metric(fp, "IQ one-entry cycles / rate", "%" PRId64 " / %.2f%%",
      g_stats.frontend_low_water_events[1], iq_one_rate);
  report_metric(fp, "Request fired / paused cycles", "%" PRId64 " / %" PRId64,
      g_stats.frontend_request_fire_cycles, pause_total);
  report_metric(fp, "Pause: redirect / credit / no-PC",
      "%" PRId64 " / %" PRId64 " / %" PRId64,
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_EXTERNAL_REDIRECT],
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_RESERVATION],
      g_stats.frontend_pause_cycles[FRONTEND_PAUSE_NO_CANDIDATE]);
  report_metric(fp, "External refill: events / avg / max",
      "%" PRId64 " / %.2f / %" PRId64,
      g_stats.frontend_external_refill_events, average_refill,
      g_stats.frontend_external_refill_max);
  report_metric_end(fp);
}

#ifdef CONFIG_BP_TAGE
static void dump_ftq_diagnosis(FILE *fp) {
  double average_occupancy = (g_stats.frontend_ftq_cycles > 0)
      ? (double)g_stats.frontend_ftq_occupancy_sum /
          (double)g_stats.frontend_ftq_cycles
      : 0.0;
  double empty_rate = (g_stats.frontend_ftq_cycles > 0)
      ? 100.0 * (double)g_stats.frontend_ftq_empty_cycles /
          (double)g_stats.frontend_ftq_cycles
      : 0.0;
  double full_rate = (g_stats.frontend_ftq_cycles > 0)
      ? 100.0 * (double)g_stats.frontend_ftq_full_cycles /
          (double)g_stats.frontend_ftq_cycles
      : 0.0;
  int peak_occupancy = 0;
  for (int occupancy = 0; occupancy <= CONFIG_BRANCH_FTQ_DEPTH;
       occupancy++) {
    if (g_stats.frontend_ftq_occupancy_histogram[occupancy] != 0) {
      peak_occupancy = occupancy;
    }
  }

  report_section(fp, "FTQ");
  report_metric_header(fp);
  report_metric(fp, "Depth / average / peak occupancy", "%d / %.3f / %d",
      CONFIG_BRANCH_FTQ_DEPTH, average_occupancy, peak_occupancy);
  report_metric(fp, "Empty cycles / rate", "%" PRId64 " / %.2f%%",
      g_stats.frontend_ftq_empty_cycles, empty_rate);
  report_metric(fp, "FTQ empty while IQ empty", "%" PRId64,
      g_stats.frontend_ftq_empty_iq_empty_cycles);
  report_metric(fp, "Full cycles / rate", "%" PRId64 " / %.2f%%",
      g_stats.frontend_ftq_full_cycles, full_rate);
  report_metric(fp, "Override rollback events / blocks",
      "%" PRId64 " / %" PRId64,
      g_stats.frontend_ftq_rollback_events,
      g_stats.frontend_ftq_rollback_blocks);
  report_metric(fp, "Request blocked by IQ / FTQ credit",
      "%" PRId64 " / %" PRId64,
      g_stats.frontend_iq_credit_blocked_cycles,
      g_stats.frontend_ftq_credit_blocked_cycles);
  report_metric_end(fp);
}
#endif

static int compare_pc_stat_miss_count(const void *a, const void *b) {
  const BranchPcStat *lhs = (const BranchPcStat *)a;
  const BranchPcStat *rhs = (const BranchPcStat *)b;
  double lhs_rate = (lhs->total > 0) ? (double)lhs->miss / (double)lhs->total : 0.0;
  double rhs_rate = (rhs->total > 0) ? (double)rhs->miss / (double)rhs->total : 0.0;

  if (lhs->miss < rhs->miss) return 1;
  if (lhs->miss > rhs->miss) return -1;
  if (lhs->total < rhs->total) return 1;
  if (lhs->total > rhs->total) return -1;
  if (lhs_rate < rhs_rate) return 1;
  if (lhs_rate > rhs_rate) return -1;
  if (lhs->pc > rhs->pc) return 1;
  if (lhs->pc < rhs->pc) return -1;
  return 0;
}

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
static int compare_tage_pc_stat_miss_count(const void *a, const void *b) {
  const BranchPcStat *lhs = (const BranchPcStat *)a;
  const BranchPcStat *rhs = (const BranchPcStat *)b;
  double lhs_rate = (lhs->tage_total > 0) ?
      (double)lhs->tage_miss / (double)lhs->tage_total : 0.0;
  double rhs_rate = (rhs->tage_total > 0) ?
      (double)rhs->tage_miss / (double)rhs->tage_total : 0.0;

  if (lhs->tage_miss < rhs->tage_miss) return 1;
  if (lhs->tage_miss > rhs->tage_miss) return -1;
  if (lhs->tage_total < rhs->tage_total) return 1;
  if (lhs->tage_total > rhs->tage_total) return -1;
  if (lhs_rate < rhs_rate) return 1;
  if (lhs_rate > rhs_rate) return -1;
  if (lhs->pc > rhs->pc) return 1;
  if (lhs->pc < rhs->pc) return -1;
  return 0;
}
#endif

static void dump_pc_stat_table(FILE *fp, BranchPcStat *stats, uint32_t count) {
  report_section(fp, "Hot Miss PCs");
  fprintf(fp, "Tracked PCs: %u | Overflow: %" PRId64 " | Showing: %u\n",
      count, g_stats.pc_stat_overflow,
      (BR_TOPN > 0 && (uint32_t)BR_TOPN < count) ? (uint32_t)BR_TOPN : count);
  static const char *line =
      "+------+------------+------------+--------+--------------+--------------+----------+\n";
  fputs(line, fp);
  fprintf(fp, "| %-4s | %-10s | %-10s | %-6s | %12s | %12s | %8s |\n",
      "Rank", "PC", "Inst", "Kind", "Events", "Misses", "Miss %");
  fputs(line, fp);

  if (count == 0) {
    fputs(line, fp);
    return;
  }

  qsort(stats, count, sizeof(BranchPcStat), compare_pc_stat_miss_count);
  uint32_t limit = (BR_TOPN > 0 && (uint32_t)BR_TOPN < count) ? (uint32_t)BR_TOPN : count;
  for (uint32_t i = 0; i < limit; i++) {
    double miss_rate = (stats[i].total > 0)
        ? 100.0 * (double)stats[i].miss / (double)stats[i].total
        : 0.0;
    fprintf(fp, "| %4u | 0x%08x | 0x%08x | %-6s | %12" PRId64
        " | %12" PRId64 " | %7.2f%% |\n",
        i + 1,
        stats[i].pc,
        stats[i].inst,
        stats[i].is_branch ? "branch" : "jump",
        stats[i].total,
        stats[i].miss,
        miss_rate);
  }
  fputs(line, fp);
}

static void dump_top_pc_stats(FILE *fp) {
  uint32_t count = 0;
  for (uint32_t i = 0; i < BR_PC_STAT_BUCKETS; i++) {
    if (g_pc_stats[i].used) {
      count++;
    }
  }

  if (count == 0) {
    dump_pc_stat_table(fp, NULL, 0);
    return;
  }

  BranchPcStat *stats = (BranchPcStat *)malloc(count * sizeof(BranchPcStat));
  if (!stats) {
    report_section(fp, "Hot Miss PCs");
    fprintf(fp, "Cannot allocate PC statistics\n");
    return;
  }

  uint32_t pos = 0;
  for (uint32_t i = 0; i < BR_PC_STAT_BUCKETS; i++) {
    if (g_pc_stats[i].used) {
      stats[pos++] = g_pc_stats[i];
    }
  }

  dump_pc_stat_table(fp, stats, count);

  free(stats);
}

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
static void dump_tage_top_pc_stats(FILE *fp) {
  uint32_t count = 0;
  for (uint32_t i = 0; i < BR_PC_STAT_BUCKETS; i++) {
    if (g_pc_stats[i].used && g_pc_stats[i].tage_total != 0) {
      count++;
    }
  }
  if (count == 0) {
    return;
  }

  report_section(fp, "Software TAGE Hot PCs");
  fprintf(fp, "Branch PCs: %u | Showing: %u\n", count,
      (BR_TOPN > 0 && (uint32_t)BR_TOPN < count) ? (uint32_t)BR_TOPN : count);
  static const char *line =
      "+------+------------+------------+--------------+--------------+----------+\n";
  fputs(line, fp);
  fprintf(fp, "| %-4s | %-10s | %-10s | %12s | %12s | %8s |\n",
      "Rank", "PC", "Inst", "Events", "Misses", "Miss %");
  fputs(line, fp);
  BranchPcStat *stats = (BranchPcStat *)malloc(count * sizeof(BranchPcStat));
  if (!stats) {
    fprintf(fp, "| %-78s |\n", "Cannot allocate software TAGE PC statistics");
    fputs(line, fp);
    return;
  }

  uint32_t pos = 0;
  for (uint32_t i = 0; i < BR_PC_STAT_BUCKETS; i++) {
    if (g_pc_stats[i].used && g_pc_stats[i].tage_total != 0) {
      stats[pos++] = g_pc_stats[i];
    }
  }
  qsort(stats, count, sizeof(BranchPcStat), compare_tage_pc_stat_miss_count);

  uint32_t limit = (BR_TOPN > 0 && (uint32_t)BR_TOPN < count) ?
      (uint32_t)BR_TOPN : count;
  for (uint32_t i = 0; i < limit; i++) {
    double miss_rate = 100.0 * (double)stats[i].tage_miss /
        (double)stats[i].tage_total;
    fprintf(fp, "| %4u | 0x%08x | 0x%08x | %12" PRId64
        " | %12" PRId64 " | %7.2f%% |\n",
        i + 1, stats[i].pc, stats[i].inst, stats[i].tage_total,
        stats[i].tage_miss, miss_rate);
  }

  fputs(line, fp);
  free(stats);
}
#endif
#endif

void branch_difftest_dump_report(void) {
#if !defined(CONFIG_BRANCH_DIFFTEST)
  return;
#else
  if (!g_inited || g_report_dumped) {
    return;
  }

  if (g_statistics_frozen) {
    g_stats = g_frozen_stats;
    memcpy(g_pc_stats, g_frozen_pc_stats, sizeof(g_pc_stats));
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
    g_tage.predictions = g_frozen_tage_predictions;
    g_tage.correct = g_frozen_tage_correct;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
    g_local.predictions = g_frozen_local_predictions;
    g_local.correct = g_frozen_local_correct;
    g_local.target_predictions = g_frozen_local_target_predictions;
    g_local.target_correct = g_frozen_local_target_correct;
    g_local.target_taken = g_frozen_local_target_taken;
#endif
  }

  FILE *fp = fopen(g_report_path, "w");
  if (!fp) {
    Log_warn("branch difftest: cannot write report file: %s", g_report_path);
    g_report_dumped = true;
    return;
  }

  double rtl_branch_full_acc = (g_stats.update_branch_events > 0)
      ? 100.0 * (double)g_stats.rtl_branch_full_correct / (double)g_stats.update_branch_events
      : 0.0;
  double rtl_jump_full_acc = (g_stats.update_jump_events > 0)
      ? 100.0 * (double)g_stats.rtl_jump_full_correct / (double)g_stats.update_jump_events
      : 0.0;
  double rtl_total_full_acc = ((g_stats.update_branch_events + g_stats.update_jump_events) > 0)
      ? 100.0 * (double)(g_stats.rtl_branch_full_correct + g_stats.rtl_jump_full_correct)
          / (double)(g_stats.update_branch_events + g_stats.update_jump_events)
      : 0.0;
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  double tage_direction_acc = (g_tage.predictions > 0)
      ? 100.0 * (double)g_tage.correct / (double)g_tage.predictions
      : 0.0;
#endif
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  double local_direction_acc = (g_local.predictions > 0)
      ? 100.0 * (double)g_local.correct / (double)g_local.predictions
      : 0.0;
  double local_target_acc = (g_local.target_predictions > 0)
      ? 100.0 * (double)g_local.target_correct /
          (double)g_local.target_predictions
      : 0.0;
  double local_target_taken_rate = (g_local.target_predictions > 0)
      ? 100.0 * (double)g_local.target_taken /
          (double)g_local.target_predictions
      : 0.0;
#endif

  const char *predictor_name = g_predictor.name ? g_predictor.name : "unknown";
  int64_t rtl_total_events =
      g_stats.update_branch_events + g_stats.update_jump_events;
  int64_t rtl_total_direction_miss =
      g_stats.rtl_branch_direction_miss + g_stats.rtl_jump_direction_miss;
  int64_t rtl_total_target_miss =
      g_stats.rtl_branch_target_miss + g_stats.rtl_jump_target_miss;

  fprintf(fp, "Branch Prediction Report\n");
  fprintf(fp, "========================\n");
  fprintf(fp, "Test Image: %s\n", g_test_file ? g_test_file : "unknown");
  if (g_statistics_windowed) {
    fprintf(fp, "Statistics Window: external marker (startup excluded)\n");
  }

  report_section(fp, "Summary");
  report_metric_header(fp);
  report_metric(fp, "Predictor", "%s", predictor_name);
#if defined(CONFIG_BRANCH_BTB_WIDTH) && defined(CONFIG_BRANCH_BIMODAL_BITS)
  report_metric(fp, "BTB entries / counter bits", "%u / %d",
      1U << CONFIG_BRANCH_BTB_WIDTH, CONFIG_BRANCH_BIMODAL_BITS);
#endif
#ifdef CONFIG_BP_TAGE
  report_metric(fp, "TAGE tables / tag / histories",
      "4x%u / %d-bit / 4,12,32,64",
      1U << CONFIG_BRANCH_TAGE_INDEX_BITS, CONFIG_BRANCH_TAGE_TAG_BITS);
#endif
#ifdef CONFIG_BRANCH_RAS
  report_metric(fp, "RAS entries", "%u", 1U << CONFIG_BRANCH_RAS_WIDTH);
#endif
  report_metric(fp, "Branch events / dir miss / tgt miss",
      "%" PRId64 " / %" PRId64 " / %" PRId64,
      g_stats.update_branch_events,
      g_stats.rtl_branch_direction_miss, g_stats.rtl_branch_target_miss);
  report_metric(fp, "Branch accuracy", "%.2f%%", rtl_branch_full_acc);
  report_metric(fp, "Jump events / dir miss / tgt miss",
      "%" PRId64 " / %" PRId64 " / %" PRId64,
      g_stats.update_jump_events,
      g_stats.rtl_jump_direction_miss, g_stats.rtl_jump_target_miss);
  report_metric(fp, "Jump accuracy", "%.2f%%", rtl_jump_full_acc);
  report_metric(fp, "Overall events / misses / accuracy",
      "%" PRId64 " / %" PRId64 " / %.2f%%",
      rtl_total_events, rtl_total_direction_miss + rtl_total_target_miss,
      rtl_total_full_acc);
  report_metric_end(fp);

#ifdef CONFIG_BP_TAGE
  double tage_override_rate = (g_stats.tage_branch_response_events > 0)
      ? 100.0 * (double)g_stats.tage_frontend_override_events /
          (double)g_stats.tage_branch_response_events
      : 0.0;
  double tage_restart_rate = (g_stats.tage_frontend_override_events > 0)
      ? 100.0 * (double)g_stats.tage_override_restart_events /
          (double)g_stats.tage_frontend_override_events
      : 0.0;
  report_section(fp, "TAGE Activity");
  report_metric_header(fp);
  report_metric(fp, "Branch responses", "%" PRId64,
      g_stats.tage_branch_response_events);
  report_metric(fp, "Late overrides / response rate", "%" PRId64 " / %.2f%%",
      g_stats.tage_frontend_override_events, tage_override_rate);
  report_metric(fp, "Same-cycle restart / rate", "%" PRId64 " / %.2f%%",
      g_stats.tage_override_restart_events, tage_restart_rate);
  report_metric(fp, "Restart blocked by queue", "%" PRId64,
      g_stats.tage_override_blocked_events);
#if defined(CONFIG_BRANCH_LOOP_PREDICTOR)
  report_metric(fp, "Override replaced Loop / base",
      "%" PRId64 " / %" PRId64,
      g_stats.tage_override_replaced_loop_events,
      g_stats.tage_frontend_override_events -
        g_stats.tage_override_replaced_loop_events);
#endif
  report_metric_end(fp);
#endif

  dump_frontend_summary(fp);

#ifdef CONFIG_BP_TAGE
  dump_ftq_diagnosis(fp);
#endif

#ifdef CONFIG_BRANCH_FAST_RECURRENCE
  if (g_stats.frp_candidate_events > 0) {
    double frp_accuracy = (g_stats.frp_update_events > 0)
        ? 100.0 * (double)g_stats.frp_correct_events /
            (double)g_stats.frp_update_events
        : 0.0;
    double frp_coverage = 100.0 * (double)g_stats.frp_update_events /
        (double)g_stats.frp_candidate_events;
    double frp_candidate_final_accuracy =
        100.0 * (double)g_stats.frp_candidate_correct_events /
            (double)g_stats.frp_candidate_events;
    report_section(fp, "CRC Predictor");
    report_metric_header(fp);
    report_metric(fp, "Candidates", "%" PRId64,
        g_stats.frp_candidate_events);
    report_metric(fp, "Candidate final accuracy", "%.2f%%",
        frp_candidate_final_accuracy);
    report_metric(fp, "Owned / coverage", "%" PRId64 " / %.2f%%",
        g_stats.frp_update_events, frp_coverage);
    report_metric(fp, "Owned accuracy", "%.2f%%", frp_accuracy);
    report_metric(fp, "Boundary mismatch / issued block",
        "%" PRId64 " / %" PRId64,
        g_stats.frp_boundary_events, g_stats.frp_blocked_by_issued_events);
    report_metric_end(fp);
  }
#endif

#ifdef CONFIG_BRANCH_LOOP_PREDICTOR
  if (g_stats.loop_candidate_events > 0) {
    double loop_accuracy = 100.0 * (double)g_stats.loop_correct_events /
        (double)g_stats.loop_candidate_events;
    double tage_on_loop_accuracy =
        100.0 * (double)g_stats.tage_on_loop_correct_events /
            (double)g_stats.loop_candidate_events;
    double final_on_loop_accuracy =
        100.0 * (double)g_stats.final_on_loop_correct_events /
            (double)g_stats.loop_candidate_events;
    report_section(fp, "Loop Predictor");
    report_metric_header(fp);
    report_metric(fp, "Candidates", "%" PRId64,
        g_stats.loop_candidate_events);
    report_metric(fp, "Loop-only accuracy", "%.2f%%", loop_accuracy);
    report_metric(fp,
#ifdef CONFIG_BP_TAGE
        "TAGE accuracy on candidates",
#else
        "Bimodal accuracy on candidates",
#endif
        "%.2f%%", tage_on_loop_accuracy);
    report_metric(fp, "Selected accuracy", "%.2f%%",
        final_on_loop_accuracy);
    report_metric_end(fp);
  }
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  report_section(fp, "Software TAGE Reference");
  report_metric_header(fp);
  report_metric(fp, "Configuration", "%d x %d, tag %d-bit",
      TAGE_TABLES, TAGE_ENTRIES, TAGE_TAG_BITS);
  report_metric(fp, "History lengths", "4, 12, 32, 64");
  report_metric(fp, "Branch predictions", "%" PRId64, g_tage.predictions);
  report_metric(fp, "Direction accuracy", "%.2f%%", tage_direction_acc);
  report_metric_end(fp);
#endif

#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  report_section(fp, "Software Per-PC Local History Reference");
  report_metric_header(fp);
  report_metric(fp, "History / LHT / PHT", "%d / %d / %d",
      LOCAL_HISTORY_BITS, LOCAL_LHT_ENTRIES, LOCAL_PHT_ENTRIES);
  report_metric(fp, "Branch predictions", "%" PRId64, g_local.predictions);
  report_metric(fp, "Direction accuracy", "%.2f%%", local_direction_acc);
  report_metric(fp, "Target PC", "0x%08x", LOCAL_TARGET_PC);
  report_metric(fp, "Target predictions / taken", "%" PRId64 " / %" PRId64,
      g_local.target_predictions, g_local.target_taken);
  report_metric(fp, "Target taken rate", "%.2f%%", local_target_taken_rate);
  report_metric(fp, "Target direction accuracy", "%.2f%%", local_target_acc);
  report_metric_end(fp);
#endif

  dump_top_pc_stats(fp);
#ifdef CONFIG_BRANCH_DIFFTEST_TAGE
  dump_tage_top_pc_stats(fp);
#endif

  fclose(fp);
  g_report_dumped = true;
  if (g_predictor.destroy) {
    g_predictor.destroy(&g_predictor);
  }
#ifdef CONFIG_BRANCH_DIFFTEST_LOCAL
  destroy_local_history_model();
#endif
  Log("branch difftest report: %s", g_report_path);
#endif
}
