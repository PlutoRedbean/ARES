#ifndef __COMMON_H__
#define __COMMON_H__

#include <autoconf.h>

#include <stdint.h>
#include <stdio.h>
#include <macro.h>
#include <assert.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

#define NPC_NAME Mundus

// #define HAS_SCREEN 1

// #define FLASH_TEST 1

#define LOGBUF_SIZE 128
typedef char trace_log[LOGBUF_SIZE];

#define DBASE     0xa0000000
#define DSIZE_MAX 0x02000000

typedef uint32_t vaddr_t;
typedef uint32_t paddr_t;
typedef uint32_t word_t;

#endif
