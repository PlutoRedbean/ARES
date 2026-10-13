#include <cache.h>
#include <mem.h>
#include <dbg.h>

FILE *pc_trace_fp = NULL;
CacheInfo icache_ref = { 0, 0 };
CacheMetadata icache_ref_metadata[ICACHE_SET][CONFIG_ICACHE_WAY];
int lru_stack_top[ICACHE_SET] = { 0 };

extern CacheInfo icache_dut;

static inline int hit_way(uint32_t index, uint32_t tag) {
  Assert(index < ICACHE_SET, "Cache metadata out of bound");
  for (int i = 0; i < CONFIG_ICACHE_WAY; i++) {
    if (icache_ref_metadata[index][i].valid && icache_ref_metadata[index][i].tag == tag) {
      return i;
    }
  }
  return -1;
}

void init_cache() {
  Log("Cache difftest: %s", ANSI_FMT("ON", ANSI_FG_GREEN));
  for (int i = 0; i < ICACHE_SET; i++) {
    for (int j = 0; j < CONFIG_ICACHE_WAY; j++) {
      icache_ref_metadata[i][j].valid = 0;
    }
  }
}

static void strategy_LRU(uint32_t index, uint32_t tag) {
  int way = hit_way(index, tag);
  int stack_top = lru_stack_top[index];
  if (way == -1) {
    if (lru_stack_top[index] < CONFIG_ICACHE_WAY) lru_stack_top[index]++;
    if (stack_top == CONFIG_ICACHE_WAY) {
      stack_top--;
      for (int i = 1; i <= stack_top; i++) {
        icache_ref_metadata[index][i - 1] = icache_ref_metadata[index][i];
      }
    }
    icache_ref_metadata[index][stack_top].valid = 1;
    icache_ref_metadata[index][stack_top].tag = tag;
    icache_ref.total_sdram_miss += 1;
  } else {
    CacheMetadata hit_block = icache_ref_metadata[index][way];
    for (int i = way; i < stack_top - 1; i++) {
      icache_ref_metadata[index][i] = icache_ref_metadata[index][i + 1];
    }
    icache_ref_metadata[index][stack_top - 1] = hit_block;
  }
}

void cache_step(word_t cpu_pc) {
  uint32_t index = BITS(cpu_pc, INDEX_HI, INDEX_LO);
  uint32_t tag   = BITS(cpu_pc, TAG_HI  , TAG_LO  );
  if (in_sdram(cpu_pc)) {
    icache_ref.total_sdram_req += 1;
    strategy_LRU(index, tag);
  }

  if (icache_ref.total_sdram_req != icache_dut.total_sdram_req) {
    Log_err("Different cache requests, right = " FMT_WORD ", wrong = " FMT_WORD,
            icache_ref.total_sdram_req, icache_dut.total_sdram_req);
    sim_state.state = ABORT;
  }

  if (icache_ref.total_sdram_miss != icache_dut.total_sdram_miss) {
    Log_err("Different cache miss times, right = " FMT_WORD ", wrong = " FMT_WORD,
            icache_ref.total_sdram_miss, icache_dut.total_sdram_miss);
    sim_state.state = ABORT;
  }
}
