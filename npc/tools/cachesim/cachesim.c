#include <dbg.h>
#include <cachesim.h>

const char* pc_trace_file = PC_TRACE_FILE;

FILE *pc_trace_fp = NULL;
CacheInfo icache = { 0, 0 };
CacheMetadata icache_metadata[ICACHE_SET][ICACHE_WAY];
int lru_stack_top[ICACHE_SET] = { 0 };

int exec_end = 0;

static inline int in_sdram(uint32_t addr) {
  return (addr - SDRAM_BASE) < SDRAM_SIZE;
}

static uint32_t pc_step() {
  Assert(pc_trace_fp, "Fail to load pc_trace file");
  
  uint32_t ret;

  size_t size = 4, nmemb = 1;
  size_t c = fread(&ret, size, nmemb, pc_trace_fp);
  if (feof(pc_trace_fp)) {
    exec_end = 1;
    return ret;
  }
  Assert(c != 0, "Fail to read pc_trace.");

  return ret;
}

static inline int hit_way(uint32_t index, uint32_t tag) {
  Assert(index < ICACHE_SET, "Cache metadata out of bound");
  for (int i = 0; i < ICACHE_WAY; i++) {
    if (icache_metadata[index][i].valid && icache_metadata[index][i].tag == tag) {
      return i;
    }
  }
  return -1;
}

static void strategy_LRU(uint32_t index, uint32_t tag) {
  int way = hit_way(index, tag);
  int stack_top = lru_stack_top[index];
  if (way == -1) {
    if (lru_stack_top[index] < ICACHE_WAY) lru_stack_top[index]++;
    if (stack_top == ICACHE_WAY) {
      stack_top--;
      for (int i = 1; i <= stack_top; i++) {
        icache_metadata[index][i - 1] = icache_metadata[index][i];
      }
    }
    icache_metadata[index][stack_top].valid = 1;
    icache_metadata[index][stack_top].tag = tag;
    icache.total_sdram_miss += 1;
  } else {
    CacheMetadata hit_block = icache_metadata[index][way];
    for (int i = way; i < stack_top - 1; i++) {
      icache_metadata[index][i] = icache_metadata[index][i + 1];
    }
    icache_metadata[index][stack_top - 1] = hit_block;
  }
}

static void init_cachesim() {
  Assert(pc_trace_file, "Fail to load pc_trace file");
  
  FILE *fp = fopen(pc_trace_file, "r");
  Assert(fp, "Can not open '%s'", pc_trace_file);

  pc_trace_fp = fp;
}

static void init_cache() {
  for (int i = 0; i < ICACHE_SET; i++) {
    for (int j = 0; j < ICACHE_WAY; j++) {
      icache_metadata[i][j].valid = 0;
    }
  }
}

static void cache_step(uint32_t this_pc) {
  uint32_t index = BITS(this_pc, INDEX_HI, INDEX_LO);
  uint32_t tag   = BITS(this_pc, TAG_HI  , TAG_LO  );
  if (in_sdram(this_pc)) {
    icache.total_sdram_req += 1;
    strategy_LRU(index, tag);
  }
}

int main() {
  init_cachesim();
  init_cache();
  while (!exec_end) {
      uint32_t this_pc = pc_step();
      if (exec_end) break;
      cache_step(this_pc);
  }
  printf("cache size: %d(byte) * %d(block) = %d Bytes\n", ICACHE_BYTE, ICACHE_BLOCK, ICACHE_BYTE * ICACHE_BLOCK);
  printf("cache ways: %d\n", ICACHE_WAY);
  printf("total sdram requests: %d\n", icache.total_sdram_req);
  printf("total sdram misses: %d\n", icache.total_sdram_miss);
  printf("total miss time: %d\n", icache.total_sdram_miss * MISS_PENALTY);
  printf("miss_rate: %lf\n", (double)icache.total_sdram_miss / (double)icache.total_sdram_req);
}
