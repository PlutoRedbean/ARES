#include <SDL2/SDL.h>

#include <device.h>
#include <utils.h>

void init_device() {
#ifdef HAS_SCREEN
  init_vga();
#endif
}

void device_update() {
  timer_update();
#ifdef HAS_SCREEN
  vga_update_screen();
#endif
}
