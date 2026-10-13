#ifndef __VGA_H__
#define __VGA_H__

#include <common.h>

#define SCREEN_W 800
#define SCREEN_H 600
#define VMEM_SIZE SCREEN_W * SCREEN_H * sizeof(word_t)

void vga_update_screen();
void init_vga();

word_t vgactrl_read(word_t raddr);
word_t vmem_read(word_t raddr);
void vgactrl_write(word_t waddr, word_t wdata);
void vmem_write(word_t waddr, word_t wdata);

#endif
