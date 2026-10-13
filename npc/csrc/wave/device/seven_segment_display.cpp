

#include <seven_segment_display.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

namespace {

// seg7.sv uses the common-cathode, active-high bit order {g,f,e,d,c,b,a}.
constexpr uint8_t kHexSegments[16] = {
  0x3f, 0x06, 0x5b, 0x4f,
  0x66, 0x6d, 0x7d, 0x07,
  0x7f, 0x6f, 0x77, 0x7c,
  0x39, 0x5e, 0x79, 0x71,
};
constexpr char kLitSegment = '#';
constexpr const char *kGreenBlock = "\033[42m \033[0m";

bool terminal_output = false;
bool output_initialized = false;
bool have_displayed_frame = false;
uint8_t pending_digits[8] = {};
uint8_t displayed_digits[8] = {};
uint8_t pending_mask = 0;
uint64_t last_virtual_seg = 0;
bool have_virtual_seg = false;

char decode_digit(uint8_t segments) {
  const uint8_t segments_without_dp = segments & 0x7f;
  if (segments_without_dp == 0) {
    return ' ';
  }

  for (int value = 0; value < 16; value++) {
    if (segments_without_dp == kHexSegments[value]) {
      return value < 10 ? static_cast<char>('0' + value)
                        : static_cast<char>('A' + value - 10);
    }
  }
  return '?';
}

void make_digit_row(uint8_t segments, int row, char output[7]) {
  memset(output, ' ', 6);
  output[6] = '\0';

  const bool a = segments & (1u << 0);
  const bool b = segments & (1u << 1);
  const bool c = segments & (1u << 2);
  const bool d = segments & (1u << 3);
  const bool e = segments & (1u << 4);
  const bool f = segments & (1u << 5);
  const bool g = segments & (1u << 6);
  const bool dp = segments & (1u << 7);

  switch (row) {
    case 0:
      if (a) memset(output + 1, kLitSegment, 3);
      break;
    case 1:
      if (f) output[0] = kLitSegment;
      if (b) output[4] = kLitSegment;
      break;
    case 2:
      if (g) memset(output + 1, kLitSegment, 3);
      break;
    case 3:
      if (e) output[0] = kLitSegment;
      if (c) output[4] = kLitSegment;
      break;
    case 4:
      if (d) memset(output + 1, kLitSegment, 3);
      if (dp) output[5] = '.';
      break;
    default:
      break;
  }
}

void print_digit_row(const char row[7]) {
  for (int column = 0; column < 6; column++) {
    if (row[column] == kLitSegment) {
      fputs(kGreenBlock, stdout);
    } else {
      putchar(row[column]);
    }
  }
}

void render_frame() {
  if (terminal_output) {
    for (int row = 0; row < 5; row++) {
      for (int position = 7; position >= 0; position--) {
        char digit_row[7];
        make_digit_row(displayed_digits[position], row, digit_row);
        print_digit_row(digit_row);
        putchar(' ');
      }
      putchar('\n');
    }

    putchar('\n');
  } else {
    // Keep redirected logs compact while still making the simulated value
    // observable in CI and non-interactive shells.
    fputs("[7SEG] ", stdout);
    for (int position = 7; position >= 0; position--) {
      putchar(decode_digit(displayed_digits[position]));
    }
    putchar('\n');
  }
  fflush(stdout);
}

}  // namespace

void seven_segment_display_update(uint64_t virtual_seg) {
  if (!output_initialized) {
    terminal_output = isatty(STDOUT_FILENO);
    output_initialized = true;
  }
  if (have_virtual_seg && virtual_seg == last_virtual_seg) {
    return;
  }
  last_virtual_seg = virtual_seg;
  have_virtual_seg = true;

  // virtual_seg consists of four 10-bit groups. Each group carries one
  // shared {dp,g..a} segment bus and two digit enables. display_seg.sv drives
  // all four groups in the same scan phase:
  //   enable 2'b10 -> the high nibble in each byte
  //   enable 2'b01 -> the low nibble in each byte
  for (int group = 0; group < 4; group++) {
    const uint16_t group_pins = (virtual_seg >> (group * 10)) & 0x3ffu;
    const uint8_t digit_enable = (group_pins >> 8) & 0x3u;

    int nibble_index;
    if (digit_enable == 0x2) {
      nibble_index = group * 2 + 1;
    } else if (digit_enable == 0x1) {
      nibble_index = group * 2;
    } else {
      continue;
    }

    pending_digits[nibble_index] = group_pins & 0xffu;
    pending_mask |= static_cast<uint8_t>(1u << nibble_index);
  }

  // Only capture a frame after both multiplexing phases have been observed.
  // This prevents a transient display containing half old and half new data.
  if (pending_mask != 0xffu) {
    return;
  }
  pending_mask = 0;

  if (have_displayed_frame &&
      memcmp(displayed_digits, pending_digits, sizeof(displayed_digits)) == 0) {
    return;
  }

  memcpy(displayed_digits, pending_digits, sizeof(displayed_digits));
  have_displayed_frame = true;
}

void seven_segment_display_print() {
  if (!output_initialized) {
    terminal_output = isatty(STDOUT_FILENO);
    output_initialized = true;
  }

  if (!have_displayed_frame) {
    puts("[7SEG] no complete scan frame captured");
    return;
  }

  render_frame();
}
