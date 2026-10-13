#!/usr/bin/env python3
"""Generate a Mundus-scheduled CoreMark list translation unit.

The checked-in benchmark source remains untouched.  This narrow pass isolates
the hot core_list_find() loop from its large LTO caller and schedules
core_list_reverse() for the target's dual-issue rules.  It deliberately fails
when the expected upstream source shape changes.
"""

from __future__ import annotations

import argparse
from pathlib import Path


ORIGINAL = '''\
list_head *
core_list_find(list_head *list, list_data *info)
{
    if (info->idx >= 0)
    {
        while (list && (list->info->idx != info->idx))
            list = list->next;
        return list;
    }
    else
    {
        while (list && ((list->info->data16 & 0xff) != info->data16))
            list = list->next;
        return list;
    }
}'''


REPLACEMENT = '''\
/* LTO otherwise spills the search key inside the per-node traversal loop. */
__attribute__((noinline))
list_head *
core_list_find(list_head *list, list_data *info)
{
    if (info->idx >= 0)
    {
        ee_s16 target = info->idx;
        list_head *candidate;
        list_head *next_first;
        list_head *next_second;
        list_data *candidate_info;
        ee_s16 field;
        ee_s16 compare_target;

        /* Keep the two-node unroll and dependency spacing.  The two pointer
         * loads issue on separate cycles in the current one-memory-op model. */
        __asm__ volatile (
            "beqz %[list], 9f\\n\\t"
            "1:\\n\\t"
            "lw %[candidate_info], 4(%[list])\\n\\t"
            "lw %[next_first], 0(%[list])\\n\\t"
            "mv %[compare_target], %[target]\\n\\t"
            "lh %[field], 2(%[candidate_info])\\n\\t"
            "mv %[candidate], %[list]\\n\\t"
            "beqz %[next_first], 4f\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "lw %[candidate_info], 4(%[next_first])\\n\\t"
            "lw %[next_second], 0(%[next_first])\\n\\t"
            "mv %[compare_target], %[target]\\n\\t"
            "lh %[field], 2(%[candidate_info])\\n\\t"
            "mv %[candidate], %[next_first]\\n\\t"
            "beqz %[next_second], 5f\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "mv %[list], %[next_second]\\n\\t"
            "j 1b\\n\\t"
            "4:\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "li %[list], 0\\n\\t"
            "j 9f\\n\\t"
            "5:\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "li %[list], 0\\n\\t"
            "j 9f\\n\\t"
            "8:\\n\\t"
            "mv %[list], %[candidate]\\n\\t"
            "9:"
            : [list] "+&r" (list), [candidate] "=&r" (candidate),
              [next_first] "=&r" (next_first),
              [next_second] "=&r" (next_second),
              [candidate_info] "=&r" (candidate_info),
              [field] "=&r" (field),
              [compare_target] "=&r" (compare_target)
            : [target] "r" (target)
            : "memory");
    }
    else
    {
        ee_s16 target = info->data16;
        list_head *candidate;
        list_head *next_first;
        list_head *next_second;
        list_data *candidate_info;
        ee_u32 field;
        ee_u32 compare_target;

        __asm__ volatile (
            "beqz %[list], 9f\\n\\t"
            "1:\\n\\t"
            "lw %[candidate_info], 4(%[list])\\n\\t"
            "lw %[next_first], 0(%[list])\\n\\t"
            "mv %[compare_target], %[target]\\n\\t"
            "lbu %[field], 0(%[candidate_info])\\n\\t"
            "mv %[candidate], %[list]\\n\\t"
            "beqz %[next_first], 4f\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "lw %[candidate_info], 4(%[next_first])\\n\\t"
            "lw %[next_second], 0(%[next_first])\\n\\t"
            "mv %[compare_target], %[target]\\n\\t"
            "lbu %[field], 0(%[candidate_info])\\n\\t"
            "mv %[candidate], %[next_first]\\n\\t"
            "beqz %[next_second], 5f\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "mv %[list], %[next_second]\\n\\t"
            "j 1b\\n\\t"
            "4:\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "li %[list], 0\\n\\t"
            "j 9f\\n\\t"
            "5:\\n\\t"
            "beq %[field], %[compare_target], 8f\\n\\t"
            "li %[list], 0\\n\\t"
            "j 9f\\n\\t"
            "8:\\n\\t"
            "mv %[list], %[candidate]\\n\\t"
            "9:"
            : [list] "+&r" (list), [candidate] "=&r" (candidate),
              [next_first] "=&r" (next_first),
              [next_second] "=&r" (next_second),
              [candidate_info] "=&r" (candidate_info),
              [field] "=&r" (field),
              [compare_target] "=&r" (compare_target)
            : [target] "r" ((ee_s32)target)
            : "memory");
    }
    return list;
}'''


REVERSE_ORIGINAL = '''\
list_head *
core_list_reverse(list_head *list)
{
    list_head *next = NULL, *tmp;
    while (list)
    {
        tmp        = list->next;
        list->next = next;
        next       = list;
        list       = tmp;
    }
    return next;
}'''


REVERSE_REPLACEMENT = '''\
list_head *
core_list_reverse(list_head *list)
{
    list_head *previous = NULL;
    list_head *next;
    list_head *current;

    if (!list)
        return previous;

    /* Fix the six-instruction loop order so each consecutive pair matches a
     * legal Mundus issue group: load+ALU, store+ALU, then ALU+branch.  Keep
     * the branch independent of its slot-0 ALU: the current RTL deliberately
     * serializes an ALU0 result consumed by a same-group slot-1 branch. */
    __asm__ volatile (
        "1:\\n\\t"
        "lw %[next], 0(%[list])\\n\\t"
        "mv %[current], %[list]\\n\\t"
        "sw %[previous], 0(%[current])\\n\\t"
        "mv %[list], %[next]\\n\\t"
        "mv %[previous], %[current]\\n\\t"
        "bnez %[list], 1b"
        : [list] "+&r" (list), [previous] "+&r" (previous),
          [next] "=&r" (next), [current] "=&r" (current)
        :
        : "memory");
    return previous;
}'''


def rewrite(source: str) -> str:
    if source.count(ORIGINAL) != 1:
        raise ValueError("expected exactly one upstream core_list_find body")
    if source.count(REVERSE_ORIGINAL) != 1:
        raise ValueError("expected exactly one upstream core_list_reverse body")
    source = source.replace(ORIGINAL, REPLACEMENT, 1)
    return source.replace(REVERSE_ORIGINAL, REVERSE_REPLACEMENT, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_text(encoding="utf-8")
    generated = rewrite(original)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"generated Mundus-scheduled list source: {args.output}")


if __name__ == "__main__":
    main()
