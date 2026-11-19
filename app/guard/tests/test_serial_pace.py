"""上位机 pace 逻辑的单测（真实板第一次上板就栽在这里）。"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from host.golden.board_proto import output_thresholds  # noqa: E402
from tools.serial_host import next_chunk_end  # noqa: E402

SAMPLE = (Path(__file__).resolve().parent.parent / "examples" / "sample.txt").read_bytes()


class TestPaceChunking(unittest.TestCase):
    def test_first_byte_always_allowed(self) -> None:
        """发第一个字节不能有任何回读前提，否则死锁（2026-11-17 真板事故）。"""
        gates = output_thresholds(SAMPLE)
        self.assertEqual(gates[0], 0)
        self.assertGreater(next_chunk_end(gates, 0, 0), 0)

    def test_respects_chunk_limit(self) -> None:
        gates = [0] * (len(SAMPLE) + 1)
        self.assertEqual(next_chunk_end(gates, 0, 10 ** 6, chunk=64), 64)
        self.assertEqual(next_chunk_end(gates, 60, 10 ** 6, chunk=64), 124)

    def test_gate_blocks_write(self) -> None:
        gates = [0, 0, 500, 900] + [0] * 10
        # 第 2 个字节要先收到 500 B
        self.assertEqual(next_chunk_end(gates, 0, 0), 2)
        self.assertEqual(next_chunk_end(gates, 0, 500), 3)
        self.assertEqual(next_chunk_end(gates, 0, 900, chunk=64), len(gates) - 1)

    def test_never_runs_past_end(self) -> None:
        gates = [0] * (len(SAMPLE) + 1)
        self.assertEqual(next_chunk_end(gates, len(SAMPLE) - 1, 10 ** 6), len(SAMPLE))

    def test_simulated_run_terminates(self) -> None:
        """模拟"回读按期望流增长"时的发送过程：必须能全部发完。"""
        gates = output_thresholds(SAMPLE)
        i = 0
        for _ in range(10 * len(SAMPLE) + 100):
            # 假设回读已经追上到第 i+32 个输入字节对应的量
            avail = gates[min(i + 32, len(SAMPLE))]
            j = next_chunk_end(gates, i, avail)
            if j == i:
                avail = gates[i]
                j = next_chunk_end(gates, i, avail)
                self.assertGreater(j, i)
            i = j
            if i >= len(SAMPLE):
                break
        self.assertEqual(i, len(SAMPLE))


if __name__ == "__main__":
    unittest.main()
