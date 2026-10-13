/*****************************************************************
 * To be optimized:
 *   mtrace
 *   header include process
 *   mem out of bound
 *   memcpy
 **/
#include <utils.h>
#include <sim.h>
#include <mem.h>

int main(int argc, char** argv) {
  
  sim_init(argc, argv);
  
  sim_start();
  
  sim_end();
  
  return is_exit_status_bad();
  
}
