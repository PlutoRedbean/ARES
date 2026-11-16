#!/usr/bin/env python3
"""Check both application GEMM cores against signed Python matrix products."""

from pathlib import Path
import random
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def pack(values, width):
    mask = (1 << width) - 1
    value = sum((item & mask) << (width * i) for i, item in enumerate(values))
    return f"{width * len(values)}'h{value:0{width * len(values) // 4}x}"


def vectors():
    rng = random.Random(20261104)
    zero = [0] * 16
    identity = [int(r == c) for r in range(4) for c in range(4)]
    limits = [-128, 127, -1, 0] * 4
    corner = zero.copy()
    corner[-1] = -128
    first_row = [127, -128, 3, -4] + [0] * 12
    cases = [
        ([1] * 16, [1] * 16, zero),
        (zero, limits, [0x7FFFFFFF, -0x80000000, -1, 0] * 4),
        (identity, limits, zero),
        ([-128] * 16, [-128] * 16, [0x7FFFFFFF] * 16),
        (corner, [127] * 16, zero),
        (corner, corner, zero),  # Only the very last PE product is nonzero.
        (first_row, limits, [r * 4 + c for r in range(4) for c in range(4)]),
    ]
    for _ in range(128):
        cases.append((
            [rng.randrange(-128, 128) for _ in range(16)],
            [rng.randrange(-128, 128) for _ in range(16)],
            [rng.randrange(-0x80000000, 0x80000000) for _ in range(16)],
        ))
    for case_id, (a, b, initial) in enumerate(cases):
        expected = [
            initial[r * 4 + c]
            + sum(a[r * 4 + k] * b[k * 4 + c] for k in range(4))
            for r in range(4) for c in range(4)
        ]
        yield (
            f"    run_case({case_id}, {pack(a, 8)}, {pack(b, 8)}, "
            f"{pack(initial, 32)}, {pack(expected, 32)}, {case_id % 4});"
        )


TB = """`timescale 1ns/1ps
module tb_minitensor_gemm;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst = 1, cmd_valid = 0, cmd_ready;
  logic result_valid, result_ready = 0;
  logic [127:0] cmd_a_tile = 0, cmd_b_tile = 0;
  logic [511:0] cmd_acc_init = 0, result_data;
  integer cases_checked = 0, outputs_checked = 0;

  logic pe_rst = 1, pe_clear = 0, pe_step = 0;
  logic signed [7:0] pe_a = 0, pe_b = 0, pe_a_out, pe_b_out;
  logic signed [31:0] pe_init = 0, pe_acc;
  logic signed [31:0] ref_acc = 0;
  logic signed [15:0] ref_product = 0;
  logic signed [7:0] ref_a = 0, ref_b = 0;
  bit ref_valid = 0;
  integer pe_checks = 0;
  tensor_pe pe (
    .clk, .rst(pe_rst), .clear(pe_clear), .step(pe_step),
    .acc_init(pe_init), .a_in(pe_a), .b_in(pe_b),
    .a_out(pe_a_out), .b_out(pe_b_out), .acc_out(pe_acc)
  );

  task automatic pe_tick(
    input bit reset, clear_acc, issue,
    input logic signed [7:0] a, b,
    input logic signed [31:0] initial_acc
  );
    @(negedge clk);
    pe_rst = reset;
    pe_clear = clear_acc;
    pe_step = issue;
    pe_a = a;
    pe_b = b;
    pe_init = initial_acc;
    if (reset || clear_acc) begin
      ref_acc = initial_acc;
      ref_a = 0;
      ref_b = 0;
      ref_valid = 0;
    end else begin
      if (ref_valid) ref_acc = ref_acc + {{16{ref_product[15]}}, ref_product};
      if (issue) begin
        ref_a = a;
        ref_b = b;
      end
      ref_valid = issue;
    end
    ref_product = a * b;
    @(posedge clk);
    #1;
    if (pe_acc !== ref_acc || pe_a_out !== ref_a || pe_b_out !== ref_b)
      $fatal(1, "PE cycle %0d: acc=%0d expected=%0d", pe_checks, pe_acc, ref_acc);
    pe_checks++;
  endtask

  task automatic abort_case(input integer clocks_after_accept);
    @(negedge clk);
    cmd_valid = 1;
    cmd_a_tile = '1;
    cmd_b_tile = '1;
    cmd_acc_init = '0;
    result_ready = 1;
    @(negedge clk);
    cmd_valid = 0;
    repeat (clocks_after_accept) @(negedge clk);
    rst = 1;
    @(posedge clk);
    #1;
    if (result_valid || !cmd_ready)
      $fatal(1, "reset failed at compute cycle %0d", clocks_after_accept);
    @(negedge clk);
    rst = 0;
    repeat (2) begin
      @(posedge clk);
      #1;
      if (result_valid || !cmd_ready)
        $fatal(1, "stale result after reset");
    end
  endtask

  tensor_gemm_core dut (
    .clk, .rst, .cmd_valid, .cmd_ready, .cmd_a_tile, .cmd_b_tile,
    .cmd_acc_init, .result_valid, .result_ready, .result_data
  );

  task automatic run_case(
    input integer case_id,
    input logic [127:0] a, b,
    input logic [511:0] initial_acc, expected,
    input integer hold_cycles
  );
    integer compute_cycles;
    @(negedge clk);
    if (!cmd_ready) $fatal(1, "case %0d: core not ready", case_id);
    cmd_a_tile = a;
    cmd_b_tile = b;
    cmd_acc_init = initial_acc;
    cmd_valid = 1;
    result_ready = (hold_cycles == 0);
    @(posedge clk);
    #1;
    @(negedge clk);
    cmd_valid = 0;
    // Change every input after acceptance to verify operand latching.
    cmd_a_tile = ~a;
    cmd_b_tile = ~b;
    cmd_acc_init = ~initial_acc;
    compute_cycles = 0;
    while (!result_valid) begin
      @(posedge clk);
      #1;
      compute_cycles++;
      if (compute_cycles > 16) $fatal(1, "case %0d: timeout", case_id);
    end
    for (int i = 0; i < 16; i++) begin
      if (result_data[32*i +: 32] !== expected[32*i +: 32])
        $fatal(1, "case %0d output[%0d][%0d]: got %0d expected %0d",
          case_id, i/4, i%4, $signed(result_data[32*i +: 32]),
          $signed(expected[32*i +: 32]));
      outputs_checked++;
    end
    if (compute_cycles != 11)
      $fatal(1, "case %0d: got %0d compute cycles expected 11",
        case_id, compute_cycles);
    repeat (hold_cycles) begin
      @(posedge clk);
      #1;
      if (!result_valid || cmd_ready || result_data !== expected)
        $fatal(1, "case %0d: result changed under backpressure", case_id);
    end
    @(negedge clk);
    result_ready = 1;
    @(posedge clk);
    #1;
    if (result_valid || !cmd_ready)
      $fatal(1, "case %0d: result handshake failed", case_id);
    cases_checked++;
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 0;
    // Bubbles must drain a pending product once; clear/reset must discard it.
    pe_tick(1, 0, 0, 0, 0, 32'sh7fffffff);
    pe_tick(0, 0, 1, -128, -128, 0);
    pe_tick(0, 0, 1, 127, -128, 0);
    pe_tick(0, 0, 0, 17, 19, 0);
    pe_tick(0, 0, 0, 23, 29, 0);
    pe_tick(0, 0, 1, -7, 11, 0);
    pe_tick(0, 1, 1, 100, 100, -37);
    pe_tick(0, 0, 0, 0, 0, 0);
    pe_tick(0, 0, 1, -128, 127, 0);
    pe_tick(1, 0, 0, 0, 0, 42);
    pe_tick(0, 0, 0, 0, 0, 0);
    for (int cycle = 0; cycle < 100; cycle++)
      pe_tick(0, cycle == 53, (cycle % 3) != 0,
              8'(cycle * 17), 8'(cycle * 29), 32'sh80000000);
    pe_tick(0, 0, 0, 0, 0, 0);
    pe_tick(0, 0, 0, 0, 0, 0);
    for (int cycle = 0; cycle <= 11; cycle++)
      abort_case(cycle);
__CASES__
    $display("GEMM PASS: %0d cases, %0d output checks, %0d PE cycles, 12 reset phases",
      cases_checked, outputs_checked, pe_checks);
    $finish;
  end
endmodule
"""


def main():
    testbench = TB.replace("__CASES__", "\n".join(vectors()))
    for application in ("llm", "gesture"):
        build = ROOT / "build" / "minitensor_gemm" / application
        build.mkdir(parents=True, exist_ok=True)
        tb_path = build / "tb_minitensor_gemm.sv"
        tb_path.write_text(testbench)
        rtl = ROOT / "app" / application / "rtl" / "minitensor" / "tensor"
        sources = [
            rtl / "tensor_pkg.sv",
            rtl / "MXU/Systolic_Array/tensor_pe.sv",
            rtl / "MXU/Systolic_Array/tensor_systolic_array.sv",
            rtl / "MXU/INT8_GEMM/tensor_gemm_core.sv",
            tb_path,
        ]
        log_path = build / "build.log"
        print(f"Building {application}; log: {log_path}", flush=True)
        with log_path.open("w") as log:
            subprocess.run([
                "verilator", "--binary", "--timing",
                "--top-module", "tb_minitensor_gemm",
                "--Mdir", str(build / "obj"),
                *(str(path) for path in sources),
            ], check=True, stdout=log, stderr=subprocess.STDOUT)
        result = subprocess.run(
            [str(build / "obj" / "Vtb_minitensor_gemm")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        (build / "result.log").write_text(result.stdout)
        print(f"{application}: {result.stdout}", end="", flush=True)
        result.check_returncode()


if __name__ == "__main__":
    main()
