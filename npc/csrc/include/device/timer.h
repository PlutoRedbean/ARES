#ifndef __TIMER_H__
#define __TIMER_H__

#include <common.h>

uint64_t get_time();
void timer_update();
uint32_t timer_lower();
uint32_t timer_upper();

#endif
