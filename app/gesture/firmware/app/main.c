#include "ares_soc.h"

extern int yolo_run(void);

int main(void)
{
  uart_init(UART_DIV);

  printf("\n==================================================\n");
  printf("ARES gesture detector / miniTensor INT8\n");
  printf("one ARES nine-stage core + one miniTensor\n");
  printf("==================================================\n");

  int rc = yolo_run();

  printf("YOLO run returned %d\n", rc);
  halt(rc);
  return 0;
}
