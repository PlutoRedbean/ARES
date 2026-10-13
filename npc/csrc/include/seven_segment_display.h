#ifndef NPC_SEVEN_SEGMENT_DISPLAY_H
#define NPC_SEVEN_SEGMENT_DISPLAY_H

#include <stdint.h>

// Feed one sample of the FPGA's multiplexed virtual_seg[39:0] output.
void seven_segment_display_update(uint64_t virtual_seg);

// Print the last complete display frame after simulation has finished.
void seven_segment_display_print();

#endif
