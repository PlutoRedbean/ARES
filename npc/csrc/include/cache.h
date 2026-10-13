#ifndef __CACHE_H__
#define __CACHE_H__

#include <common.h>

#define ICACHE_SET       (CONFIG_ICACHE_BLOCK / CONFIG_ICACHE_WAY)
#define ICACHE_SET_WIDTH (CONFIG_ICACHE_BLOCK_WIDTH - CONFIG_ICACHE_WAY_WIDTH)

#define TAG_HI      (32 - 1)
#define TAG_LO      (CONFIG_ICACHE_BYTE_WIDTH + ICACHE_SET_WIDTH)
#define INDEX_HI    (TAG_LO - 1)
#define INDEX_LO    (CONFIG_ICACHE_BYTE_WIDTH)

typedef struct {
  uint32_t valid;
  uint32_t tag;
} CacheMetadata;

typedef struct {
  uint32_t total_sdram_req;
  uint32_t total_sdram_miss;
} CacheInfo;

void init_cachesim(const char *pc_trace_file);
void init_cache();
void cache_step(word_t cpu_pc);

#endif
