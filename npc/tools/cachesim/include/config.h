#ifndef __CONFIG_H__
#define __CONFIG_H__

#define PC_TRACE_FILE "/home/redbean/ysyx-workbench/npc/resources/pc_trace.bin"

#define SDRAM_ACCESS_TIME  12

#define BUSDATA_BYTE       4

#define ICACHE_BYTE        4
#define ICACHE_BLOCK       32
#define ICACHE_WAY         4

#define ICACHE_BYTE_WIDTH  2
#define ICACHE_BLOCK_WIDTH 5
#define ICACHE_WAY_WIDTH   2

#define SDRAM_BASE 0xa0000000
#define SDRAM_SIZE 0x2000000

#define MISS_PENALTY       (SDRAM_ACCESS_TIME * (ICACHE_BYTE / BUSDATA_BYTE))

#endif
