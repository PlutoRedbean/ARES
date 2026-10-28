// Minimal board bring-up payload: print one line on the console and halt.
// Used to check clock/reset/memory/UART before running CoreMark.
#include <am.h>
#include <ares.h>

int main(const char *args) {
    const char *p = "ARES L2 board hello\n";
    while (*p != '\0') {
        outb(SERIAL_PORT, (uint8_t)*p++);
    }
    return 0;
}
