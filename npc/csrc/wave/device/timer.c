#include <device.h>
#include <sys/time.h>
#include <common.h>

static uint64_t _boot_time_;
uint64_t _uptime_ = 0;
uint32_t time_reg[2] = { (uint32_t)_uptime_, (uint32_t)(_uptime_ >> 32) };

static uint64_t get_time_internal() {
  struct timeval now;
  gettimeofday(&now, NULL);
  uint64_t us = now.tv_sec * 1000000 + now.tv_usec;

  return us;
}

uint64_t get_time() {
  if (_boot_time_ == 0) _boot_time_ = get_time_internal();
  uint64_t _uptime_ = get_time_internal();
  return _uptime_ - _boot_time_;
}

void timer_update() {
  _uptime_ = get_time();
  time_reg[0] = (uint32_t)_uptime_;
  time_reg[1] = (uint32_t)(_uptime_ >> 32);
}

uint32_t timer_lower() {
  return time_reg[0];
}

uint32_t timer_upper() {
  return time_reg[1];
}

