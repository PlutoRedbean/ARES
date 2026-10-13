#include <common.h>
#include <dbg.h>

#include <stdarg.h>

extern uint64_t g_nr_guest_inst;

FILE *log_fp = NULL;
FILE *csv_fp = NULL;

void init_log(const char *log_file) {
  log_fp = NULL;
  if (log_file != NULL) {
    FILE *fp = fopen(log_file, "w");
    Assert(fp, "Can not open '%s'", log_file);
    log_fp = fp;
  }
  Log("Log is written to %s", log_file ? log_file : "stdout");
}

void init_csv(const char *csv_file) {
  Assert(csv_file, "Fail to load csv file");
  
  FILE *fp = fopen(csv_file, "w");
  Assert(fp, "Can not open '%s'", csv_file);
  csv_fp = fp;
  Log("Log is written to %s", csv_file);
}

void csv_write(const char *msg, ...) {
  va_list ap;
  va_start(ap, msg);

  if (csv_fp != NULL) {
    vfprintf(csv_fp, msg, ap);
  }

  va_end(ap);
}

bool log_enable() {
  return true;
}
