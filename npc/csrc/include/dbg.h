#ifndef __dbg_h__
#define __dbg_h__

#include <errno.h>
#include <string.h>
#include <assert.h>
#include <utils.h>

#define Assert(cond, format, ...) \
  do { \
      if (!(cond)) { \
        Log_err(format, ## __VA_ARGS__); \
        fflush(stdout); \
        extern void assert_fail_msg(); \
        assert_fail_msg(); \
        assert(cond); \
      } \
  } while (0)

#define Log(format, ...) \
    _Log(ANSI_FMT("[%s:%d %s] " format, ANSI_FG_BLUE) "\n", \
        __FILE__, __LINE__, __func__, ## __VA_ARGS__)

#define Log_warn(format, ...) \
    _Log(ANSI_FMT("[WARN] [%s:%d %s] " format, ANSI_FG_YELLOW) "\n", \
        __FILE__, __LINE__, __func__, ## __VA_ARGS__)

#define Log_err(format, ...) \
    _Log(ANSI_FMT("[ERROR] [%s:%d %s] " format, ANSI_FG_RED) "\n", \
        __FILE__, __LINE__, __func__, ## __VA_ARGS__)

#define panic(format, ...) Assert(0, format, ## __VA_ARGS__)

#define Log_Check(cond, format, ...) if(!(cond)) {\
    Log_warn(format, ##__VA_ARGS__);\
  }
        
#define func_check(A, ret, M, ...) if(!(A)) { Log_warn(M, ##__VA_ARGS__); return ret; }
        
#endif
