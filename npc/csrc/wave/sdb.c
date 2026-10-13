#include <sdb.h>

#include <readline/readline.h>
#include <readline/history.h>
#include <common.h>
#include <verilator_ctrl.h>
#include <expr.h>
#include <mem.h>
#include <cpu.h>
#include <reg.h>
#include <dbg.h>

static char* rl_gets();

static int cmd_help(char *args);
static int cmd_c(char *args);
static int cmd_q(char *args);
static int cmd_si(char *args);
static int cmd_sc(char *args);
static int cmd_info(char *args);
static int cmd_x(char *args);

static int var_cnt = 1;

static struct {
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table [] = {
  { "help", "Display information about all supported commands.", cmd_help },
  { "c", "Continue the execution of the program.", cmd_c },
  { "q", "Exit sdb.", cmd_q },
  { "si", "Step program.", cmd_si },
  { "sc", "Single clock cycle.", cmd_sc },
  { "info", "Generic command for showing things about the program being debugged.", cmd_info },
  { "x", "Examine memory.", cmd_x },
  // { "p", "Print value of expression EXPR.", cmd_p },
  // { "w", "Set a watchpoint for EXPR.", cmd_w },
  // { "d", "Delete a watchpoint N.", cmd_d }
};

static char* rl_gets() {
  static char *line_read = NULL;

  if (line_read) {
    free(line_read);
    line_read = NULL;
  }

  line_read = readline("(" str(NPC_NAME) ") ");

  if (line_read && *line_read) {
    add_history(line_read);
  }

  return line_read;
}

static int cmd_help(char *args) {
  /* extract the first argument */
  char *arg = strtok(NULL, " ");
  int i;

  if (arg == NULL) {
    /* no argument given */
    for (i = 0; i < NR_CMD; i ++) {
      printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
    }
  }
  else {
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(arg, cmd_table[i].name) == 0) {
        printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
        return 0;
      }
    }
    printf("Unknown command '%s'\n", arg);
  }
  return 0;
}

static int cmd_c(char *args) {
  cpu_exec(-1);
  return 0;
}

static int cmd_q(char *args) {
  cpu_quit();
  return -1;
}

static int cmd_si(char *args) {
  if (!args) {
    cpu_exec(1u);

    return 0;
  }

  uint64_t num = (uint64_t)atoi(args);
  func_check(num > 0, 1, "Invalid number for si.");

  cpu_exec(num);

  return 0;
}

static int cmd_sc(char *args) {
  if (!args) {
    while (retire_event_pending()) cpu_exec(1);
    single_cycle();

    return 0;
  }

  uint64_t num = (uint64_t)atoi(args);
  func_check(num > 0, 1, "Invalid number for sc.");

  for (uint64_t i = 0; i < num; i++) {
    while (retire_event_pending()) cpu_exec(1);
    single_cycle();
  }

  return 0;
}

static int cmd_info(char *args) {
  func_check(args, 1, "USAGE: info SUBCMD");

  if (strcmp(args, "r") == 0) {
    isa_reg_display();
  } else {
    Log_warn("Unknown SUBCMD.");
  }

  return 0;
}

static int cmd_x(char *args) {
  func_check(args, 1, "USAGE: x N EXPR");
  // strtok bug
  char *EXPR;
  char *N = strtok_r(args, " ", &EXPR);
  func_check(N, 1, "USAGE: x N EXPR");
  // char *EXPR = strtok(NULL, " ");
  func_check(EXPR, 1, "USAGE: x N EXPR");
  
  unsigned int word = atoi(N);
  func_check(word > 0, 1, "Invalid number for N.");
  Log_Check(word <= 33554431, "Overflow possible.");
  
  // uint32_t addr;
  // int c = sscanf(EXPR, FMT_WORD, &addr);
  // func_check(c != 0 && c != EOF, 1, "Fail to read EXPR");
  bool success;
  uint32_t addr = expr(EXPR, &success);
  func_check(success == true, 1, "Fail to read EXPR.");

  int i;
  for (i = 0; i < word << 2; i += 4) {
    func_check(in_pmem(addr + i), 1, FMT_WORD " is out of bound.", addr + i);
    printf(FMT_WORD ": " FMT_WORD "\n", addr + i, vaddr_read(addr + i));
  }

  return 0;
}

void sdb_mainloop() {
  for (char *str; (str = rl_gets()) != NULL; ) {
    char *str_end = str + strlen(str);

    /* extract the first token as the command */
    char *cmd = strtok(str, " ");
    if (cmd == NULL) { continue; }

    /* treat the remaining string as the arguments,
     * which may need further parsing
     */
    char *args = cmd + strlen(cmd) + 1;
    if (args >= str_end) {
      args = NULL;
    }

    int i;
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(cmd, cmd_table[i].name) == 0) {
        if (cmd_table[i].handler(args) < 0) { return; }
        break;
      }
    }

    if (i == NR_CMD) { printf("Unknown command '%s'\n", cmd); }
  }
}
