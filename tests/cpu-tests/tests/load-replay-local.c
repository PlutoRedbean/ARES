#include "trap.h"
#include <stdint.h>

// The D-cache is word indexed, so the first access to each untouched word is
// a miss and the second access to the same word is a hit.
static volatile uint32_t replay_data[16] __attribute__((aligned(64))) = {
  0x10203040u, 0x55667788u, 0x01020304u, 0x11121314u,
  0x21222324u, 0x31323334u, 0x41424344u, 0x51525354u,
  0x61626364u, 0x71727374u, 0x81828384u, 0x91929394u,
  0xa1a2a3a4u, 0xb1b2b3b4u, 0xc1c2c3c4u, 0xd1d2d3d4u,
};

static uint32_t load_use_rs1(volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "addi t2, zero, 5\n"
    "lw t0, 0(%1)\n"
    "add %0, t0, t2\n"
    "addi t3, zero, 9\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t2", "t3", "memory"
  );
  return result;
}

static uint32_t load_use_rs2(volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "addi t2, zero, 5\n"
    "lw t0, 0(%1)\n"
    "sub %0, t2, t0\n"
    "addi t3, zero, 11\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t2", "t3", "memory"
  );
  return result;
}

static uint32_t load_use_mul(volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "addi t2, zero, 3\n"
    "lw t0, 0(%1)\n"
    "mul %0, t0, t2\n"
    "addi t3, zero, 13\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t2", "t3", "memory"
  );
  return result;
}

static uint32_t load_without_immediate_dependency(
    volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "addi t2, zero, 7\n"
    "lw t0, 0(%1)\n"
    "addi t3, zero, 17\n"
    "addi t4, zero, 19\n"
    "nop\n"
    "nop\n"
    "add %0, t0, t2\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t2", "t3", "t4", "memory"
  );
  return result;
}

__attribute__((noinline))
static uint32_t pair_alu(
    volatile uint32_t *address, uint32_t addend) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "lw t0, 0(%1)\n"
    "add %0, t0, %2\n"
    "addi t2, zero, 3\n"
    "addi t3, zero, 5\n"
    : "=&r"(result)
    : "r"(address), "r"(addend)
    : "t0", "t2", "t3", "memory"
  );
  return result;
}

__attribute__((noinline))
static uint32_t pair_branch_eq(
    volatile uint32_t *address, uint32_t expected) {
  uint32_t result;
  asm volatile(
    "addi %0, zero, 0\n"
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "lw t0, 0(%1)\n"
    "beq t0, %2, 2f\n"
    "addi %0, zero, 1\n"
    "j 3f\n"
    "2:\n"
    "addi %0, zero, 2\n"
    "3:\n"
    : "=&r"(result)
    : "r"(address), "r"(expected)
    : "t0", "memory"
  );
  return result;
}

__attribute__((noinline))
static uint32_t pair_result_followed_by_consumer(
    volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "lw t0, 0(%1)\n"
    "addi t1, t0, 7\n"
    "xori t2, t1, 0x55\n"
    "addi t3, zero, 9\n"
    "add %0, t2, t3\n"
    "addi t4, zero, 11\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t1", "t2", "t3", "t4", "memory"
  );
  return result;
}

__attribute__((noinline))
static uint32_t pair_miss_with_full_skid(
    volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "lw t0, 0(%1)\n"
    "addi t1, t0, 1\n"
    "addi t2, zero, 2\n"
    "addi t3, zero, 3\n"
    "add t4, t1, t2\n"
    "xor t5, t4, t3\n"
    "addi t6, zero, 5\n"
    "add %0, t5, t6\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory"
  );
  return result;
}

__attribute__((noinline))
static uint32_t pair_miss_before_independent_redirect(
    volatile uint32_t *address) {
  uint32_t result;
  asm volatile(
    "j 1f\n"
    ".balign 8\n"
    "1:\n"
    "lw t0, 0(%1)\n"
    "addi t1, t0, 4\n"
    "beq zero, zero, 2f\n"
    "addi t1, zero, 0\n"
    "2:\n"
    "addi %0, t1, 6\n"
    : "=&r"(result)
    : "r"(address)
    : "t0", "t1", "memory"
  );
  return result;
}

int main() {
  // The synthesizable D-cache invalidates one of its 2048 entries per cycle.
  // Wait past that startup window so this test can distinguish a real refill
  // hit from startup-suppressed misses.
  asm volatile(
    "li t0, 2300\n"
    "1:\n"
    "addi t0, t0, -1\n"
    "bnez t0, 1b\n"
    :
    :
    : "t0", "memory"
  );

  // Untouched words force the scalar-miss replay path. The independent
  // instruction paired with each consumer verifies that poisoning is group
  // local even when only one lane has the dependency.
  check(load_use_rs1(&replay_data[0]) == replay_data[0] + 5u);
  check(load_use_rs2(&replay_data[1]) == 5u - replay_data[1]);
  check(load_use_mul(&replay_data[2]) == replay_data[2] * 3u);

  // A miss without an immediate load-use edge must not need local replay.
  check(load_without_immediate_dependency(&replay_data[3]) ==
        replay_data[3] + 7u);

  // replay_data[0] is now resident. Re-run the immediate dependency to cover
  // the unchanged zero-bubble hit path.
  check(load_use_rs1(&replay_data[0]) == replay_data[0] + 5u);

  // Same-group slot-0 load -> slot-1 ALU. The first access is a miss and the
  // second is the unchanged zero-bubble hit path.
  check(pair_alu(&replay_data[4], 13u) == 0x21222324u + 13u);
  check(pair_alu(&replay_data[4], 13u) == 0x21222324u + 13u);

  // Delayed pair branches resolve only after the selected fast/slow data is
  // real. Cover hit, miss-taken, and miss-not-taken outcomes.
  check(pair_branch_eq(&replay_data[5], 0x31323334u) == 2u);
  check(pair_branch_eq(&replay_data[5], 0x31323334u) == 2u);
  check(pair_branch_eq(&replay_data[6], 0x41424344u) == 2u);
  check(pair_branch_eq(&replay_data[7], 0x51525354u ^ 1u) == 1u);

  // The pair result must be forwardable to the following group, and a miss
  // may fill both replay-buffer entries without allowing either to overtake.
  check(pair_result_followed_by_consumer(&replay_data[8]) ==
        ((0x61626364u + 7u) ^ 0x55u) + 9u);
  check(pair_miss_with_full_skid(&replay_data[9]) ==
        ((((0x71727374u + 1u) + 2u) ^ 3u) + 5u));

  // A younger independent branch is held behind the pair miss. It redirects
  // only after the saved slot-1 consumer has completed.
  check(pair_miss_before_independent_redirect(&replay_data[10]) ==
        0x81828384u + 10u);

  return 0;
}
