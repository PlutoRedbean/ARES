#include <device/vga.h>

#include <SDL2/SDL.h>
#include <mem.h>
#include <dbg.h>

#define SCREEN_REG vgactl_port_base[0]
#define SYNC_REG vgactl_port_base[1]

// static uint32_t screen_width() {
//   return SCREEN_W;
// }

// static uint32_t screen_height() {
//   return SCREEN_H;
// }

// static uint32_t screen_size() {
//   return screen_width() * screen_height() * sizeof(uint32_t);
// }

static uint32_t vmem[SCREEN_W * SCREEN_H];
static uint32_t vgactl_port_base[2];

static SDL_Renderer *renderer = NULL;
static SDL_Texture *texture = NULL;

static void init_screen() {
  SDL_Window *window = NULL;
  char title[128];
  sprintf(title, str(NPC_NAME));
  SDL_Init(SDL_INIT_VIDEO);
  SDL_CreateWindowAndRenderer(SCREEN_W, SCREEN_H, 0, &window, &renderer);
  SDL_SetWindowTitle(window, title);
  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
      SDL_TEXTUREACCESS_STATIC, SCREEN_W, SCREEN_H);
  SDL_RenderPresent(renderer);
}

static inline void update_screen() {
  SDL_UpdateTexture(texture, NULL, vmem, SCREEN_W * sizeof(uint32_t));
  SDL_RenderClear(renderer);
  SDL_RenderCopy(renderer, texture, NULL, NULL);
  SDL_RenderPresent(renderer);
}

void vga_update_screen() {
  if (SYNC_REG) {
    update_screen();
    SYNC_REG = (uint32_t)false;
  }
}

word_t vgactrl_read(word_t raddr) {
  int offset = raddr - VGACTL_ADDR;
  return vgactl_port_base[offset << 2];
}

word_t vmem_read(word_t raddr) {
  int offset = raddr - VGA_VMEM_ADDR;
  return vmem[offset];
}

void vgactrl_write(word_t waddr, word_t wdata) {
  int offset = (waddr - VGACTL_ADDR) >> 2;
  vgactl_port_base[offset] = wdata;
}

void vmem_write(word_t waddr, word_t wdata) {
  int offset = (waddr - VGA_VMEM_ADDR) >> 2;
  vmem[offset] = wdata;
}

void init_vga() {
  SCREEN_REG = (SCREEN_W << 16) | SCREEN_H;
  SYNC_REG = (uint32_t)true;

  init_screen();
}
