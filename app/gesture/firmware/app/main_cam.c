#include "ares_soc.h"

extern int yolo_camera_run(void);

int main(void)
{
  uart_init(UART_DIV);

  printf("\n==================================================\n");
  printf("ARES gesture demo / miniTensor INT8\n");
  printf("one ARES nine-stage core + one miniTensor + OV5640\n");
  printf("==================================================\n");

  return yolo_camera_run();
}
