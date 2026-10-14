#!/usr/bin/env python3
"""Generate the measured-best CoreMark state-machine schedule.

The checked-in EEMBC source remains untouched.  The optimized build input:

* returns the updated byte pointer and final state as one 64-bit scalar, which
  maps to the RV32 a0/a1 result-register pair and removes the pointer
  spill/reload dependency between tokens;
* loads the next byte before the final-count load and places the required
  state-index shift between them, avoiding adjacent loads on the single memory
  issue port;
* carries the next state-machine byte across loop iterations, moving its load
  ahead of the switch body so the late load result is ready before the next
  loop condition consumes it.

Every rewrite is shape checked so an upstream CoreMark change fails loudly.
"""

from __future__ import annotations

import argparse
from pathlib import Path


FORWARD_DECLARATION = (
    "enum CORE_STATE core_state_transition(ee_u8 **instr, "
    "ee_u32 *transition_count);"
)

REGISTER_RETURN_DECLARATION = """\
typedef unsigned long long mundus_state_result;

static __attribute__((noinline)) mundus_state_result
core_state_transition(ee_u8 *str, ee_u32 *transition_count);"""

TRANSITION_SIGNATURE = """\
enum CORE_STATE
core_state_transition(ee_u8 **instr, ee_u32 *transition_count)
{
    ee_u8 *         str = *instr;"""

REGISTER_RETURN_SIGNATURE = """\
static __attribute__((noinline)) mundus_state_result
core_state_transition(ee_u8 *str, ee_u32 *transition_count)
{"""

TRANSITION_CALL = """\
        enum CORE_STATE fstate = core_state_transition(&p, track_counts);
        final_counts[fstate]++;"""

OUTER_LOOP_CONDITION = "    while (*p != 0)"

TRANSITION_RETURN = """\
    *instr = str;
    return state;"""

REGISTER_RETURN = """\
    return ((mundus_state_result)(ee_u32)state << 32)
           | (mundus_state_result)(ee_u32)str;"""

TRANSITION_LOOP_HEAD = """\
    ee_u8           NEXT_SYMBOL;
    enum CORE_STATE state = CORE_START;
    for (; *str && state != CORE_INVALID; str++)
    {
        NEXT_SYMBOL = *str;"""

SCHEDULED_TRANSITION_LOOP_HEAD = """\
    ee_u32          NEXT_SYMBOL;
    ee_u32          comma_symbol;
    __asm__ volatile (
        "lbu %0, 0(%2)\\n\\t"
        "li %1, 44"
        : "=&r" (NEXT_SYMBOL), "=&r" (comma_symbol)
        : "r" (str)
        : "memory");
    ee_u8           following_symbol;
    enum CORE_STATE state = CORE_START;
    for (; NEXT_SYMBOL && state != CORE_INVALID; str++)
    {"""

TRANSITION_COMMA_TAIL = """\
        if (NEXT_SYMBOL == ',') /* end of this input */
        {
            str++;
            break;
        }
        switch (state)"""

SCHEDULED_TRANSITION_COMMA_TAIL = """\
        if (NEXT_SYMBOL == comma_symbol) /* end of this input */
        {
            str++;
            break;
        }
        following_symbol = str[1];
        switch (state)"""

TRANSITION_SWITCH_TAIL = """\
            default:
                break;
        }
    }
    return ((mundus_state_result)(ee_u32)state << 32)"""

SCHEDULED_TRANSITION_SWITCH_TAIL = """\
            default:
                break;
        }
        NEXT_SYMBOL = following_symbol;
    }
    return ((mundus_state_result)(ee_u32)state << 32)"""


def scheduled_call(next_symbol: str) -> str:
    return f'''\
        mundus_state_result transition
            = core_state_transition(p, track_counts);
        enum CORE_STATE fstate
            = (enum CORE_STATE)(ee_u32)(transition >> 32);
        p = (ee_u8 *)(ee_u32)transition;

        ee_u32 final_offset;
        {next_symbol} = *p;
        /* This shift is required for the counter address.  Pin it after the
         * next-byte load so the two independent loads cannot become adjacent
         * again during scheduling. */
        __asm__ volatile (
            "slli %0, %1, 2"
            : "=r" (final_offset)
            : "r" (fstate)
            : "memory");
        ee_u32 *final_count = (ee_u32 *)
            ((ee_u8 *)final_counts + final_offset);
        (*final_count)++;'''


def replace_exact(source: str, old: str, new: str, expected: int) -> str:
    matches = source.count(old)
    if matches != expected:
        raise ValueError(
            f"expected {expected} occurrence(s), found {matches}: {old[:40]!r}"
        )
    return source.replace(old, new)


def rewrite(source: str, strategy: str) -> str:
    if strategy == "none":
        return source

    generated = replace_exact(
        source, FORWARD_DECLARATION, REGISTER_RETURN_DECLARATION, 1
    )
    generated = replace_exact(
        generated, TRANSITION_SIGNATURE, REGISTER_RETURN_SIGNATURE, 1
    )
    generated = replace_exact(
        generated, TRANSITION_RETURN, REGISTER_RETURN, 1
    )
    generated = replace_exact(
        generated,
        TRANSITION_LOOP_HEAD,
        SCHEDULED_TRANSITION_LOOP_HEAD,
        1,
    )
    generated = replace_exact(
        generated,
        TRANSITION_COMMA_TAIL,
        SCHEDULED_TRANSITION_COMMA_TAIL,
        1,
    )
    generated = replace_exact(
        generated,
        TRANSITION_SWITCH_TAIL,
        SCHEDULED_TRANSITION_SWITCH_TAIL,
        1,
    )

    for next_symbol in ("next_symbol_first", "next_symbol_second"):
        condition = (
            f"    ee_u8 {next_symbol} = *p;\n"
            f"    while ({next_symbol} != 0)"
        )
        if OUTER_LOOP_CONDITION not in generated:
            raise ValueError("expected another state outer loop")
        generated = generated.replace(OUTER_LOOP_CONDITION, condition, 1)
        if TRANSITION_CALL not in generated:
            raise ValueError("expected another state-transition call")
        generated = generated.replace(
            TRANSITION_CALL, scheduled_call(next_symbol), 1
        )

    if OUTER_LOOP_CONDITION in generated or TRANSITION_CALL in generated:
        raise ValueError("unexpected extra state loop or transition call")
    return generated


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--strategy",
        choices=("none", "register-return-scheduled"),
        default="register-return-scheduled",
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    generated = rewrite(original, args.strategy)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(
        "generated state scheduling source: "
        f"{args.output} ({args.strategy})"
    )


if __name__ == "__main__":
    main()
