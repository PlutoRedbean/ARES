#ifndef __CACHESIM_H__
#define __CACHESIM_H__

#include <stdint.h>
#include "config.h"

#define BITMASK(bits) ((1ull << (bits)) - 1)
#define BITS(x, hi, lo) (((x) >> (lo)) & BITMASK((hi) - (lo) + 1)) // similar to x[hi:lo] in verilog

#define ICACHE_SET       (ICACHE_BLOCK / ICACHE_WAY)
#define ICACHE_SET_WIDTH (ICACHE_BLOCK_WIDTH - ICACHE_WAY_WIDTH)

#define TAG_HI      (32 - 1)
#define TAG_LO      (ICACHE_BYTE_WIDTH + ICACHE_SET_WIDTH)
#define INDEX_HI    (TAG_LO - 1)
#define INDEX_LO    (ICACHE_BYTE_WIDTH)

typedef struct {
  uint32_t valid;
  uint32_t tag;
} CacheMetadata;

typedef struct {
  uint32_t total_sdram_req;
  uint32_t total_sdram_miss;
} CacheInfo;

#endif
