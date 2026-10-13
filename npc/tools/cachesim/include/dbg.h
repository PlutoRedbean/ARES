#ifndef __DBG_H__
#define __DBG_H__

#include <stdio.h>
#include <assert.h>

#define Assert(cond, format, ...) \
  do { \
      if (!(cond)) { \
        printf(format "\n", ## __VA_ARGS__); \
        fflush(stdout); \
        assert(cond); \
      } \
  } while (0)

#endif
