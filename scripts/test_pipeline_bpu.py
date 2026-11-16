#!/usr/bin/env python3
"""Check one-cycle BimodalRas predictions against an independent table model."""

import argparse
from pathlib import Path
import random
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def pack(fields):
    value = 0
    for width, item in fields:
        value = (value << width) | (int(item) & ((1 << width) - 1))
    return value


def vectors(width, loop_enabled):
    rng = random.Random(20261117 + width)
    entries = 1 << width
    table = [dict(valid=False, tag=None, target=None, counter=1, ret=False)
             for _ in range(entries)]
    loops = [dict(valid=False, tag=None, trip=0, count=0, confidence=0, pred=True)
             for _ in range(16)]

    def step(reset=0, request=1, pc=0x80000000, update=0, update_pc=0x80000000,
             is_return=0, is_branch=0, target=0x80000100, taken=0):
        entry = table[(pc >> 2) & (entries - 1)]
        hit = entry['valid'] and entry['tag'] == pc >> (width + 2)
        direction = entry['counter'] >= 2
        loop = loops[(pc >> 2) & 15]
        if (loop_enabled and loop['valid'] and loop['tag'] == pc >> 6
                and loop['confidence'] >= 2):
            direction = loop['pred']
        # Snapshot the pre-write entry: a same-address update becomes visible
        # on the following query, including replacement by an aliased tag.
        expected = pack([(1, request and not reset), (32, pc), (1, hit),
                         (1, hit and direction), (1, hit and entry['ret']),
                         (1, entry['target'] is not None),
                         (32, 0 if entry['target'] is None else entry['target'])])
        if reset:
            for item in table:
                item['valid'] = False
                item['counter'] = 1
            for item in loops:
                item['valid'] = False
        elif update:
            item = table[(update_pc >> 2) & (entries - 1)]
            if item['valid']:
                item['counter'] = max(0, min(3, item['counter'] + (1 if taken else -1)))
            elif taken:
                item['counter'] = 2
            if taken:
                item.update(valid=True, tag=update_pc >> (width + 2),
                            target=target, ret=bool(is_return))
            if loop_enabled and is_branch:
                item = loops[(update_pc >> 2) & 15]
                if item['valid'] and item['tag'] == update_pc >> 6:
                    if taken:
                        item['count'] = min(65535, item['count'] + 1)
                        item['pred'] = not (item['trip'] != 0 and item['count'] == item['trip'])
                    else:
                        if item['count'] != 0 and item['count'] == item['trip']:
                            item['confidence'] = min(3, item['confidence'] + 1)
                        else:
                            item['trip'] = item['count']
                            item['confidence'] = 0
                        item['count'] = 0
                        item['pred'] = True
                elif taken and target < update_pc:
                    item.update(valid=True, tag=update_pc >> 6, trip=0, count=1,
                                confidence=0, pred=True)
        inputs = pack([(1, reset), (1, request), (32, pc), (1, update),
                       (32, update_pc), (1, is_return), (1, is_branch),
                       (32, target), (1, taken)])
        return f'{(inputs << 69) | expected:043x}'

    yield step(reset=1)
    # Exercise every index, saturation in both directions, collisions, return
    # metadata and a target/tag replacement at the same direct-mapped index.
    for index in range(entries):
        pc = 0x80000000 + 4 * index
        yield step(pc=pc)
        for taken in [1, 1, 1, 1, 0, 0, 0, 0, 1, 1]:
            yield step(pc=pc, update=1, update_pc=pc, target=pc + 0x400,
                       is_return=index % 2, taken=taken)
        alias = pc + 4 * entries
        yield step(pc=pc, update=1, update_pc=alias, target=alias + 0x100,
                   is_return=1, taken=1)
        yield step(pc=pc)
        yield step(pc=alias)
        yield step(request=0, pc=alias, update=1, update_pc=alias, taken=0)
        yield step(pc=alias)
    # Train a backward loop until it overrides the bimodal direction.
    pc = 0x80001000
    for _ in range(8):
        for taken in [1, 1, 1, 0]:
            yield step(pc=pc, update=1, update_pc=pc, is_branch=1,
                       target=pc - 16, taken=taken)
            yield step(pc=pc)
    for cycle in range(3000):
        pc = 0x80000000 + 4 * rng.randrange(entries * 4)
        update_pc = pc if cycle % 3 == 0 else 0x80000000 + 4 * rng.randrange(entries * 4)
        yield step(reset=cycle in (777, 1777), request=rng.randrange(2), pc=pc,
                   update=rng.randrange(2), update_pc=update_pc,
                   target=0x80000000 + 4 * rng.randrange(entries * 8),
                   is_return=rng.randrange(2), is_branch=rng.randrange(2),
                   taken=rng.randrange(2))


TB = r'''`timescale 1ns/1ps
module tb_pipeline_bpu;
  parameter integer BTB_WIDTH = 4;
  parameter integer CASES = 1;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst = 1, req_valid = 0, update_en = 0;
  reg [31:0] fetch_pc = 0, update_pc = 0, update_target = 0;
  reg update_is_return = 0, update_is_branch = 0, actual_taken = 0;
  wire resp_valid, pred_taken, btb_hit, pred_is_return;
  wire [31:0] resp_pc, pred_target_pc;
  reg [170:0] cases [0:CASES-1];
  reg [68:0] previous = 0;
  string vector_file;
  integer row;
  BimodalRas #(.BTB_WIDTH(BTB_WIDTH)) dut (
    .clk, .rst, .req_valid, .fetch_pc, .resp_valid, .resp_pc,
    .pred_taken, .pred_target_pc, .btb_hit, .pred_is_return,
    .update_en, .update_pc, .update_is_return,
`ifdef CONFIG_BRANCH_LOOP_PREDICTOR
    .update_is_branch,
`endif
    .update_target, .actual_taken
  );
  task automatic check_outputs(input reg [68:0] expected);
    reg valid, hit, taken, ret, target_known;
    reg [31:0] pc, target;
    {valid, pc, hit, taken, ret, target_known, target} = expected;
    if (resp_valid !== valid) $fatal(1, "row %0d: response latency mismatch", row);
    if (valid) begin
      if ({resp_pc, btb_hit, pred_taken, pred_is_return} !== {pc, hit, taken, ret})
        $fatal(1, "row %0d: prediction mismatch pc=%08x hit/taken/ret=%b%b%b expected=%b%b%b",
               row, resp_pc, btb_hit, pred_taken, pred_is_return, hit, taken, ret);
      if (target_known && pred_target_pc !== target)
        $fatal(1, "row %0d: target mismatch got=%08x expected=%08x",
               row, pred_target_pc, target);
    end
  endtask
  initial begin
    if (!$value$plusargs("VECTORS=%s", vector_file)) $fatal(1, "missing vectors");
    $readmemh(vector_file, cases);
    repeat (2) @(negedge clk);
    for (row = 0; row < CASES; row++) begin
      {rst, req_valid, fetch_pc, update_en, update_pc, update_is_return,
       update_is_branch, update_target, actual_taken} = cases[row][170:69];
      #1;
      check_outputs(previous); // Inputs must not change a registered response.
      @(posedge clk);
      #1;
      check_outputs(cases[row][68:0]);
      previous = cases[row][68:0];
      @(negedge clk);
    end
    $display("BPU PASS: width=%0d cycles=%0d one-cycle reads and old-data collisions", BTB_WIDTH, CASES);
    $finish;
  end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path,
                        default=ROOT / 'rtl/pipeline/core/vsrc/Mundus/BimodalRas.v')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/pipeline_bpu')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    tb = args.out / 'tb_pipeline_bpu.sv'
    tb.write_text(TB)
    for width in (2, 4, 6):
        for loop in (False, True):
            name = f'w{width}_loop{int(loop)}'
            rows = list(vectors(width, loop))
            vector_file = args.out / f'{name}.hex'
            vector_file.write_text('\n'.join(rows) + '\n')
            binary = args.out / f'{name}.vvp'
            subprocess.run([
                'iverilog', '-g2012', '-s', 'tb_pipeline_bpu',
                '-I', str(ROOT / 'rtl/pipeline/include'),
                f'-Ptb_pipeline_bpu.BTB_WIDTH={width}', f'-Ptb_pipeline_bpu.CASES={len(rows)}',
                *(['-DCONFIG_BRANCH_LOOP_PREDICTOR'] if loop else []),
                '-o', str(binary), str(args.rtl), str(tb),
            ], check=True, cwd=ROOT)
            result = subprocess.run(['vvp', str(binary), f'+VECTORS={vector_file}'],
                                    check=True, capture_output=True, text=True, cwd=ROOT)
            (args.out / f'{name}.log').write_text(result.stdout)
            print(f'loop={int(loop)} {result.stdout}', end='', flush=True)


if __name__ == '__main__':
    main()
