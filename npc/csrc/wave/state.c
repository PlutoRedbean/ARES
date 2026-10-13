#include <utils.h>

NPCSTATE sim_state = { .halt_val = 1, .state = RUN };

int is_exit_status_bad() {
  int good = (sim_state.state == END && sim_state.halt_val == 0) ||
    (sim_state.state == QUIT);
  return !good;
}
